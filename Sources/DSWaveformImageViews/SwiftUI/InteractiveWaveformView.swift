import DSWaveformImage
import SwiftUI

@available(iOS 15.0, macOS 12.0, *)
/// An interactive waveform that supports pinch-to-zoom and drag-to-scroll over a high-resolution sample cache.
///
/// Analyzes the audio once at `viewportWidth × scale × maximumZoom` resolution. At a given zoom the
/// full file is resampled into a **wide** layer (`viewportWidth × zoom`); panning only translates that
/// layer — it does **not** re-slice peaks every frame, which avoids the shimmer/flicker of
/// bucket-shifting envelopes. Circular renderers are not supported — zoom/scroll is a linear-envelope
/// interaction.
public struct InteractiveWaveformView<Content: View>: View {
    private let audioURL: URL
    private let configuration: Waveform.Configuration
    private let renderer: WaveformRenderer
    private let priority: TaskPriority
    private let minimumZoom: CGFloat
    private let maximumZoom: CGFloat
    /// When `false`, pinch still works but horizontal pan is left to a parent (e.g. timeline).
    private let allowsScrolling: Bool
    private let content: (WaveformShape) -> Content

    @Binding private var zoom: CGFloat
    @Binding private var visibleRange: Waveform.VisibleRange

    @State private var samples: [Float] = []
    @State private var spectralCentroids: [Float] = []
    /// Full-file samples resampled for the current zoom / viewport width. Stable while panning.
    @State private var displaySamples: [Float] = []
    @State private var displayCentroids: [Float] = []
    @State private var displayContentWidth: CGFloat = 0
    @State private var viewportSize: CGSize = .zero
    @State private var analysisTask: Task<Void, Never>?

    @State private var pinchBaseZoom: CGFloat?
    @State private var pinchBaseRange: Waveform.VisibleRange?
    @State private var dragBaseRange: Waveform.VisibleRange?
    @State private var isPinching = false
    @State private var isPanning = false

