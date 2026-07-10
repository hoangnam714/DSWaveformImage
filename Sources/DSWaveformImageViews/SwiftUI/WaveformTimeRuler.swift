import DSWaveformImage
import SwiftUI

/// A zoom-aware time ruler for the currently visible waveform window.
@available(iOS 15.0, macOS 12.0, *)
public struct WaveformTimeRuler: View {
    public enum Style: Sendable {
        /// Compact decimal labels (`0`, `2`, `4`) drawn under ticks.
        case decimal
        /// Editor-style clock labels (`0:00`, `0:02.5`) with a baseline — matches typical DAW rulers.
        case clock
    }

    public var duration: TimeInterval
    public var visibleRange: Waveform.VisibleRange
    public var color: Color
    public var height: CGFloat
    public var style: Style

    public init(
        duration: TimeInterval,
        visibleRange: Waveform.VisibleRange,
        color: Color = .secondary,
        height: CGFloat = 28,
        style: Style = .decimal
    ) {
        self.duration = duration
        self.visibleRange = visibleRange
        self.color = color
        self.height = height
        self.style = style
    }

    public var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: context, size: size)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var timeFormat: Waveform.Timeline.TimeFormatStyle {
        switch style {
        case .decimal: return .automatic
        case .clock: return .clock
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard duration > 0, size.width > 0, visibleRange.span > 0 else { return }

        let visibleDuration = duration * visibleRange.span
        let major = Waveform.Timeline.majorInterval(visibleDuration: visibleDuration)
        let minor = major / 5
        let startTime = duration * visibleRange.lowerBound
        let endTime = duration * visibleRange.upperBound

        let edgePad: CGFloat = 2
        let edgeLabelBand: CGFloat = style == .clock ? 22 : 18
        var occupiedLabelFrames: [CGRect] = []

        // Baseline for clock style (ticks rise from the line).
        if style == .clock {
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: 1))
            baseline.addLine(to: CGPoint(x: size.width, y: 1))
            context.stroke(baseline, with: .color(color.opacity(0.35)), lineWidth: 1)
        }

        let firstMinor = (startTime / minor).rounded(.up) * minor
        var t = firstMinor
        while t <= endTime + 0.0001 {
            let progress = t / duration
            let x = CGFloat((progress - visibleRange.lowerBound) / visibleRange.span) * size.width
            let isMajor = isNearMultiple(t, of: major)
            let tickHeight: CGFloat = isMajor ? (style == .clock ? 8 : 10) : (style == .clock ? 4 : 5)

            if x >= -0.5, x <= size.width + 0.5 {
                var path = Path()
                path.move(to: CGPoint(x: x, y: style == .clock ? 1 : 0))
                path.addLine(to: CGPoint(x: x, y: 1 + tickHeight))
                context.stroke(path, with: .color(color.opacity(isMajor ? 0.85 : 0.4)), lineWidth: 1)
            }

            let inEdgeBand = x <= edgeLabelBand || x >= size.width - edgeLabelBand
            if isMajor, !inEdgeBand {
                drawLabel(
                    Waveform.Timeline.formatTime(t, style: timeFormat, majorInterval: major),
                    at: x,
                    tickHeight: tickHeight,
                    in: context,
                    size: size,
                    edgePad: edgePad,
                    occupied: &occupiedLabelFrames
                )
            }
            t += minor
        }

        drawLabel(
            Waveform.Timeline.formatTime(startTime, style: timeFormat, majorInterval: major),
            at: edgePad,
            tickHeight: 10,
            in: context,
            size: size,
            edgePad: edgePad,
            occupied: &occupiedLabelFrames,
            preferredAnchor: .leading
        )
        drawLabel(
            Waveform.Timeline.formatTime(endTime, style: timeFormat, majorInterval: major),
            at: size.width - edgePad,
            tickHeight: 10,
            in: context,
            size: size,
            edgePad: edgePad,
            occupied: &occupiedLabelFrames,
            preferredAnchor: .trailing
        )
    }

    private func isNearMultiple(_ value: Double, of step: Double) -> Bool {
        guard step > 0 else { return false }
        let quotient = value / step
        return abs(quotient.rounded() - quotient) < 0.001
    }

    private func drawLabel(
        _ label: String,
        at x: CGFloat,
        tickHeight: CGFloat,
        in context: GraphicsContext,
        size: CGSize,
        edgePad: CGFloat,
        occupied: inout [CGRect],
        preferredAnchor: UnitPoint? = nil
    ) {
        let text = Text(label)
            .font(.system(size: style == .clock ? 9 : 10, weight: .medium, design: .monospaced))
            .foregroundColor(color)
        let resolved = context.resolve(text)
        let textSize = resolved.measure(in: CGSize(width: 120, height: 20))

        let anchor: UnitPoint
        let drawX: CGFloat
        if let preferredAnchor {
            anchor = preferredAnchor
            drawX = x
        } else if x - textSize.width / 2 < edgePad {
            anchor = .leading
            drawX = edgePad
        } else if x + textSize.width / 2 > size.width - edgePad {
            anchor = .trailing
            drawX = size.width - edgePad
        } else {
            anchor = .center
            drawX = x
        }

        let originX: CGFloat
        switch anchor {
        case .leading: originX = drawX
        case .trailing: originX = drawX - textSize.width
        default: originX = drawX - textSize.width / 2
        }
        let frame = CGRect(
            x: originX,
            y: tickHeight + 2,
            width: textSize.width,
            height: textSize.height
        )

        for existing in occupied where existing.insetBy(dx: -4, dy: 0).intersects(frame) {
            return
        }

        occupied.append(frame)
        context.draw(resolved, at: CGPoint(x: drawX, y: tickHeight + 11), anchor: anchor)
    }
}
