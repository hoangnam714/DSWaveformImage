import XCTest
@testable import DSWaveformImage

final class WaveformSampleViewportTests: XCTestCase {
    func testVisibleRangeFromZoomClampsStart() {
        let range = Waveform.VisibleRange.from(zoom: 4, start: 0.9)
        XCTAssertEqual(range.span, 0.25, accuracy: 0.0001)
        XCTAssertEqual(range.lowerBound, 0.75, accuracy: 0.0001)
        XCTAssertEqual(range.upperBound, 1.0, accuracy: 0.0001)
    }

    func testSliceMonoMiddleQuarter() {
        let samples: [Float] = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
        let range = Waveform.VisibleRange(lowerBound: 0.25, upperBound: 0.5)
        let sliced = WaveformSampleViewport.slice(samples, range: range, isStereo: false)
        XCTAssertEqual(sliced, [0.2, 0.3])
    }

    func testSliceStereoKeepsChannelLayout() {
        // 4 slots per channel → [L0 L1 L2 L3 R0 R1 R2 R3]
        let samples: [Float] = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
        let range = Waveform.VisibleRange(lowerBound: 0.25, upperBound: 0.75)
        let sliced = WaveformSampleViewport.slice(samples, range: range, isStereo: true)
        // Left middle half: L1 L2; right middle half: R1 R2
        XCTAssertEqual(sliced, [0.1, 0.2, 0.5, 0.6])
    }

    func testResampleKeepsLoudestPeak() {
        // Inverted amplitudes: 0 = loud, 1 = silence
        let samples: [Float] = [0.8, 0.2, 0.9, 0.4]
        let resampled = WaveformSampleViewport.resample(samples, to: 2, isStereo: false)
        XCTAssertEqual(resampled.count, 2)
        XCTAssertEqual(resampled[0], 0.2, accuracy: 0.0001)
        XCTAssertEqual(resampled[1], 0.4, accuracy: 0.0001)
    }

    func testSamplesCombinesSliceAndResample() {
        let samples: [Float] = (0..<100).map { Float($0) / 100 }
        let range = Waveform.VisibleRange(lowerBound: 0.1, upperBound: 0.3)
        let result = WaveformSampleViewport.samples(from: samples, visibleIn: range, targetCount: 10, isStereo: false)
        XCTAssertEqual(result.count, 10)
    }
}
