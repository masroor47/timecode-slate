import XCTest
@testable import SlateCore

final class LTCDecoderTests: XCTestCase {

    let sampleRate = 48000.0

    /// Encode a run of frames and decode it back, returning the results.
    private func roundTrip(rate: TimecodeRate,
                           start: Timecode? = nil,
                           frames: Int = 20,
                           transform: ([Float]) -> [Float] = { $0 }) -> [LTCDecodeResult] {
        let startTC = start ?? Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, rate: rate)
        let encoder = LTCEncoder(sampleRate: sampleRate, rate: rate)
        let audio = transform(encoder.encode(from: startTC, frames: frames))
        let decoder = LTCDecoder(sampleRate: sampleRate)
        return decoder.decodeAll(audio)
    }

    // MARK: - Core correctness

    func testDecodesEveryStandardRate() {
        for rate in TimecodeRate.allCases {
            let start = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, rate: rate)
            let results = roundTrip(rate: rate, start: start, frames: 30)

            // First frame or two are lost to clock acquisition; that's expected
            // and matches how real hardware behaves.
            XCTAssertGreaterThanOrEqual(results.count, 27,
                "\(rate.displayName): decoded only \(results.count)/30 frames")

            // The rate family (24 / 25 / 30 / …) must always be identified.
            guard let last = results.last else { continue }
            XCTAssertEqual(last.rate.nominalFPS, rate.nominalFPS,
                "\(rate.displayName): inferred family \(last.rate.displayName)")
            XCTAssertEqual(last.rate.isDropFrame, rate.isDropFrame,
                "\(rate.displayName): drop-frame flag not recovered")
        }
    }

    func testPinnedRateIsHonoured() {
        // When the user tells us the project rate, we use it verbatim — the
        // only fully reliable way to resolve pull-down.
        for rate in [TimecodeRate.fps23_976, .fps24, .fps47_952, .fps59_94ndf] {
            let encoder = LTCEncoder(sampleRate: sampleRate, rate: rate)
            let audio = encoder.encode(from: Timecode(hours: 10, rate: rate), frames: 30)
            let decoder = LTCDecoder(sampleRate: sampleRate)
            decoder.assumedRate = rate
            let results = decoder.decodeAll(audio)
            XCTAssertGreaterThan(results.count, 25)
            XCTAssertEqual(results.last?.rate, rate,
                "pinned rate \(rate.displayName) was overridden")
        }
    }

    func testLongWindowResolvesPullDown() {
        // Given a few seconds of clean signal and a trustworthy capture clock,
        // the 0.1% speed difference between 23.976 and 24 is measurable.
        for rate in [TimecodeRate.fps23_976, .fps24, .fps29_97ndf, .fps30] {
            let encoder = LTCEncoder(sampleRate: sampleRate, rate: rate)
            let audio = encoder.encode(from: Timecode(hours: 10, rate: rate), frames: 150)
            let decoder = LTCDecoder(sampleRate: sampleRate)
            let results = decoder.decodeAll(audio)

            XCTAssertEqual(results.last?.rate, rate,
                "\(rate.displayName): long-window inference gave \(results.last?.rate.displayName ?? "nil")")

            guard let precise = decoder.preciseFPS else {
                XCTFail("\(rate.displayName): no precise rate measurement")
                continue
            }
            // Needs to be well inside the 0.1% gap between neighbouring rates.
            let tolerance = rate.actualFPS * 0.0002
            XCTAssertEqual(precise, rate.actualFPS, accuracy: tolerance,
                "\(rate.displayName): precise rate \(precise)")
        }
    }

    func testDecodedValuesAreConsecutiveAndCorrect() {
        for rate in [TimecodeRate.fps23_976, .fps24, .fps25, .fps29_97ndf, .fps29_97df, .fps30] {
            let start = Timecode(hours: 9, minutes: 59, seconds: 58, frames: 0, rate: rate)
            let results = roundTrip(rate: rate, start: start, frames: 90)

            guard results.count > 10 else {
                XCTFail("\(rate.displayName): too few frames decoded")
                continue
            }
            // Interpret against the known encoding rate so this test measures
            // the decoded digits, not the rate-inference logic.
            let decoded = results.map { $0.frame.timecode(rate: rate) }

            // Every decoded frame must be exactly one frame after the previous:
            // no duplicates, no gaps.
            for i in 1..<decoded.count {
                XCTAssertEqual(decoded[i].frameNumber, decoded[i - 1].frameNumber + 1,
                    "\(rate.displayName): \(decoded[i - 1]) -> \(decoded[i]) is not consecutive")
            }
            // And they must line up with what we actually encoded.
            let offset = decoded[0].frameNumber - start.frameNumber
            XCTAssertTrue((0...3).contains(offset),
                "\(rate.displayName): first decoded frame off by \(offset)")
        }
    }

    func testUserBitsSurviveDecoding() {
        let rate = TimecodeRate.fps25
        let encoder = LTCEncoder(sampleRate: sampleRate, rate: rate)
        let ub: [UInt8] = [1, 2, 0, 3, 2, 0, 2, 6]   // e.g. a date in user bits
        var audio = [Float]()
        var tc = Timecode(hours: 4, rate: rate)
        for _ in 0..<20 {
            encoder.encode(timecode: tc, userBits: ub, into: &audio)
            tc = tc.adding(frames: 1)
        }
        let results = LTCDecoder(sampleRate: sampleRate).decodeAll(audio)
        XCTAssertGreaterThan(results.count, 15)
        for r in results {
            XCTAssertEqual(r.frame.userBits, ub)
        }
    }

    // MARK: - Timing accuracy (this is what jam sync accuracy rests on)

    func testFrameStartTimingIsSubSampleAccurate() {
        let rate = TimecodeRate.fps24
        let encoder = LTCEncoder(sampleRate: sampleRate, rate: rate)
        let audio = encoder.encode(from: Timecode(hours: 1, rate: rate), frames: 40)
        let results = LTCDecoder(sampleRate: sampleRate).decodeAll(audio)

        XCTAssertGreaterThan(results.count, 30)
        let samplesPerFrame = encoder.samplesPerFrame

        // Absolute position: which sample did this frame begin at?
        for r in results {
            let expectedFrameOrdinal = (r.timecode.frameNumber - Timecode(hours: 1, rate: rate).frameNumber)
            let expectedStart = Double(expectedFrameOrdinal) * samplesPerFrame
            XCTAssertEqual(r.startSampleIndex, expectedStart, accuracy: 2.0,
                "frame start off by \(r.startSampleIndex - expectedStart) samples")
        }

        // Frame-to-frame spacing matters even more than absolute offset, since
        // any constant bias cancels out of a jam.
        for i in 1..<results.count {
            let delta = results[i].startSampleIndex - results[i - 1].startSampleIndex
            XCTAssertEqual(delta, samplesPerFrame, accuracy: 0.5,
                "frame spacing drifted: \(delta) vs \(samplesPerFrame)")
        }
    }

    func testMeasuredFrameRateIsAccurate() {
        for rate in [TimecodeRate.fps23_976, .fps24, .fps25, .fps29_97ndf, .fps30] {
            let results = roundTrip(rate: rate, frames: 40)
            guard let last = results.last else {
                XCTFail("no frames for \(rate.displayName)")
                continue
            }
            XCTAssertEqual(last.measuredFPS, rate.actualFPS, accuracy: 0.05,
                "\(rate.displayName): measured \(last.measuredFPS)")
        }
    }

    // MARK: - Signal abuse

    func testSurvivesHardClipping() {
        // A line-level timecode generator puts out volts; a phone mic input
        // wants tens of millivolts. Even with a sane attenuator, expect the
        // input to be slammed. Clipping removes amplitude information but
        // leaves edge timing intact, which is all this decoder needs.
        for gain in [2.0, 10.0, 50.0, 500.0] as [Float] {
            let results = roundTrip(rate: .fps24, frames: 30) {
                Signal.clip($0, gain: gain)
            }
            XCTAssertGreaterThanOrEqual(results.count, 27,
                "clipping at \(gain)x gain broke decoding (\(results.count)/30)")
        }
    }

    func testSurvivesVeryLowAmplitude() {
        // Under-attenuated is one failure mode; over-attenuated is the other.
        for level in [0.1, 0.01, 0.001, 0.0001] as [Float] {
            let results = roundTrip(rate: .fps24, frames: 30) {
                Signal.scale($0, by: level)
            }
            XCTAssertGreaterThanOrEqual(results.count, 27,
                "level \(level) broke decoding (\(results.count)/30)")
        }
    }

    func testNoiseTolerance() {
        // Sweep down until it breaks, so we know the real margin.
        var lowestPassing = Double.infinity
        for snr in [40.0, 30.0, 20.0, 15.0, 10.0, 6.0, 3.0] {
            let results = roundTrip(rate: .fps24, frames: 40) {
                Signal.addNoise($0, snrDB: snr)
            }
            if results.count >= 36 { lowestPassing = min(lowestPassing, snr) }
        }
        XCTAssertLessThanOrEqual(lowestPassing, 10.0,
            "expected clean decoding down to at least 10 dB SNR, best was \(lowestPassing) dB")
    }

    func testPolarityInversionIsIrrelevant() {
        // Biphase mark carries no absolute polarity, so a swapped cable or an
        // inverting input stage must not matter.
        let normal = roundTrip(rate: .fps25, frames: 30)
        let inverted = roundTrip(rate: .fps25, frames: 30) { Signal.invert($0) }
        XCTAssertEqual(normal.count, inverted.count)
        XCTAssertEqual(normal.map(\.timecode.description), inverted.map(\.timecode.description))
    }

    func testSurvivesDCOffset() {
        for offset in [0.1, 0.3, 0.6] as [Float] {
            let results = roundTrip(rate: .fps24, frames: 40) {
                Signal.addDC($0, offset: offset)
            }
            XCTAssertGreaterThanOrEqual(results.count, 35,
                "DC offset \(offset) broke decoding (\(results.count)/40)")
        }
    }

    func testSurvivesBandwidthLimiting() {
        // Cable capacitance and input filtering round off the square edges.
        // 30 fps LTC has half-bit pulses at 2.4 kHz fundamental.
        for cutoff in [12000.0, 8000.0, 6000.0] {
            let results = roundTrip(rate: .fps30, frames: 30) {
                Signal.lowPass($0, cutoffHz: cutoff, sampleRate: sampleRate)
            }
            XCTAssertGreaterThanOrEqual(results.count, 26,
                "\(cutoff) Hz bandwidth broke decoding (\(results.count)/30)")
        }
    }

    func testSurvivesSampleRateMismatch() {
        // The Zoom's clock and the phone's clock will never agree exactly.
        for ppm in [50.0, 500.0, 2000.0, 10000.0] {
            let ratio = 1.0 + ppm * 1e-6
            let results = roundTrip(rate: .fps24, frames: 30) {
                Signal.resample($0, ratio: ratio)
            }
            XCTAssertGreaterThanOrEqual(results.count, 26,
                "\(ppm) ppm clock mismatch broke decoding (\(results.count)/30)")
        }
    }

    func testAcquiresLockFromSilence() {
        // Real use: the app is already listening when you plug the cable in.
        let rate = TimecodeRate.fps24
        let encoder = LTCEncoder(sampleRate: sampleRate, rate: rate)
        let audio = Signal.pad(encoder.encode(from: Timecode(hours: 2, rate: rate), frames: 30),
                               leading: 12000, trailing: 4000)
        let decoder = LTCDecoder(sampleRate: sampleRate)
        let results = decoder.decodeAll(audio)
        XCTAssertGreaterThanOrEqual(results.count, 26)
        XCTAssertTrue(decoder.isLocked)
    }

    func testRecoversAfterSignalDropout() {
        // Cable yanked mid-stream, then reconnected.
        let rate = TimecodeRate.fps24
        let encoder = LTCEncoder(sampleRate: sampleRate, rate: rate)
        let first = encoder.encode(from: Timecode(hours: 3, rate: rate), frames: 15)
        let encoder2 = LTCEncoder(sampleRate: sampleRate, rate: rate)
        let second = encoder2.encode(from: Timecode(hours: 3, minutes: 0, seconds: 5, rate: rate), frames: 15)
        let audio = first + [Float](repeating: 0, count: 9600) + second

        let decoder = LTCDecoder(sampleRate: sampleRate)
        let results = decoder.decodeAll(audio)

        let beforeGap = results.filter { $0.timecode.seconds < 3 }
        let afterGap = results.filter { $0.timecode.seconds >= 5 }
        XCTAssertGreaterThan(beforeGap.count, 10, "lost the pre-dropout run")
        XCTAssertGreaterThan(afterGap.count, 10, "failed to re-acquire after dropout")
    }

    func testRealisticWorstCase() {
        // Everything at once: hot and clipped, noisy, DC-offset, bandwidth
        // limited, and with the two clocks disagreeing.
        let results = roundTrip(rate: .fps29_97df, frames: 60) { audio in
            var s = Signal.resample(audio, ratio: 1.0 + 300e-6)
            s = Signal.lowPass(s, cutoffHz: 10000, sampleRate: self.sampleRate)
            s = Signal.clip(s, gain: 20.0)
            s = Signal.addDC(s, offset: 0.05)
            s = Signal.addNoise(s, snrDB: 20.0)
            return s
        }
        XCTAssertGreaterThanOrEqual(results.count, 54,
            "realistic worst case decoded only \(results.count)/60")

        let decoded = results.map { $0.frame.timecode(rate: .fps29_97df) }
        for i in 1..<decoded.count {
            XCTAssertEqual(decoded[i].frameNumber, decoded[i - 1].frameNumber + 1,
                           "non-consecutive under worst-case conditions: \(decoded[i - 1]) -> \(decoded[i])")
        }
    }

    func testDoesNotDecodeGarbageFromNoise() {
        // False locks would be worse than no lock — the slate would silently
        // jam to nonsense.
        var rng = SeededRandom(seed: 7)
        let noise = (0..<48000 * 3).map { _ in rng.gaussian() * 0.3 }
        let decoder = LTCDecoder(sampleRate: sampleRate)
        let results = decoder.decodeAll(noise)
        XCTAssertEqual(results.count, 0, "decoded \(results.count) phantom frames from pure noise")
    }

    func testHandlesOtherSampleRates() {
        for sr in [44100.0, 48000.0, 96000.0] {
            let rate = TimecodeRate.fps25
            let encoder = LTCEncoder(sampleRate: sr, rate: rate)
            let audio = encoder.encode(from: Timecode(hours: 5, rate: rate), frames: 30)
            let results = LTCDecoder(sampleRate: sr).decodeAll(audio)
            XCTAssertGreaterThanOrEqual(results.count, 26, "\(sr) Hz: \(results.count)/30")
        }
    }
}
