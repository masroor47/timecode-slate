import Foundation
import SlateCore

/// Renders continuous LTC to a WAV file, and optionally plays it.
///
/// The point of this tool is to close the whole loop — capture, decode, jam,
/// free run — with no timecode hardware attached to anything. Play the file out
/// of the Mac's speakers and let the phone hear it acoustically (README §2,
/// path C), or feed it down a cable once one exists.
///
/// It is also the honest way to test *before* an adapter arrives: the decoder
/// cannot tell the difference between this and a Zoom, because it is the same
/// biphase-mark waveform. What it does *not* test is the analogue input stage,
/// which remains the one thing only real hardware can answer.

struct Options {
    var rate: TimecodeRate = .fps24
    var startText = "10:00:00:00"
    var minutes: Double = 10
    var sampleRate: Double = 48000
    var amplitude: Float = 0.8
    var output = "ltc.wav"
    var play = false
    var verify = false
}

/// Read a 16-bit mono WAV back to floats. Deliberately reads the file from
/// disk rather than reusing the in-memory samples, so the WAV header and the
/// Int16 conversion are covered too.
func readWAV(_ path: String) -> [Float]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          data.count > 44 else { return nil }
    let body = data.dropFirst(44)
    var out = [Float]()
    out.reserveCapacity(body.count / 2)
    body.withUnsafeBytes { raw in
        let ints = raw.bindMemory(to: Int16.self)
        for v in ints { out.append(Float(Int16(littleEndian: v)) / 32767.0) }
    }
    return out
}

func parseRate(_ s: String) -> TimecodeRate? {
    switch s.lowercased() {
    case "23.976", "23976", "23.98": return .fps23_976
    case "24": return .fps24
    case "25": return .fps25
    case "29.97", "29.97ndf": return .fps29_97ndf
    case "29.97df", "2997df": return .fps29_97df
    case "30": return .fps30
    case "47.952": return .fps47_952
    case "48": return .fps48
    case "50": return .fps50
    case "59.94", "59.94ndf": return .fps59_94ndf
    case "59.94df": return .fps59_94df
    case "60": return .fps60
    default: return nil
    }
}

func parseTimecode(_ s: String, rate: TimecodeRate) -> Timecode? {
    let parts = s.split(separator: ":").map { Int($0) }
    guard parts.count == 4, !parts.contains(where: { $0 == nil }) else { return nil }
    let tc = Timecode(hours: parts[0]!, minutes: parts[1]!,
                      seconds: parts[2]!, frames: parts[3]!, rate: rate)
    return tc.isValid ? tc : nil
}

func usage() -> Never {
    print("""
    ltcplay — generate LTC timecode audio

    USAGE: ltcplay [options]

      --rate <fps>        24 (default), 23.976, 25, 29.97, 29.97df, 30, 48, 50, 59.94, 60
      --start <tc>        starting timecode, HH:MM:SS:FF (default 10:00:00:00)
      --minutes <n>       duration in minutes (default 10)
      --amplitude <0-1>   output level (default 0.8)
      --rate-hz <hz>      sample rate (default 48000)
      --out <path>        output WAV path (default ltc.wav)
      --play              play it after writing, via afplay

    EXAMPLE
      ltcplay --rate 24 --start 10:00:00:00 --minutes 20 --play
    """)
    exit(1)
}

func appendLE<T>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
}

func parseOptions(_ argv: [String]) -> Options {
    var opts = Options()
    var i = 0
    func next() -> String {
        i += 1
        guard i < argv.count else { usage() }
        return argv[i]
    }
    while i < argv.count {
        switch argv[i] {
        case "--rate":
            guard let r = parseRate(next()) else { usage() }
            opts.rate = r
        case "--start":     opts.startText = next()
        case "--minutes":
            guard let v = Double(next()) else { usage() }
            opts.minutes = v
        case "--amplitude":
            guard let v = Float(next()) else { usage() }
            opts.amplitude = v
        case "--rate-hz":
            guard let v = Double(next()) else { usage() }
            opts.sampleRate = v
        case "--out":       opts.output = next()
        case "--play":      opts.play = true
        case "--verify":    opts.verify = true
        default:            usage()
        }
        i += 1
    }
    return opts
}

