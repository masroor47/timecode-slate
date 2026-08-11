import Foundation

/// A timecode frame rate, in the sense the film/TV world means it: a *counting*
/// rate (how many frames make up one second of timecode) plus whether the clock
/// is pulled down by 1000/1001 and whether it drops frame numbers to stay
/// honest against wall clock.
public enum TimecodeRate: String, CaseIterable, Sendable, Codable {
    case fps23_976
    case fps24
    case fps25
    case fps29_97ndf
    case fps29_97df
    case fps30
    case fps47_952
    case fps48
    case fps50
    case fps59_94ndf
    case fps59_94df
    case fps60

    /// Frames counted per second of timecode. This is what the `:ff` field wraps at.
    public var nominalFPS: Int {
        switch self {
        case .fps23_976, .fps24: return 24
        case .fps25: return 25
        case .fps29_97ndf, .fps29_97df, .fps30: return 30
        case .fps47_952, .fps48: return 48
        case .fps50: return 50
        case .fps59_94ndf, .fps59_94df, .fps60: return 60
        }
    }

    /// True when frame *numbers* are skipped to keep timecode near wall clock.
    public var isDropFrame: Bool {
        switch self {
        case .fps29_97df, .fps59_94df: return true
        default: return false
        }
    }

    /// True when the real rate is nominal * 1000/1001.
    public var isPullDown: Bool {
        switch self {
        case .fps23_976, .fps29_97ndf, .fps29_97df, .fps47_952, .fps59_94ndf, .fps59_94df:
            return true
        default:
            return false
        }
    }

    /// Frames per real-world second. This is what drives the LTC bit rate.
    public var actualFPS: Double {
        let n = Double(nominalFPS)
        return isPullDown ? n * 1000.0 / 1001.0 : n
    }

    /// LTC carries 80 bits per frame, so the bit rate follows directly.
    public var ltcBitRate: Double { actualFPS * 80.0 }

    public var displayName: String {
        switch self {
        case .fps23_976: return "23.976"
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps29_97ndf: return "29.97 NDF"
        case .fps29_97df: return "29.97 DF"
        case .fps30: return "30"
        case .fps47_952: return "47.952"
        case .fps48: return "48"
        case .fps50: return "50"
        case .fps59_94ndf: return "59.94 NDF"
        case .fps59_94df: return "59.94 DF"
        case .fps60: return "60"
        }
    }

    /// How many frame numbers are skipped at each drop boundary.
    var dropCount: Int {
        guard isDropFrame else { return 0 }
        // 2 for 30-based, 4 for 60-based.
        return nominalFPS / 15
    }
}

/// A timecode value. Stored as h/m/s/f plus the rate that gives it meaning.
public struct Timecode: Equatable, Hashable, Sendable, Codable {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var rate: TimecodeRate

    public init(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, frames: Int = 0, rate: TimecodeRate) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.rate = rate
    }

    /// Total elapsed frames since 00:00:00:00, accounting for dropped numbers.
    /// This is the canonical form for arithmetic — never do math on h/m/s/f directly.
    public var frameNumber: Int {
        let n = rate.nominalFPS
        var total = hours * 3600 * n + minutes * 60 * n + seconds * n + frames
        if rate.isDropFrame {
            let totalMinutes = hours * 60 + minutes
            total -= rate.dropCount * (totalMinutes - totalMinutes / 10)
        }
        return total
    }

    public init(frameNumber: Int, rate: TimecodeRate) {
        let n = rate.nominalFPS
        let framesPerDay = n * 3600 * 24 - (rate.isDropFrame ? rate.dropCount * (1440 - 144) : 0)
        var f = frameNumber % framesPerDay
        if f < 0 { f += framesPerDay }

        if rate.isDropFrame {
            // Walk the frame number back up into "as if non-drop" space, then
            // do a plain positional decode.
            let drop = rate.dropCount
            let framesPer10Min = n * 600 - drop * 9
            let framesPerMin = n * 60 - drop
            let d = f / framesPer10Min
            let m = f % framesPer10Min
            var adjusted = f + drop * 9 * d
            if m >= drop {
                adjusted += drop * ((m - drop) / framesPerMin)
            }
            f = adjusted
        }

        self.frames = f % n
        self.seconds = (f / n) % 60
        self.minutes = (f / (n * 60)) % 60
        self.hours = (f / (n * 3600)) % 24
        self.rate = rate
    }

    /// Advance (or rewind) by a number of frames, wrapping at 24 hours.
    public func adding(frames delta: Int) -> Timecode {
        Timecode(frameNumber: frameNumber + delta, rate: rate)
    }

    /// Re-interpret this wall position at a different rate, preserving *time*
    /// rather than frame count. Used when the user changes the project rate.
    public func converted(to newRate: TimecodeRate) -> Timecode {
        let elapsed = Double(frameNumber) / rate.actualFPS
        return Timecode(frameNumber: Int((elapsed * newRate.actualFPS).rounded()), rate: newRate)
    }

    /// Seconds of real time since 00:00:00:00.
    public var elapsedSeconds: Double {
        Double(frameNumber) / rate.actualFPS
    }

    /// SMPTE convention: `;` before the frames field means drop frame.
    public var description: String {
        let sep = rate.isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, sep, frames)
    }

    /// Whether the h/m/s/f fields are self-consistent for the rate. A decoded
    /// LTC word can carry nonsense if the signal is marginal, so callers should
    /// check this before trusting a jam.
    public var isValid: Bool {
        guard hours >= 0, hours < 24,
              minutes >= 0, minutes < 60,
              seconds >= 0, seconds < 60,
              frames >= 0, frames < rate.nominalFPS
        else { return false }
        if rate.isDropFrame, seconds == 0, minutes % 10 != 0, frames < rate.dropCount {
            // These frame numbers don't exist in drop frame.
            return false
        }
        return true
    }
}

extension Timecode: CustomStringConvertible {}
