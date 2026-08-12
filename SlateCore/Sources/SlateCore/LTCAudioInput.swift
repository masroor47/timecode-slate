import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
#endif

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
///
/// Runs on macOS as well as iOS, so the input path can be exercised against
/// real timecode hardware from the command line — see the `ltclisten` tool.
/// Everything from the engine down is shared; only input *selection* differs,
/// because iOS chooses ports through `AVAudioSession` and macOS chooses devices
/// through CoreAudio, and there is no honest way to paper over that.
public final class LTCAudioInput {

    public enum InputError: Error, LocalizedError {
        case sessionConfigurationFailed(Error)
        case engineStartFailed(Error)
        case noInputAvailable
        case deviceSelectionFailed(String, OSStatus)

        public var errorDescription: String? {
            switch self {
            case .sessionConfigurationFailed(let e): return "Audio session setup failed: \(e.localizedDescription)"
            case .engineStartFailed(let e): return "Audio engine failed to start: \(e.localizedDescription)"
            case .noInputAvailable: return "No audio input is available."
            case .deviceSelectionFailed(let name, let status):
                return "Could not select input device '\(name)' (OSStatus \(status))."
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
    /// What `preferExternalInput` last managed to do, verbatim, for the
    /// diagnostics screen.
    public private(set) var preferredInputOutcome = "not attempted"

    /// Subtract the hardware capture latency from each frame's host time.
    ///
    /// Worth being exact about what this does and does not correct, because the
    /// two are easy to conflate. A buffer's `AVAudioTime` says when its first
    /// sample was *captured*, so however long the buffer then sat around before
    /// reaching us is already accounted for — buffer size and scheduling jitter
    /// do not bias the jam, which is the whole reason the timestamp is used
    /// instead of the callback's arrival time.
    ///
    /// What the timestamp cannot know is the delay between the signal arriving
    /// at the physical connector and the converter timestamping it. That is
    /// hardware, the driver reports it separately, and it is a genuine constant
    /// bias: without this, the jammed clock sits that far behind the source.
    ///
    /// Small — a millisecond or two, well under a frame at any rate — but it is
    /// free to remove and it only ever points one way.
    public var compensateInputLatency = true

    /// Hardware capture latency for the current input, in seconds.
    public private(set) var inputLatencySeconds: Double = 0

    /// Frames in the most recent tap buffer. The requested size is a hint that
    /// platforms feel free to ignore, so this is the only honest figure.
    public private(set) var observedBufferFrames: Int = 0

    /// Sample index in the decoder's stream at the start of the current buffer.
    private var bufferStartSampleIndex: Double = 0
    private var bufferStartHostTime: Double = 0
    private var routeObserver: NSObjectProtocol?

    /// Capture continuity. A gap in the driver's sample numbering means audio
    /// we never received, which corrupts whichever frame straddled it.
    private var expectedSampleTime: Int64?
    public private(set) var dropEventCount = 0
    public private(set) var droppedFrameCount: Int64 = 0
    /// Fired with the number of frames missed, for a harness that wants to say so.
    public var onDrop: ((Int64) -> Void)?

    public init() {}

    /// Ask for microphone access. Without this the first `start()` fails with an
    /// opaque engine error rather than anything a user could act on.
    public static func requestPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    #if os(macOS)
    /// Substring of the CoreAudio device name to capture from; nil uses the
    /// system default input. macOS has no `AVAudioSession`, so the timecode
    /// interface has to be named rather than merely preferred.
    public var preferredDeviceMatch: String?

    /// The device `start()` actually selected.
    public private(set) var selectedDevice: AudioInputDevice?
    #endif

    /// Pin the expected project rate, or nil to auto-detect.
    public var assumedRate: TimecodeRate? {
        didSet { decoder?.assumedRate = assumedRate }
    }

    public func start() throws {
        guard !isRunning else { return }

        #if os(iOS)
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
        measureInputLatency()

        try startEngine()
        observeRouteChanges()
        #else
        try selectDevice()
        measureInputLatency()
        try startEngine()
        #endif

        isRunning = true
    }

    /// Ask the platform what the capture hardware's latency is.
    ///
    /// Deliberately *excludes* the safety offset and the buffer size, though
    /// both appear in the driver's numbers. Those describe when the audio
    /// reaches us, which the buffer timestamp already accounts for. Including
    /// them here would double-count and push the jam early.
    private func measureInputLatency() {
        #if os(iOS)
        inputLatencySeconds = AVAudioSession.sharedInstance().inputLatency
        #else
        guard let device = selectedDevice else { inputLatencySeconds = 0; return }
        let budget = MacAudioDevices.latencyBudget(device.id)
        inputLatencySeconds = Double(budget.deviceLatency) / budget.sampleRate
        #endif
    }

    #if os(macOS)
    /// Point the engine's input unit at the chosen device. Must happen before
    /// the input format is read, or the format describes the old device.
    private func selectDevice() throws {
        let device = preferredDeviceMatch.flatMap { MacAudioDevices.input(matching: $0) }
            ?? MacAudioDevices.defaultInput()
        guard let device else { throw InputError.noInputAvailable }

        guard let unit = engine.inputNode.audioUnit else {
            throw InputError.noInputAvailable
        }
        var id = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw InputError.deviceSelectionFailed(device.name, status)
        }
        selectedDevice = device
        preferredInputOutcome = "selected \(device.name) [\(device.uid)]"
    }
    #endif

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
            var hostTime = self.bufferStartHostTime + offsetSamples / format.sampleRate
            if self.compensateInputLatency {
                // The frame reached the connector this much before the
                // converter timestamped it.
                hostTime -= self.inputLatencySeconds
            }
            self.onReading?(Reading(result: result, hostTime: hostTime))
        }
        self.decoder = decoder

