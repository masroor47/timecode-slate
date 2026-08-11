import Foundation

/// The metadata a slate carries. Field names follow standard camera-report
/// practice so the data lines up with what a script supervisor expects.
public struct SlateInfo: Equatable, Sendable, Codable {
    public var production: String = ""
    public var director: String = ""
    public var cinematographer: String = ""
    public var scene: String = ""
    public var shot: String = ""          // the letter, e.g. "A", "B"
    public var take: Int = 1
    public var roll: String = ""          // camera roll
    public var soundRoll: String = ""
    public var notes: String = ""

    public var isMOS: Bool = false        // shot without sound
    public var isInterior: Bool = true
    public var isDay: Bool = true
    public var isPickup: Bool = false

    public init() {}

    /// "24A" — the conventional scene/shot slug.
    public var slug: String {
        scene.isEmpty && shot.isEmpty ? "" : "\(scene)\(shot)"
    }
}

/// What the slate is currently showing.
public enum SlateDisplayMode: Equatable, Sendable {
    /// Timecode running live.
    case running
    /// Frozen on the timecode captured at the clap, so a camera can read it
    /// without motion blur. This is the behaviour that matters — a running
    /// display photographs as an unreadable smear at the moment of sync.
    case held(ClapEvent)
}

/// What a frozen slate is showing at a given moment.
///
/// A real slate is photographed for a few seconds after the clap, which is
/// long enough to show two things in sequence. The timecode comes first
/// because it is the sync-critical read; the user bits follow because they
/// carry the date or reel ID and only need to be legible once per setup.
public enum HoldPhase: Equatable, Sendable {
    case timecode
    case userBits
}

/// Drives clap → hold → resume, and take numbering.
public final class SlateState {

    public private(set) var info: SlateInfo
    public private(set) var mode: SlateDisplayMode = .running
    /// Every clap this session, newest last — the basis of a take log.
    public private(set) var history: [ClapEvent] = []

    /// How long the timecode stays frozen, counted in **frames of the clapped
    /// rate** rather than seconds.
    ///
    /// Frames are the right unit here because the consumer is a camera, not a
    /// person: the freeze only has to survive long enough to guarantee a few
    /// completely clean exposures. Four frames guarantees at least three fully
    /// clean frames at a matching camera rate whatever the shutter phase, and
    /// keeps the slate showing the wrong (frozen) time for as little as
    /// possible — 167 ms at 24 fps.
    public var timecodeHoldFrames: Int = 4
    /// How long the user bits are shown once the timecode window has passed.
    public var userBitsHoldDuration: Double = 0.5
    /// Whether the take number advances automatically after each clap.
    public var autoIncrementTake = true

    public var onChange: (() -> Void)?

    public init(info: SlateInfo = SlateInfo()) {
        self.info = info
    }

    public func update(_ mutate: (inout SlateInfo) -> Void) {
        mutate(&info)
        onChange?()
    }

    /// Record a sync point. Returns the captured event.
    ///
    /// The take counter deliberately does *not* advance here. It advances on
    /// resume (see `endHold`), so the whole time the slate is frozen and being
    /// photographed it still reads the take that was actually just shot.
    @discardableResult
    public func clap(timecode: Timecode, atHostTime hostTime: Double) -> ClapEvent {
        let event = ClapEvent(
            timecode: timecode,
            hostTime: hostTime,
            scene: info.scene,
            shot: info.shot,
            take: info.take
        )
        history.append(event)
        mode = .held(event)
        onChange?()
        return event
    }

    /// Which half of the hold we are in, or nil when not holding.
    public func holdPhase(atHostTime hostTime: Double) -> HoldPhase? {
        guard case .held(let event) = mode else { return nil }
        return hostTime - event.hostTime < timecodeWindow(for: event)
            ? .timecode : .userBits
    }

    /// Call from a display timer. Releases the hold once it has expired.
    public func tick(atHostTime hostTime: Double) {
        guard case .held(let event) = mode else { return }
        if hostTime - event.hostTime >= totalHold(for: event) {
            endHold()
        }
    }

    /// The timecode half, in seconds, derived from the rate of the frame that
    /// was actually clapped — so 4 frames means 4 frames at 24 fps *and* at
    /// 60 fps, rather than a fixed duration that means different things.
    private func timecodeWindow(for event: ClapEvent) -> Double {
        Double(timecodeHoldFrames) / event.timecode.rate.actualFPS
    }

    private func totalHold(for event: ClapEvent) -> Double {
        timecodeWindow(for: event) + userBitsHoldDuration
    }

    /// Drop the hold early, e.g. the operator tapped to dismiss.
    public func release() {
        guard case .held = mode else { return }
        endHold()
    }

    /// Resume the running display, advancing the take. Both the timed release
    /// and a manual one land here so the take can only ever advance once per
    /// clap, whichever way the hold ends.
    private func endHold() {
        mode = .running
        if autoIncrementTake {
            info.take += 1
        }
        onChange?()
    }

    /// Starting a new setup: next shot letter, take back to 1.
    public func advanceShot() {
        info.shot = Self.nextShotLetter(after: info.shot)
        info.take = 1
        onChange?()
    }

    public func advanceScene(to scene: String) {
        info.scene = scene
        info.shot = ""
        info.take = 1
        onChange?()
    }

    /// "" → "A", "A" → "B", "Z" → "AA", "AZ" → "BA".
    static func nextShotLetter(after current: String) -> String {
        guard !current.isEmpty else { return "A" }
        var chars = Array(current.uppercased())
        var i = chars.count - 1
        while i >= 0 {
            if chars[i] == "Z" {
                chars[i] = "A"
                i -= 1
            } else if let scalar = chars[i].unicodeScalars.first,
                      scalar.value >= 65, scalar.value < 90 {
                chars[i] = Character(UnicodeScalar(scalar.value + 1)!)
                return String(chars)
            } else {
                return current
            }
        }
        return "A" + String(chars)
    }

    /// The take log, ready to write out as a camera report.
    public func csvLog() -> String {
        var lines = ["scene,shot,take,timecode"]
        for e in history {
            lines.append("\(e.scene),\(e.shot),\(e.take),\(e.timecode.description)")
        }
        return lines.joined(separator: "\n")
    }
}
