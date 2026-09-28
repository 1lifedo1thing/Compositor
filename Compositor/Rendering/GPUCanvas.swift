import AppKit
import CoreImage
import Metal
import QuartzCore

/// The canvas composited on the GPU. Core Graphics composites every layer on the CPU, about 5 ms for each full-size
/// layer on a Retina screen, on every frame of a drag, pan or zoom; here the layers stay on the GPU as textures and a
/// frame only places them again.
///
/// Everything is laid out in pixel coordinates with y pointing down, as the pixels sit in a texture: an image's top
/// row is its row 0, and the frame's row 0 is the top of the view. Blending happens in sRGB, not linear light, as it
/// does on the canvas and in Photoshop.
@MainActor final class GPUCanvasRenderer {
    static let shared: GPUCanvasRenderer? = GPUCanvasRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private struct Key: Hashable {
        let id: ObjectIdentifier
        let level: Int
    }
    private struct Entry {
        /// Held so the identifier can't be reused by another object while the texture is kept.
        let source: AnyObject
        let image: CIImage
        var used: Int
    }
    private var textures: [Key: Entry] = [:]
    private var frame = 0
    /// Textures not used for this many frames are let go.
    private let keepFrames = 90

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: space, .cacheIntermediates: false])
    }

    /// `image` as a texture, `level` halvings smaller (sharp reductions for zooming out, as `DownsampleCache` makes on
    /// the CPU). A mask comes back with its values in the red channel.
    func image(_ image: CGImage, level: Int = 0, mask: Bool = false) -> CIImage? {
        let key = Key(id: ObjectIdentifier(image), level: level)
        if var entry = textures[key] {
            entry.used = frame
            textures[key] = entry
            return entry.image
        }
        let made: CIImage?
        if level == 0 {
            made = upload(image, mask: mask)
        } else if let full = self.image(image, level: 0, mask: mask) {
            made = reduce(full, width: image.width, height: image.height, level: level, mask: mask)
        } else { made = nil }
        guard let made else { return nil }
        textures[key] = Entry(source: image, image: made, used: frame)
        return made
    }

    /// A painted layer's tiles put together into one texture, redone only when the raster is replaced.
    func image(_ raster: RasterSnapshot, level: Int = 0) -> CIImage? {
        let key = Key(id: ObjectIdentifier(raster), level: level)
        if var entry = textures[key] {
            entry.used = frame
            textures[key] = entry
            return entry.image
        }
        let made: CIImage?
        if level == 0 {
            made = assemble(raster)
        } else if let full = image(raster, level: 0) {
            made = reduce(full, width: raster.width, height: raster.height, level: level, mask: raster.isMask)
        } else { made = nil }
        guard let made else { return nil }
        textures[key] = Entry(source: raster, image: made, used: frame)
        return made
    }

    /// Lets go of textures no frame has used for a while.
    func endFrame() {
        frame += 1
        let oldest = frame - keepFrames
        textures = textures.filter { $0.value.used >= oldest }
    }

    private func texture(width: Int, height: Int, mask: Bool) -> MTLTexture? {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: mask ? .r8Unorm : .rgba8Unorm,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private func wrap(_ texture: MTLTexture, mask: Bool) -> CIImage? {
        CIImage(mtlTexture: texture, options: [.colorSpace: mask ? NSNull() : space])
    }

    /// The image's own bytes, copied straight in: sRGB, premultiplied, top row first — or for a mask, its gray values.
    private func upload(_ image: CGImage, mask: Bool) -> CIImage? {
        guard let texture = texture(width: image.width, height: image.height, mask: mask),
              let pixels = try? (mask ? Self.grayCopy(image) : BrushRaster.copy(image)), let data = pixels.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: pixels.bytesPerRow)
        return wrap(texture, mask: mask)
    }

    private static func grayCopy(_ image: CGImage) throws -> CGContext {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return context
    }

    private func assemble(_ raster: RasterSnapshot) -> CIImage? {
        guard let texture = texture(width: raster.width, height: raster.height, mask: raster.isMask) else { return nil }
        // Transparent (or a mask's fill) everywhere first, then the base and every tile in its place: tiles replace
        // what's under them, transparent pixels included.
        let clear = raster.isMask ? CIImage(color: CIColor(red: raster.fill, green: raster.fill, blue: raster.fill)) : CIImage.clear
        guard let buffer = queue.makeCommandBuffer() else { return nil }
        context.render(clear, to: texture, commandBuffer: buffer,
                       bounds: CGRect(x: 0, y: 0, width: raster.width, height: raster.height), colorSpace: space)
        buffer.commit()
        buffer.waitUntilCompleted()
        func place(_ image: CGImage, at rect: CGRect) {
            let bounds = rect.integral.intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
            guard !bounds.isEmpty, image.width == Int(rect.width.rounded()), image.height == Int(rect.height.rounded()),
                  let pixels = try? (raster.isMask ? Self.grayCopy(image) : BrushRaster.copy(image)), let data = pixels.data else { return }
            let bytes = raster.isMask ? 1 : 4
            let offset = (Int(bounds.minY - rect.minY.rounded()) * pixels.bytesPerRow) + Int(bounds.minX - rect.minX.rounded()) * bytes
            texture.replace(region: MTLRegionMake2D(Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height)),
                            mipmapLevel: 0, withBytes: data + offset, bytesPerRow: pixels.bytesPerRow)
        }
        if let base = raster.base { place(base, at: raster.baseRect) }
        for patch in raster.patches { place(patch.image, at: patch.rect) }
        return wrap(texture, mask: raster.isMask)
    }

    /// A sharp copy `level` halvings smaller, rounded up like `DownsampleCache`'s, kept as a texture of its own.
    private func reduce(_ full: CIImage, width: Int, height: Int, level: Int, mask: Bool) -> CIImage? {
        let w = max(1, (width + (1 << level) - 1) >> level), h = max(1, (height + (1 << level) - 1) >> level)
        let sx = CGFloat(w) / CGFloat(width), sy = CGFloat(h) / CGFloat(height)
        let reduced = full.clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        guard let texture = texture(width: w, height: h, mask: mask), let buffer = queue.makeCommandBuffer() else { return nil }
        // A mask's values carry no color space; rendered in the working space, they're written as they are.
        context.render(reduced, to: texture, commandBuffer: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       colorSpace: space)
        buffer.commit()
        buffer.waitUntilCompleted()
        return wrap(texture, mask: mask)
    }

    /// Draws `image` into `layer`'s next drawable, in step with the Core Animation transaction it's drawn in, so it
    /// lands on the same frame as the overlays above it.
    func present(_ image: CIImage, in layer: CAMetalLayer) {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let size = layer.drawableSize
        // Core Image writes a texture that can be rendered to bottom row first (a plain one, top row first), so the
        // frame is turned over to land top row first.
        let upright = drawable.texture.usage.contains(.renderTarget)
            ? image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)) : image
        context.render(upright, to: drawable.texture, commandBuffer: buffer,
                       bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height), colorSpace: space)
        buffer.commit()
        buffer.waitUntilScheduled()
        drawable.present()
        endFrame()
    }
}