    /**
     Creates an interactive waveform for `audioURL`.

     - Parameters:
        - audioURL: Local audio file URL.
        - zoom: Binding for the current zoom factor (`1` = fit full file, up to `maximumZoom`).
        - visibleRange: Binding for the normalized visible window (`0...1` of total duration).
        - configuration: Rendering configuration. Damping is typically unwanted while zoomed; pass `damping: nil` if needed.
        - renderer: Must be a linear-style renderer. Defaults to `LinearWaveformRenderer()`.
        - minimumZoom: Lower zoom clamp. Defaults to `1`.
        - maximumZoom: Upper zoom clamp and analysis density multiplier. Defaults to `8`.
        - allowsScrolling: When `false`, this view does not install its own pan gesture (useful when a
          parent timeline coordinates pan vs trim/playhead). Pinch-to-zoom still works. Defaults to `true`.
        - priority: The `TaskPriority` used during analyzing. Defaults to `.userInitiated`.
        - content: ViewBuilder that styles the visible `WaveformShape`.
     */
    public init(
        audioURL: URL,
        zoom: Binding<CGFloat>,
        visibleRange: Binding<Waveform.VisibleRange>,
        configuration: Waveform.Configuration = Waveform.Configuration(damping: .init(percentage: 0.125, sides: .both)),
        renderer: WaveformRenderer = LinearWaveformRenderer(),
        minimumZoom: CGFloat = 1,
        maximumZoom: CGFloat = 8,
        allowsScrolling: Bool = true,
        priority: TaskPriority = .userInitiated,
        @ViewBuilder content: @escaping (WaveformShape) -> Content
    ) {
        self.audioURL = audioURL
        self._zoom = zoom
        self._visibleRange = visibleRange
        self.configuration = configuration
        self.renderer = renderer
        self.minimumZoom = max(1, minimumZoom)
        self.maximumZoom = max(self.minimumZoom, maximumZoom)
        self.allowsScrolling = allowsScrolling
        self.priority = priority
        self.content = content
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let contentWidth = zoomedContentWidth(for: size.width)
            let offsetX = panOffset(contentWidth: contentWidth)

            ZStack(alignment: .leading) {
                if case .spectralTint = configuration.style {
                    spectralCanvas(contentWidth: contentWidth, height: size.height)
                        .offset(x: offsetX)
                } else {
                    content(WaveformShape(
                        samples: displaySamples,
                        configuration: configuration,
                        renderer: renderer
                    ))
                    .frame(width: contentWidth, height: size.height)
                    // Rasterize once per zoom; pan only moves the texture (no path rebuild / shimmer).
                    .drawingGroup(opaque: false)
                    .offset(x: offsetX)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            // Pan updates must not implicitly animate sample/path morphs.
            .transaction { $0.animation = nil }
            .modifier(PanGestureModifier(
                enabled: allowsScrolling && zoomedIn,
                gesture: dragGesture(viewportWidth: size.width)
            ))
            .simultaneousGesture(magnificationGesture(viewportWidth: size.width))
            .onAppear {
                viewportSize = size
                reloadSamplesIfNeeded(for: size)
                rebuildDisplaySamples(for: size)
            }
            .modifier(OnChange(of: size, action: { newValue in
                viewportSize = newValue
                reloadSamplesIfNeeded(for: newValue)
                rebuildDisplaySamples(for: newValue)
            }))
            .modifier(OnChange(of: audioURL, action: { _ in
                samples = []
                spectralCentroids = []
                displaySamples = []
                displayCentroids = []
                reloadSamplesIfNeeded(for: size, force: true)
            }))
            .modifier(OnChange(of: configuration, action: { _ in
                reloadSamplesIfNeeded(for: size, force: true)
                rebuildDisplaySamples(for: size)
            }))
            .modifier(OnChange(of: rendererChannelSelection, action: { _ in
                samples = []
                spectralCentroids = []
                displaySamples = []
                displayCentroids = []
                reloadSamplesIfNeeded(for: size, force: true)
            }))
            .modifier(OnChange(of: zoom, action: { newZoom in
                rebuildDisplaySamples(for: size)
                guard !isPinching else { return }
                syncRange(to: newZoom, anchor: nil)
            }))
            .modifier(OnChange(of: samples.count, action: { _ in
                rebuildDisplaySamples(for: size)
            }))
        }
        .preference(key: WaveformInteractionKey.self, value: isPanning || isPinching)
    }

    private var zoomedIn: Bool {
        zoom > minimumZoom + 0.001
    }

    // MARK: - Zoomed layer (stable while panning)

    private var isStereo: Bool {
        (renderer as? ChannelAwareWaveformRenderer)?.channelSelection == .stereo
    }

    private var rendererChannelSelection: Waveform.ChannelSelection {
        (renderer as? ChannelAwareWaveformRenderer)?.channelSelection ?? .merged
    }

    private func zoomedContentWidth(for viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth > 0 else { return 0 }
        // Prefer the last rebuilt width when it matches current zoom so the offset stays
        // consistent with the rasterized layer even mid-frame.
        if displayContentWidth > 0 {
            let expected = viewportWidth * max(zoom, minimumZoom)
            if abs(displayContentWidth - expected) < 0.5 {
                return displayContentWidth
            }
        }
        return viewportWidth * max(zoom, minimumZoom)
    }

    private func panOffset(contentWidth: CGFloat) -> CGFloat {
        guard contentWidth > 0 else { return 0 }
        let raw = -CGFloat(visibleRange.lowerBound) * contentWidth
        // Snap to device pixels so stripes stay crisp while dragging.
        let scale = max(configuration.scale, 1)
        return (raw * scale).rounded() / scale
    }

    private func rebuildDisplaySamples(for size: CGSize) {
        guard !samples.isEmpty, size.width > 0 else {
            displaySamples = []
            displayCentroids = []
            displayContentWidth = 0
            return
        }

        let contentWidth = size.width * max(zoom, minimumZoom)
        let targetCount = max(1, Int(contentWidth * configuration.scale))
        displayContentWidth = contentWidth
        displaySamples = WaveformSampleViewport.resample(
            samples,
            to: targetCount,
            isStereo: isStereo
        )

        if case .spectralTint = configuration.style, !spectralCentroids.isEmpty {
            displayCentroids = WaveformSampleViewport.resample(
                spectralCentroids,
                to: targetCount,
                isStereo: isStereo
            )
        } else {
            displayCentroids = []
        }
    }

    @ViewBuilder
    private func spectralCanvas(contentWidth: CGFloat, height: CGFloat) -> some View {
        let amplitudes = displaySamples
        let centroids = displayCentroids
        let configuration = self.configuration
        let renderer = self.renderer
        Canvas(rendersAsynchronously: false) { context, canvasSize in
            context.withCGContext { cgContext in
                let effectiveRenderer = (renderer as? SpectralAwareWaveformRenderer)?.withSpectralCentroids(centroids) ?? renderer
                WaveformImageDrawer().draw(
                    waveform: amplitudes,
                    on: cgContext,
                    with: configuration.with(size: canvasSize),
                    renderer: effectiveRenderer
                )
            }
        }
        .frame(width: contentWidth, height: height)
        .drawingGroup(opaque: false)
    }

    // MARK: - Gestures

    private func dragGesture(viewportWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !isPinching, zoomedIn, viewportWidth > 0 else { return }

                // Lock to horizontal once a pan has started so a slight vertical drift
                // doesn't cancel mid-gesture / hand the touch back to a parent ScrollView.
                let alreadyPanning = dragBaseRange != nil
                if !alreadyPanning {
                    let horizontal = abs(value.translation.width)
                    let vertical = abs(value.translation.height)
                    guard horizontal >= vertical, horizontal > 2 else { return }
                    dragBaseRange = visibleRange
                    isPanning = true
                }

                guard let base = dragBaseRange else { return }
                let deltaFraction = -Double(value.translation.width / viewportWidth) * base.span
                visibleRange = Waveform.VisibleRange.from(
                    zoom: Double(zoom),
                    start: base.lowerBound + deltaFraction
                )
            }
            .onEnded { _ in
                dragBaseRange = nil
                isPanning = false
            }
    }

