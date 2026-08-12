import AVFoundation
import Foundation
import SlateCore

/// Live LTC capture from real hardware, on the Mac.
///
/// `ltcplay` proves the decoder against a signal we generated ourselves;
/// `ltcbench` characterises it against deliberately degraded ones. This is the
/// third case and the one neither of those can reach: an actual timecode
/// generator, through an actual interface, arriving through the same
/// `LTCAudioInput` the phone uses.
///
/// It exists because the analogue input stage was for a long time the one
/// unverified part of the system, and because verifying it on the phone is
/// awkward — a USB-C interface occupies the only port, leaving no cable for a
/// debugger. On the Mac the whole path can be watched directly.
///
/// The numbers to trust are DROPS and the frame yield. Capture that silently
/// loses buffers looks exactly like a bad analogue signal — frames failing to
/// decode for no visible reason — and the two must not be confused.

struct Options {
    var device: String?
    var seconds = 10.0
    var bufferFrames: UInt32 = 64
    var rate: TimecodeRate?
    var list = false
}

func parse() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--list":    o.list = true
        case "--device":  i += 1; o.device = i < args.count ? args[i] : nil
        case "--seconds": i += 1; o.seconds = Double(args[safe: i] ?? "") ?? 10
        case "--buffer":  i += 1; o.bufferFrames = UInt32(args[safe: i] ?? "") ?? 64
        case "--rate":
            i += 1
            let want = args[safe: i] ?? ""
            guard let r = TimecodeRate.allCases.first(where: {
                $0.displayName.caseInsensitiveCompare(want) == .orderedSame
            }) else {
                print("unknown rate '\(want)'. One of: "
                      + TimecodeRate.allCases.map(\.displayName).joined(separator: ", "))
                exit(1)
            }
            o.rate = r
        case "-h", "--help":
            print("""
            ltclisten — decode LTC from a live audio input

              --list             list input devices and exit
              --device <match>   substring of the device name (default: system input)
              --seconds <n>      how long to listen (default 10)
              --buffer <frames>  requested device buffer size (default 64)
              --rate <fps>       pin the rate instead of auto-detecting
            """)
            exit(0)
        default: break
        }
        i += 1
    }
    return o
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

let opts = parse()

let devices = MacAudioDevices.inputs()
print("=== INPUT DEVICES ===")
for d in devices {
    print(String(format: "  %-34@ %d ch  %.0f Hz  %@",
                 d.name as NSString, d.channels, d.sampleRate, d.uid as NSString))
}
if opts.list { exit(0) }

guard let device = opts.device.flatMap({ MacAudioDevices.input(matching: $0) })
        ?? MacAudioDevices.defaultInput() else {
    print("\nno usable input device")
    exit(1)
}
print("\nusing: \(device.name)")

// Buffer size is the one knob that actually changes capture latency; the rest
// of the budget is fixed by the hardware.
let settled = MacAudioDevices.setBufferFrameSize(device.id, opts.bufferFrames)
if settled != opts.bufferFrames {
    print("note: asked for \(opts.bufferFrames)-frame buffers, driver settled on \(settled)")
}

print("\n=== INPUT LATENCY BUDGET (as the driver reports it) ===")
print(MacAudioDevices.latencyBudget(device.id).report)
print("  A jam is late by this much unless it is subtracted.")
print("  USB interfaces routinely under-report; treat it as a floor.")

// Deliberately synchronous. A single `await` at top level would make the whole
// of main.swift an async context, which bans the plain locking and sleeping
// this tool is built out of.
func micPermissionGranted() -> Bool {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
    final class Box: @unchecked Sendable { var granted = false }
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        box.granted = granted
        semaphore.signal()
    }
    semaphore.wait()
    return box.granted
}

guard micPermissionGranted() else {
    print("\nmicrophone permission denied — grant it for your terminal in "
          + "System Settings → Privacy & Security → Microphone")
    exit(1)
}

// MARK: - Capture

final class Run: @unchecked Sendable {
    let lock = NSLock()
    var readings = 0
    var gaps = 0
    var first: Timecode?
    var last: Timecode?
    var firstHostTime: Double?
    var lastHostTime: Double = 0
    var fpsSum = 0.0
    var peak: Float = 0
    var drops = 0
    var droppedFrames: Int64 = 0
}
let run = Run()

