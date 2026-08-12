#if os(iOS)
import AVFoundation
import Foundation

/// A snapshot of what iOS believes about audio input, for the on-device
/// diagnostics screen.
///
/// This exists because the phone cannot be tethered while a USB-C timecode
/// interface is plugged into its only port, so every question about routing has
/// to be answered on the phone's own screen. The distinction that matters is
/// between an interface iOS never enumerated — a power or class-compliance
/// problem, nothing to do with this app — and one that was enumerated and then
/// not selected, which is ours to fix.
public struct AudioDiagnostics: Sendable {

    public struct Port: Sendable, Identifiable, Equatable {
        public let id: String
        public let name: String
        public let type: String
        public let channels: Int
        /// True when this port is the one actually feeding the engine.
        public let isActive: Bool
        /// True for the ports a timecode signal could plausibly arrive on.
        public let isExternal: Bool
    }

    public var category = ""
    public var mode = ""
    public var availableInputs: [Port] = []
    public var activeInputs: [Port] = []
    public var sessionSampleRate: Double = 0
    public var ioBufferDuration: Double = 0
    public var inputLatency: Double = 0
    public var inputChannelCount: Int = 0
    public var engineInputFormat: String?
    public var preferredInputOutcome: String?
    public var probeError: String?
    /// Frames actually delivered per tap buffer, and the latency subtracted
    /// from each jam. Only meaningful while capture is running.
    public var observedBufferFrames: Int?
    public var compensatedLatency: Double?

    public var externalInputs: [Port] { availableInputs.filter(\.isExternal) }
    public var activeInputIsExternal: Bool { activeInputs.contains { $0.isExternal } }

    /// The one line worth reading first, phrased as what to do next.
    public var verdict: String {
        if let probeError { return "Session probe failed: \(probeError)" }
        if availableInputs.isEmpty {
            return "iOS reported no inputs at all. Arm JAM and probe again — "
                 + "availableInputs is empty outside a recording category."
        }
        if externalInputs.isEmpty {
            return "iOS is not enumerating the interface. Only "
                 + availableInputs.map(\.type).joined(separator: ", ")
                 + " is offered, so this is upstream of the app — power, "
                 + "cable, or the adapter not being class-compliant on iOS."
        }
        if activeInputIsExternal {
            let names = activeInputs.filter(\.isExternal).map(\.name).joined(separator: ", ")
            return "Routed to \(names). Input path is good; any failure from "
                 + "here is level or decoding, not routing."
        }
        return "Interface IS enumerated (\(externalInputs.map(\.name).joined(separator: ", "))) "
             + "but iOS is still routing to \(activeInputs.map(\.name).joined(separator: ", "))"
             + ". This is a routing bug in the app, not a hardware problem."
    }

    /// Flat text, so the whole snapshot can be copied off an untethered phone.
    public var report: String {
        var out = "TIMECODE SLATE — INPUT DIAGNOSTICS\n"
        out += "\nVERDICT\n  \(verdict)\n"
        out += "\nSESSION\n"
        out += "  category           \(category)\n"
        out += "  mode               \(mode)\n"
        out += String(format: "  sample rate        %.0f Hz\n", sessionSampleRate)
        out += String(format: "  IO buffer          %.2f ms\n", ioBufferDuration * 1000)
        out += String(format: "  input latency      %.2f ms\n", inputLatency * 1000)
        out += "  input channels     \(inputChannelCount)\n"
        out += "  engine format      \(engineInputFormat ?? "—")\n"
        out += "  preferred input    \(preferredInputOutcome ?? "—")\n"
        if let frames = observedBufferFrames, sessionSampleRate > 0 {
            out += String(format: "  actual tap buffer  %d frames (%.2f ms)\n",
                          frames, 1000 * Double(frames) / sessionSampleRate)
        }
        if let latency = compensatedLatency {
            out += String(format: "  jam compensation   %.2f ms subtracted\n", latency * 1000)
        }
        out += "\nAVAILABLE INPUTS (\(availableInputs.count))\n"
        if availableInputs.isEmpty { out += "  none\n" }
        for p in availableInputs {
            out += "  \(p.isActive ? "▶" : " ") \(p.name)\n"
            out += "      type \(p.type)   channels \(p.channels)"
                 + (p.isExternal ? "   [external]" : "") + "\n"
        }
        out += "\nACTIVE ROUTE\n"
        if activeInputs.isEmpty { out += "  none\n" }
        for p in activeInputs { out += "  \(p.name)  [\(p.type)]  \(p.channels) ch\n" }
        return out
    }

