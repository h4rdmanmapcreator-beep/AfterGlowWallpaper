import AppKit
import MetalKit

final class Renderer: NSObject, MTKViewDelegate {
    static var device: MTLDevice!
    static var queue: MTLCommandQueue!
    static var pipelines: [MTLRenderPipelineState] = []
    static var fadePipelines: [MTLRenderPipelineState] = []

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
        try makePipelines(device: device, library: library, pixelFormat: .bgra8Unorm)
        queue = device.makeCommandQueue()
        Self.device = device
    }

    /// One pipeline per style, specialised with the STYLE function constant, plus a blended twin used to
    /// cross-fade into the next style.
    static func makePipelines(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) throws {
        let vertex = library.makeFunction(name: "vmain")
        pipelines = []
        fadePipelines = []
        for style in Style.allCases {
            let constants = MTLFunctionConstantValues()
            var value = Int32(style.rawValue)
            constants.setConstantValue(&value, type: .int, index: 0)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex
            desc.fragmentFunction = try library.makeFunction(name: "fmain", constantValues: constants)
            desc.colorAttachments[0].pixelFormat = pixelFormat
            pipelines.append(try device.makeRenderPipelineState(descriptor: desc))

            let blend = desc.colorAttachments[0]!
            blend.isBlendingEnabled = true
            blend.sourceRGBBlendFactor = .blendAlpha   // the cross-fade amount, set per draw
            blend.destinationRGBBlendFactor = .oneMinusBlendAlpha
            blend.sourceAlphaBlendFactor = .one
            blend.destinationAlphaBlendFactor = .zero
            fadePipelines.append(try device.makeRenderPipelineState(descriptor: desc))
        }
    }

    /// Draws the current style, then the incoming one blended on top while a cross-fade is running.
    static func encode(_ encoder: MTLRenderCommandEncoder, uniforms: Uniforms, data: [Float]) {
        var u = uniforms
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        data.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setRenderPipelineState(pipelines[Int(u.mode)])
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if u.modeMix > 0 {
            encoder.setRenderPipelineState(fadePipelines[Int(u.mode2)])
            encoder.setBlendColor(red: 0, green: 0, blue: 0, alpha: u.modeMix)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
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
            Self.encode(encoder, uniforms: u, data: engine.shaderData)
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
