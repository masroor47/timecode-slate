import Foundation
import SlateCore

// Characterises the decoder against degraded signals, so the numbers in the
// README are measured rather than guessed. Run with: swift run -c release ltcbench

let sampleRate = 48000.0
let testRate = TimecodeRate.fps24
let frameCount = 100

struct RNG {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1 }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2685821657736338717
    }
    mutating func gaussian() -> Float {
        var acc: Float = 0
        for _ in 0..<6 { acc += Float(Double(next() >> 11) / Double(1 << 53)) * 2 - 1 }
        return acc / 2.449
    }
}

func cleanAudio() -> [Float] {
    LTCEncoder(sampleRate: sampleRate, rate: testRate)
        .encode(from: Timecode(hours: 10, rate: testRate), frames: frameCount)
}

/// Fraction of frames recovered, and whether they were all consecutive.
func score(_ audio: [Float]) -> (yield: Double, consecutive: Bool) {
    let decoder = LTCDecoder(sampleRate: sampleRate)
    var results = [LTCDecodeResult]()
    decoder.onFrame = { results.append($0) }
    var offset = 0
    while offset < audio.count {
        let end = min(offset + 512, audio.count)
        decoder.process(Array(audio[offset..<end]))
        offset = end
    }
    guard results.count > 1 else { return (0, false) }
    var consecutive = true
    let tcs = results.map { $0.frame.timecode(rate: testRate) }
    for i in 1..<tcs.count where tcs[i].frameNumber != tcs[i - 1].frameNumber + 1 {
        consecutive = false
    }
    return (Double(results.count) / Double(frameCount), consecutive)
}

func report(_ label: String, _ value: String, _ result: (yield: Double, consecutive: Bool)) {
    let pct = String(format: "%5.1f%%", result.yield * 100)
    let flag = result.consecutive ? "ok" : "GAPS"
    print(String(format: "  %-22@ %@   %@  %@", label as NSString, value, pct, flag))
}

print("LTC decoder characterisation — \(testRate.displayName) fps @ \(Int(sampleRate)) Hz, \(frameCount) frames\n")

// --- Noise ---
print("Additive white noise (SNR relative to signal RMS):")
for snr in [30.0, 20.0, 15.0, 12.0, 10.0, 8.0, 6.0, 4.0, 2.0, 0.0] {
    var rng = RNG(seed: 99)
    let clean = cleanAudio()
    let rms = sqrt(clean.reduce(0.0) { $0 + Double($1 * $1) } / Double(clean.count))
    let noiseRMS = Float(rms / pow(10.0, snr / 20.0))
    let audio = clean.map { $0 + rng.gaussian() * noiseRMS }
    report("SNR", String(format: "%5.1f dB", snr), score(audio))
}

// --- Level ---
print("\nSignal level (full scale = 1.0):")
for level in [1.0, 0.1, 0.01, 0.003, 0.001, 0.0003, 0.0001, 0.00003] as [Float] {
    let audio = cleanAudio().map { $0 * level }
    let dbfs = 20 * log10(Double(level) * 0.8)
    report("level", String(format: "%8.1f dBFS", dbfs), score(audio))
}

// --- Overdrive ---
print("\nOverdrive into hard clipping (gain before a 1.0 ceiling):")
for gain in [1.0, 2.0, 10.0, 100.0, 1000.0, 10000.0] as [Float] {
    let audio = cleanAudio().map { min(max($0 * gain, -1), 1) }
    report("gain", String(format: "%9.0fx", gain), score(audio))
}

// --- Bandwidth ---
print("\nBandwidth limiting (one-pole low pass; bit rate is \(Int(testRate.ltcBitRate)) bps):")
for cutoff in [20000.0, 10000.0, 6000.0, 4000.0, 3000.0, 2000.0, 1500.0] {
    let rc = 1.0 / (2 * Double.pi * cutoff)
    let alpha = Float((1.0 / sampleRate) / (rc + 1.0 / sampleRate))
    var y: Float = 0
    let audio = cleanAudio().map { x -> Float in y += alpha * (x - y); return y }
    report("cutoff", String(format: "%8.0f Hz", cutoff), score(audio))
}

