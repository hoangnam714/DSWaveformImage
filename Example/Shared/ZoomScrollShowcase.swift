import DSWaveformImage
import DSWaveformImageViews
import SwiftUI

/// Pinch-to-zoom + drag-to-scroll demo. Shared across iOS, macOS, and visionOS examples.
@available(iOS 15.0, macOS 12.0, *)
public struct ZoomScrollShowcase: View {
    public init() {}

    public var body: some View {
        GalleryScrollView {
            GalleryHero(
                title: "Zoom & Scroll",
                subtitle: "Pinch to zoom, drag to pan, and scrub the playhead. The time ruler rescales with the visible window."
            )
            TimelineSection()
            InteractiveZoomSection()
        }
    }
}

// MARK: - Timeline (ruler + playhead + trim)

@available(iOS 15.0, macOS 12.0, *)
private struct TimelineSection: View {
    private let url = SampleAudio.stereoDemo
    @State private var zoom: CGFloat = 1
    @State private var visibleRange: Waveform.VisibleRange = .full
    @State private var progress: Double = 0.35
    @State private var selection: Waveform.Timeline.Selection = .init(start: 0.15, end: 0.85)

    var body: some View {
        GallerySection(
            "Timeline",
            systemImage: "timeline.selection",
            subtitle: "Playhead time hides when it overlaps a trim handle. The overview always shows the full file; drag the yellow frame to move or resize the trim."
        ) {
            WaveformCard(caption: "InteractiveWaveformTimeline + overview") {
                VStack(spacing: 14) {
                    InteractiveWaveformTimeline(
                        audioURL: url,
                        zoom: $zoom,
                        visibleRange: $visibleRange,
                        progress: $progress,
                        selection: $selection,
                        showsOverview: true,
                        rulerStyle: .clock,
                        maximumZoom: 8,
                        waveformHeight: 110,
                        waveformColors: [.purple, .blue, .cyan]
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(white: 0.14))
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            zoom = 1
                            visibleRange = .full
                        }
                    }

                    HStack {
                        Label(String(format: "%.1f×", zoom), systemImage: "plus.magnifyingglass")
                        Spacer()
                        Text(trimLabel)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    Slider(
                        value: Binding(
                            get: { zoom },
                            set: { newZoom in
                                zoom = newZoom
                                visibleRange = .from(zoom: Double(newZoom), start: visibleRange.lowerBound)
                            }
                        ),
                        in: 1...8
                    )
                }
            }
        }
    }

    private var trimLabel: String {
        // Demo clip ≈ 6s; labels are approximate until duration loads in the timeline itself.
        let duration = 6.0
        let start = selection.start * duration
        let end = selection.end * duration
        return String(format: "%.1fs – %.1fs", start, end)
    }
}

// MARK: - Freeform interaction

@available(iOS 15.0, macOS 12.0, *)
private struct InteractiveZoomSection: View {
    private let url = SampleAudio.stereoDemo
    @State private var zoom: CGFloat = 1
    @State private var visibleRange: Waveform.VisibleRange = .full

    var body: some View {
        GallerySection(
            "Pinch & pan",
            systemImage: "hand.pinch",
            subtitle: "Waveform-only zoom/pan without the ruler — same InteractiveWaveformView used under the timeline."
        ) {
            WaveformCard(caption: "{ shape in shape.stroke(…) } — striped + stroke override") {
                VStack(spacing: 14) {
                    InteractiveWaveformView(
                        audioURL: url,
                        zoom: $zoom,
                        visibleRange: $visibleRange,
                        configuration: .init(
                            style: .striped(.init(color: .systemIndigo, width: 3, spacing: 3)),
                            damping: nil
                        ),
                        maximumZoom: 8
                    ) { shape in
                        shape.stroke(
                            LinearGradient(colors: [.purple, .blue, .cyan], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                    }
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            zoom = 1
                            visibleRange = .full
                        }
                    }

                    HStack {
                        Label(String(format: "%.1f×", zoom), systemImage: "plus.magnifyingglass")
                        Spacer()
                        Text(rangeLabel)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    Slider(
                        value: Binding(
                            get: { zoom },
                            set: { newZoom in
                                zoom = newZoom
                                visibleRange = .from(zoom: Double(newZoom), start: visibleRange.lowerBound)
                            }
                        ),
                        in: 1...8
                    )
                }
            }
        }
    }

    private var rangeLabel: String {
        String(format: "%.0f%% – %.0f%%", visibleRange.lowerBound * 100, visibleRange.upperBound * 100)
    }
}

#if DEBUG
@available(iOS 15.0, macOS 12.0, *)
struct ZoomScrollShowcase_Previews: PreviewProvider {
    static var previews: some View {
        ZoomScrollShowcase()
    }
}
#endif