    // MARK: - Capture

    /// Ports a timecode signal can realistically arrive on.
    private static let externalPorts: Set<AVAudioSession.Port> = [
        .usbAudio, .headsetMic, .lineIn, .bluetoothHFP, .carAudio, .airPlay
    ]

    private static func describe(_ d: AVAudioSessionPortDescription,
                                 activeUIDs: Set<String>) -> Port {
        Port(id: d.uid,
             name: d.portName,
             type: d.portType.rawValue,
             channels: d.channels?.count ?? 0,
             isActive: activeUIDs.contains(d.uid),
             isExternal: externalPorts.contains(d.portType))
    }

    /// Read the current state without touching the session.
    ///
    /// Note that `availableInputs` is empty unless the session is in a
    /// recording category, so at rest — which is where this app deliberately
    /// spends most of its life, microphone off — this reports very little. Use
    /// `probe()` to answer the routing question from a standing start.
    public static func current() -> AudioDiagnostics {
        let session = AVAudioSession.sharedInstance()
        var d = AudioDiagnostics()
        let activeUIDs = Set(session.currentRoute.inputs.map(\.uid))
        d.category = session.category.rawValue
        d.mode = session.mode.rawValue
        d.availableInputs = (session.availableInputs ?? []).map { describe($0, activeUIDs: activeUIDs) }
        d.activeInputs = session.currentRoute.inputs.map { describe($0, activeUIDs: activeUIDs) }
        d.sessionSampleRate = session.sampleRate
        d.ioBufferDuration = session.ioBufferDuration
        d.inputLatency = session.inputLatency
        d.inputChannelCount = session.inputNumberOfChannels
        return d
    }

    /// Configure a recording session exactly as capture would, read everything,
    /// then stand back down.
    ///
    /// **Call this off the main thread.** `setCategory`/`setActive` are
    /// synchronous IPC to `mediaserverd` and have been measured blocking for
    /// seconds on this project; doing it on the main thread stalls the display
    /// link and freezes the slate on a stale timecode.
    public static func probe() -> AudioDiagnostics {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(48000)
            try session.setActive(true)
        } catch {
            // Report and carry on: a partially configured session still tells
            // us which ports iOS is willing to admit exist.
            var d = current()
            d.probeError = error.localizedDescription
            return d
        }

        // Ask for the external input, so the snapshot reflects what capture
        // would actually get rather than the idle default.
        var outcome = "no external input offered"
        if let inputs = session.availableInputs {
            let order: [AVAudioSession.Port] = [.usbAudio, .headsetMic, .lineIn]
            if let match = order.compactMap({ port in inputs.first { $0.portType == port } }).first {
                do {
                    try session.setPreferredInput(match)
                    outcome = "requested \(match.portName) [\(match.portType.rawValue)]"
                } catch {
                    outcome = "setPreferredInput(\(match.portName)) FAILED: \(error.localizedDescription)"
                }
            } else {
                outcome += "; saw " + inputs.map(\.portType.rawValue).joined(separator: ", ")
            }
        }

        var d = current()
        d.preferredInputOutcome = outcome

        // Leave the microphone off again — the whole privacy design of this app
        // is that it listens only between arming a jam and getting one.
        try? session.setActive(false)
        return d
    }
}
#endif
