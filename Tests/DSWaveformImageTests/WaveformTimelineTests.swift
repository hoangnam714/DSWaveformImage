import XCTest
@testable import DSWaveformImage

final class WaveformTimelineTests: XCTestCase {
    func testMajorIntervalGrowsWithVisibleDuration() {
        XCTAssertLessThanOrEqual(Waveform.Timeline.majorInterval(visibleDuration: 2), 1)
        XCTAssertGreaterThanOrEqual(Waveform.Timeline.majorInterval(visibleDuration: 40), 5)
    }

    func testXPositionInsideVisibleRange() {
        let range = Waveform.VisibleRange(lowerBound: 0.25, upperBound: 0.75)
        let x = Waveform.Timeline.xPosition(progress: 0.5, visibleRange: range, width: 200)
        XCTAssertEqual(x!, 100, accuracy: 0.001)
    }

    func testXPositionOutsideReturnsNil() {
        let range = Waveform.VisibleRange(lowerBound: 0.4, upperBound: 0.6)
        XCTAssertNil(Waveform.Timeline.xPosition(progress: 0.1, visibleRange: range, width: 200))
    }

    func testProgressFromX() {
        let range = Waveform.VisibleRange(lowerBound: 0.2, upperBound: 0.6)
        let progress = Waveform.Timeline.progress(x: 50, visibleRange: range, width: 100)
        XCTAssertEqual(progress, 0.4, accuracy: 0.0001)
    }

    func testSelectionClampsStartBeforeEnd() {
        var selection = Waveform.Timeline.Selection(start: 0.2, end: 0.8)
        selection.setStart(0.9)
        XCTAssertLessThan(selection.start, selection.end)
        XCTAssertEqual(selection.start, 0.79, accuracy: 0.001)
    }

    func testClockFormatAddsFractionWhenZoomed() {
        XCTAssertEqual(
            Waveform.Timeline.formatTime(2.0, style: .clock, majorInterval: 1),
            "0:02"
        )
        XCTAssertEqual(
            Waveform.Timeline.formatTime(2.4, style: .clock, majorInterval: 0.2),
            "0:02.4"
        )
        XCTAssertEqual(
            Waveform.Timeline.formatTime(2.45, style: .clock, majorInterval: 0.05),
            "0:02.45"
        )
    }

    func testClockFormatKeepsMajorsUniqueAtSubSecondInterval() {
        let major = Waveform.Timeline.majorInterval(visibleDuration: 0.75)
        XCTAssertLessThan(major, 1)
        let a = Waveform.Timeline.formatTime(2.0, style: .clock, majorInterval: major)
        let b = Waveform.Timeline.formatTime(2.0 + major, style: .clock, majorInterval: major)
        XCTAssertNotEqual(a, b)
    }
}
