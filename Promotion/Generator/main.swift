// Regenerates every README screenshot in `Promotion/readme/`. Run with:
//
//     swift run WaveformScreenshots
//
// All output PNGs use the same `example_stereo.m4a` source so visual comparisons across cards stay
// consistent. Cards are stacked vertically into composite PNGs per feature group so the README
// embeds one image per gallery section.

import AppKit
import Foundation
import DSWaveformImage

// MARK: - Setup

let audioURL: URL = {
    guard let url = Bundle.module.url(forResource: "example_stereo", withExtension: "m4a") else {
        FileHandle.standardError.write(Data("missing example_stereo.m4a in WaveformScreenshots bundle\n".utf8))
        exit(1)
    }
    return url
}()

let outputDir: URL = {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let dir = cwd.appendingPathComponent("Promotion").appendingPathComponent("readme")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

let drawer = WaveformImageDrawer()

/// Scale factor every screenshot is rendered at. 2x gives crisp images on retina displays without
/// blowing up file size the way 3x would.
let renderScale: CGFloat = 2

/// Default canvas size for a single linear waveform card. Wide and short — the typical "row in a
/// gallery" shape.
let cardSize = CGSize(width: 800, height: 120)

let standardDamping = Waveform.Damping(percentage: 0.125, sides: .both)

// MARK: - Configuration helpers

func config(
    style: Waveform.Style,
    damping: Waveform.Damping? = standardDamping,
    verticalScalingFactor: CGFloat = 1,
    amplitudeScaling: Waveform.AmplitudeScaling = .absolute,
    size: CGSize = cardSize
) -> Waveform.Configuration {
    Waveform.Configuration(
        size: size,
        style: style,
        damping: damping,
        scale: renderScale,
        verticalScalingFactor: verticalScalingFactor,
        amplitudeScaling: amplitudeScaling
    )
}

func render(
    style: Waveform.Style,
    renderer: WaveformRenderer = LinearWaveformRenderer(),
    damping: Waveform.Damping? = standardDamping,
    verticalScalingFactor: CGFloat = 1,
    amplitudeScaling: Waveform.AmplitudeScaling = .absolute,
    size: CGSize = cardSize
) async throws -> NSImage {
    // Workaround: `WaveformImageDrawer.waveformImage(fromAudioAt:)` is broken for stereo — it asks the
    // analyzer for `width * scale` samples and then the static path rejects the doubled stereo array
    // it gets back. Skip that path for stereo renderers and assemble the image from raw analyzer
    // output instead.
    let isStereo = (renderer as? ChannelAwareWaveformRenderer)?.channelSelection == .stereo
    if isStereo {
        return try await renderStereo(
            style: style,
            renderer: renderer,
            size: size,
            verticalScalingFactor: verticalScalingFactor,
            amplitudeScaling: amplitudeScaling
        )
    }
    return try await drawer.waveformImage(
        fromAudioAt: audioURL,
        with: config(
            style: style,
            damping: damping,
            verticalScalingFactor: verticalScalingFactor,
            amplitudeScaling: amplitudeScaling,
            size: size
        ),
        renderer: renderer
    )
}

/// Stereo bypass — the library's `waveformImage(fromAudioAt:)` path is broken for stereo (its
/// static count check rejects the doubled `[allLeft..., allRight...]` array the analyzer returns),
/// so we render via a raw CGContext using the renderer's lower-level `render(samples:on:…)` entry.
/// Asks the analyzer for `width * scale` samples per channel so each half drives a full-canvas
/// span; damping is skipped because the drawer's `damp(…)` helpers aren't public.
func renderStereo(
    style: Waveform.Style,
    renderer: WaveformRenderer,
    size: CGSize,
    verticalScalingFactor: CGFloat,
    amplitudeScaling: Waveform.AmplitudeScaling
) async throws -> NSImage {
    let cfg = Waveform.Configuration(
        size: size,
        style: style,
        damping: nil,
        scale: renderScale,
        verticalScalingFactor: verticalScalingFactor,
        amplitudeScaling: amplitudeScaling
    )
    let perChannelCount = Int(cfg.size.width * cfg.scale)
    let samples = try await WaveformAnalyzer().samples(
        fromAudioAt: audioURL,
        count: perChannelCount,
        channelSelection: .stereo
    )

    let pixelWidth = Int(cfg.size.width * cfg.scale)
    let pixelHeight = Int(cfg.size.height * cfg.scale)
    guard let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        struct StereoContextError: Error {}
        throw StereoContextError()
    }
    // CGContext's default y-up coordinate system mirrors what the renderer expects (the rest of
    // the library renders into NSGraphicsContext(flipped: false) contexts). Scale so renderer math
    // in points aligns with the bitmap's pixel grid.
    context.scaleBy(x: cfg.scale, y: cfg.scale)
    renderer.render(samples: samples, on: context, with: cfg, lastOffset: 0, position: .middle)

    guard let cgImage = context.makeImage() else {
        struct StereoImageError: Error {}
        throw StereoImageError()
    }
    return NSImage(cgImage: cgImage, size: cfg.size)
}

// MARK: - Composition + I/O

