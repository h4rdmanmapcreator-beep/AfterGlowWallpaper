import AppKit
import MetalKit

final class Renderer: NSObject, MTKViewDelegate {
    static var device: MTLDevice!
    static var queue: MTLCommandQueue!
    static var pipeline: MTLRenderPipelineState!

    /// Shaders are compiled from source at launch, so no Xcode / Metal toolchain is needed to build.
    static func setUp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "Afterglow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Metal device"])
        }
        guard let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal") else {
            throw NSError(domain: "Afterglow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Shaders.metal missing from bundle"])
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) { options.mathMode = .fast }
        let library = try device.makeLibrary(source: source, options: options)

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vmain")
        desc.fragmentFunction = library.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        queue = device.makeCommandQueue()
        Self.device = device
    }

    private let engine = Engine.shared

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = Self.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Paused = pure black (all OLED pixels off), never a frozen frame.
        if !Settings.shared.paused {
            engine.tick()
            var u = engine.uniforms
            u.resolution = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            encoder.setRenderPipelineState(Self.pipeline)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            engine.shaderData.withUnsafeBytes {
                encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

final class WallpaperWindow: NSWindow {
    let renderer = Renderer()
    let metalView: MTKView
    let screenID: CGDirectDisplayID

    init(screen: NSScreen) {
        screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        metalView = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: Renderer.device)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)

        // Sits where the desktop picture is: under desktop icons and every app window.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false

        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.framebufferOnly = true
        metalView.delegate = renderer
        metalView.autoresizingMask = [.width, .height]
        contentView = metalView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
