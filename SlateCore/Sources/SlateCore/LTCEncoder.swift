import Foundation

/// Generates LTC audio: biphase-mark ("Manchester") encoded square wave.
///
/// Biphase mark rule: the level flips at *every* bit boundary, and a `1` bit
/// gets an extra flip in the middle. So a `0` is one long pulse and a `1` is
/// two short ones — which is exactly what makes the code self-clocking and
/// polarity-independent.
public final class LTCEncoder {
    public let sampleRate: Double
    public let rate: TimecodeRate
    public var amplitude: Float

    private var level: Float = 1.0
    /// Absolute sample position of the next edge, kept in floating point so
    /// non-integer bit periods (23.976, 29.97) never accumulate drift.
    private var nextEdge: Double = 0
    private var written: Double = 0

    public init(sampleRate: Double, rate: TimecodeRate, amplitude: Float = 0.8) {
        self.sampleRate = sampleRate
        self.rate = rate
        self.amplitude = amplitude
    }

    public var samplesPerBit: Double { sampleRate / rate.ltcBitRate }
    public var samplesPerFrame: Double { sampleRate / rate.actualFPS }

    /// Append one timecode frame's worth of audio.
    public func encode(timecode: Timecode, userBits: [UInt8] = Array(repeating: 0, count: 8), into out: inout [Float]) {
        var frame = LTCFrame(timecode: timecode)
        frame.userBits = userBits.count == 8 ? userBits : Array(repeating: 0, count: 8)
        let bits = LTCFrame.bitSequence(dataBits: frame.dataBits(rate: rate))
        let half = samplesPerBit / 2.0

        for bit in bits {
            level = -level
            nextEdge += half
            while written < nextEdge {
                out.append(level * amplitude)
                written += 1
            }
            if bit == 1 { level = -level }
            nextEdge += half
            while written < nextEdge {
                out.append(level * amplitude)
                written += 1
            }
        }
    }

    /// Convenience: render `count` consecutive frames starting at `start`.
    public func encode(from start: Timecode, frames count: Int) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(Int(samplesPerFrame * Double(count)) + 64)
        var tc = start
        for _ in 0..<count {
            encode(timecode: tc, into: &out)
            tc = tc.adding(frames: 1)
        }
        return out
    }
}
