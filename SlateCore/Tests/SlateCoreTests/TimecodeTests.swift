import XCTest
@testable import SlateCore

final class TimecodeTests: XCTestCase {

    func testFrameNumberRoundTripAllRates() {
        for rate in TimecodeRate.allCases {
            let n = rate.nominalFPS
            let framesPerDay = n * 3600 * 24 - (rate.isDropFrame ? rate.dropCount * (1440 - 144) : 0)
            // Step through a full 24 hours; stride keeps runtime sane while
            // still crossing every drop-frame boundary shape.
            for f in stride(from: 0, to: framesPerDay, by: 7) {
                let tc = Timecode(frameNumber: f, rate: rate)
                XCTAssertEqual(tc.frameNumber, f, "round trip failed at \(f) for \(rate.displayName) -> \(tc)")
                XCTAssertTrue(tc.isValid, "produced invalid tc \(tc) at frame \(f) for \(rate.displayName)")
            }
        }
    }

    func testDropFrameSkipsExpectedNumbers() {
        let rate = TimecodeRate.fps29_97df
        // At the top of minute 1, frames :00 and :01 do not exist.
        let beforeBoundary = Timecode(hours: 0, minutes: 0, seconds: 59, frames: 29, rate: rate)
        let after = beforeBoundary.adding(frames: 1)
        XCTAssertEqual(after.minutes, 1)
        XCTAssertEqual(after.seconds, 0)
        XCTAssertEqual(after.frames, 2, "29.97DF must skip frames 0 and 1 at minute 1")

        // Minute 10 is exempt.
        let beforeTen = Timecode(hours: 0, minutes: 9, seconds: 59, frames: 29, rate: rate)
        let afterTen = beforeTen.adding(frames: 1)
        XCTAssertEqual(afterTen.minutes, 10)
        XCTAssertEqual(afterTen.frames, 0, "minute 10 must not drop")
    }

    func testDropFrameTracksWallClock() {
        // The point of drop frame: after one hour of 29.97, the timecode should
        // read very close to one hour.
        let rate = TimecodeRate.fps29_97df
        let oneHour = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: rate)
        let realSeconds = oneHour.elapsedSeconds
        XCTAssertEqual(realSeconds, 3600.0, accuracy: 0.15,
                       "drop frame should track wall clock to well under a second per hour")

        // Non-drop 29.97 drifts by the familiar ~3.6 seconds per hour.
        let ndf = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: .fps29_97ndf)
        XCTAssertEqual(ndf.elapsedSeconds - 3600.0, 3.6, accuracy: 0.1)
    }

    func testInvalidDropFrameValuesRejected() {
        let bad = Timecode(hours: 0, minutes: 1, seconds: 0, frames: 0, rate: .fps29_97df)
        XCTAssertFalse(bad.isValid, "00:01:00;00 does not exist in drop frame")
        let good = Timecode(hours: 0, minutes: 1, seconds: 0, frames: 2, rate: .fps29_97df)
        XCTAssertTrue(good.isValid)
    }

    func testDescriptionUsesSemicolonForDropFrame() {
        XCTAssertEqual(Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: .fps24).description,
                       "01:02:03:04")
        XCTAssertEqual(Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: .fps29_97df).description,
                       "01:02:03;04")
    }

    func testMidnightWraps() {
        let tc = Timecode(hours: 23, minutes: 59, seconds: 59, frames: 23, rate: .fps24)
        XCTAssertEqual(tc.adding(frames: 1).description, "00:00:00:00")
    }
}
