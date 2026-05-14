import Foundation
import CoreGraphics

/**
 Draws a stereo waveform with the left channel in the top half and the right channel in the bottom half.

 Pair with `Waveform.ChannelSelection.stereo` when sampling — the analyzer lays the samples out as
 `[allLeft..., allRight...]`, which this renderer splits at the midpoint.
 */
public struct StereoWaveformRenderer: WaveformRenderer {
    private let baseRenderer: LinearWaveformRenderer

    public init() {
        self.baseRenderer = LinearWaveformRenderer()
    }

    public func path(samples: [Float], with configuration: Waveform.Configuration, lastOffset: Int, position: Waveform.Position = .middle) -> CGPath {
        let combinedPath = CGMutablePath()

        let halfCount = samples.count / 2
        guard halfCount > 0 else { return combinedPath }

        let leftSamples = Array(samples[0..<halfCount])
        let rightSamples = Array(samples[halfCount..<samples.count])

        // Render each channel into its own half-height canvas, centered. The half-height path's
        // coordinates already sit in 0..H/2, so the left half-path lands in the top half without
        // translation; the right one gets shifted down by H/2 to land in the bottom half.
        let halfHeight = configuration.size.height / 2
        let halfHeightConfiguration = configuration.with(size: CGSize(width: configuration.size.width, height: halfHeight))

        let leftPath = baseRenderer.path(samples: leftSamples, with: halfHeightConfiguration, lastOffset: lastOffset)
        combinedPath.addPath(leftPath)

        let rightPath = baseRenderer.path(samples: rightSamples, with: halfHeightConfiguration, lastOffset: lastOffset)
        var transform = CGAffineTransform(translationX: 0, y: halfHeight)
        if let translatedRightPath = rightPath.copy(using: &transform) {
            combinedPath.addPath(translatedRightPath)
        }

        return combinedPath
    }

    public func render(samples: [Float], on context: CGContext, with configuration: Waveform.Configuration, lastOffset: Int, position: Waveform.Position = .middle) {
        context.addPath(path(samples: samples, with: configuration, lastOffset: lastOffset, position: position))
        defaultStyle(context: context, with: configuration)
    }
}
