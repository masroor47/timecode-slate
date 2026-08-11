import Foundation
import QuartzCore
import SwiftUI
import SlateCore

/// `CADisplayLink` needs an ObjC selector target, which a plain Swift
/// `ObservableObject` cannot provide. This forwards to a closure instead.
@MainActor
private final class DisplayLinkProxy: NSObject {
    private let handler: @MainActor (CADisplayLink) -> Void
    init(handler: @escaping @MainActor (CADisplayLink) -> Void) {
        self.handler = handler
    }
    @objc func step(_ link: CADisplayLink) { handler(link) }
}

/// Ties the decoder, the free-running clock and the slate metadata together,
/// and republishes them for SwiftUI at display rate.
@MainActor
final class SlateViewModel: ObservableObject {

    enum SyncStatus: Equatable {
        /// Microphone off. The resting state — see `armJam()`.
        case idle
        case listening
        case locked(fps: Double)
        case freeRunning(sinceJam: TimeInterval)
        case error(String)

        var label: String {
            switch self {
            case .idle: return "MIC OFF — TAP JAM"
            case .listening: return "LISTENING FOR LTC…"
            case .locked(let fps): return String(format: "LOCKED  %.3f fps", fps)
            case .freeRunning(let since):
                let m = Int(since) / 60
                return m < 1 ? "FREE RUN  jammed just now" : "FREE RUN  jammed \(m)m ago"
            case .error(let message): return message.uppercased()
            }
        }

        var color: Color {
            switch self {
            case .idle: return .gray
            case .listening: return .yellow
            case .locked: return .green
            case .freeRunning: return .cyan
            case .error: return .red
            }
        }
    }

    // Published display state
    @Published private(set) var displayTimecode = "00:00:00:00"
    @Published private(set) var isHolding = false
    @Published private(set) var heldEvent: ClapEvent?
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var inputName = "—"
    @Published private(set) var level: Float = 0
    /// Which half of the hold the frozen slate is showing.
    @Published private(set) var holdPhase: HoldPhase = .timecode
    /// User bits exactly as decoded at the last jam, or nil if we never jammed.
    @Published private(set) var decodedUserBits: String?

    /// What the slate actually shows in the user-bits half of the hold.
    ///
    /// Falls back to today's date when nothing meaningful has been decoded —
    /// either because we have not jammed yet, or because the source sends all
    /// zeros, which plenty of gear does. DDMMYY is the usual convention, and a
    /// date is far more useful on a slate than eight zeros.
    var userBitsDisplay: String {
        if let decoded = decodedUserBits, decoded.contains(where: { $0 != "0" }) {
            return Self.grouped(decoded)
        }
        return Self.dateUserBits()
    }

    /// User bits read as pairs, the way a slate prints them.
    private static func grouped(_ raw: String) -> String {
        stride(from: 0, to: raw.count, by: 2).map { offset in
            let start = raw.index(raw.startIndex, offsetBy: offset)
            let end = raw.index(start, offsetBy: min(2, raw.count - offset))
            return String(raw[start..<end])
        }.joined(separator: " ")
    }

    private static func dateUserBits() -> String {
        let parts = Calendar.current.dateComponents([.day, .month, .year], from: Date())
        return String(format: "%02d %02d %02d 00",
                      parts.day ?? 0, parts.month ?? 0, (parts.year ?? 0) % 100)
    }
    /// Whether an audible clap is emitted. Safe to leave on: the microphone is
    /// off except while jamming, so there is no capture session to disturb.
    @Published var clapSoundEnabled = true
    @Published var info = SlateInfo() {
        didSet { slate.update { $0 = info } }
    }
    @Published var rate: TimecodeRate = .fps24 {
        didSet {
            guard rate != oldValue else { return }
            clock.setRate(rate, atHostTime: CACurrentMediaTime())
            applyRatePreference()
        }
    }
    /// When true, take the rate from the incoming signal instead of the picker.
    @Published var autoDetectRate = true {
        didSet { applyRatePreference() }
    }

    /// Pin the decoder to the chosen rate, or let it auto-detect.
    private func applyRatePreference() {
        #if os(iOS)
        audio.assumedRate = autoDetectRate ? nil : rate
        #endif
    }

    private let clock = TimecodeClock(rate: .fps24)
    private let slate = SlateState()
    #if os(iOS)
    private let audio = LTCAudioInput()
    #endif

    private var displayLink: CADisplayLink?
    private var lastLockHostTime: Double?
    private var lastMode: SlateDisplayMode = .running
    /// Host time the armed clap is due to fire, or nil when none is armed.
    private var scheduledClapHostTime: Double?
    /// Delay between pressing the button and the sync point.
    var clapLeadTime: Double = 0.5
    /// Set while the user has armed jamming; cleared once we take a jam.
    private var armedForJam = false
    /// When arming happened, so the wait can time out instead of listening
    /// indefinitely.
    private var armedAtHostTime: Double?