func save(_ image: NSImage, as name: String) throws {
    let path = outputDir.appendingPathComponent(name)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("png encode failed for \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: path)
    print("wrote", path.path)
}

/// Stack a set of cards vertically into a single transparent PNG. Each card keeps its own pixel
/// size; the composite is sized to the widest card and the sum of heights plus inter-card spacing.
func stackVertically(_ images: [NSImage], spacing: CGFloat = 16) -> NSImage {
    precondition(!images.isEmpty)
    let width = images.map { $0.size.width }.max() ?? 0
    let height = images.reduce(0) { $0 + $1.size.height } + spacing * CGFloat(images.count - 1)
    let pixelWidth = Int(width * renderScale)
    let pixelHeight = Int(height * renderScale)

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else { fatalError("could not allocate bitmap rep") }

    bitmap.size = CGSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    var y = height
    for image in images {
        y -= image.size.height
        image.draw(
            in: NSRect(x: (width - image.size.width) / 2, y: y, width: image.size.width, height: image.size.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        y -= spacing
    }

    let composite = NSImage(size: CGSize(width: width, height: height))
    composite.addRepresentation(bitmap)
    return composite
}

// MARK: - Cards

let renderColor = NSColor.systemIndigo
let renderColorAlt = NSColor.systemBlue

// 1. Linear renderers — default linear envelope + stereo, sharing one style so layout is the only
// variable. `Sides.up`/`Sides.down` are intentionally skipped here — they're a parameter of
// `LinearWaveformRenderer` documented in the README's text, not a separate renderer.
func renderersCard() async throws -> NSImage {
    let style: Waveform.Style = .gradient([renderColor, renderColorAlt])
    let linear = try await render(style: style)
    let stereo = try await render(style: style, renderer: LinearWaveformRenderer.stereo, size: CGSize(width: 800, height: 220))
    return stackVertically([linear, stereo], spacing: 20)
}

// 1b. Circular renderers — own card so they get room to breathe at a size you can actually read.
func circularRenderersCard() async throws -> NSImage {
    let style: Waveform.Style = .gradient([renderColor, renderColorAlt])
    let size = CGSize(width: 380, height: 380)
    let circle = try await render(style: style, renderer: CircularWaveformRenderer(kind: .circle), size: size)
    let ring = try await render(style: style, renderer: CircularWaveformRenderer(kind: .ring(0.5)), size: size)
    return stackHorizontally([circle, ring], spacing: 40)
}

func stackHorizontally(_ images: [NSImage], spacing: CGFloat = 16) -> NSImage {
    precondition(!images.isEmpty)
    let height = images.map { $0.size.height }.max() ?? 0
    let width = images.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(images.count - 1)
    let pixelWidth = Int(width * renderScale)
    let pixelHeight = Int(height * renderScale)

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else { fatalError("could not allocate bitmap rep") }

    bitmap.size = CGSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    var x: CGFloat = 0
    for image in images {
        image.draw(
            in: NSRect(x: x, y: (height - image.size.height) / 2, width: image.size.width, height: image.size.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        x += image.size.width + spacing
    }

    let composite = NSImage(size: CGSize(width: width, height: height))
    composite.addRepresentation(bitmap)
    return composite
}

// 2. Styles — one renderer, every shipping style.
func stylesCard() async throws -> NSImage {
    let primary: DSColor = .systemIndigo
    let secondary: DSColor = .systemPurple
    return stackVertically([
        try await render(style: .filled(primary)),
        try await render(style: .outlined(primary, 1.5)),
        try await render(style: .gradient([primary, secondary])),
        try await render(style: .gradientOutlined([primary, secondary], 1.5)),
        try await render(style: .striped(.init(color: primary, width: 3, spacing: 3))),
    ])
}

// 3. Spectral tint — per-column FFT-driven coloring.
func spectralCard() async throws -> NSImage {
    return stackVertically([
        try await render(style: .spectralTint(low: .systemBlue, high: .systemRed)),
        try await render(style: .spectralTint(low: .systemIndigo, high: .systemMint)),
    ])
}

// 4. Channel selection — merged / left / right (linear, mono).
func channelsCard() async throws -> NSImage {
    let merged = try await render(style: .filled(.systemGray))
    let left = try await render(
        style: .filled(.systemBlue),
        renderer: LinearWaveformRenderer(channelSelection: .specific(0))
    )
    let right = try await render(
        style: .filled(.systemRed),
        renderer: LinearWaveformRenderer(channelSelection: .specific(1))
    )
    return stackVertically([merged, left, right])
}

// 5. Stereo — full stereo two-channel image (its own card so the layout reads).
func stereoCard() async throws -> NSImage {
    try await render(
        style: .gradient([.systemBlue, .systemRed]),
        renderer: LinearWaveformRenderer.stereo,
        size: CGSize(width: 800, height: 220)
    )
}

// 6. Damping — off vs on, same style.
func dampingCard() async throws -> NSImage {
    let style: Waveform.Style = .filled(.systemIndigo)
    return stackVertically([
        try await render(style: style, damping: nil),
        try await render(style: style, damping: .init(percentage: 0.18, sides: .both)),
    ])
}

// 9. Hero — wide linear gradient banner. The most recognizable shape a waveform library produces,
// generous size + bold gradient so it carries the top of the README.
func heroCard() async throws -> NSImage {
    try await render(
        style: .gradient([.systemOrange, .systemRed, .systemPink, .systemPurple, .systemIndigo]),
        renderer: LinearWaveformRenderer(),
        damping: .init(percentage: 0.18, sides: .both),
        verticalScalingFactor: 0.95,
        size: CGSize(width: 1200, height: 320)
    )
}

// MARK: - Run everything

func attempt(_ name: String, _ body: () async throws -> NSImage) async {
    do {
        let image = try await body()
        try save(image, as: name)
    } catch {
        FileHandle.standardError.write(Data("FAILED \(name): \(error)\n".utf8))
    }
}

await attempt("hero.png", heroCard)
await attempt("renderers.png", renderersCard)
await attempt("renderers-circular.png", circularRenderersCard)
await attempt("styles.png", stylesCard)
await attempt("spectral.png", spectralCard)
await attempt("channels.png", channelsCard)
await attempt("stereo.png", stereoCard)
await attempt("damping.png", dampingCard)

print("done — wrote screenshots to", outputDir.path)
