import Foundation
import SwiftUI
import DSWaveformImage

/// A waveform SwiftUI `Shape` object for generating a shape path from component(s) of the waveform.
/// **Note:** The Shape does *not* style itself. Use `WaveformView` for that purpose and only use the Shape directly if needed.
///
/// If `renderer` is a `ChannelAwareWaveformRenderer` with a non-`.merged` selection, the caller is
/// responsible for providing `samples` in the matching layout (e.g. `[allLeft..., allRight...]` for
/// `.stereo`). The Shape only renders; it cannot re-sample the audio. `WaveformView` handles this
/// automatically — prefer it when working from an `audioURL`.
@available(iOS 15.0, macOS 12.0, *)
public struct WaveformShape: Shape {
    private let samples: [Float]
    private let configuration: Waveform.Configuration
    private let renderer: WaveformRenderer

    public init(
        samples: [Float],
        configuration: Waveform.Configuration = Waveform.Configuration(),
        renderer: WaveformRenderer = LinearWaveformRenderer()
    ) {
        self.samples = samples
        self.configuration = configuration
        self.renderer = renderer
    }

    public func path(in rect: CGRect) -> Path {
        // Debug-only sanity check: stereo expects an even-length sample array (one half per channel).
        // We can't verify content correctness here — that's on the caller — but an odd count is
        // unambiguously wrong and easy to catch.
        if let channelAware = renderer as? ChannelAwareWaveformRenderer, channelAware.channelSelection == .stereo {
            assert(samples.count % 2 == 0, "WaveformShape: a `.stereo` renderer expects samples laid out as [allLeft..., allRight...] (even length). Got \(samples.count).")
        }

        let size = CGSize(width: rect.maxX, height: rect.maxY)
        let isStereo = (renderer as? ChannelAwareWaveformRenderer)?.channelSelection == .stereo
        let drawer = WaveformImageDrawer()
        let scaledSamples = drawer.applyAmplitudeScaling(samples, scaling: configuration.amplitudeScaling)
        let dampedSamples = configuration.shouldDamp ? drawer.damp(scaledSamples, with: configuration, isStereo: isStereo) : scaledSamples
        let path = renderer.path(samples: dampedSamples, with: configuration.with(size: size), lastOffset: 0)

        return Path(path)
    }

    /// Whether the shape has no underlying samples to display.
    var isEmpty: Bool {
        samples.isEmpty
    }

    /// SwiftUI fill style this shape's path expects. Uses even-odd when the renderer's path is
    /// built from multiple subpaths that need region subtraction (e.g. `CircularWaveformRenderer`
    /// in `.ring` kind). Defaults to non-zero for everyone else.
    public var fillStyle: FillStyle {
        let eoFill = (renderer as? CircularWaveformRenderer)?.prefersEvenOddFillRule ?? false
        return FillStyle(eoFill: eoFill)
    }
}