    private func magnificationGesture(viewportWidth: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                if pinchBaseZoom == nil {
                    isPinching = true
                    pinchBaseZoom = zoom
                    pinchBaseRange = visibleRange
                    dragBaseRange = nil
                    isPanning = false
                }
                guard let baseZoom = pinchBaseZoom, let baseRange = pinchBaseRange else { return }
                let nextZoom = clampZoom(baseZoom * magnification)
                let anchor = baseRange.lowerBound + baseRange.span / 2
                zoom = nextZoom
                syncRange(to: nextZoom, anchor: anchor)
                _ = viewportWidth
            }
            .onEnded { _ in
                pinchBaseZoom = nil
                pinchBaseRange = nil
                isPinching = false
            }
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, value))
    }

    /// Keeps `visibleRange` consistent with `zoom`. When `anchor` is provided (pinch), that
    /// normalized position stays centered in the viewport.
    private func syncRange(to newZoom: CGFloat, anchor: Double?) {
        let clamped = clampZoom(newZoom)
        let span = 1 / Double(clamped)
        let center = anchor ?? (visibleRange.lowerBound + visibleRange.span / 2)
        let start = center - span / 2
        visibleRange = Waveform.VisibleRange.from(zoom: Double(clamped), start: start)
        if zoom != clamped {
            zoom = clamped
        }
    }

    // MARK: - Analysis

    private func reloadSamplesIfNeeded(for size: CGSize, force: Bool = false) {
        guard size.width > 0 else { return }
        let samplesNeeded = max(1, Int(size.width * configuration.scale * maximumZoom))
        let currentPerChannel = isStereo ? samples.count / 2 : samples.count
        if !force, currentPerChannel >= samplesNeeded { return }

        analysisTask?.cancel()
        analysisTask = Task(priority: priority) {
            do {
                let channelSelection = rendererChannelSelection
                if case .spectralTint = configuration.style {
                    let analysis = try await WaveformAnalyzer().analyze(
                        fromAudioAt: audioURL,
                        count: samplesNeeded,
                        channelSelection: channelSelection
                    )
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.samples = analysis.amplitudes
                        self.spectralCentroids = analysis.spectralCentroids
                        self.rebuildDisplaySamples(for: self.viewportSize)
                    }
                } else {
                    let analyzed = try await WaveformAnalyzer().samples(
                        fromAudioAt: audioURL,
                        count: samplesNeeded,
                        channelSelection: channelSelection
                    )
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.samples = analyzed
                        self.spectralCentroids = []
                        self.rebuildDisplaySamples(for: self.viewportSize)
                    }
                }
            } catch {
                assertionFailure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Parent scroll coordination

/// Bubbles up whether the waveform is currently consuming a pan/pinch, so a parent
/// `ScrollView` can call `.scrollDisabled(true)` and stop stealing the gesture.
@available(iOS 15.0, macOS 12.0, *)
public struct WaveformInteractionKey: PreferenceKey {
    public static let defaultValue = false
    public static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

@available(iOS 15.0, macOS 12.0, *)
public extension View {
    /// Disables scrolling on this container while an `InteractiveWaveformView` inside is panning or pinching.
    func disablesScrollDuringWaveformInteraction() -> some View {
        modifier(DisableScrollDuringWaveformInteraction())
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct DisableScrollDuringWaveformInteraction: ViewModifier {
    @State private var interacting = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(WaveformInteractionKey.self) { interacting = $0 }
            .modifier(ScrollDisabledIfAvailable(disabled: interacting))
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct ScrollDisabledIfAvailable: ViewModifier {
    let disabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            content.scrollDisabled(disabled)
        } else {
            content
        }
    }
}

// MARK: - Convenience inits

@available(iOS 15.0, macOS 12.0, *)
public extension InteractiveWaveformView {
    /// Default-styled interactive waveform (filled / outlined / … via `configuration.style`).
    init(
        audioURL: URL,
        zoom: Binding<CGFloat>,
        visibleRange: Binding<Waveform.VisibleRange>,
        configuration: Waveform.Configuration = Waveform.Configuration(damping: .init(percentage: 0.125, sides: .both)),
        renderer: WaveformRenderer = LinearWaveformRenderer(),
        minimumZoom: CGFloat = 1,
        maximumZoom: CGFloat = 8,
        allowsScrolling: Bool = true,
        priority: TaskPriority = .userInitiated
    ) where Content == AnyView {
        self.init(
            audioURL: audioURL,
            zoom: zoom,
            visibleRange: visibleRange,
            configuration: configuration,
            renderer: renderer,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom,
            allowsScrolling: allowsScrolling,
            priority: priority
        ) { shape in
            AnyView(DefaultShapeStyler().style(shape: shape, with: configuration))
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct PanGestureModifier<G: Gesture>: ViewModifier {
    let enabled: Bool
    let gesture: G

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.highPriorityGesture(gesture, including: .all)
        } else {
            content
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
/// Owns zoom / visible-range state internally when the caller doesn't need to observe them.
public struct InteractiveWaveform<Content: View>: View {
    private let audioURL: URL
    private let configuration: Waveform.Configuration
    private let renderer: WaveformRenderer
    private let minimumZoom: CGFloat
    private let maximumZoom: CGFloat
    private let priority: TaskPriority
    private let content: (WaveformShape) -> Content

    @State private var zoom: CGFloat = 1
    @State private var visibleRange: Waveform.VisibleRange = .full

    public init(
        audioURL: URL,
        configuration: Waveform.Configuration = Waveform.Configuration(damping: .init(percentage: 0.125, sides: .both)),
        renderer: WaveformRenderer = LinearWaveformRenderer(),
        minimumZoom: CGFloat = 1,
        maximumZoom: CGFloat = 8,
        priority: TaskPriority = .userInitiated,
        @ViewBuilder content: @escaping (WaveformShape) -> Content
    ) {
        self.audioURL = audioURL
        self.configuration = configuration
        self.renderer = renderer
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.priority = priority
        self.content = content
    }

    public var body: some View {
        InteractiveWaveformView(
            audioURL: audioURL,
            zoom: $zoom,
            visibleRange: $visibleRange,
            configuration: configuration,
            renderer: renderer,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom,
            priority: priority,
            content: content
        )
    }
}

@available(iOS 15.0, macOS 12.0, *)
public extension InteractiveWaveform {
    init(
        audioURL: URL,
        configuration: Waveform.Configuration = Waveform.Configuration(damping: .init(percentage: 0.125, sides: .both)),
        renderer: WaveformRenderer = LinearWaveformRenderer(),
        minimumZoom: CGFloat = 1,
        maximumZoom: CGFloat = 8,
        priority: TaskPriority = .userInitiated
    ) where Content == AnyView {
        self.init(
            audioURL: audioURL,
            configuration: configuration,
            renderer: renderer,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom,
            priority: priority
        ) { shape in
            AnyView(DefaultShapeStyler().style(shape: shape, with: configuration))
        }
    }
}
