import Foundation
@testable import SlateCore

/// Deterministic PRNG so noise tests are reproducible.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }

    /// Uniform in -1...1
    mutating func uniform() -> Float {
        Float(Double(next() >> 11) / Double(1 << 53)) * 2.0 - 1.0
    }

    /// Approximately Gaussian, via sum of uniforms.
    mutating func gaussian() -> Float {
        var acc: Float = 0
        for _ in 0..<6 { acc += uniform() }
        return acc / 2.449
    }
}

enum Signal {

    /// Add white noise at a given SNR in dB relative to the signal's RMS.
    static func addNoise(_ samples: [Float], snrDB: Double, seed: UInt64 = 42) -> [Float] {
        var rng = SeededRandom(seed: seed)
        let signalRMS = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        let noiseRMS = signalRMS / pow(10.0, snrDB / 20.0)
        return samples.map { $0 + rng.gaussian() * Float(noiseRMS) }
    }

    /// Hard-clip, modelling a hot source driving an input into its rails.
    /// `gain` above 1 pushes the signal past full scale before clipping.
    static func clip(_ samples: [Float], gain: Float, ceiling: Float = 1.0) -> [Float] {
        samples.map { min(max($0 * gain, -ceiling), ceiling) }
    }

    static func scale(_ samples: [Float], by factor: Float) -> [Float] {
        samples.map { $0 * factor }
    }

    static func invert(_ samples: [Float]) -> [Float] {
        samples.map { -$0 }
    }

    /// Add a constant DC offset, as a coupling capacitor charge-up would.
    static func addDC(_ samples: [Float], offset: Float) -> [Float] {
        samples.map { $0 + offset }
    }

    /// Resample by linear interpolation. Used to model the source and the phone
    /// disagreeing slightly about what "48 kHz" means.
    static func resample(_ samples: [Float], ratio: Double) -> [Float] {
        let outCount = Int(Double(samples.count) / ratio)
        var out = [Float]()
        out.reserveCapacity(outCount)
        for i in 0..<outCount {
            let pos = Double(i) * ratio
            let idx = Int(pos)
            guard idx + 1 < samples.count else { break }
            let frac = Float(pos - Double(idx))
            out.append(samples[idx] * (1 - frac) + samples[idx + 1] * frac)
        }
        return out
    }

    /// One-pole low-pass, modelling cable capacitance and input bandwidth
    /// rounding off the square edges.
    static func lowPass(_ samples: [Float], cutoffHz: Double, sampleRate: Double) -> [Float] {
        let rc = 1.0 / (2.0 * Double.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        let alpha = Float(dt / (rc + dt))
        var y: Float = 0
        return samples.map { x in
            y += alpha * (x - y)
            return y
        }
    }

    /// Silence padding, so the decoder has to acquire lock from nothing.
    static func pad(_ samples: [Float], leading: Int, trailing: Int = 0) -> [Float] {
        [Float](repeating: 0, count: leading) + samples + [Float](repeating: 0, count: trailing)
    }
}

extension LTCDecoder {
    /// Run a whole buffer and collect every decoded frame.
    func decodeAll(_ samples: [Float], chunkSize: Int = 512) -> [LTCDecodeResult] {
        var results = [LTCDecodeResult]()
        onFrame = { results.append($0) }
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            process(Array(samples[offset..<end]))
            offset = end
        }
        return results
    }
}