    init() {
        clock.set(to: Timecode(hours: 10, rate: .fps24), atHostTime: CACurrentMediaTime())
        startDisplayTimer()
        #if os(iOS)
        // Build the player and claim the route at launch, so even the very
        // first clap has nothing slow left to do.
        ClapSound.shared.prewarm()
        #endif
    }

    // MARK: - Audio

    /// Arm a jam, or cancel one already in flight.
    ///
    /// The microphone is off at rest and only runs between arming and the
    /// first clean frame. That is a deliberate privacy choice — a slate has no
    /// business listening to a set all day — and it has a useful side effect:
    /// because capture is stopped whenever you clap, the clap sound never has
    /// to fight the `.record`/`.measurement` session for the audio route.
    func armJam() {
        #if os(iOS)
        guard !armedForJam else { cancelJam(); return }
        armedForJam = true
        armedAtHostTime = CACurrentMediaTime()
        Task { @MainActor in
            guard await LTCAudioInput.requestPermission() else {
                armedForJam = false
                status = .error("Microphone access denied")
                return
            }
            guard armedForJam else { return }   // cancelled while we waited
            beginCapture()
        }
        #endif
    }

    /// Stop waiting and put the microphone away again.
    func cancelJam(message: String? = nil) {
        #if os(iOS)
        armedForJam = false
        armedAtHostTime = nil
        audio.stop()
        level = 0
        inputName = "—"
        if let message {
            status = .error(message)
        } else {
            status = restingStatus()
        }
        #endif
    }

    /// Where the status returns to when the microphone shuts off: free running
    /// if we ever jammed, otherwise idle.
    private func restingStatus() -> SyncStatus {
        if let jam = clock.lastJamHostTime {
            return .freeRunning(sinceJam: (CACurrentMediaTime() - jam).rounded(.down))
        }
        return .idle
    }

    func stopListening() {
        #if os(iOS)
        audio.stop()
        armedForJam = false
        armedAtHostTime = nil
        #endif
    }

    #if os(iOS)
    /// How long to wait for a decodable signal before giving up.
    private static let jamTimeout: TimeInterval = 20

    private func beginCapture() {
        audio.assumedRate = autoDetectRate ? nil : rate
        audio.onLevel = { [weak self] peak in
            Task { @MainActor in self?.level = peak }
        }
        audio.onReading = { [weak self] reading in
            Task { @MainActor in self?.handle(reading) }
        }
        // Plugging the timecode cable in mid-session is the normal case, not
        // the exception — surface the new input rather than silently staying
        // on the built-in mic.
        audio.onRouteChange = { [weak self] name in
            Task { @MainActor in self?.inputName = name }
        }
        do {
            try audio.start()
            status = .listening
            inputName = audio.currentInputDescription
        } catch {
            armedForJam = false
            armedAtHostTime = nil
            status = .error(error.localizedDescription)
        }
    }

    private func handle(_ reading: LTCAudioInput.Reading) {
        lastLockHostTime = CACurrentMediaTime()
        if autoDetectRate { rate = reading.result.rate }

        guard armedForJam else {
            status = .locked(fps: reading.result.measuredFPS)
            return
        }

        // Jam on the first clean frame, then shut the microphone off. From here
        // the clock free-runs, which is the whole point — see README §4.
        clock.jam(to: reading.result.timecode, atHostTime: reading.hostTime)
        decodedUserBits = reading.result.frame.userBitsString
        armedForJam = false
        armedAtHostTime = nil
        audio.stop()
        level = 0
        inputName = "—"
        status = .freeRunning(sinceJam: 0)
        // Capture just held the session in `.record`; hand it back to playback
        // now rather than on the next clap path.
        if clapSoundEnabled { ClapSound.shared.prewarm() }
    }
    #endif

    var isArmedForJam: Bool { armedForJam }

    // MARK: - Slate

    /// Arm the clap. Nothing visible happens yet.
    ///
    /// The sync point is deliberately *not* the button press. A press lands at
    /// an arbitrary moment, drags UIKit's touch handling with it, and — as this
    /// app found the hard way — can pull slow one-off work onto the main thread
    /// at exactly the instant that must not stall. So the press only starts a
    /// countdown; the clap itself happens `clapLeadTime` later, on a display
    /// frame, with every expensive thing already done.
    ///
    /// The lead is a feature in its own right: the operator gets a beat of
    /// warning, and the timecode visibly keeps running so nothing about the
    /// press can be mistaken for the sync point.
    func clap() {
        guard !isHolding, scheduledClapHostTime == nil else { return }
        let due = CACurrentMediaTime() + clapLeadTime
        scheduledClapHostTime = due
        #if os(iOS)
        // Hand the sound its exact target time now. It is rendered by the audio
        // thread at that instant, so nothing has to happen on the main thread
        // when the sync point arrives.
        if clapSoundEnabled && !audio.isRunning {
            ClapSound.shared.schedule(atHostTime: due)
        }
        #endif
    }

