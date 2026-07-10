import Foundation

public extension Waveform {
    /// A normalized window into an audio file, expressed as fractions of total duration.
    /// `lowerBound` and `upperBound` are always clamped to `0...1`, and `lowerBound < upperBound`.
    struct VisibleRange: Equatable, Sendable {
        public var lowerBound: Double
        public var upperBound: Double

        public init(lowerBound: Double, upperBound: Double) {
            let lo = min(max(0, lowerBound), 1)
            let hi = min(max(0, upperBound), 1)
            self.lowerBound = min(lo, hi)
            self.upperBound = max(lo, hi)
            if self.lowerBound == self.upperBound {
                // Degenerate ranges collapse to a tiny non-empty window so callers never divide by zero.
                if self.upperBound < 1 {
                    self.upperBound = min(1, self.lowerBound + .leastNonzeroMagnitude)
                } else {
                    self.lowerBound = max(0, self.upperBound - .leastNonzeroMagnitude)
                }
            }
        }

        public init(_ range: ClosedRange<Double>) {
            self.init(lowerBound: range.lowerBound, upperBound: range.upperBound)
        }

        public static let full = VisibleRange(lowerBound: 0, upperBound: 1)

        public var span: Double { upperBound - lowerBound }

        public var closedRange: ClosedRange<Double> { lowerBound...upperBound }

        /// Builds a range from a zoom factor (≥ 1) and a start offset in `0...(1 - 1/zoom)`.
        public static func from(zoom: Double, start: Double) -> VisibleRange {
            let clampedZoom = max(1, zoom)
            let span = 1 / clampedZoom
            let maxStart = max(0, 1 - span)
            let clampedStart = min(max(0, start), maxStart)
            return VisibleRange(lowerBound: clampedStart, upperBound: clampedStart + span)
        }
    }
}

/// Utilities for mapping a high-resolution sample buffer onto a zoomed / scrolled viewport.
public enum WaveformSampleViewport {
    /// Extracts the samples that fall inside `range`, preserving stereo `[allLeft..., allRight...]` layout when `isStereo` is true.
    public static func slice(_ samples: [Float], range: Waveform.VisibleRange, isStereo: Bool) -> [Float] {
        guard !samples.isEmpty else { return [] }

        if isStereo {
            let half = samples.count / 2
            guard half > 0 else { return [] }
            let left = Array(samples[0..<half])
            let right = Array(samples[half..<samples.count])
            return sliceChannel(left, range: range) + sliceChannel(right, range: range)
        }

        return sliceChannel(samples, range: range)
    }

    /// Downsamples (or lightly upsamples) `samples` to exactly `targetCount` slots.
    ///
    /// Amplitudes in this library are inverted (`0` = loud, `1` = silence), so each output bucket
    /// keeps the **minimum** (loudest peak) of its source window — the usual peak-envelope behaviour
    /// for zoomed waveforms.
    public static func resample(_ samples: [Float], to targetCount: Int, isStereo: Bool) -> [Float] {
        guard targetCount > 0 else { return [] }
        guard !samples.isEmpty else { return Array(repeating: 1, count: isStereo ? targetCount * 2 : targetCount) }

        if isStereo {
            let half = samples.count / 2
            guard half > 0 else { return Array(repeating: 1, count: targetCount * 2) }
            let left = resampleChannel(Array(samples[0..<half]), to: targetCount)
            let right = resampleChannel(Array(samples[half..<samples.count]), to: targetCount)
            return left + right
        }

        return resampleChannel(samples, to: targetCount)
    }

    /// Convenience: slice a visible window, then resample to the pixel budget of a viewport.
    public static func samples(
        from samples: [Float],
        visibleIn range: Waveform.VisibleRange,
        targetCount: Int,
        isStereo: Bool
    ) -> [Float] {
        let sliced = slice(samples, range: range, isStereo: isStereo)
        return resample(sliced, to: targetCount, isStereo: isStereo)
    }

    // MARK: - Private

    private static func sliceChannel(_ samples: [Float], range: Waveform.VisibleRange) -> [Float] {
        let count = samples.count
        guard count > 0 else { return [] }
        let start = Int(floor(range.lowerBound * Double(count)))
        let end = Int(ceil(range.upperBound * Double(count)))
        let clampedStart = min(max(0, start), count - 1)
        let clampedEnd = min(max(clampedStart + 1, end), count)
        return Array(samples[clampedStart..<clampedEnd])
    }

    private static func resampleChannel(_ samples: [Float], to targetCount: Int) -> [Float] {
        guard targetCount > 0 else { return [] }
        guard !samples.isEmpty else { return Array(repeating: 1, count: targetCount) }
        if samples.count == targetCount { return samples }

        if samples.count < targetCount {
            // Nearest-neighbour upsample — cheap and stable while a higher-res analysis is loading.
            return (0..<targetCount).map { i in
                let sourceIndex = Int(Double(i) / Double(targetCount) * Double(samples.count))
                return samples[min(sourceIndex, samples.count - 1)]
            }
        }

        var result = [Float](repeating: 1, count: targetCount)
        for i in 0..<targetCount {
            let start = (i * samples.count) / targetCount
            let end = max(start + 1, ((i + 1) * samples.count) / targetCount)
            let clampedEnd = min(end, samples.count)
            var peak: Float = 1
            for j in start..<clampedEnd {
                peak = min(peak, samples[j])
            }
            result[i] = peak
        }
        return result
    }
}