/// The GPU canvas's surface: a Metal layer under the canvas's overlays, shown while the GPU draws the canvas.
final class MetalCanvasView: NSView {
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = GPUCanvasRenderer.shared?.device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Core Image writes the frame with a compute pass.
        layer.framebufferOnly = false
        layer.presentsWithTransaction = true
        layer.isOpaque = true
        return layer
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    // Clicks go to the canvas behind it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Sizes the drawable to the view in screen pixels.
    func fit(scale: CGFloat) {
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }
}

/// How one layer's pixels land in the frame.
@MainActor struct GPUPlacement {
    /// Document pixels to frame pixels (y down).
    let mapping: CGAffineTransform
    /// Frame pixels per document pixel.
    let scale: CGFloat
    let renderer: GPUCanvasRenderer

    /// `source` (an image or a painted raster, `width` × `height` pixels) placed where `transform` puts it. Large
    /// reductions draw from a sharp smaller copy; pixel for pixel, or with Nearest sampling, pixels are copied.
    func place(width: Int, height: Int, transform: LayerTransform, mask: Bool = false,
               source: (Int) -> CIImage?) -> CIImage? {
        guard width > 0, height > 0 else { return nil }
        let factor = transform.size.width * scale / CGFloat(width)
        let level = transform.sampling == .nearest ? 0 : DownsampleCache.level(for: factor)
        guard let image = source(level) else { return nil }
        let reduced = image.extent.size
        let toFull = CGAffineTransform(scaleX: CGFloat(width) / reduced.width, y: CGFloat(height) / reduced.height)
        let placement = toFull
            .concatenating(BrushRaster.pixelToDocument(transform, width: width, height: height))
            .concatenating(mapping)
        let upright = transform.radians == 0 && abs(abs(factor) - 1) < 0.001 && level == 0
        let sampled = transform.sampling == .nearest || upright ? image.samplingNearest() : image
        return sampled.transformed(by: placement)
    }

