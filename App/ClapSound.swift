#if os(iOS)
import AVFoundation
import Foundation

/// The audible half of a clapperboard.
///
/// A physical slate syncs picture to sound because the camera sees the sticks
/// meet and the recorder hears the crack. The visual freeze covers the picture
/// side; this covers the sound side.
///
/// **Why this uses `AVAudioEngine` and not `AVAudioPlayer`.** `player.play()`
/// means "start as soon as you can", which is a promise about the main thread,
/// not about time. Measured on device, the crack landed roughly three frames
/// after the visual sync point. `AVAudioPlayerNode` can instead be handed an
/// absolute host time and will render the buffer *at* it, on the audio thread,
/// with no main-thread involvement at the moment that matters.
///
/// That is only possible because the clap is armed half a second ahead (see
/// `SlateViewModel.clap()`). The lead time is what turns the sound from
/// best-effort into scheduled.
///
/// The waveform is synthesised rather than shipped as an asset: a clap is a
/// broadband transient with a very fast decay, which is a few lines of maths.
@MainActor
final class ClapSound {
    static let shared = ClapSound()

    private var engine = AVAudioEngine()
    private var node = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer?
    private var configObserver: NSObjectProtocol?

    private var attached = false
    /// Last engine failure, surfaced on the diagnostics sheet. Silence is very
    /// hard to debug on a device you cannot attach a console to.
    private(set) var lastError: String?

    private init() {
        buffer = Self.renderBuffer()
        ensureGraph()
        // Deactivating the audio session — which capture does on every jam,
        // taken or cancelled — does not merely stop the engine on a real
        // device: it invalidates the graph, and the node's connection to the
        // mixer goes with it. Restarting alone then yields silence, which is
        // why this was device-only and invisible in the simulator.
        observeConfigurationChanges()
    }

    private func observeConfigurationChanges() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { _ in
            Task { @MainActor in ClapSound.shared.recover() }
        }
    }

    /// Throw the engine away and build a new one.
    ///
    /// An `AVAudioEngine` is bound to the audio session it was started against.
    /// Once that session has been pulled out from under it the engine can end up
    /// permanently unable to start again — attached, connected, and refusing to
    /// run, which is exactly what the diagnostics reported. Nothing recovers it
    /// short of a fresh instance.
    private func rebuild() {
        engine.stop()
        engine = AVAudioEngine()
        node = AVAudioPlayerNode()
        attached = false
        ensureGraph()
        observeConfigurationChanges()
    }

    /// Attach and connect the player, if that is not already true.
    private func ensureGraph() {
        guard let buffer else { return }
        if !attached {
            engine.attach(node)
            attached = true
        }
        if engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty {
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        }
    }

    private func recover() {
        ensureGraph()
        start()
    }

    /// Engine state in words, for the diagnostics sheet.
    var statusDescription: String {
        var parts = ["engine \(engine.isRunning ? "running" : "stopped")",
                     "player \(node.isPlaying ? "playing" : "idle")",
                     engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty
                        ? "NOT connected" : "connected"]
        if let lastError { parts.append("last error: \(lastError)") }
        return parts.joined(separator: ", ")
    }

    /// Claim the audio route and spin the engine up ahead of time.
    ///
    /// `setCategory`/`setActive` are synchronous calls into `mediaserverd` and
    /// can block for a long time — doing that on the clap path once stalled the
    /// display link for seconds, freezing the slate on a stale running
    /// timecode. All of it belongs here, off the main thread, well before the
    /// sync point.
    nonisolated func prewarm() {
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            // `.playback`, not `.ambient`: ambient obeys the Ring/Silent
            // switch — independent of the volume buttons — so on a phone
            // flipped to silent the clap never sounds. `.mixWithOthers` stops
            // it interrupting anything else the crew has running.
            try? session.setCategory(.playback, mode: .default,
                                     options: [.mixWithOthers])
            try? session.setActive(true)
            await MainActor.run { Self.shared.start() }
        }
    }

    /// Bring the engine up, or back up.
    ///
    /// **State is read from the engine, never cached.** This used to keep an
    /// `isRunning` flag, which was wrong in a way that silenced the clap for the
    /// rest of a session: deactivating the audio session — which is exactly what
    /// `LTCAudioInput.stop()` does after a jam is taken or cancelled — stops the
    /// engine underneath us, and the flag stayed `true`. Every later call then
    /// short-circuited, and buffers were scheduled onto a dead engine.
    private func start() {
        guard buffer != nil else { return }
        // Rebuild the graph first — after a session deactivation the node can
        // still be attached while its connection to the mixer has gone.
        ensureGraph()
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
                lastError = nil
            } catch {
                // One retry on a clean engine. A failure here is almost always
                // an engine outliving the session it was started against, and a
                // new one starts where the old one never will again.
                lastError = "start failed (\(error.localizedDescription)); rebuilding"
                rebuild()
                engine.prepare()
                do {
                    try engine.start()
                    lastError = nil
                } catch {
                    lastError = "rebuild failed: \(error.localizedDescription)"
                    return
                }
            }
        }
        // The node runs continuously and idles silently; scheduled buffers then
        // fire at their appointed time rather than "whenever play() gets
        // called". It stops along with the engine, so it needs restarting too.
        if engine.isRunning, !node.isPlaying {
            node.play()
        }
    }

    /// Schedule the crack to *emerge from the speaker* at `hostTime`.
    ///
    /// Output latency is subtracted, because the target is when the sound
    /// reaches the room, not when it enters the render graph.
    func schedule(atHostTime hostTime: Double) {
        start()
        guard engine.isRunning, let buffer else { return }

        let latency = AVAudioSession.sharedInstance().outputLatency
            + engine.outputNode.presentationLatency
        // Never schedule in the past; if the lead was too short, fire promptly.
        let target = max(hostTime - latency, CACurrentMediaTime() + 0.002)
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: target))
        node.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
    }

    // MARK: - Synthesis

    private static func renderBuffer(sampleRate: Double = 44100) -> AVAudioPCMBuffer? {
        let duration = 0.07
        let count = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: count),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = count

        // Deterministic noise, so the clap is identical every time and there is
        // no per-launch variation to chase if it ever sounds wrong.
        var seed: UInt32 = 0x9E3779B9
        func nextNoise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) * 2 - 1
        }

        var peak: Float = 0
        for i in 0..<Int(count) {
            let t = Double(i) / sampleRate
            // Two decays: a very fast one for the crack, a slower low-mid body
            // so it carries in a room instead of sounding like a click.
            let crack = Float(exp(-t / 0.004))
            let body = Float(exp(-t / 0.020))
            let tone = Float(sin(2 * .pi * 1_150 * t))
            let sample = crack * nextNoise() * 0.85 + body * tone * 0.35
            channel[i] = sample
            peak = max(peak, abs(sample))
        }

        if peak > 0 {
            let gain = 0.92 / peak
            for i in 0..<Int(count) { channel[i] *= gain }
        }

        // A couple of milliseconds of fade-out so the tail does not click.
        let fade = Int(sampleRate * 0.003)
        for i in 0..<min(fade, Int(count)) {
            channel[Int(count) - 1 - i] *= Float(i) / Float(fade)
        }
        return buffer
    }
}
#endif
