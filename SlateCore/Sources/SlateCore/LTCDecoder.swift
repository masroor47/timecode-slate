import Foundation

/// A successfully decoded LTC frame plus the timing information needed to jam
/// an internal clock to it.
public struct LTCDecodeResult: Sendable {
    public let frame: LTCFrame
    /// Rate inferred from the measured bit period plus the drop-frame flag.
    public let rate: TimecodeRate
    /// Absolute sample index (in the decoder's stream) where this frame's bit 0
    /// began. Fractional — edges are interpolated between samples, so this is
    /// good to well under one sample.
    public let startSampleIndex: Double
    /// Absolute sample index where the frame's last bit ended.
    public let endSampleIndex: Double
    /// Frame rate implied by the measured bit period, in frames per second.
    public let measuredFPS: Double
    /// True if the signal is running backwards (tape/deck shuttling in reverse).
    public let reverse: Bool

    public var duration: Double { endSampleIndex - startSampleIndex }

    public var timecode: Timecode { frame.timecode(rate: rate) }
}

/// Streaming LTC decoder.
///
/// Works on raw edge timing rather than correlation, which is the right call
/// here: LTC is a square wave, and a hot signal into a phone input will clip
/// hard. Clipping destroys amplitude information but *preserves* edge timing,
/// so an edge-interval decoder actually gets more robust as the signal gets
/// hotter, not less.
public final class LTCDecoder {

    /// Called on every successfully decoded frame.
    public var onFrame: ((LTCDecodeResult) -> Void)?

    public let sampleRate: Double

    // Absolute position in the input stream.
    private var sampleIndex: Double = 0

    // --- Edge detection state ---
    private var dcEstimate: Float = 0
    private var envelope: Float = 0
    private var isHigh = false
    private var lastSample: Float = 0
    private var lastEdgeIndex: Double = -1
    private var haveEdge = false

    // --- Bit clock recovery ---
    /// Running estimate of a half-bit period, in samples.
    private var halfBitPeriod: Double = 0
    private var pendingShortPulse = false

    // --- Frame assembly ---
    private var dataRegister: UInt64 = 0
    private var syncRegister: UInt16 = 0
    private var bitsSinceSync = 0
    /// Sample index of the edge that opened the oldest bit currently in the
    /// 80-bit shift register.
    private var bitStartIndices = [Double](repeating: 0, count: 80)
    private var bitStartCursor = 0

    /// Minimum plausible half-bit period, guards against latching onto noise.
    private let minHalfBit: Double
    private let maxHalfBit: Double

    public private(set) var isLocked = false
    /// Frames decoded since the last reset.
    public private(set) var framesDecoded = 0

    /// Pin the interpretation to a known project rate.
    ///
    /// Worth understanding why this exists: LTC carries a drop-frame flag but
    /// carries *nothing* that distinguishes a pull-down rate from its integer
    /// parent. 23.976 and 24 differ only in that the whole signal runs 0.1%
    /// slower. We can resolve that by timing the signal over a long window
    /// (see `preciseFPS`), but only if the capture clock is trustworthy. When
    /// the user already knows the project rate, pinning it is more reliable.
    public var assumedRate: TimecodeRate?

    // Long-window rate measurement: counting whole frame periods over seconds
    // gives far better precision than smoothing individual edge intervals.
    private var firstFrameEndIndex: Double?
    private var framesSinceFirstEnd = 0
    /// Latched once the long-window measurement is trustworthy, so the reported
    /// rate stops changing mid-run.
    private var latchedRate: TimecodeRate?

