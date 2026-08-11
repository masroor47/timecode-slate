import Foundation

/// A free-running timecode clock anchored to a monotonic host clock.
///
/// The whole point of jam sync: you connect an external LTC source once, the
/// clock captures *both* the timecode value and the exact host time that value
/// occurred at, then keeps extrapolating from that anchor after you unplug.
/// Accuracy afterwards is entirely down to the host oscillator's stability.
public final class TimecodeClock {

    public private(set) var rate: TimecodeRate

    /// Frame position at the anchor instant (fractional — sub-frame precision).
    private var anchorFrame: Double = 0
    /// Host clock reading, in seconds, at the anchor instant.
    private var anchorHost: Double = 0

    /// Measured oscillator error in parts per million, applied to extrapolation.
    /// Positive means the host clock runs fast. Populated by `calibrate`.
    public var driftPPM: Double = 0

    public private(set) var isRunning = false
    /// Host time of the most recent jam, for "jammed 12m ago" style UI.
    public private(set) var lastJamHostTime: Double?

    public init(rate: TimecodeRate) {
        self.rate = rate
    }

    /// Set the clock from an external source.
    ///
    /// - Parameters:
    ///   - timecode: the decoded value.
    ///   - hostTime: the host-clock instant at which that frame *began*.
    public func jam(to timecode: Timecode, atHostTime hostTime: Double) {
        rate = timecode.rate
        anchorFrame = Double(timecode.frameNumber)
        anchorHost = hostTime
        lastJamHostTime = hostTime
        isRunning = true
    }

    /// Start free-running from a manually entered value.
    public func set(to timecode: Timecode, atHostTime hostTime: Double) {
        rate = timecode.rate
        anchorFrame = Double(timecode.frameNumber)
        anchorHost = hostTime
        isRunning = true
    }

    public func stop() { isRunning = false }

    /// Fractional frame position at a given host time.
    public func framePosition(atHostTime hostTime: Double) -> Double {
        guard isRunning else { return anchorFrame }
        let elapsed = (hostTime - anchorHost) * (1.0 - driftPPM * 1e-6)
        return anchorFrame + elapsed * rate.actualFPS
    }

    /// Current timecode at a given host time.
    public func timecode(atHostTime hostTime: Double) -> Timecode {
        let pos = framePosition(atHostTime: hostTime)
        return Timecode(frameNumber: Int(floor(pos)), rate: rate)
    }

    /// How far into the current frame we are, 0..<1. Useful for driving a
    /// sub-frame progress indicator or deciding when to repaint.
    public func framePhase(atHostTime hostTime: Double) -> Double {
        let pos = framePosition(atHostTime: hostTime)
        return pos - floor(pos)
    }

    /// Change the working rate, keeping the same wall-clock position.
    public func setRate(_ newRate: TimecodeRate, atHostTime hostTime: Double) {
        let current = timecode(atHostTime: hostTime)
        let converted = current.converted(to: newRate)
        rate = newRate
        anchorFrame = Double(converted.frameNumber)
        anchorHost = hostTime
    }

    /// Compare a freshly decoded external frame against what we're predicting.
    /// Returns the error in frames (positive = we are ahead of the source).
    public func error(against timecode: Timecode, atHostTime hostTime: Double) -> Double {
        framePosition(atHostTime: hostTime) - Double(timecode.frameNumber)
    }

    /// Derive the host oscillator's error from two jams separated in time, and
    /// store it so subsequent free-running extrapolation compensates.
    ///
    /// Returns the computed ppm, or nil if the baseline is too short to be
    /// meaningful.
    @discardableResult
    public func calibrate(reference timecode: Timecode, atHostTime hostTime: Double, minimumBaseline: Double = 60.0) -> Double? {
        guard isRunning, let jamTime = lastJamHostTime else { return nil }
        let baseline = hostTime - jamTime
        guard baseline >= minimumBaseline else { return nil }

        // Error accumulated over the baseline, expressed as a rate ratio.
        let errorFrames = framePosition(atHostTime: hostTime) - Double(timecode.frameNumber)
        let errorSeconds = errorFrames / rate.actualFPS
        let ppm = (errorSeconds / baseline) * 1e6
        driftPPM += ppm
        return driftPPM
    }
}

/// A captured sync event — what the slate freezes on screen when the sticks clap.
public struct ClapEvent: Sendable, Equatable {
    public let timecode: Timecode
    public let hostTime: Double
    public let scene: String
    public let shot: String
    public let take: Int

    public init(timecode: Timecode, hostTime: Double, scene: String, shot: String, take: Int) {
        self.timecode = timecode
        self.hostTime = hostTime
        self.scene = scene
        self.shot = shot
        self.take = take
    }
}