    func place(_ image: CGImage, transform: LayerTransform, mask: Bool = false) -> CIImage? {
        place(width: image.width, height: image.height, transform: transform, mask: mask) {
            renderer.image(image, level: $0, mask: mask)
        }
    }

    func place(_ raster: RasterSnapshot, transform: LayerTransform) -> CIImage? {
        place(width: raster.width, height: raster.height, transform: transform, mask: raster.isMask) {
            renderer.image(raster, level: $0)
        }
    }
}

nonisolated enum GPUBlend {
    /// `top` composited over `bottom` in `mode`.
    static func blend(_ top: CIImage, over bottom: CIImage, mode: LayerBlendMode) -> CIImage {
        guard let name = filterName(mode) else { return top.composited(over: bottom) }
        return top.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: bottom])
    }

    static func filterName(_ mode: LayerBlendMode) -> String? {
        if let name = mode.coreImageFilter { return name }
        switch mode {
        case .normal: return nil
        case .darken: return "CIDarkenBlendMode"
        case .multiply: return "CIMultiplyBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .hardLight: return "CIHardLightBlendMode"
        case .difference: return "CIDifferenceBlendMode"
        case .exclusion: return "CIExclusionBlendMode"
        case .hue: return "CIHueBlendMode"
        case .saturation: return "CISaturationBlendMode"
        case .color: return "CIColorBlendMode"
        case .luminosity: return "CILuminosityBlendMode"
        default: return nil
        }
    }

    /// `image` shown only where `mask` (values in red) is on, and nothing elsewhere — past the mask's edges too, as a
    /// Core Graphics clip to a mask does.
    static func masked(_ image: CIImage, by mask: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                 kCIInputMaskImageKey: mask])
    }

    /// `image` at `opacity`.
    static func faded(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
    }
}

nonisolated enum GPUAdjustment {
    /// The adjustments the GPU canvas runs itself; a layer with any other falls back to the Core Graphics canvas.
    static func supports(_ adjustment: LayerAdjustment) -> Bool {
        switch adjustment.kind {
        case .levels, .hsv: true
        default: false
        }
    }

    static func apply(_ adjustment: LayerAdjustment, to image: CIImage) -> CIImage {
        switch adjustment.kind {
        case .levels:
            guard !adjustment.levels.isIdentity else { return image }
            // Enough entries that stepping between them stays well under one 8-bit level.
            let size = 1024, step = Double(size - 1)
            let curve = (0..<size).flatMap { index in
                [LevelsChannel.red, .green, .blue].map { Float(adjustment.levels.apply(Double(index) / step, channel: $0)) }
            }
            return image.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": curve.withUnsafeBufferPointer { Data(buffer: $0) },
                "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            ])
        case .hsv:
            return image.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": HueSaturationFilter.dimension,
                "inputCubeData": HueSaturationFilter.cube(adjustment.resolvedHSV),
            ])
        default:
            return image
        }
    }
}
