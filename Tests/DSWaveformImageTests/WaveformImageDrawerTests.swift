import AVFoundation
import CoreGraphics
import XCTest
@testable import DSWaveformImage

#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class WaveformImageDrawerTests: XCTestCase {

    // MARK: - Stereo async path

    /// Regression test for the stereo async path: `waveformImage(fromAudioAt:)` used to throw
    /// `GenerationError.generic` whenever a stereo renderer was passed in. The analyzer returned
    /// `2 * sampleCount` samples (the documented `[allLeft..., allRight...]` layout) but the static
    /// helper's count guard expected `sampleCount`, so the image generation failed before any
    /// rendering happened.
    func testAsyncWaveformImageRendersWithStereoRenderer() async throws {
        let url = try makeStereoAudioFile(durationSeconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Waveform.Configuration(
            size: CGSize(width: 200, height: 80),
            style: .filled(.red),
            scale: 1
        )
        let image = try await WaveformImageDrawer().waveformImage(
            fromAudioAt: url,
            with: config,
            renderer: LinearWaveformRenderer.stereo
        )
        XCTAssertEqual(image.size, config.size)
    }

    // MARK: - Static helper count tolerance

    /// The sync `waveformImage(from:)` helper accepts the stereo `[allLeft..., allRight...]` layout
    /// when paired with a stereo renderer. Without this, the async path's call into this helper
    /// rejects valid stereo input.
    func testStaticWaveformImageAcceptsDoubledStereoSamples() {
        let config = Waveform.Configuration(
            size: CGSize(width: 100, height: 40),
            style: .filled(.red),
            scale: 1
        )
        let perChannel = Int(config.size.width * config.scale)
        let samples = [Float](repeating: 0.5, count: perChannel * 2)
        let image = WaveformImageDrawer().waveformImage(
            from: samples,
            with: config,
            renderer: LinearWaveformRenderer.stereo
        )
        XCTAssertNotNil(image, "stereo renderer must accept 2× sample count")
    }

    /// Mono renderers continue to reject mismatched sample counts. Specifically a stereo-sized
    /// array handed to a mono renderer is still wrong and should fail loudly rather than half-render.
    func testStaticWaveformImageRejectsStereoSamplesWithMonoRenderer() {
        let config = Waveform.Configuration(
            size: CGSize(width: 100, height: 40),
            style: .filled(.red),
            scale: 1
        )
        let perChannel = Int(config.size.width * config.scale)
        let samples = [Float](repeating: 0.5, count: perChannel * 2)
        let image = WaveformImageDrawer().waveformImage(
            from: samples,
            with: config,
            renderer: LinearWaveformRenderer()
        )
        XCTAssertNil(image, "mono renderer must reject doubled sample count")
    }

    // MARK: - Sides.up vs Sides.down

    /// `LinearWaveformRenderer(sides: .up)` and `LinearWaveformRenderer(sides: .down)` must produce
    /// distinct images: `.up` fills the upper half of the canvas (relative to the renderer's
    /// coordinate system), `.down` fills the lower half. Previously the non-striped paths happened
    /// to fill nearly identical regions because both polygons closed back along the centerline in a
    /// way that depended on path start position rather than envelope direction.
    func testSidesUpAndDownProduceDistinctImages() async throws {
        // Mirror the generator's setup: damping enabled, scale=2, example-style real audio. The
        // bug report was filed from this exact configuration.
        let url = try makeStereoAudioFile(durationSeconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Waveform.Configuration(
            size: CGSize(width: 800, height: 120),
            style: .filled(.red),
            damping: .init(percentage: 0.125, sides: .both),
            scale: 2
        )
        let upImage = try await WaveformImageDrawer().waveformImage(
            fromAudioAt: url,
            with: config,
            renderer: LinearWaveformRenderer(sides: .up)
        )
        let downImage = try await WaveformImageDrawer().waveformImage(
            fromAudioAt: url,
            with: config,
            renderer: LinearWaveformRenderer(sides: .down)
        )

        let upHalves = drawnHalfRatios(of: upImage)
        let downHalves = drawnHalfRatios(of: downImage)

        // `.up` must fill predominantly one half; `.down` the other. They cannot both be the same
        // half (regression guard for #2 in the 15.0 bug triage — turned out the static path already
        // renders them distinctly).
        XCTAssertNotEqual(upHalves.dominantHalf, downHalves.dominantHalf,
                          ".up and .down must occupy opposite halves of the canvas (up=\(upHalves), down=\(downHalves))")
    }

    // MARK: - Helpers

    /// Counts opaque pixels in the top and bottom halves of an image. Used to detect cases where
    /// `.up`/`.down` render to the same half.
    private struct HalfRatios: CustomStringConvertible {
        let topOpaque: Int
        let bottomOpaque: Int
        var description: String { "top=\(topOpaque) bottom=\(bottomOpaque)" }
        var dominantHalf: DominantHalf {
            if topOpaque > bottomOpaque * 4 { return .top }
            if bottomOpaque > topOpaque * 4 { return .bottom }
            return .neither
        }
        enum DominantHalf { case top, bottom, neither }
    }

    private func drawnHalfRatios(of image: DSImage) -> HalfRatios {
        let cgImage = cgImage(from: image)
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var top = 0
        var bottom = 0
        let halfRow = height / 2
        for y in 0..<height {
            for x in 0..<width {
                let alpha = bytes[y * bytesPerRow + x * 4 + 3]
                if alpha > 16 {
                    if y < halfRow { top += 1 } else { bottom += 1 }
                }
            }
        }
        return HalfRatios(topOpaque: top, bottomOpaque: bottom)
    }

    private func cgImage(from image: DSImage) -> CGImage {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        #else
        return image.cgImage!
        #endif
    }
}