    /// True between the press and the sync point.
    var isClapPending: Bool { scheduledClapHostTime != nil }

    /// Take the sync point, timed to the frame the audience actually sees.
    ///
    /// This runs from the display link with `host` set to `targetTimestamp`,
    /// the moment the frame will light the panel. Capturing the timecode here
    /// rather than in the button handler is the difference between a sync point
    /// that is *correct* and one that is merely close: the button handler runs
    /// at an arbitrary moment inside a refresh interval, so a timecode taken
    /// there belongs to a frame that is not yet — and may never be — on screen.
    ///
    /// Doing it here means the frozen number, the colour change, the sticks
    /// meeting and the clap sound all belong to one identical frame. That frame
    /// is the sync point.
    private func performPendingClap(atHostTime host: Double) {
        guard let due = scheduledClapHostTime, host >= due else { return }
        scheduledClapHostTime = nil
        slate.clap(timecode: clock.timecode(atHostTime: host), atHostTime: host)
        // Note there is deliberately no audio call here — the crack was
        // scheduled against the audio clock when the clap was armed.
    }

    func releaseHold() {
        slate.release()
        syncFromSlate()
    }

    func advanceShot() {
        slate.advanceShot()
        syncFromSlate()
    }

    private func syncFromSlate() {
        if info != slate.info { info = slate.info }

        // Only react to an actual clap/release, not to every display refresh.
        let mode = slate.mode
        guard mode != lastMode else { return }
        lastMode = mode
        switch mode {
        case .running:
            isHolding = false
            heldEvent = nil
        case .held(let event):
            isHolding = true
            heldEvent = event
        }
    }

    // MARK: - Display

    /// Drive the display from `CADisplayLink` rather than a `Timer`.
    ///
    /// Two things matter here, and a 30 Hz timer got both wrong:
    ///
    /// 1. **Rate.** A 30 Hz timer sampling 24 fps timecode shows numbers up to
    ///    33 ms stale, and irregularly repeats or skips frame values — the
    ///    displayed frames digit is simply wrong some of the time. Running at
    ///    the panel's own refresh (120 Hz on ProMotion) puts every digit change
    ///    within one refresh interval of the true frame boundary.
    ///
    /// 2. **Which instant to render.** `targetTimestamp` is when this frame
    ///    will actually light up the panel, not when the callback ran. Reading
    ///    the clock at that time means the number on screen is correct for the
    ///    moment the photons leave the display — which is the moment the camera
    ///    photographs.
    ///
    /// Note ProMotion also needs `CADisableMinimumFrameDurationOnPhone` in
    /// Info.plist; without it iOS caps third-party apps at 60 Hz.
    private func startDisplayTimer() {
        let proxy = DisplayLinkProxy { [weak self] link in
            self?.tick(atHostTime: link.targetTimestamp)
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func tick(atHostTime host: Double) {
        // Before anything else, so the clap and everything it changes land in
        // this frame rather than the next one.
        performPendingClap(atHostTime: host)

        slate.tick(atHostTime: host)
        syncFromSlate()

        #if os(iOS)
        // Give up rather than hold the microphone open forever.
        if armedForJam, let armed = armedAtHostTime,
           host - armed > Self.jamTimeout {
            cancelJam(message: "No timecode found — check the source and try again")
        }

        let phase = slate.holdPhase(atHostTime: host) ?? .timecode
        if phase != holdPhase { holdPhase = phase }
        #endif

        // Every assignment below is guarded, because @Published fires on write
        // regardless of whether the value changed. At 120 Hz an unguarded
        // assignment would redraw the whole slate 120 times a second to show
        // the same digits.
        let shown = isHolding
            ? (heldEvent?.timecode.description ?? displayTimecode)
            : clock.timecode(atHostTime: host).description
        if shown != displayTimecode { displayTimecode = shown }

        // Drop out of "locked" once the signal stops arriving.
        if let last = lastLockHostTime, host - last > 0.5 {
            let next: SyncStatus
            if let jam = clock.lastJamHostTime {
                // Quantised to whole seconds: the label only renders minutes,
                // so carrying the raw interval would make this differ on every
                // refresh and defeat the guard below.
                next = .freeRunning(sinceJam: (host - jam).rounded(.down))
            } else {
                next = .listening
            }
            if next != status { status = next }
        }
    }
}
