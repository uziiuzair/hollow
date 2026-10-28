import AppKit
import DiskApp
import Metal
import MetalKit
import QuartzCore
import os

/// Draws a `MapSnapshot` with Metal. The view redraws only on change; during a zoom it runs at the
/// display's refresh rate and only the uniforms change from frame to frame.
@MainActor
final class TreemapRenderer: NSObject, MTKViewDelegate {
    var onFirstFrame: (() -> Void)?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let blockPipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "map")

    private var scene: Scene?
    private var uniforms = TreemapUniforms()
    private var generation = 0
    private var pending: Task<Void, Never>?
    private var firstFrameDone = false

    private var zoom: ZoomAnimation?
    private var zoomStart: CFTimeInterval = 0
    private var zoomStats = ZoomStats()

    /// GPU resources for one snapshot. Built off main, then only read on main.
    private struct Scene: @unchecked Sendable {
        let blocks: MTLBuffer?
        let blockCount: Int
        let labels: MTLBuffer?
        let labelCount: Int
        let atlas: MTLTexture?
    }

    private struct ZoomStats {
        var frames = 0
        var late = 0
        var lastPresented: CFTimeInterval = 0
        var budget: CFTimeInterval = 1.5 / 60
    }

    private struct DeviceBox: @unchecked Sendable { let device: MTLDevice }

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: TreemapScene.shaderSource, options: nil),
              let block = Self.pipeline(device, library, vertex: "blockVertex", fragment: "blockFragment"),
              let label = Self.pipeline(device, library, vertex: "labelVertex", fragment: "labelFragment")
        else { return nil }
        self.device = device
        self.queue = queue
        self.blockPipeline = block
        self.labelPipeline = label
        super.init()
    }

    private static func pipeline(_ device: MTLDevice, _ library: MTLLibrary, vertex: String, fragment: String) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: vertex)
        d.fragmentFunction = library.makeFunction(name: fragment)
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        // Premultiplied alpha.
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add
        c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: d)
    }

    /// Builds instances and the label atlas off main, then swaps them in. A newer call discards an older one.
    func show(_ snapshot: MapSnapshot, dark: Bool, animation: ZoomAnimation?, in view: MTKView) {
        generation += 1
        let generation = self.generation
        pending?.cancel()
        uniforms.outlineRing = TreemapScene.outlineRing(dark: dark)
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let box = DeviceBox(device: device)
        pending = Task.detached(priority: .userInitiated) { [weak self] in
            guard let scene = Self.makeScene(snapshot, dark: dark, scale: scale, device: box.device),
                  !Task.isCancelled else { return }
            await self?.install(scene, generation: generation, animation: animation, in: view)
        }
    }

    /// Nil when the task was cancelled (a newer `show` superseded it). Checks between the expensive
    /// steps so a superseded build never rasterizes labels or allocates GPU memory it will throw away.
    nonisolated private static func makeScene(_ snapshot: MapSnapshot, dark: Bool, scale: CGFloat, device: MTLDevice) -> Scene? {
        var instances = TreemapScene.instances(snapshot: snapshot, dark: dark)
        guard !Task.isCancelled else { return nil }
        let darkText = TreemapScene.darkLabels(instances: instances, layout: snapshot.layout, dark: dark)
        let atlas = LabelAtlas.build(snapshot: snapshot, scale: scale, darkText: darkText)
        guard !Task.isCancelled else { return nil }
        var quads = atlas.quads
        let blocks = instances.isEmpty ? nil : device.makeBuffer(
            bytes: &instances, length: instances.count * MemoryLayout<BlockInstance>.stride, options: .storageModeShared)
        let labels = quads.isEmpty ? nil : device.makeBuffer(
            bytes: &quads, length: quads.count * MemoryLayout<LabelQuad>.stride, options: .storageModeShared)
        return Scene(blocks: blocks, blockCount: blocks == nil ? 0 : instances.count,
                     labels: labels, labelCount: labels == nil ? 0 : quads.count,
                     atlas: atlas.image.flatMap { texture($0, device: device) })
    }

    /// Uploads an atlas made by `LabelAtlas` (premultiplied BGRA, sRGB) as is.
    nonisolated private static func texture(_ image: CGImage, device: MTLDevice) -> MTLTexture? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: image.bytesPerRow)
        return texture
    }

    private func install(_ scene: Scene, generation: Int, animation: ZoomAnimation?, in view: MTKView) {
        guard generation == self.generation else { return }
        self.scene = scene
        pending = nil
        if let animation {
            startZoom(animation, in: view)
        } else {
            if zoom != nil { endZoom(in: view) }
            view.needsDisplay = true
        }
    }

    /// Changes uniforms only.
    func setHighlight(hoveredTop: Int?, outlinedTop: Int?, in view: MTKView) {
        let hovered = Int32(hoveredTop ?? -1), outlined = Int32(outlinedTop ?? -1)
        guard hovered != uniforms.hoveredTop || outlined != uniforms.outlinedTop else { return }
        uniforms.hoveredTop = hovered
        uniforms.outlinedTop = outlined
        if zoom == nil { view.needsDisplay = true }
    }

    // MARK: Zoom

    private func startZoom(_ animation: ZoomAnimation, in view: MTKView) {
        let fps = view.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        zoom = animation
        zoomStart = CACurrentMediaTime()
        zoomStats = ZoomStats(budget: 1.5 / Double(max(fps, 1)))
        apply(animation.transform(progress: 0))
        uniforms.labelAlpha = 0
        view.preferredFramesPerSecond = fps
        view.enableSetNeedsDisplay = false
        view.isPaused = false
    }

    private func endZoom(in view: MTKView) {
        zoom = nil
        uniforms.scale = .one
        uniforms.offset = .zero
        uniforms.labelAlpha = 1
        view.isPaused = true
        view.enableSetNeedsDisplay = true
    }

    private func apply(_ t: (scale: CGSize, offset: CGPoint)) {
        uniforms.scale = SIMD2(Float(t.scale.width), Float(t.scale.height))
        uniforms.offset = SIMD2(Float(t.offset.x), Float(t.offset.y))
    }

    private func presented(_ time: CFTimeInterval, final: Bool) {
        zoomStats.frames += 1
        if time == 0 || (zoomStats.lastPresented > 0 && time - zoomStats.lastPresented > zoomStats.budget) {
            zoomStats.late += 1
        }
        if time > 0 { zoomStats.lastPresented = time }
        if final {
            log.info("zoom: \(self.zoomStats.frames) frames, \(self.zoomStats.late) late")
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    private func encode(_ encoder: MTLRenderCommandEncoder, size: CGSize, pixelsPerPoint: Float) {
        uniforms.viewport = SIMD2(Float(size.width), Float(size.height))
        uniforms.pixelsPerPoint = pixelsPerPoint
        var u = uniforms
        guard let scene else { return }
        if let blocks = scene.blocks, scene.blockCount > 0 {
            encoder.setRenderPipelineState(blockPipeline)
            encoder.setVertexBuffer(blocks, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<TreemapUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: scene.blockCount)
        }
        if u.labelAlpha > 0, let labels = scene.labels, let atlas = scene.atlas, scene.labelCount > 0 {
            encoder.setRenderPipelineState(labelPipeline)
            encoder.setVertexBuffer(labels, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<TreemapUniforms>.stride, index: 0)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: scene.labelCount)
        }
    }

    #if DEBUG
    /// Draws the current scene into an offscreen image, for screenshots when the screen
    /// can't be captured (locked, asleep).
    func debugImage(in view: MTKView) -> CGImage? {
        let size = view.bounds.size
        let width = Int(view.drawableSize.width), height = Int(view.drawableSize.height)
        guard size.width > 0, width > 0, height > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d), let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = view.clearColor
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(encoder, size: size, pixelsPerPoint: Float(CGFloat(width) / size.width))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    #endif

    func draw(in view: MTKView) {
        var finalZoomFrame = false
        let zooming = zoom != nil
        if let zoom {
            let progress = min(1, (CACurrentMediaTime() - zoomStart) / ZoomAnimation.duration)
            apply(zoom.transform(progress: progress))
            if progress >= 1 {
                finalZoomFrame = true
                endZoom(in: view)
            }
        }

        let bounds = view.bounds.size
        guard bounds.width > 0, bounds.height > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        encode(encoder, size: bounds, pixelsPerPoint: Float(view.drawableSize.width / bounds.width))
        encoder.endEncoding()

        if zooming {
            let final = finalZoomFrame
            drawable.addPresentedHandler { [weak self] drawable in
                let time = drawable.presentedTime
                Task { @MainActor in self?.presented(time, final: final) }
            }
        }
        commands.present(drawable)
        commands.commit()

        if !firstFrameDone, (scene?.blockCount ?? 0) > 0 {
            firstFrameDone = true
            onFirstFrame?()
        }
    }
}