func run() {
    let opts = parseOptions(Array(CommandLine.arguments.dropFirst()))

    guard let start = parseTimecode(opts.startText, rate: opts.rate) else {
        print("error: '\(opts.startText)' is not a valid \(opts.rate.displayName) timecode")
        exit(1)
    }

    let frameCount = Int(opts.minutes * 60.0 * opts.rate.actualFPS)
    let encoder = LTCEncoder(sampleRate: opts.sampleRate, rate: opts.rate,
                             amplitude: opts.amplitude)

    print("Generating \(frameCount) frames of \(opts.rate.displayName) LTC from \(start)…")
    let samples = encoder.encode(from: start, frames: frameCount)

    // 16-bit mono PCM WAV.
    let dataBytes = samples.count * 2
    var wav = Data()
    wav.reserveCapacity(dataBytes + 44)

    wav.append(contentsOf: Array("RIFF".utf8))
    appendLE(UInt32(36 + dataBytes).littleEndian, to: &wav)
    wav.append(contentsOf: Array("WAVEfmt ".utf8))
    appendLE(UInt32(16).littleEndian, to: &wav)                   // fmt chunk size
    appendLE(UInt16(1).littleEndian, to: &wav)                    // PCM
    appendLE(UInt16(1).littleEndian, to: &wav)                    // mono
    appendLE(UInt32(opts.sampleRate).littleEndian, to: &wav)
    appendLE(UInt32(opts.sampleRate * 2).littleEndian, to: &wav)  // byte rate
    appendLE(UInt16(2).littleEndian, to: &wav)                    // block align
    appendLE(UInt16(16).littleEndian, to: &wav)                   // bits per sample
    wav.append(contentsOf: Array("data".utf8))
    appendLE(UInt32(dataBytes).littleEndian, to: &wav)

    for s in samples {
        let clamped = max(-1.0, min(1.0, s))
        appendLE(Int16(clamped * 32767).littleEndian, to: &wav)
    }

    let url = URL(fileURLWithPath: opts.output)
    do {
        try wav.write(to: url)
    } catch {
        print("error: could not write \(opts.output): \(error.localizedDescription)")
        exit(1)
    }

    let end = start.adding(frames: frameCount - 1)
    let mb = Double(wav.count) / 1_048_576.0
    print(String(format: "Wrote %@ — %.1f MB, %@ → %@", opts.output, mb,
                 start.description, end.description))

    if opts.verify {
        guard let readback = readWAV(opts.output) else {
            print("verify: could not read \(opts.output) back")
            exit(1)
        }
        let decoder = LTCDecoder(sampleRate: opts.sampleRate)
        decoder.assumedRate = opts.rate
        var decoded = [Timecode]()
        decoder.onFrame = { decoded.append($0.timecode) }
        decoder.process(readback)

        // The first and last frames are expected losses: a frame is only
        // resolvable once the sync words either side of it have been seen, so
        // a stream that begins and ends mid-air gives up one frame at each
        // end. Real hardware behaves the same way (README §1).
        guard let first = decoded.first, let last = decoded.last else {
            print("verify: FAIL — nothing decoded")
            exit(1)
        }
        let contiguous = decoded.enumerated().allSatisfy {
            $0.element == first.adding(frames: $0.offset)
        }
        print("verify: decoded \(decoded.count) of \(frameCount) frames "
              + "(\(first) → \(last))")
        let ok = decoded.count >= frameCount - 2 && contiguous
            && first.frameNumber >= start.frameNumber
            && last.frameNumber <= end.frameNumber
        print(ok ? "verify: PASS — contiguous, in order, no gaps or repeats "
                 + "(first/last frame dropped as expected)"
                 : "verify: FAIL")
        if !ok { exit(1) }
    }

    if opts.play {
        print("Playing. Hold the phone near the speaker and tap JAM. Ctrl-C to stop.")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        task.arguments = [url.path]

        // Without this, Ctrl-C kills us and leaves afplay orphaned to PID 1,
        // still playing timecode into the room with no obvious way to stop it.
        // Signals are ignored at the default disposition and handled on a
        // background queue instead, because the main thread is parked in
        // waitUntilExit().
        var sources = [DispatchSourceSignal]()
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                if task.isRunning { task.terminate() }
                exit(0)
            }
            source.resume()
            sources.append(source)
        }

        do {
            try task.run()
        } catch {
            print("error: could not run afplay: \(error.localizedDescription)")
            exit(1)
        }
        task.waitUntilExit()
        withExtendedLifetime(sources) {}
    }
}

run()