        var runningIndex: Double = 0
        expectedSampleTime = nil
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self, let channel = buffer.floatChannelData else { return }

            // Take channel 0 rather than summing: if a stereo source carries the
            // same signal inverted on the other leg, summing would cancel it.
            let samples = UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))

            // The driver numbers every frame it ever captured, so a jump larger
            // than this buffer is audio that never reached us. Worth counting:
            // dropped capture looks exactly like a mangled analogue signal —
            // frames failing to decode for no visible reason — and without this
            // the two are indistinguishable. It cost a full debugging session
            // once already.
            if when.isSampleTimeValid {
                if let expected = self.expectedSampleTime, when.sampleTime > expected {
                    let missing = when.sampleTime - expected
                    self.dropEventCount += 1
                    self.droppedFrameCount += missing
                    self.onDrop?(missing)
                }
                self.expectedSampleTime = when.sampleTime + Int64(buffer.frameLength)
            }

            self.bufferStartSampleIndex = runningIndex
            self.bufferStartHostTime = AVAudioTime.seconds(forHostTime: when.hostTime)
            self.observedBufferFrames = Int(buffer.frameLength)
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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
        isRunning = false
    }

    // MARK: - Route changes
    #if os(iOS)

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
    ///
    /// The outcome is recorded rather than discarded. When the phone stays on
    /// the built-in microphone with a timecode interface plugged in, the whole
    /// question is *which* of these steps failed — whether the interface was
    /// absent from `availableInputs` altogether, or was found and refused — and
    /// a bare `try?` throws that distinction away.
    private func preferExternalInput(session: AVAudioSession) {
        guard let inputs = session.availableInputs, !inputs.isEmpty else {
            preferredInputOutcome = "no availableInputs (session inactive or not a recording category)"
            return
        }
        let preferredOrder: [AVAudioSession.Port] = [.usbAudio, .headsetMic, .lineIn]
        for port in preferredOrder {
            if let match = inputs.first(where: { $0.portType == port }) {
                do {
                    try session.setPreferredInput(match)
                    preferredInputOutcome = "requested \(match.portName) [\(match.portType.rawValue)]"
                } catch {
                    preferredInputOutcome = "setPreferredInput(\(match.portName)) FAILED: \(error.localizedDescription)"
                }
                return
            }
        }
        preferredInputOutcome = "no external input offered; only "
            + inputs.map(\.portType.rawValue).joined(separator: ", ")
    }

    /// Current state plus the two things only this object knows: the engine's
    /// negotiated input format, and what the last attempt to select an external
    /// input actually did.
    public func diagnostics() -> AudioDiagnostics {
        var d = AudioDiagnostics.current()
        d.preferredInputOutcome = preferredInputOutcome
        if isRunning {
            d.engineInputFormat = engine.inputNode.inputFormat(forBus: 0).description
            d.observedBufferFrames = observedBufferFrames
            d.compensatedLatency = compensateInputLatency ? inputLatencySeconds : 0
        }
        return d
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
    #else

    /// Human-readable description of the current input, for the UI.
    public var currentInputDescription: String {
        selectedDevice?.name ?? "No input"
    }

    /// True when capturing from something other than the Mac's own microphone.
    /// Heuristic — CoreAudio has no "built-in" flag — but good enough for a
    /// harness, where the device was named explicitly anyway.
    public var isExternalInputConnected: Bool {
        guard let device = selectedDevice else { return false }
        return !device.uid.hasPrefix("BuiltIn")
    }

    /// The input latency a jam has to subtract for the selected device.
    public var latencyBudget: InputLatencyBudget? {
        selectedDevice.map { MacAudioDevices.latencyBudget($0.id) }
    }
    #endif
}
