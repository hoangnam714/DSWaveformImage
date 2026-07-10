import AVFoundation
import DSWaveformImage
import SwiftUI

/// Zoomable waveform with a time ruler, draggable playhead, optional trim handles, and overview.
///
/// Pan, trim, and playhead share **one** gesture recognizer (hit-tested on touch-down) so they
/// never fight each other. Trim/playhead drags freeze the visible window for the duration of the
/// gesture — no mid-drag auto-scroll that would scramble coordinates.
///
/// The overview strip always renders the **full** file; its yellow frame tracks `selection`.
@available(iOS 15.0, macOS 12.0, *)
public struct InteractiveWaveformTimeline: View {
    private let audioURL: URL
    private let configuration: Waveform.Configuration
    private let renderer: WaveformRenderer
    private let minimumZoom: CGFloat
    private let maximumZoom: CGFloat
    private let waveformHeight: CGFloat
    private let stripeWidth: CGFloat
    private let cursorColor: Color
    private let rulerColor: Color
    private let trimColor: Color
    private let showsTrimming: Bool
    private let showsOverview: Bool
    private let rulerStyle: WaveformTimeRuler.Style
    private let waveformColors: [Color]
    private let playheadLabelHideDistance: CGFloat
    private let handleHitSlop: CGFloat = 28
    private let topBandHeight: CGFloat = 44
    private let topBandSlop: CGFloat = 40

    @Binding private var zoom: CGFloat
    @Binding private var visibleRange: Waveform.VisibleRange
    @Binding private var progress: Double
    @Binding private var selection: Waveform.Timeline.Selection

    @State private var duration: TimeInterval = 0
    @State private var activeDrag: DragKind?
    @State private var gestureBaseRange: Waveform.VisibleRange?
    @State private var gestureOriginX: CGFloat = 0
    @State private var pinchBaseZoom: CGFloat?
    @State private var pinchBaseRange: Waveform.VisibleRange?

    private enum DragKind {
        case pan
        case playhead
        case trimStart
        case trimEnd
    }

