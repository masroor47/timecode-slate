import XCTest
@testable import SlateCore

final class SlateStateTests: XCTestCase {

    private func makeState() -> SlateState {
        var info = SlateInfo()
        info.scene = "24"
        info.shot = "A"
        info.take = 1
        return SlateState(info: info)
    }

    func testClapHoldsThenResumes() {
        let state = makeState()
        let tc = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, rate: .fps24)

        XCTAssertEqual(state.mode, .running)
        let event = state.clap(timecode: tc, atHostTime: 100.0)
        XCTAssertEqual(state.mode, .held(event))

        // Still frozen partway through the hold (4 frames + 0.5 s = 667 ms).
        state.tick(atHostTime: 100.3)
        XCTAssertEqual(state.mode, .held(event))

        // Released once the hold expires.
        state.tick(atHostTime: 100.7)
        XCTAssertEqual(state.mode, .running)
    }

    func testTakeAdvancesOnResumeNotOnClap() {
        let state = makeState()
        let tc = Timecode(hours: 1, rate: .fps24)

        let first = state.clap(timecode: tc, atHostTime: 0)
        XCTAssertEqual(first.take, 1, "the frozen display must show the take just shot")
        XCTAssertEqual(state.info.take, 1,
                       "the counter must not move while the slate is still being photographed")

        state.release()
        XCTAssertEqual(state.info.take, 2, "resuming readies the next take")

        let second = state.clap(timecode: tc, atHostTime: 10)
        XCTAssertEqual(second.take, 2)
        XCTAssertEqual(state.info.take, 2)
        state.release()
        XCTAssertEqual(state.info.take, 3)
    }

    /// Whether the hold ends on the timer or by hand, the take must advance
    /// exactly once — never twice, never not at all.
    func testTimedReleaseAlsoAdvancesTakeExactlyOnce() {
        let state = makeState()
        state.clap(timecode: Timecode(hours: 1, rate: .fps24), atHostTime: 100)

        state.tick(atHostTime: 100.3)
        XCTAssertEqual(state.info.take, 1, "still holding")

        state.tick(atHostTime: 100.7)
        XCTAssertEqual(state.info.take, 2)

        state.tick(atHostTime: 110.0)
        XCTAssertEqual(state.info.take, 2, "a second tick must not advance it again")

        state.release()
        XCTAssertEqual(state.info.take, 2, "releasing when not held must be a no-op")
    }

    func testHoldShowsTimecodeThenUserBits() {
        let state = makeState()   // 4 frames of timecode, then 0.5 s of user bits
        state.clap(timecode: Timecode(hours: 1, rate: .fps24), atHostTime: 100)

        // 4 frames at 24 fps = 166.7 ms.
        XCTAssertEqual(state.holdPhase(atHostTime: 100.0), .timecode)
        XCTAssertEqual(state.holdPhase(atHostTime: 100.16), .timecode)
        XCTAssertEqual(state.holdPhase(atHostTime: 100.17), .userBits)
        XCTAssertEqual(state.holdPhase(atHostTime: 100.6), .userBits)

        state.release()
        XCTAssertNil(state.holdPhase(atHostTime: 100.7), "not holding any more")
    }

    /// The timecode window is specified in frames, so it must scale with the
    /// clapped rate rather than being a fixed number of seconds.
    func testTimecodeHoldScalesWithFrameRate() {
        let state = makeState()

        state.clap(timecode: Timecode(hours: 1, rate: .fps24), atHostTime: 0)
        XCTAssertEqual(state.holdPhase(atHostTime: 0.15), .timecode, "4/24 = 167 ms")
        state.release()

        state.clap(timecode: Timecode(hours: 1, rate: .fps60), atHostTime: 0)
        XCTAssertEqual(state.holdPhase(atHostTime: 0.15), .userBits,
                       "4/60 = 67 ms, so 150 ms is already past the timecode window")
    }

    func testHoldReleasesAfterTimecodePlusUserBits() {
        let state = makeState()
        state.clap(timecode: Timecode(hours: 1, rate: .fps24), atHostTime: 100)

        state.tick(atHostTime: 100.6)
        XCTAssertEqual(state.mode, .held(state.history[0]), "0.167 + 0.5 not yet elapsed")

        state.tick(atHostTime: 100.7)
        XCTAssertEqual(state.mode, .running)
        XCTAssertEqual(state.info.take, 2)
    }

    func testAutoIncrementCanBeDisabled() {
        let state = makeState()
        state.autoIncrementTake = false
        state.clap(timecode: Timecode(hours: 1, rate: .fps24), atHostTime: 0)
        state.release()
        XCTAssertEqual(state.info.take, 1)
    }

    func testClapCapturesExactTimecode() {
        let state = makeState()
        let tc = Timecode(hours: 14, minutes: 32, seconds: 8, frames: 17, rate: .fps24)
        let event = state.clap(timecode: tc, atHostTime: 500)
        XCTAssertEqual(event.timecode.description, "14:32:08:17")

        // The held value must not move as the clock keeps running.
        state.tick(atHostTime: 500.1)
        guard case .held(let held) = state.mode else {
            return XCTFail("expected still held")
        }
        XCTAssertEqual(held.timecode.description, "14:32:08:17")
    }

    func testShotLetterAdvances() {
        XCTAssertEqual(SlateState.nextShotLetter(after: ""), "A")
        XCTAssertEqual(SlateState.nextShotLetter(after: "A"), "B")
        XCTAssertEqual(SlateState.nextShotLetter(after: "Y"), "Z")
        XCTAssertEqual(SlateState.nextShotLetter(after: "Z"), "AA")
        XCTAssertEqual(SlateState.nextShotLetter(after: "AZ"), "BA")
        XCTAssertEqual(SlateState.nextShotLetter(after: "ZZ"), "AAA")
    }

    func testAdvanceShotResetsTake() {
        let state = makeState()
        state.update { $0.take = 7 }
        state.advanceShot()
        XCTAssertEqual(state.info.shot, "B")
        XCTAssertEqual(state.info.take, 1)
    }

    func testAdvanceSceneResets() {
        let state = makeState()
        state.update { $0.take = 4 }
        state.advanceScene(to: "25")
        XCTAssertEqual(state.info.scene, "25")
        XCTAssertEqual(state.info.shot, "")
        XCTAssertEqual(state.info.take, 1)
    }

    func testHistoryAndCSVLog() {
        let state = makeState()
        state.clap(timecode: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: .fps24), atHostTime: 0)
        state.release()   // resuming is what advances the take
        state.clap(timecode: Timecode(hours: 1, minutes: 0, seconds: 30, frames: 12, rate: .fps24), atHostTime: 30)

        XCTAssertEqual(state.history.count, 2)
        let csv = state.csvLog()
        XCTAssertTrue(csv.contains("24,A,1,01:00:00:00"), csv)
        XCTAssertTrue(csv.contains("24,A,2,01:00:30:12"), csv)
    }

    func testSlug() {
        var info = SlateInfo()
        info.scene = "24"
        info.shot = "A"
        XCTAssertEqual(info.slug, "24A")
    }

    // MARK: - Whole-flow rehearsal

    func testFullTakeFlow() {
        // Jam from external LTC, unplug, clap a couple of takes, check the log.
        let sampleRate = 48000.0
        let rate = TimecodeRate.fps24
        let source = Timecode(hours: 9, minutes: 0, seconds: 0, frames: 0, rate: rate)

        let audio = LTCEncoder(sampleRate: sampleRate, rate: rate).encode(from: source, frames: 30)
        let decoder = LTCDecoder(sampleRate: sampleRate)
        let clock = TimecodeClock(rate: rate)
        let state = makeState()

        let bufferHost = 1000.0
        var jammed = false
        decoder.onFrame = { result in
            guard !jammed else { return }
            clock.jam(to: result.frame.timecode(rate: rate),
                      atHostTime: bufferHost + result.startSampleIndex / sampleRate)
            jammed = true
        }
        decoder.process(audio)
        XCTAssertTrue(jammed)

        // Cable unplugged. Two minutes later, clap take 1.
        let clapHost = bufferHost + 120.0
        let clapTC = clock.timecode(atHostTime: clapHost)
        XCTAssertEqual(clapTC.description, "09:02:00:00")
        state.clap(timecode: clapTC, atHostTime: clapHost)

        // Thirty seconds later, take 2.
        let clap2Host = clapHost + 30.0
        state.tick(atHostTime: clap2Host)
        XCTAssertEqual(state.mode, .running, "hold should have released long ago")
        state.clap(timecode: clock.timecode(atHostTime: clap2Host), atHostTime: clap2Host)

        let csv = state.csvLog()
        XCTAssertTrue(csv.contains("24,A,1,09:02:00:00"), csv)
        XCTAssertTrue(csv.contains("24,A,2,09:02:30:00"), csv)
    }
}