// --- Clock error ---
print("\nCapture-clock error vs source (linear resample):")
for ppm in [0.0, 100.0, 1000.0, 5000.0, 20000.0, 50000.0, 100000.0] {
    let ratio = 1.0 + ppm * 1e-6
    let clean = cleanAudio()
    var audio = [Float]()
    var i = 0
    while true {
        let pos = Double(i) * ratio
        let idx = Int(pos)
        if idx + 1 >= clean.count { break }
        let f = Float(pos - Double(idx))
        audio.append(clean[idx] * (1 - f) + clean[idx + 1] * f)
        i += 1
    }
    report("clock error", String(format: "%7.0f ppm", ppm), score(audio))
}

// --- Timing precision ---
print("\nJam timing precision (error in locating each frame's start):")
let encoder = LTCEncoder(sampleRate: sampleRate, rate: testRate)
let audio = encoder.encode(from: Timecode(hours: 10, rate: testRate), frames: frameCount)
let base = Timecode(hours: 10, rate: testRate).frameNumber
for label in ["clean", "clipped 100x", "20 dB SNR"] {
    var signal = audio
    if label == "clipped 100x" { signal = audio.map { min(max($0 * 100, -1), 1) } }
    if label == "20 dB SNR" {
        var rng = RNG(seed: 3)
        let rms = sqrt(audio.reduce(0.0) { $0 + Double($1 * $1) } / Double(audio.count))
        let n = Float(rms / 10.0)
        signal = audio.map { $0 + rng.gaussian() * n }
    }
    let decoder = LTCDecoder(sampleRate: sampleRate)
    var worst = 0.0, sum = 0.0, count = 0
    decoder.onFrame = { r in
        let ordinal = r.frame.timecode(rate: testRate).frameNumber - base
        let expected = Double(ordinal) * encoder.samplesPerFrame
        let err = abs(r.startSampleIndex - expected)
        worst = max(worst, err); sum += err; count += 1
    }
    decoder.process(signal)
    let meanUs = (sum / Double(max(count, 1))) / sampleRate * 1e6
    let worstUs = worst / sampleRate * 1e6
    print(String(format: "  %-22@ mean %6.1f us   worst %6.1f us   (frame = %.0f us)",
                 label as NSString, meanUs, worstUs, 1e6 / testRate.actualFPS))
}

// --- False lock ---
print("\nFalse-lock resistance (should decode nothing):")
for (label, gen) in [
    ("white noise", { (rng: inout RNG) in rng.gaussian() * 0.5 }),
    ("loud noise", { (rng: inout RNG) in rng.gaussian() * 2.0 }),
] {
    var rng = RNG(seed: 11)
    let noise = (0..<Int(sampleRate * 10)).map { _ in gen(&rng) }
    let decoder = LTCDecoder(sampleRate: sampleRate)
    var n = 0
    decoder.onFrame = { _ in n += 1 }
    decoder.process(noise)
    print(String(format: "  %-22@ %d phantom frames in 10 s", label as NSString, n))
}

// --- Throughput ---
print("\nThroughput:")
let bigAudio = LTCEncoder(sampleRate: sampleRate, rate: testRate)
    .encode(from: Timecode(hours: 10, rate: testRate), frames: 24 * 60)
let t0 = Date()
let d = LTCDecoder(sampleRate: sampleRate)
d.process(bigAudio)
let elapsed = Date().timeIntervalSince(t0)
let audioSeconds = Double(bigAudio.count) / sampleRate
print(String(format: "  %.1f s of audio decoded in %.3f s  (%.0fx realtime)",
             audioSeconds, elapsed, audioSeconds / elapsed))
