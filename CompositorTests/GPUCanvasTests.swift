import AppKit
import CoreImage
import Metal
import Testing
@testable import Compositor

/// The GPU canvas against the Core Graphics canvas, frame for frame.
@MainActor struct GPUCanvasTests {
    private func pattern(_ w: Int, _ h: Int, seed: Int, alpha: Bool = false) throws -> CGImage {
        let context = try BrushRaster.context(width: w, height: h, mask: false)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let a = alpha ? UInt8(min(255, (x + y) * 255 / max(1, w + h - 2) + 40)) : 255
            func c(_ v: Int) -> UInt8 { UInt8(Int(v & 255) * Int(a) / 255) }
            data[i] = c(x * 255 / w + seed * 40); data[i + 1] = c(y * 255 / h + seed * 25)
            data[i + 2] = c((x / 16 + y / 16) % 2 == 0 ? 200 : 60); data[i + 3] = a
        } }
        return context.makeImage()!
    }
    private func gradientMask(_ w: Int, _ h: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: w, height: h, mask: true)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w { data[y * context.bytesPerRow + x] = UInt8(x * 255 / max(1, w - 1)) } }
        return context.makeImage()!
    }

    /// A document using most of what the GPU canvas draws: masks, opacity, rotation, blend modes, a folder with a
    /// mask, a clipping stack, and Levels and Hue/Saturation layers.
    private func session(zoom: CGFloat) throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 500, height: 400), backingScale: 2, documentSize: nil)
        session.createDocument(width: 600, height: 500)
        func insert(_ image: CGImage, _ name: String) -> Int {
            session.insert(ImportedImage(image: image, thumbnail: image, name: name))
            return session.document!.layers.firstIndex { $0.id == session.activeLayerID }!
        }
        _ = insert(try pattern(600, 500, seed: 0), "Background")
        let multiply = insert(try pattern(300, 260, seed: 1), "Multiply")
        session.document!.layers[multiply].blendMode = .multiply
        session.document!.layers[multiply].transform.origin = CGPoint(x: 40, y: 30)
        let rotated = insert(try pattern(240, 200, seed: 2, alpha: true), "Rotated")
        session.document!.layers[rotated].transform.rotation = 20
        session.document!.layers[rotated].opacity = 0.7
        let masked = insert(try pattern(320, 240, seed: 3), "Masked")
        session.document!.layers[masked].transform.origin = CGPoint(x: 250, y: 220)
        session.document!.layers[masked].mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(320, 240)))
        let base = insert(try pattern(200, 200, seed: 4, alpha: true), "Base")
        session.document!.layers[base].transform.origin = CGPoint(x: 350, y: 40)
        let clipped = insert(try pattern(260, 120, seed: 5), "Clipped")
        session.document!.layers[clipped].transform.origin = CGPoint(x: 330, y: 100)
        session.document!.layers[clipped].maskSourceID = session.document!.layers[base].id
        session.document!.layers[clipped].blendMode = .screen
        let dodge = insert(try pattern(200, 160, seed: 6, alpha: true), "Dodge")
        session.document!.layers[dodge].blendMode = .colorDodge
        session.document!.layers[dodge].transform.origin = CGPoint(x: 60, y: 300)
        // A folder holding the dodge layer, with a mask of its own.
        let size = CGSize(width: 600, height: 500)
        var folder = ImageLayer(name: "Folder", blankSize: size)
        folder.isGroup = true
        folder.mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(600, 500)))
        session.document!.layers[dodge].parentID = folder.id
        session.document!.layers.insert(folder, at: dodge + 1)
        var levels = ImageLayer(name: "Levels", blankSize: size)
        levels.adjustment = LayerAdjustment(kind: .levels)
        levels.adjustment!.levels.ranges[0].gamma = 1.4
        levels.adjustment!.levels.ranges[0].black = 20
        session.document!.layers.append(levels)
        var hsv = ImageLayer(name: "Hue/Saturation", blankSize: size)
        hsv.adjustment = LayerAdjustment(kind: .hsv)
        hsv.adjustment!.hsvSettings = HueSaturationSettings(hue: 30, saturation: 40)
        hsv.opacity = 0.8
        hsv.mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(600, 500)))
        session.document!.layers.append(hsv)
        session.selectLayer(nil)
        session.zoom(to: zoom)
        return session
    }

    private struct Difference { let mean: Double; let over: Double }

    /// Both canvases drawn for `session`; the share of pixels more than 12 levels apart, and the mean difference.
    private func compare(_ session: EditorSession, name: String) throws -> Difference {
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let width = 1000, height = 800
        let cpu = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        cpu.translateBy(x: 0, y: CGFloat(height)); cpu.scaleBy(x: 2, y: -2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cpu, flipped: true)
        canvas.allowsGPU = false
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()

        let renderer = try #require(GPUCanvasRenderer.shared)
        let frame = try #require(canvas.gpuFrame(size: CGSize(width: width, height: height)))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let buffer = try #require(renderer.queue.makeCommandBuffer())
        renderer.context.render(frame, to: texture, commandBuffer: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                colorSpace: renderer.space)
        buffer.commit(); buffer.waitUntilCompleted()
        var gpu = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&gpu, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        let reference = cpu.data!.assumingMemoryBound(to: UInt8.self)
        var total = 0.0, over = 0
        for pixel in 0..<(width * height) {
            var largest = 0
            for channel in 0..<3 {
                let difference = abs(Int(reference[pixel * 4 + channel]) - Int(gpu[pixel * 4 + channel]))
                largest = max(largest, difference)
                total += Double(difference)
            }
            if largest > 12 { over += 1 }
        }
        // Side by side for looking at: Core Graphics on the left, the GPU on the right.
        let pair = try BrushRaster.context(width: width * 2, height: height, mask: false)
        let gpuData = Data(gpu)
        let gpuImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: gpuData as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        BrushRaster.draw(cpu.makeImage()!, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: pair)
        BrushRaster.draw(gpuImage, in: CGRect(x: width, y: 0, width: width, height: height), mask: false, context: pair)
        if let png = NSBitmapImageRep(cgImage: pair.makeImage()!).representation(using: .png, properties: [:]) {
            Attachment.record(png, named: "\(name).png")
        }
        return Difference(mean: total / Double(width * height * 3), over: Double(over) / Double(width * height))
    }

    @Test(arguments: [1.0, 2.0 / 3.0, 1.0 / 3.0, 2.0])
    func matchesCoreGraphicsCanvas(zoom: CGFloat) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let difference = try compare(try session(zoom: zoom), name: "zoom-\(Int(zoom * 100))")
        // Shrinking, the two sample a hard edge a little differently; the test pattern is all hard edges.
        #expect(difference.mean < 1.5 && difference.over < (zoom < 1 ? 0.03 : 0.01),
                "zoom \(zoom): mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// Selected pixels being dragged: the GPU draws them from the lifted pixels, the Core Graphics canvas from the
    /// rebuilt tiles.
    @Test(arguments: [false, true])
    func matchesWhileMovingPixels(duplicate: Bool) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 500, height: 400), backingScale: 2, documentSize: nil)
        session.createDocument(width: 600, height: 500)
        let image = try pattern(600, 500, seed: 2)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        session.applySelection(CGPath(ellipseIn: CGRect(x: 120, y: 100, width: 220, height: 160), transform: nil), mode: .replace, name: "Select")
        #expect(session.beginPixelMove(duplicate: duplicate))
        session.movePixels(by: CGSize(width: 90, height: 60))
        session.zoom(to: 1)
        let difference = try compare(session, name: duplicate ? "duplicating" : "moving")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// A photo on the canvas, with a mask on it when `masked`, ready to paint.
    private func paintable(masked: Bool = false) throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 500, height: 400), backingScale: 2, documentSize: nil)
        session.createDocument(width: 600, height: 500)
        let image = try pattern(420, 360, seed: 2)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        let index = session.document!.layers.firstIndex { $0.id == session.activeLayerID }!
        session.document!.layers[index].transform.origin = CGPoint(x: 90, y: 70)
        if masked { session.document!.layers[index].mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(420, 360))) }
        session.brushSettings.diameter = 60
        session.foregroundColor = PaletteColor(red: 0.9, green: 0.2, blue: 0.1)
        return session
    }

    private func stroke(_ session: EditorSession) {
        session.beginBrush(at: CGPoint(x: 60, y: 100))
        for x in stride(from: 70.0, through: 540, by: 10) { session.continueBrush(at: CGPoint(x: x, y: 100 + x / 3)) }
    }

    /// A brush stroke in progress, on a layer's pixels (with and without a mask on it) and on its mask.
    @Test(arguments: [(false, false), (true, false), (true, true)])
    func matchesWhilePainting(masked: Bool, paintingMask: Bool) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable(masked: masked)
        session.tool = .brush
        session.isMaskSelected = paintingMask
        session.maskPaintWhite = false
        stroke(session)
        #expect(session.brushStroke != nil)
        session.zoom(to: 1)
        let difference = try compare(session, name: "painting-\(masked)-\(paintingMask)")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// A gradient being dragged, linear and radial, the radial one inside a selection.
    @Test(arguments: [GradientShape.linear, .radial])
    func matchesWhileDraggingAGradient(shape: GradientShape) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable()
        session.tool = .gradient
        session.gradientSettings.shape = shape
        if shape == .radial {
            session.applySelection(CGPath(ellipseIn: CGRect(x: 100, y: 80, width: 300, height: 260), transform: nil), mode: .replace, name: "Select")
        }
        session.beginGradient(at: CGPoint(x: 150, y: 120))
        session.moveGradient(end: CGPoint(x: 420, y: 330))
        #expect(session.gradientEdit?.hasLine == true)
        session.zoom(to: 1)
        let difference = try compare(session, name: "gradient-\(shape)")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }

    /// A Smudge stroke in progress.
    @Test func matchesWhileSmudging() throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let session = try paintable(masked: true)
        session.tool = .blur
        session.blurMode = .smudge
        stroke(session)
        #expect(session.warpStroke != nil)
        session.zoom(to: 1)
        let difference = try compare(session, name: "smudge")
        #expect(difference.mean < 1.5 && difference.over < 0.01, "mean \(difference.mean), over 12 levels \(difference.over * 100)%")
    }
}
