#if os(macOS)
import CoreAudio
import Foundation

/// CoreAudio input-device enumeration and the input latency budget.
///
/// This exists so a timecode interface can be exercised end to end from the
/// command line, against real hardware, with no phone and no simulator in the
/// way — the same reason the decoder itself lives in a platform-independent
/// package. iOS picks inputs through `AVAudioSession` port descriptions;
/// macOS has no such thing, so device selection genuinely differs per platform
/// even though everything above it is shared.
public struct AudioInputDevice: Sendable, Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let channels: Int
    public let sampleRate: Double
}

/// The delay between a sample arriving at the converter and this process being
/// handed it. A jam that does not subtract this is systematically late by it.
public struct InputLatencyBudget: Sendable {
    public let deviceLatency: UInt32
    public let safetyOffset: UInt32
    public let bufferFrames: UInt32
    public let sampleRate: Double

    public var totalFrames: UInt32 { deviceLatency + safetyOffset + bufferFrames }
    public var totalSeconds: Double { Double(totalFrames) / sampleRate }

    public var report: String {
        func ms(_ f: UInt32) -> String { String(format: "%6.2f ms", 1000 * Double(f) / sampleRate) }
        return """
          device latency   \(String(format: "%5d", deviceLatency)) frames  \(ms(deviceLatency))
          safety offset    \(String(format: "%5d", safetyOffset)) frames  \(ms(safetyOffset))
          buffer size      \(String(format: "%5d", bufferFrames)) frames  \(ms(bufferFrames))
          ------------------------------------------------
          total            \(String(format: "%5d", totalFrames)) frames  \(ms(totalFrames))
        """
    }
}

public enum MacAudioDevices {

    public static func inputs() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                name: stringProperty(id, kAudioObjectPropertyName) ?? "unknown",
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
                channels: channels,
                sampleRate: nominalSampleRate(id) ?? 0)
        }
    }

    /// First input device whose name contains `match`, case-insensitively.
    public static func input(matching match: String) -> AudioInputDevice? {
        inputs().first { $0.name.localizedCaseInsensitiveContains(match) }
    }

    public static func defaultInput() -> AudioInputDevice? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return inputs().first { $0.id == id }
    }

    public static func latencyBudget(_ id: AudioDeviceID) -> InputLatencyBudget {
        InputLatencyBudget(
            deviceLatency: uintProperty(id, kAudioDevicePropertyLatency,
                                        scope: kAudioObjectPropertyScopeInput) ?? 0,
            safetyOffset: uintProperty(id, kAudioDevicePropertySafetyOffset,
                                       scope: kAudioObjectPropertyScopeInput) ?? 0,
            bufferFrames: uintProperty(id, kAudioDevicePropertyBufferFrameSize,
                                       scope: kAudioObjectPropertyScopeGlobal) ?? 0,
            sampleRate: nominalSampleRate(id) ?? 48000)
    }

    /// Request a device buffer size. Returns what the driver actually settled
    /// on, which is frequently not what was asked for.
    @discardableResult
    public static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: UInt32) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var want = frames
        AudioObjectSetPropertyData(id, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &want)
        return uintProperty(id, kAudioDevicePropertyBufferFrameSize,
                            scope: kAudioObjectPropertyScopeGlobal) ?? 0
    }

    // MARK: - Property helpers

    static func stringProperty(_ id: AudioDeviceID,
                               _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func uintProperty(_ id: AudioDeviceID,
                             _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return Int(UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels })
    }
}
#endif