    public init(
        audioURL: URL,
        zoom: Binding<CGFloat>,
        visibleRange: Binding<Waveform.VisibleRange>,
        progress: Binding<Double>,
        selection: Binding<Waveform.Timeline.Selection> = .constant(.full),
        showsTrimming: Bool = true,
        showsOverview: Bool = true,
        rulerStyle: WaveformTimeRuler.Style = .clock,
        configuration: Waveform.Configuration = Waveform.Configuration(
            style: .striped(.init(color: .white, width: 2, spacing: 2)),
            damping: nil
        ),
        renderer: WaveformRenderer = LinearWaveformRenderer(),
        minimumZoom: CGFloat = 1,
        maximumZoom: CGFloat = 8,
        waveformHeight: CGFloat = 100,
        stripeWidth: CGFloat = 2,
        cursorColor: Color = Color(red: 0.45, green: 0.78, blue: 1.0),
        rulerColor: Color = .white.opacity(0.55),
        waveformColors: [Color] = [.purple, .blue, .cyan],
        trimColor: Color = Color(red: 1.0, green: 0.84, blue: 0.0),
        playheadLabelHideDistance: CGFloat = 36
    ) {
        self.audioURL = audioURL
        self._zoom = zoom
        self._visibleRange = visibleRange
        self._progress = progress
        self._selection = selection
        self.showsTrimming = showsTrimming
        self.showsOverview = showsOverview
        self.rulerStyle = rulerStyle
        self.configuration = configuration
        self.renderer = renderer
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.waveformHeight = waveformHeight
        self.stripeWidth = stripeWidth
        self.cursorColor = cursorColor
        self.rulerColor = rulerColor
        self.waveformColors = waveformColors
        self.trimColor = trimColor
        self.playheadLabelHideDistance = playheadLabelHideDistance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    waveform()
                        .frame(width: width, height: waveformHeight)
                        .padding(.top, 14)
                        .allowsHitTesting(false)

                    if showsTrimming {
                        trimChrome(width: width)
                            .allowsHitTesting(false)
                    }

                    playheadChrome(width: width)
                        .allowsHitTesting(false)
                }
                .frame(width: width, height: waveformHeight + 14)
                .contentShape(Rectangle())
                .highPriorityGesture(unifiedDrag(width: width), including: .all)
                .simultaneousGesture(magnificationGesture)
            }
            .frame(height: waveformHeight + 14)

            WaveformTimeRuler(
                duration: duration,
                visibleRange: visibleRange,
                color: rulerColor,
                style: rulerStyle
            )

            if showsOverview {
                WaveformTimelineOverview(
                    audioURL: audioURL,
                    selection: $selection,
                    progress: $progress,
                    frameColor: trimColor,
                    playheadColor: cursorColor
                )
            }
        }
        .task(id: audioURL) {
            duration = await loadDuration(url: audioURL)
        }
        .preference(key: WaveformInteractionKey.self, value: activeDrag != nil)
    }

    private var waveformGradient: LinearGradient {
        LinearGradient(colors: waveformColors, startPoint: .leading, endPoint: .trailing)
    }

    // MARK: - Waveform

    private func waveform() -> some View {
        InteractiveWaveformView(
            audioURL: audioURL,
            zoom: $zoom,
            visibleRange: $visibleRange,
            configuration: configuration,
            renderer: renderer,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom,
            allowsScrolling: false
        ) { shape in
            shape.stroke(waveformGradient, style: StrokeStyle(lineWidth: stripeWidth, lineCap: .round))
        }
    }

    // MARK: - Trim

    private func trimChrome(width: CGFloat) -> some View {
        let startX = clampedX(for: selection.start, width: width)
        let endX = clampedX(for: selection.end, width: width)

        return ZStack(alignment: .topLeading) {
            // Dim outside selection; soft tint inside.
            GeometryReader { proxy in
                let w = proxy.size.width
                let leftWidth = max(0, startX)
                let midWidth = max(0, endX - startX)
                let rightWidth = max(0, w - endX)
                HStack(spacing: 0) {
                    Color.black.opacity(leftWidth > 0 ? 0.45 : 0)
                        .frame(width: leftWidth)
                    trimColor.opacity(midWidth > 0 ? 0.12 : 0)
                        .frame(width: midWidth)
                    Color.black.opacity(rightWidth > 0 ? 0.45 : 0)
                        .frame(width: rightWidth)
                }
            }
            .padding(.top, 14)
            .frame(height: waveformHeight + 14)

            if isVisible(selection.start) {
                trimHandle(
                    at: startX,
                    label: Waveform.Timeline.formatTime(
                        Waveform.Timeline.time(progress: selection.start, duration: duration),
                        style: .decimal,
                        majorInterval: 0.1
                    )
                )
            }
            if isVisible(selection.end) {
                trimHandle(
                    at: endX,
                    label: Waveform.Timeline.formatTime(
                        Waveform.Timeline.time(progress: selection.end, duration: duration),
                        style: .decimal,
                        majorInterval: 0.1
                    )
                )
            }
        }
    }

    private func trimHandle(at x: CGFloat, label: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.black.opacity(0.85))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(trimColor))

            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: 28, height: waveformHeight)
                Capsule()
                    .fill(trimColor)
                    .frame(width: 3, height: waveformHeight)
                VStack {
                    Circle().fill(trimColor).frame(width: 8, height: 8)
                    Spacer(minLength: 0)
                    Circle().fill(trimColor).frame(width: 8, height: 8)
                }
                .frame(height: waveformHeight)
            }
        }
        .frame(width: 48, alignment: .top)
        .position(x: x, y: (waveformHeight + 14) / 2 + 2)
    }

    // MARK: - Playhead

    private func playheadChrome(width: CGFloat) -> some View {
        Group {
            if let x = Waveform.Timeline.xPosition(
                progress: progress,
                visibleRange: visibleRange,
                width: width
            ) {
                let hideLabel = shouldHidePlayheadLabel(at: x, width: width)
                VStack(spacing: 2) {
                    if !hideLabel {
                        Text(timeLabel)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.black.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(cursorColor))
                    } else {
                        Color.clear.frame(height: 18)
                    }

                    Circle()
                        .fill(cursorColor)
                        .frame(width: 8, height: 8)

                    Rectangle()
                        .fill(cursorColor.opacity(0.95))
                        .frame(width: 1.5, height: waveformHeight - 8)

                    Circle()
                        .fill(cursorColor)
                        .frame(width: 8, height: 8)
                }
                .frame(width: 48, alignment: .top)
                .position(x: x, y: (waveformHeight + 14) / 2)
            }
        }
    }

    private func shouldHidePlayheadLabel(at playX: CGFloat, width: CGFloat) -> Bool {
        guard showsTrimming else { return false }
        if isVisible(selection.start) {
            let startX = clampedX(for: selection.start, width: width)
            if abs(playX - startX) < playheadLabelHideDistance { return true }
        }
        if isVisible(selection.end) {
            let endX = clampedX(for: selection.end, width: width)
            if abs(playX - endX) < playheadLabelHideDistance { return true }
        }
        return false
    }

    // MARK: - Gestures

    private func unifiedDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if activeDrag == nil {
                    let kind = hitTest(value.startLocation, width: width)
                    activeDrag = kind
                    gestureBaseRange = visibleRange
                    switch kind {
                    case .pan:
                        gestureOriginX = value.startLocation.x
                    case .playhead:
                        gestureOriginX = Waveform.Timeline.xPosition(
                            progress: progress,
                            visibleRange: visibleRange,
                            width: width
                        ) ?? value.startLocation.x
                    case .trimStart:
                        gestureOriginX = clampedX(for: selection.start, width: width)
                    case .trimEnd:
                        gestureOriginX = clampedX(for: selection.end, width: width)
                    }
                }

                guard let kind = activeDrag, let frozen = gestureBaseRange else { return }

                switch kind {
                case .pan:
                    guard zoom > minimumZoom + 0.001 else { return }
                    let deltaFraction = -Double(value.translation.width / width) * frozen.span
                    visibleRange = .from(zoom: Double(zoom), start: frozen.lowerBound + deltaFraction)

                case .playhead, .trimStart, .trimEnd:
                    let scrubX = min(max(0, gestureOriginX + value.translation.width), width)
                    let newProgress = Waveform.Timeline.progress(
                        x: scrubX,
                        visibleRange: frozen,
                        width: width
                    )
                    switch kind {
                    case .playhead:
                        progress = min(max(newProgress, selection.start), selection.end)
                    case .trimStart:
                        selection.setStart(newProgress)
                        if progress < selection.start { progress = selection.start }
                    case .trimEnd:
                        selection.setEnd(newProgress)
                        if progress > selection.end { progress = selection.end }
                    case .pan:
                        break
                    }
                }
            }
            .onEnded { _ in
                activeDrag = nil
                gestureBaseRange = nil
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                guard activeDrag == nil else { return }
                if pinchBaseZoom == nil {
                    pinchBaseZoom = zoom
                    pinchBaseRange = visibleRange
                }
                guard let baseZoom = pinchBaseZoom, let baseRange = pinchBaseRange else { return }
                let next = min(maximumZoom, max(minimumZoom, baseZoom * magnification))
                let anchor = baseRange.lowerBound + baseRange.span / 2
                zoom = next
                visibleRange = .from(zoom: Double(next), start: anchor - (1 / Double(next)) / 2)
            }
            .onEnded { _ in
                pinchBaseZoom = nil
                pinchBaseRange = nil
            }
    }

    private func hitTest(_ point: CGPoint, width: CGFloat) -> DragKind {
        let zoomed = zoom > minimumZoom + 0.001
        let inTopBand = point.y <= topBandHeight
        let slop = inTopBand ? topBandSlop : handleHitSlop

        struct Candidate {
            let kind: DragKind
            let distance: CGFloat
        }
        var candidates: [Candidate] = []

        if showsTrimming {
            if isVisible(selection.start) {
                let distance = abs(point.x - clampedX(for: selection.start, width: width))
                if distance <= slop {
                    candidates.append(Candidate(kind: .trimStart, distance: distance))
                }
            }
            if isVisible(selection.end) {
                let distance = abs(point.x - clampedX(for: selection.end, width: width))
                if distance <= slop {
                    candidates.append(Candidate(kind: .trimEnd, distance: distance))
                }
            }
        }

        if let playX = Waveform.Timeline.xPosition(
            progress: progress,
            visibleRange: visibleRange,
            width: width
        ) {
            let distance = abs(point.x - playX)
            if distance <= slop {
                candidates.append(Candidate(kind: .playhead, distance: distance))
            }
        }

        if let best = candidates.min(by: { $0.distance < $1.distance }) {
            if zoomed, !inTopBand, best.distance > handleHitSlop * 0.65 {
                return .pan
            }
            return best.kind
        }

        if zoomed { return .pan }
        return .playhead
    }

    // MARK: - Helpers

    private func clampedX(for progress: Double, width: CGFloat) -> CGFloat {
        guard width > 0, visibleRange.span > 0 else { return 0 }
        if progress <= visibleRange.lowerBound { return 0 }
        if progress >= visibleRange.upperBound { return width }
        return CGFloat((progress - visibleRange.lowerBound) / visibleRange.span) * width
    }

    private func isVisible(_ progress: Double) -> Bool {
        progress >= visibleRange.lowerBound && progress <= visibleRange.upperBound
    }

    private var timeLabel: String {
        let seconds = Waveform.Timeline.time(progress: progress, duration: duration)
        return Waveform.Timeline.formatTime(seconds, style: .decimal, majorInterval: 0.1)
    }

    private func loadDuration(url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite ? max(0, seconds) : 0
    }
}
