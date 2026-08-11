import XCTest
@testable import SlateCore

final class TimecodeClockTests: XCTestCase {

    func testJamThenFreeRun() {
        let clock = TimecodeClock(rate: .fps24)
        let jamTC = Timecode(hours: 10, minutes: 30, seconds: 0, frames: 0, rate: .fps24)
        clock.jam(to: jamTC, atHostTime: 1000.0)

        XCTAssertEqual(clock.timecode(atHostTime: 1000.0).description, "10:30:00:00")
        // One second later.
        XCTAssertEqual(clock.timecode(atHostTime: 1001.0).description, "10:30:01:00")
        // Ten minutes later — cable long since unplugged.
        XCTAssertEqual(clock.timecode(atHostTime: 1600.0).description, "10:40:00:00")
    }

    func testSubFramePositionAdvancesSmoothly() {
        let clock = TimecodeClock(rate: .fps24)
        clock.jam(to: Timecode(hours: 1, rate: .fps24), atHostTime: 0)
        // Half a frame in.
        XCTAssertEqual(clock.framePhase(atHostTime: 0.5 / 24.0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(clock.timecode(atHostTime: 0.5 / 24.0).frames, 0)
        XCTAssertEqual(clock.timecode(atHostTime: 1.5 / 24.0).frames, 1)
    }

    func testPullDownRatesRunAtCorrectSpeed() {
        let clock = TimecodeClock(rate: .fps23_976)
        clock.jam(to: Timecode(hours: 0, rate: .fps23_976), atHostTime: 0)
        // After exactly one hour of real time, 23.976 timecode reads ~00:59:56:10
        // (it runs slow relative to wall clock by 0.1%).
        let tc = clock.timecode(atHostTime: 3600.0)
        XCTAssertEqual(tc.hours, 0)
        XCTAssertEqual(tc.minutes, 59)
        XCTAssertEqual(tc.seconds, 56, "23.976 should lag wall clock by ~3.6s/hour")
    }

    func testDriftCompensationCorrectsFreeRun() {
        // Model a host oscillator running 20 ppm fast. Note that calibration
        // works off the *exact host time a known frame began* — which is what
        // the decoder hands us — so there is no whole-frame quantisation here.
        let hostError = 20e-6
        /// Host-clock reading at the instant source frame `f` begins.
        func hostTime(ofSourceFrame f: Int) -> Double {
            (Double(f) / 24.0) * (1.0 + hostError)
        }

        let clock = TimecodeClock(rate: .fps24)
        clock.jam(to: Timecode(hours: 0, rate: .fps24), atHostTime: hostTime(ofSourceFrame: 0))

        // One hour of source time later.
        let refFrame = 24 * 3600
        let refTC = Timecode(frameNumber: refFrame, rate: .fps24)
        let refHost = hostTime(ofSourceFrame: refFrame)

        let errorBefore = abs(clock.error(against: refTC, atHostTime: refHost))
        XCTAssertGreaterThan(errorBefore, 1.0, "should have drifted more than a frame in an hour")

        clock.calibrate(reference: refTC, atHostTime: refHost)
        XCTAssertEqual(clock.driftPPM, 20.0, accuracy: 0.5)

        // Re-jam and confirm the compensated clock now tracks over a further hour.
        clock.jam(to: refTC, atHostTime: refHost)
        let laterFrame = refFrame + 24 * 3600
        let laterTC = Timecode(frameNumber: laterFrame, rate: .fps24)
        let errorAfter = abs(clock.error(against: laterTC, atHostTime: hostTime(ofSourceFrame: laterFrame)))
        XCTAssertLessThan(errorAfter, 0.1,
            "drift compensation should hold well inside a frame over an hour, was \(errorAfter) frames")
    }

    func testRateChangePreservesWallClockPosition() {
        let clock = TimecodeClock(rate: .fps24)
        clock.jam(to: Timecode(hours: 10, minutes: 0, seconds: 30, frames: 0, rate: .fps24), atHostTime: 500)
        clock.setRate(.fps25, atHostTime: 500)
        let tc = clock.timecode(atHostTime: 500)
        XCTAssertEqual(tc.rate, .fps25)
        XCTAssertEqual(tc.hours, 10)
        XCTAssertEqual(tc.minutes, 0)
        XCTAssertEqual(tc.seconds, 30)
    }

    // MARK: - End-to-end: decode real LTC audio, jam a clock, free-run

    func testEndToEndJamFromDecodedAudio() {
        let sampleRate = 48000.0
        let rate = TimecodeRate.fps24
        let sourceTC = Timecode(hours: 14, minutes: 22, seconds: 5, frames: 0, rate: rate)

        let encoder = LTCEncoder(sampleRate: sampleRate, rate: rate)
        // Hot and clipped, the way it will really arrive.
        let audio = Signal.clip(encoder.encode(from: sourceTC, frames: 30), gain: 15.0)

        // Pretend the buffer began at this host time.
        let bufferHostTime = 8000.0
        let decoder = LTCDecoder(sampleRate: sampleRate)
        let clock = TimecodeClock(rate: rate)

        var jammed = false
        decoder.onFrame = { result in
            guard !jammed else { return }
            // The frame began at this many seconds into the buffer.
            let hostTime = bufferHostTime + result.startSampleIndex / sampleRate
            clock.jam(to: result.timecode, atHostTime: hostTime)
            jammed = true
        }
        decoder.process(audio)

        XCTAssertTrue(jammed, "never achieved lock")

        // Now unplug. Where is the clock 10 minutes later? It should read
        // exactly 10 minutes past the jam point.
        let audioDuration = Double(audio.count) / sampleRate
        let jamPoint = clock.timecode(atHostTime: bufferHostTime + audioDuration)

        // The source would be at start + however many frames elapsed.
        let expectedFrames = Int(audioDuration * rate.actualFPS)
        let expected = sourceTC.adding(frames: expectedFrames)
        let errorFrames = abs(jamPoint.frameNumber - expected.frameNumber)
        XCTAssertLessThanOrEqual(errorFrames, 1,
            "clock read \(jamPoint), expected \(expected)")

        let tenMinutesLater = clock.timecode(atHostTime: bufferHostTime + 600.0)
        XCTAssertEqual(tenMinutesLater.description, "14:32:05:00")
    }

    func testJamAccuracyIsSubFrame() {
        // How precisely does the decode → jam path land? This is the number
        // that decides whether the slate is genuinely frame accurate.
        let sampleRate = 48000.0
        let rate = TimecodeRate.fps24
        let sourceTC = Timecode(hours: 1, rate: rate)
        let encoder = LTCEncoder(sampleRate: sampleRate, rate: rate)
        let audio = encoder.encode(from: sourceTC, frames: 40)

        let decoder = LTCDecoder(sampleRate: sampleRate)
        var worstErrorSeconds = 0.0

        decoder.onFrame = { result in
            // In the encoded stream, this frame truly began here:
            let ordinal = result.timecode.frameNumber - sourceTC.frameNumber
            let trueStart = Double(ordinal) * encoder.samplesPerFrame
            let errorSamples = abs(result.startSampleIndex - trueStart)
            worstErrorSeconds = max(worstErrorSeconds, errorSamples / sampleRate)
        }
        decoder.process(audio)

        let frameDuration = 1.0 / rate.actualFPS
        XCTAssertLessThan(worstErrorSeconds, frameDuration * 0.01,
            "jam timing error \(worstErrorSeconds * 1000) ms exceeds 1% of a frame")
    }
}