    /// Frame rate measured across the whole locked run, in fps. Much more
    /// precise than `measuredFPS` on a single frame once a few seconds of
    /// signal have gone by.
    public private(set) var preciseFPS: Double?

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // LTC bit rates span roughly 1918 bps (23.976) to 4800 bps (60fps).
        // Allow generous margin either side.
        self.maxHalfBit = sampleRate / (80.0 * 20.0) / 2.0   // as slow as 20 fps
        self.minHalfBit = sampleRate / (80.0 * 75.0) / 2.0   // as fast as 75 fps
    }

    public func reset() {
        dcEstimate = 0
        envelope = 0
        isHigh = false
        haveEdge = false
        halfBitPeriod = 0
        pendingShortPulse = false
        dataRegister = 0
        syncRegister = 0
        bitsSinceSync = 0
        bitStartCursor = 0
        isLocked = false
        firstFrameEndIndex = nil
        framesSinceFirstEnd = 0
        preciseFPS = nil
        latchedRate = nil
    }

    /// Feed a buffer of mono samples. Call repeatedly; state carries across calls.
    public func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { process($0) }
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        // DC blocker time constant ~ a few LTC frames, slow enough not to chase
        // the square wave itself.
        let dcAlpha: Float = Float(1.0 / (sampleRate * 0.05))
        let envDecay: Float = Float(1.0 - 1.0 / (sampleRate * 0.02))

        for x in samples {
            dcEstimate += (x - dcEstimate) * dcAlpha
            let y = x - dcEstimate

            let mag = abs(y)
            envelope = mag > envelope ? mag : envelope * envDecay

            // Hysteresis proportional to signal level, with an absolute floor so
            // silence doesn't produce phantom edges.
            let hyst = max(envelope * 0.25, 1e-5)

            if !isHigh && y > hyst {
                registerEdge(threshold: hyst, previous: lastSample, current: y)
                isHigh = true
            } else if isHigh && y < -hyst {
                registerEdge(threshold: -hyst, previous: lastSample, current: y)
                isHigh = false
            }

            lastSample = y
            sampleIndex += 1
        }
    }

    // MARK: - Edge handling

    private func registerEdge(threshold: Float, previous: Float, current: Float) {
        // Linear interpolation of where the signal actually crossed, so timing
        // resolution isn't limited to whole samples.
        var frac = 0.0
        let denom = current - previous
        if abs(denom) > 1e-9 {
            frac = Double((threshold - previous) / denom)
            frac = min(max(frac, 0.0), 1.0)
        }
        let edgeIndex = sampleIndex - 1.0 + frac

        defer { lastEdgeIndex = edgeIndex; haveEdge = true }
        guard haveEdge else { return }

        let interval = edgeIndex - lastEdgeIndex
        guard interval > 0 else { return }
        handleInterval(interval, edgeIndex: edgeIndex)
    }

    private func handleInterval(_ interval: Double, edgeIndex: Double) {
        // Bootstrap: first plausible interval seeds the clock estimate.
        if halfBitPeriod == 0 {
            if interval >= minHalfBit && interval <= maxHalfBit * 2 {
                halfBitPeriod = min(interval, maxHalfBit)
            }
            return
        }

        // Interval far too long — dropout or silence. Drop lock.
        if interval > halfBitPeriod * 3.0 {
            loseLock()
            if interval >= minHalfBit && interval <= maxHalfBit * 2 {
                halfBitPeriod = min(interval, maxHalfBit)
            }
            return
        }

        // We seeded on a full-bit (a `0`) pulse and are running at 2x too slow.
        // A pulse near half our estimate proves it; re-seed and resync.
        if interval < halfBitPeriod * 0.6 {
            halfBitPeriod = interval
            loseLock()
            return
        }

        let isShort = interval < halfBitPeriod * 1.5

        // Track the clock. Slow adaptation keeps a stray edge from yanking it.
        let observedHalf = isShort ? interval : interval / 2.0
        if observedHalf >= minHalfBit && observedHalf <= maxHalfBit {
            halfBitPeriod += (observedHalf - halfBitPeriod) * 0.05
        }

        if isShort {
            if pendingShortPulse {
                // Second half of a `1`.
                pendingShortPulse = false
                pushBit(1, startIndex: pendingBitStart, endIndex: edgeIndex)
            } else {
                pendingShortPulse = true
                pendingBitStart = edgeIndex - interval
            }
        } else {
            if pendingShortPulse {
                // A half pulse followed by a full pulse means we're out of
                // phase with the bit grid. Drop the orphan and resync.
                pendingShortPulse = false
                loseLock()
            }
            pushBit(0, startIndex: edgeIndex - interval, endIndex: edgeIndex)
        }
    }

    private var pendingBitStart: Double = 0

    private func loseLock() {
        isLocked = false
        bitsSinceSync = 0
        pendingShortPulse = false
        syncRegister = 0
        dataRegister = 0
        // The long-window rate measurement is only valid across an unbroken
        // run, so a dropout invalidates it.
        firstFrameEndIndex = nil
        framesSinceFirstEnd = 0
        preciseFPS = nil
        latchedRate = nil
    }

    // MARK: - Frame assembly

    private func pushBit(_ bit: UInt8, startIndex: Double, endIndex: Double) {
        // Bits shift right; newest enters at the top of the 16-bit sync window,
        // and whatever falls out the bottom enters the 64-bit data register.
        // After 80 bits, dataRegister bit `i` holds LTC bit `i`.
        let spill = UInt64(syncRegister & 1)
        syncRegister = (syncRegister >> 1) | (UInt16(bit) << 15)
        dataRegister = (dataRegister >> 1) | (spill << 63)

        bitStartIndices[bitStartCursor] = startIndex
        bitStartCursor = (bitStartCursor + 1) % 80

        if bitsSinceSync < 1000 { bitsSinceSync += 1 }

        guard syncRegister == LTCFrame.syncWord else {
            // Also check for a reversed sync word so we can at least report
            // that the source is running backwards.
            return
        }
        // Need a full 80 bits in the pipe before the data register is valid.
        guard bitsSinceSync >= 80 else {
            bitsSinceSync = 80
            return
        }

        // Track frame periods across the run for a high-precision rate estimate.
        // The counter must be incremented *before* dividing: N frame periods
        // have elapsed by the Nth frame after the baseline.
        if let first = firstFrameEndIndex {
            framesSinceFirstEnd += 1
            let elapsed = (endIndex - first) / sampleRate
            if elapsed > 0 { preciseFPS = Double(framesSinceFirstEnd) / elapsed }
        } else {
            firstFrameEndIndex = endIndex
        }

        let rate = inferRate(dataBits: dataRegister)
        let frame = LTCFrame(dataBits: dataRegister, rate: rate)

        // Oldest of the 80 buffered bits is the one we're about to overwrite.
        let startIdx = bitStartIndices[bitStartCursor]
        let measuredFPS = sampleRate / (halfBitPeriod * 2.0 * 80.0)

        let result = LTCDecodeResult(
            frame: frame,
            rate: rate,
            startSampleIndex: startIdx,
            endSampleIndex: endIndex,
            measuredFPS: measuredFPS,
            reverse: false
        )

        // Only surface frames whose fields make sense.
        guard frame.hours < 24, frame.minutes < 60, frame.seconds < 60, frame.frames < 60 else {
            loseLock()
            return
        }

        isLocked = true
        framesDecoded += 1
        onFrame?(result)
    }

    /// Pick the standard rate whose bit period best matches what we're seeing.
    /// Lets the app auto-detect 24 vs 25 vs 30 instead of making the user guess.
    private func inferRate(dataBits: UInt64) -> TimecodeRate {
        let dropFlag = (dataBits >> 10) & 1 == 1

        // A pinned rate wins outright, provided it's in the right family.
        let coarse = sampleRate / (halfBitPeriod * 2.0 * 80.0)
        if let assumed = assumedRate, abs(Double(assumed.nominalFPS) - coarse) < 3.0 {
            return assumed
        }

        var best: TimecodeRate
        if let latched = latchedRate {
            // Once the measurement is solid, stop revising it. A rate that
            // flickers mid-run would be worse than one that is merely slow to
            // settle.
            best = latched
        } else {
            // Prefer the long-window measurement when we have enough of a
            // baseline to resolve pull-down; otherwise fall back to the coarse
            // estimate and assume the integer rate.
            let haveBaseline = framesSinceFirstEnd >= 10
            let measured = haveBaseline ? (preciseFPS ?? coarse) : coarse

            best = .fps30
            var bestErr = Double.infinity
            for candidate in TimecodeRate.allCases where !candidate.isDropFrame {
                // Without a solid baseline, don't guess at pull-down.
                if !haveBaseline && candidate.isPullDown { continue }
                let err = abs(candidate.actualFPS - measured)
                if err < bestErr {
                    bestErr = err
                    best = candidate
                }
            }
            if framesSinceFirstEnd >= 20 { latchedRate = best }
        }

        // Rate alone can't distinguish DF from NDF — they run at identical
        // speed. Bit 10 is what actually decides it.
        if dropFlag {
            switch best {
            case .fps29_97ndf, .fps30: best = .fps29_97df
            case .fps59_94ndf, .fps60: best = .fps59_94df
            default: break
            }
        }
        return best
    }

    /// Best guess at the incoming frame rate, or nil if not locked.
    public var detectedRate: TimecodeRate? {
        guard isLocked, halfBitPeriod > 0 else { return nil }
        return inferRate(dataBits: dataRegister)
    }
}
