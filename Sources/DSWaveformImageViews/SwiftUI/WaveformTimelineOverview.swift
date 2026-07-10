import DSWaveformImage
import SwiftUI

/// Mini full-file waveform with a draggable trim frame over the complete audio.
///
/// The strip always shows **100%** of the file. The yellow (or custom) frame marks the
/// current trim `selection`; drag the frame to move the window, drag its edges to resize.
@available(iOS 15.0, macOS 12.0, *)
public struct WaveformTimelineOverview: View {
    private let audioURL: URL
    private let height: CGFloat
    private let waveformColor: Color
    private let frameColor: Color
    private let playheadColor: Color
    private let trackColor: Color
    private let minimumSpan: Double

    @Binding private var selection: Waveform.Timeline.Selection
    @Binding private var progress: Double

    @State private var samples: [Float] = []
    @State private var dragKind: DragKind?
    @State private var dragBaseSelection: Waveform.Timeline.Selection?

    private enum DragKind {
        case pan
        case resizeLeading
        case resizeTrailing
    }

    public init(
        audioURL: URL,
        selection: Binding<Waveform.Timeline.Selection>,
        progress: Binding<Double>,
        height: CGFloat = 44,
        minimumSpan: Double = 0.01,
        waveformColor: Color = .white.opacity(0.85),
        frameColor: Color = Color(red: 1.0, green: 0.84, blue: 0.0),
        playheadColor: Color = Color(red: 0.45, green: 0.75, blue: 1.0),
        trackColor: Color = Color.white.opacity(0.08)
    ) {
        self.audioURL = audioURL
        self._selection = selection
        self._progress = progress
        self.height = height
        self.minimumSpan = minimumSpan
        self.waveformColor = waveformColor
        self.frameColor = frameColor
        self.playheadColor = playheadColor
        self.trackColor = trackColor
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let configuration = Waveform.Configuration(
                style: .striped(.init(color: .white, width: 1, spacing: 1)),
                damping: nil
            )
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(trackColor)

                WaveformShape(samples: samples, configuration: configuration)
                    .stroke(waveformColor, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .padding(.horizontal, 2)

                // Trim frame in full-file coordinates.
                trimFrame(width: width)
                    .allowsHitTesting(false)

                // Playhead in overview coordinates (full file).
                Rectangle()
                    .fill(playheadColor)
                    .frame(width: 1.5)
                    .offset(x: CGFloat(progress) * width - 0.75)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .gesture(overviewDrag(width: width))
            .task(id: audioURL) {
                await loadSamples(width: width, scale: configuration.scale)
            }
            .modifier(OnChange(of: width, action: { newWidth in
                Task { await loadSamples(width: newWidth, scale: configuration.scale) }
            }))
        }
        .frame(height: height)
        .preference(key: WaveformInteractionKey.self, value: dragKind != nil)
    }

    private func trimFrame(width: CGFloat) -> some View {
        let leading = CGFloat(selection.start) * width
        let trailing = CGFloat(selection.end) * width
        let frameWidth = max(18, trailing - leading)

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(frameColor.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(frameColor, lineWidth: 2)
                )
                .frame(width: frameWidth, height: height - 4)

            // Edge grips
            HStack {
                edgeGrip(systemName: "chevron.left")
                Spacer(minLength: 0)
                edgeGrip(systemName: "chevron.right")
            }
            .frame(width: frameWidth, height: height - 4)
        }
        .frame(width: frameWidth, height: height - 4)
        .offset(x: leading, y: 0)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func edgeGrip(systemName: String) -> some View {
        ZStack {
            Capsule()
                .fill(frameColor)
                .frame(width: 10, height: height - 12)
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.black.opacity(0.7))
        }
    }

    private func overviewDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragKind == nil {
                    let kind = hitTest(value.startLocation.x, width: width)
                    dragKind = kind

                    if kind == .pan,
                       value.startLocation.x < CGFloat(selection.start) * width
                        || value.startLocation.x > CGFloat(selection.end) * width {
                        // Tap outside → jump trim window so the tap is centered.
                        let span = selection.span
                        let center = Double(value.startLocation.x / width)
                        let newStart = min(max(0, center - span / 2), 1 - span)
                        selection = Waveform.Timeline.Selection(start: newStart, end: newStart + span)
                        clampProgressToSelection()
                    }
                    dragBaseSelection = selection
                }
                guard let kind = dragKind, let base = dragBaseSelection else { return }
                let delta = Double(value.translation.width / width)

                switch kind {
                case .pan:
                    let span = base.span
                    var newStart = base.start + delta
                    newStart = min(max(0, newStart), 1 - span)
                    selection = Waveform.Timeline.Selection(start: newStart, end: newStart + span)
                    clampProgressToSelection()
                case .resizeLeading:
                    var next = base
                    next.setStart(base.start + delta, minimumSpan: minimumSpan)
                    selection = next
                    clampProgressToSelection()
                case .resizeTrailing:
                    var next = base
                    next.setEnd(base.end + delta, minimumSpan: minimumSpan)
                    selection = next
                    clampProgressToSelection()
                }
            }
            .onEnded { _ in
                dragKind = nil
                dragBaseSelection = nil
            }
    }

    private func clampProgressToSelection() {
        if progress < selection.start { progress = selection.start }
        if progress > selection.end { progress = selection.end }
    }

    private func hitTest(_ x: CGFloat, width: CGFloat) -> DragKind {
        let leading = CGFloat(selection.start) * width
        let trailing = CGFloat(selection.end) * width
        let edge: CGFloat = 14
        if abs(x - leading) <= edge { return .resizeLeading }
        if abs(x - trailing) <= edge { return .resizeTrailing }
        if x >= leading, x <= trailing { return .pan }
        // Tap outside → jump the trim window so the tap is centered.
        return .pan
    }

    private func loadSamples(width: CGFloat, scale: CGFloat) async {
        guard width > 0 else { return }
        // Must match `WaveformView` / renderer expectations: sample count = width × scale.
        // Fewer samples get right-aligned (live-recording style) and look like a broken preview.
        let count = max(32, Int(width * scale))
        do {
            let analyzed = try await WaveformAnalyzer().samples(fromAudioAt: audioURL, count: count)
            await MainActor.run { samples = analyzed }
        } catch {
            assertionFailure(error.localizedDescription)
        }
    }
}
