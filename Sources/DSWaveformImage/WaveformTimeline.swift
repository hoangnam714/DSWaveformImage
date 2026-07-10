import Foundation

public extension Waveform {
    /// Helpers for mapping normalized progress / visible windows onto absolute audio time.
    enum Timeline {
        /// Formats a time in seconds for ruler labels — matches the compact `30.0` style when under
        /// a minute, then switches to `m:ss` / `m:ss.s` for longer spans.
        public static func formatTime(_ seconds: Double, majorInterval: Double) -> String {
            formatTime(seconds, style: .automatic, majorInterval: majorInterval)
        }

        public enum TimeFormatStyle: Sendable {
            /// `30.0` under a minute, `m:ss` above.
            case automatic
            /// Editor-style clock labels (`0:00`, `0:02.5`, …). Adds fractional seconds when
            /// `majorInterval` is sub-second so zoomed-in rulers stay unique.
            case clock
            /// Always decimal seconds (`0.0`, `1.5`, …).
            case decimal
        }

        public static func formatTime(
            _ seconds: Double,
            style: TimeFormatStyle,
            majorInterval: Double = 1
        ) -> String {
            let value = max(0, seconds)
            switch style {
            case .clock:
                return formatClock(value, majorInterval: majorInterval)
            case .decimal:
                if majorInterval >= 1 {
                    return String(format: "%.0f", value)
                }
                if majorInterval >= 0.1 {
                    return String(format: "%.1f", value)
                }
                return String(format: "%.2f", value)
            case .automatic:
                if value >= 60 || majorInterval >= 60 {
                    return formatClock(value, majorInterval: majorInterval)
                }
                if majorInterval >= 1 {
                    return String(format: "%.0f", value)
                }
                if majorInterval >= 0.1 {
                    return String(format: "%.1f", value)
                }
                return String(format: "%.2f", value)
            }
        }

        /// `m:ss` at coarse zoom; `m:ss.d` / `m:ss.dd` when major ticks are sub-second.
        private static func formatClock(_ value: Double, majorInterval: Double) -> String {
            let minutes = Int(value) / 60
            let secs = value.truncatingRemainder(dividingBy: 60)
            if majorInterval >= 1 {
                return String(format: "%d:%02d", minutes, Int(secs.rounded(.down)))
            }
            if majorInterval >= 0.1 {
                return String(format: "%d:%04.1f", minutes, secs)
            }
            return String(format: "%d:%05.2f", minutes, secs)
        }

        /// Picks a "nice" major tick interval (seconds) so roughly `targetMajorTicks` labels fit
        /// the currently visible duration. Minor ticks are derived as `major / minorDivisions`.
        public static func majorInterval(visibleDuration: Double, targetMajorTicks: Int = 4) -> Double {
            let duration = max(visibleDuration, 0.001)
            let raw = duration / Double(max(targetMajorTicks, 1))
            let nice: [Double] = [
                0.01, 0.02, 0.05,
                0.1, 0.2, 0.25, 0.5,
                1, 2, 5,
                10, 15, 30,
                60, 120, 300, 600, 900, 1800, 3600
            ]
            return nice.first(where: { $0 >= raw }) ?? nice.last!
        }

        /// Absolute time (seconds) for a normalized progress value in `0...1`.
        public static func time(progress: Double, duration: TimeInterval) -> TimeInterval {
            min(max(0, progress), 1) * max(duration, 0)
        }

        /// Normalized progress for an absolute time.
        public static func progress(time: TimeInterval, duration: TimeInterval) -> Double {
            guard duration > 0 else { return 0 }
            return min(max(0, time / duration), 1)
        }

        /// X position of `progress` inside a viewport that shows `visibleRange`.
        /// Returns `nil` when the playhead is outside the visible window.
        public static func xPosition(
            progress: Double,
            visibleRange: VisibleRange,
            width: CGFloat
        ) -> CGFloat? {
            guard width > 0, visibleRange.span > 0 else { return nil }
            let p = min(max(0, progress), 1)
            guard p >= visibleRange.lowerBound, p <= visibleRange.upperBound else { return nil }
            let fraction = (p - visibleRange.lowerBound) / visibleRange.span
            return CGFloat(fraction) * width
        }

        /// Normalized progress for a tap/drag x inside the visible window.
        public static func progress(
            x: CGFloat,
            visibleRange: VisibleRange,
            width: CGFloat
        ) -> Double {
            guard width > 0 else { return visibleRange.lowerBound }
            let fraction = min(max(0, Double(x / width)), 1)
            return visibleRange.lowerBound + fraction * visibleRange.span
        }

        /// A trim/selection window in normalized `0...1` file time, always `start < end`.
        public struct Selection: Equatable, Sendable {
            public var start: Double
            public var end: Double

            public init(start: Double = 0, end: Double = 1) {
                let s = min(max(0, start), 1)
                let e = min(max(0, end), 1)
                self.start = min(s, e)
                self.end = max(s, e)
                if self.end - self.start < 0.001 {
                    self.end = min(1, self.start + 0.001)
                }
            }

            public static let full = Selection(start: 0, end: 1)

            public var span: Double { end - start }

            public var asVisibleRange: VisibleRange {
                VisibleRange(lowerBound: start, upperBound: end)
            }

            /// Clamps `start` while keeping at least `minimumSpan` before `end`.
            public mutating func setStart(_ value: Double, minimumSpan: Double = 0.01) {
                let maxStart = max(0, end - minimumSpan)
                start = min(max(0, value), maxStart)
            }

            /// Clamps `end` while keeping at least `minimumSpan` after `start`.
            public mutating func setEnd(_ value: Double, minimumSpan: Double = 0.01) {
                let minEnd = min(1, start + minimumSpan)
                end = max(min(1, value), minEnd)
            }
        }
    }
}
