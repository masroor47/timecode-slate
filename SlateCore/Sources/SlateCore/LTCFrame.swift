import Foundation

/// One SMPTE 12M linear timecode word: 64 data bits followed by a 16-bit sync
/// word. Bit 0 is transmitted first.
///
/// Layout (SMPTE 12M-1):
/// ```
///  0- 3  frame units (BCD)      32-35  minute units
///  4- 7  user group 1           36-39  user group 5
///  8- 9  frame tens             40-42  minute tens
/// 10     drop frame flag        43     BGF0        (25fps: polarity)
/// 11     colour frame flag      44-47  user group 6
/// 12-15  user group 2           48-51  hour units
/// 16-19  second units           52-55  user group 7
/// 20-23  user group 3           56-57  hour tens
/// 24-26  second tens            58     BGF1
/// 27     polarity  (25fps: BGF0) 59    BGF2
/// 28-31  user group 4           60-63  user group 8
/// ```
public struct LTCFrame: Equatable, Sendable {

    /// The 16-bit sync word as it sits in a shift register whose *newest* bit
    /// is at position 15. Wire order (bit 64 first) is 0011111111111101.
    public static let syncWord: UInt16 = 0xBFFC

    public var hours: Int = 0
    public var minutes: Int = 0
    public var seconds: Int = 0
    public var frames: Int = 0

    public var dropFrame: Bool = false
    public var colorFrame: Bool = false

    /// Eight 4-bit user groups, group 1 first. Commonly carries a date or reel ID.
    public var userBits: [UInt8] = Array(repeating: 0, count: 8)

    public var bgf0: Bool = false
    public var bgf1: Bool = false
    public var bgf2: Bool = false

    public init() {}

    public init(timecode: Timecode, userBits: [UInt8] = Array(repeating: 0, count: 8)) {
        self.hours = timecode.hours
        self.minutes = timecode.minutes
        self.seconds = timecode.seconds
        self.frames = timecode.frames
        self.dropFrame = timecode.rate.isDropFrame
        self.userBits = userBits.count == 8 ? userBits : Array(repeating: 0, count: 8)
    }

    public func timecode(rate: TimecodeRate) -> Timecode {
        Timecode(hours: hours, minutes: minutes, seconds: seconds, frames: frames, rate: rate)
    }

    // MARK: - Bit packing

    /// Pack into the 64 data bits, bit 0 in the least significant position.
    ///
    /// `polarityCorrected` sets the phase-correction bit so the whole 80-bit
    /// word contains an even number of zero bits, which is what keeps the
    /// waveform polarity constant frame to frame.
    public func dataBits(rate: TimecodeRate, polarityCorrected: Bool = true) -> UInt64 {
        var bits: UInt64 = 0

        func put(_ value: Int, at offset: Int, width: Int) {
            let mask = (UInt64(1) << UInt64(width)) - 1
            bits |= (UInt64(value) & mask) << UInt64(offset)
        }
        func putFlag(_ value: Bool, at offset: Int) {
            if value { bits |= UInt64(1) << UInt64(offset) }
        }

        put(frames % 10, at: 0, width: 4)
        put(Int(userBits[0]), at: 4, width: 4)
        put(frames / 10, at: 8, width: 2)
        putFlag(dropFrame, at: 10)
        putFlag(colorFrame, at: 11)
        put(Int(userBits[1]), at: 12, width: 4)

        put(seconds % 10, at: 16, width: 4)
        put(Int(userBits[2]), at: 20, width: 4)
        put(seconds / 10, at: 24, width: 3)
        put(Int(userBits[3]), at: 28, width: 4)

        put(minutes % 10, at: 32, width: 4)
        put(Int(userBits[4]), at: 36, width: 4)
        put(minutes / 10, at: 40, width: 3)
        put(Int(userBits[5]), at: 44, width: 4)

        put(hours % 10, at: 48, width: 4)
        put(Int(userBits[6]), at: 52, width: 4)
        put(hours / 10, at: 56, width: 2)
        put(Int(userBits[7]), at: 60, width: 4)

        // Binary group flags. At 25 fps the polarity bit and BGF0 swap places.
        let polarityBit = (rate.nominalFPS == 25) ? 59 : 27
        let bgf0Bit = (rate.nominalFPS == 25) ? 27 : 43
        putFlag(bgf0, at: bgf0Bit)
        putFlag(bgf1, at: 58)
        if rate.nominalFPS != 25 { putFlag(bgf2, at: 59) }

        if polarityCorrected {
            // The whole 80-bit word must contain an even number of zeros. The
            // sync word 0011111111111101 contributes 3 of them, so the 64 data
            // bits need an odd count to make the total even. Setting the
            // polarity bit turns one 0 into a 1, flipping the parity.
            let zeros = 64 - bits.nonzeroBitCount
            if zeros % 2 == 0 {
                bits |= UInt64(1) << UInt64(polarityBit)
            }
        }
        return bits
    }

    /// Unpack from the 64 data bits.
    public init(dataBits bits: UInt64, rate: TimecodeRate) {
        func get(_ offset: Int, _ width: Int) -> Int {
            let mask = (UInt64(1) << UInt64(width)) - 1
            return Int((bits >> UInt64(offset)) & mask)
        }
        func flag(_ offset: Int) -> Bool {
            (bits >> UInt64(offset)) & 1 == 1
        }

        self.frames = get(8, 2) * 10 + get(0, 4)
        self.seconds = get(24, 3) * 10 + get(16, 4)
        self.minutes = get(40, 3) * 10 + get(32, 4)
        self.hours = get(56, 2) * 10 + get(48, 4)

        self.dropFrame = flag(10)
        self.colorFrame = flag(11)

        self.userBits = [
            UInt8(get(4, 4)), UInt8(get(12, 4)), UInt8(get(20, 4)), UInt8(get(28, 4)),
            UInt8(get(36, 4)), UInt8(get(44, 4)), UInt8(get(52, 4)), UInt8(get(60, 4)),
        ]

        let bgf0Bit = (rate.nominalFPS == 25) ? 27 : 43
        self.bgf0 = flag(bgf0Bit)
        self.bgf1 = flag(58)
        self.bgf2 = (rate.nominalFPS == 25) ? false : flag(59)
    }

    /// The user bits rendered the way a slate or recorder usually shows them.
    public var userBitsString: String {
        userBits.map { String(format: "%X", $0) }
            .enumerated()
            .reduce(into: "") { acc, pair in
                if pair.offset > 0 && pair.offset % 2 == 0 { acc += ":" }
                acc += pair.element
            }
    }

    /// Emit the full 80-bit sequence in transmission order (bit 0 first).
    public static func bitSequence(dataBits: UInt64) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(80)
        for i in 0..<64 {
            out.append(UInt8((dataBits >> UInt64(i)) & 1))
        }
        // Sync word on the wire, bit 64 first.
        let sync: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
        out.append(contentsOf: sync)
        return out
    }
}
