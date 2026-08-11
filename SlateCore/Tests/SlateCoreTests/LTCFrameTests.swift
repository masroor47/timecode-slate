import XCTest
@testable import SlateCore

final class LTCFrameTests: XCTestCase {

    func testSyncWordMatchesWireOrder() {
        // Wire order, bit 64 first, is 0011111111111101. Shifted into a register
        // whose newest bit lands at position 15, that must equal LTCFrame.syncWord.
        let wire: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]
        var reg: UInt16 = 0
        for bit in wire {
            reg = (reg >> 1) | (UInt16(bit) << 15)
        }
        XCTAssertEqual(reg, LTCFrame.syncWord)
        XCTAssertEqual(LTCFrame.syncWord, 0xBFFC)
    }

    func testBitPackingRoundTrip() {
        for rate in [TimecodeRate.fps24, .fps25, .fps29_97df, .fps30] {
            for _ in 0..<200 {
                let tc = Timecode(frameNumber: Int.random(in: 0..<2_000_000), rate: rate)
                let ub: [UInt8] = (0..<8).map { _ in UInt8.random(in: 0...15) }
                var frame = LTCFrame(timecode: tc)
                frame.userBits = ub

                let bits = frame.dataBits(rate: rate)
                let decoded = LTCFrame(dataBits: bits, rate: rate)

                XCTAssertEqual(decoded.hours, tc.hours)
                XCTAssertEqual(decoded.minutes, tc.minutes)
                XCTAssertEqual(decoded.seconds, tc.seconds)
                XCTAssertEqual(decoded.frames, tc.frames)
                XCTAssertEqual(decoded.dropFrame, rate.isDropFrame)
                XCTAssertEqual(decoded.userBits, ub, "user bits must survive the round trip")
            }
        }
    }

    func testPolarityCorrectionYieldsEvenZeroCount() {
        // SMPTE requires the 80-bit word to hold an even number of zeros so the
        // waveform polarity stays constant frame to frame.
        for rate in [TimecodeRate.fps24, .fps25, .fps30] {
            for f in stride(from: 0, to: 500_000, by: 1013) {
                let tc = Timecode(frameNumber: f, rate: rate)
                let bits = LTCFrame(timecode: tc).dataBits(rate: rate, polarityCorrected: true)
                let sequence = LTCFrame.bitSequence(dataBits: bits)
                let zeros = sequence.filter { $0 == 0 }.count
                XCTAssertEqual(zeros % 2, 0, "odd zero count for \(tc) at \(rate.displayName)")
            }
        }
    }

    func testBitSequenceIsEightyBits() {
        let bits = LTCFrame(timecode: Timecode(hours: 1, rate: .fps24)).dataBits(rate: .fps24)
        XCTAssertEqual(LTCFrame.bitSequence(dataBits: bits).count, 80)
    }

    func testDropFrameFlagIsBitTen() {
        let df = LTCFrame(timecode: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 2, rate: .fps29_97df))
        XCTAssertEqual((df.dataBits(rate: .fps29_97df) >> 10) & 1, 1)

        let ndf = LTCFrame(timecode: Timecode(hours: 1, rate: .fps30))
        XCTAssertEqual((ndf.dataBits(rate: .fps30) >> 10) & 1, 0)
    }
}
