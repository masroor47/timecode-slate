#if os(iOS)
import AVFoundation
import Foundation

/// Captures audio from whatever input is attached and feeds it to an LTCDecoder,
/// preserving the host-clock timing needed for an accurate jam.
///
/// Two details here matter more than all the rest:
///
/// 1. **`.measurement` mode.** iOS applies automatic gain control, noise
///    suppression and voice-band EQ to microphone input by default. All three
///    are actively hostile to LTC — AGC pumps the level, noise suppression
///    treats a square wave as noise. `.measurement` mode turns the whole chain
///    off and gives us raw samples.
///
/// 2. **Host time, not buffer arrival time.** Each tap buffer carries an
///    `AVAudioTime` describing when its *first sample* was captured, on the same
///    mach timebase as `CACurrentMediaTime()`. Anchoring to that, rather than
///    to when our callback happened to run, keeps jam accuracy independent of
///    buffer size and scheduling jitter.
public final class LTCAudioInput {

    public enum InputError: Error, LocalizedError {
        case sessionConfigurationFailed(Error)
        case engineStartFailed(Error)
        case noInputAvailable

        public var errorDescription: String? {
            switch self {
            case .sessionConfigurationFailed(let e): return "Audio session setup failed: \(e.localizedDescription)"
            case .engineStartFailed(let e): return "Audio engine failed to start: \(e.localizedDescription)"
            case .noInputAvailable: return "No audio input is available."
            }
        }
    }

    /// Delivered on every decoded frame, with `hostTime` giving the exact
    /// moment that frame began — ready to hand straight to `TimecodeClock.jam`.
    public struct Reading: Sendable {
        public let result: LTCDecodeResult
        public let hostTime: Double
    }

    public var onReading: ((Reading) -> Void)?
    /// Peak level of the most recent buffer, 0...1, for a signal meter.
    public var onLevel: ((Float) -> Void)?
    /// Fired whenever the active input changes, with its new description.
    /// The interesting case is plugging the timecode cable in while the app is
    /// already listening.
    public var onRouteChange: ((String) -> Void)?

    private let engine = AVAudioEngine()
    public private(set) var decoder: LTCDecoder?
    public private(set) var isRunning = false

    /// Sample index in the decoder's stream at the start of the current buffer.
    private var bufferStartSampleIndex: Double = 0
    private var bufferStartHostTime: Double = 0
    private var routeObserver: NSObjectProtocol?

    public init() {}

    /// Ask for microphone access. Without this the first `start()` fails with an
    /// opaque engine error rather than anything a user could act on.
    public static func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Pin the expected project rate, or nil to auto-detect.
    public var assumedRate: TimecodeRate? {
        didSet { decoder?.assumedRate = assumedRate }
    }

    public func start() throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // .measurement disables AGC / noise suppression / voice EQ.
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(48000)
            // Short buffers reduce latency; timing accuracy does not depend on
            // this, but responsiveness of the lock indicator does.
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            throw InputError.sessionConfigurationFailed(error)
        }

        preferExternalInput(session: session)

        try startEngine()
        observeRouteChanges()
        isRunning = true
    }

    /// Build the decoder and tap for whatever the current route offers, and run.
    /// Split out from `start()` because a route change has to redo all of it:
    /// the new device may well report a different sample rate.
    private func startEngine() throws {
        let input = engine.inputNode
        // Ask for no processing on the input node as well, belt and braces.
        try? input.setVoiceProcessingEnabled(false)

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw InputError.noInputAvailable
        }

        // Run the decoder at the hardware rate rather than resampling: fewer
        // moving parts, and no interpolation smearing the edges we time from.
        let decoder = LTCDecoder(sampleRate: format.sampleRate)
        decoder.assumedRate = assumedRate
        decoder.onFrame = { [weak self] result in
            guard let self else { return }
            // The frame may have begun in an earlier buffer; a negative offset
            // is fine because the sample clock is continuous across buffers.
            let offsetSamples = result.startSampleIndex - self.bufferStartSampleIndex
            let hostTime = self.bufferStartHostTime + offsetSamples / format.sampleRate
            self.onReading?(Reading(result: result, hostTime: hostTime))
        }
        self.decoder = decoder

        var runningIndex: Double = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self, let channel = buffer.floatChannelData else { return }

            // Take channel 0 rather than summing: if a stereo source carries the
            // same signal inverted on the other leg, summing would cancel it.
            let samples = UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))

            self.bufferStartSampleIndex = runningIndex
            self.bufferStartHostTime = AVAudioTime.seconds(forHostTime: when.hostTime)
            runningIndex += Double(buffer.frameLength)

            var peak: Float = 0
            for s in samples { peak = max(peak, abs(s)) }
            self.onLevel?(peak)

            decoder.process(samples)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw InputError.engineStartFailed(error)
        }
    }

    public func stop() {
        guard isRunning else { return }
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
    }

    // MARK: - Route changes

    /// The timecode cable is normally plugged in *after* the app is already
    /// listening. Without this, the session keeps the built-in mic and the
    /// external input is silently ignored.
    private func observeRouteChanges() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            switch AVAudioSession.RouteChangeReason(rawValue: raw ?? 0) {
            case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange, .override:
                self.rebuildForCurrentRoute()
            default:
                break
            }
        }
    }

    /// Tear the tap down and rebuild it against the new route. The decoder is
    /// recreated rather than reused because the sample rate may have changed;
    /// that costs nothing, since every frame is timestamped from the buffer's
    /// own host time rather than from a running total.
    private func rebuildForCurrentRoute() {
        guard isRunning else { return }
        let session = AVAudioSession.sharedInstance()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        preferExternalInput(session: session)

        do {
            try startEngine()
            onRouteChange?(currentInputDescription)
        } catch {
            isRunning = false
            onRouteChange?(error.localizedDescription)
        }
    }

    /// Prefer a wired or USB input over the built-in microphone, since that is
    /// where the timecode will be arriving.
    private func preferExternalInput(session: AVAudioSession) {
        guard let inputs = session.availableInputs else { return }
        let preferredOrder: [AVAudioSession.Port] = [.usbAudio, .headsetMic, .lineIn]
        for port in preferredOrder {
            if let match = inputs.first(where: { $0.portType == port }) {
                try? session.setPreferredInput(match)
                return
            }
        }
    }

    /// Human-readable description of the current input, for the UI.
    public var currentInputDescription: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let input = route.inputs.first else { return "No input" }
        return input.portName
    }

    /// True when the active input is something other than the built-in mic.
    public var isExternalInputConnected: Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let input = route.inputs.first else { return false }
        return input.portType != .builtInMic
    }
}
#endif