let input = LTCAudioInput()
input.preferredDeviceMatch = opts.device
input.assumedRate = opts.rate
input.onLevel = { peak in
    run.lock.lock(); run.peak = max(run.peak, peak); run.lock.unlock()
}
input.onDrop = { missing in
    run.lock.lock(); run.drops += 1; run.droppedFrames += missing; run.lock.unlock()
}
input.onReading = { reading in
    run.lock.lock()
    defer { run.lock.unlock() }
    if run.first == nil { run.first = reading.result.timecode }
    if let last = run.last, reading.result.timecode != last.adding(frames: 1) { run.gaps += 1 }
    run.last = reading.result.timecode
    if run.firstHostTime == nil { run.firstHostTime = reading.hostTime }
    run.lastHostTime = reading.hostTime
    run.readings += 1
    run.fpsSum += reading.result.measuredFPS
}

do {
    try input.start()
} catch {
    print("\nstart failed: \(error.localizedDescription)")
    exit(1)
}

print("\n=== LISTENING for \(Int(opts.seconds))s ===")
let deadline = Date().addingTimeInterval(opts.seconds)
var second = 0
while Date() < deadline {
    Thread.sleep(forTimeInterval: 1)
    second += 1
    run.lock.lock()
    print(String(format: "  t=%2ds  decoded=%5d  gaps=%3d  drops=%d/%d  peak=%.3f  tc=%@",
                 second, run.readings, run.gaps, run.drops, run.droppedFrames,
                 run.peak, (run.last.map(String.init(describing:)) ?? "—") as NSString))
    run.peak = 0
    run.lock.unlock()
}
input.stop()

// MARK: - Report

run.lock.lock()
print("\n=== RESULT ===")
print("  input              \(input.currentInputDescription)")
print("  external           \(input.isExternalInputConnected)")
print("  selection          \(input.preferredInputOutcome)")
print(String(format: "  DROPS              %d events, %d frames", input.dropEventCount, input.droppedFrameCount))
print("  decoded            \(run.readings) frames, \(run.gaps) discontinuities")
print("  detected rate      \(input.decoder?.detectedRate?.displayName ?? "unknown")")

if let first = run.first, let last = run.last, run.readings > 1 {
    print("  timecode           \(first) → \(last)")
    print(String(format: "  measured fps       %.4f", run.fpsSum / Double(run.readings)))

    // Yield is the honest pass/fail. A contiguous run of timecode with every
    // frame present is the only result that proves the whole path.
    let span = last.frameNumber - first.frameNumber + 1
    print(String(format: "  frame yield        %d of %d (%.1f%%)",
                 run.readings, span, 100 * Double(run.readings) / Double(span)))

    // Cross-check the source's clock against this machine's, by comparing the
    // timecode elapsed with the host time elapsed over the same frames.
    //
    // Reported with its own resolution, because that resolution is brutal:
    // timecode is quantised to whole frames, so a short run cannot resolve
    // drift at all. Ten seconds at 24 fps buys ±4200 ppm — worse than the
    // error being looked for. Only a run of minutes says anything.
    let tcElapsed = Double(span - 1) / Double(last.rate.nominalFPS)
    let hostElapsed = run.lastHostTime - (run.firstHostTime ?? 0)
    if hostElapsed > 0 {
        let ppm = 1e6 * (tcElapsed / hostElapsed - 1)
        let resolution = 1e6 / Double(last.rate.nominalFPS) / hostElapsed
        print(String(format: "  source vs host     %+.1f ppm over %.1f s (±%.0f ppm resolution)",
                     ppm, hostElapsed, resolution))
        if abs(ppm) < resolution {
            print("                     — within quantisation noise; run for minutes to measure drift")
        }
    }

    let ok = run.gaps == 0 && input.dropEventCount == 0 && run.readings == span
    print("\n  \(ok ? "PASS — contiguous, no gaps, no dropped capture" : "FAIL — see gaps/drops above")")
} else {
    print("\n  FAIL — nothing decoded. Check the interface is selected and the "
          + "generator is running.")
}
run.lock.unlock()
