// Offscreen preview: renders every style (ambient + with fake music) to PNGs.
//   ./Tools/preview.sh [output-dir]      (THEME=<id> picks a colour theme, see Theme in Settings.swift)
import AppKit
import Metal

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let device = MTLCreateSystemDefaultDevice()!
let source = try! String(contentsOfFile: "Resources/Shaders.metal", encoding: .utf8)
let library = try! device.makeLibrary(source: source, options: nil)
try! Renderer.makePipelines(device: device, library: library, pixelFormat: .rgba8Unorm)
let queue = device.makeCommandQueue()!

let w = 1280, h = 720
let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
texDesc.usage = [.renderTarget, .shaderRead]
texDesc.storageMode = .shared
let texture = device.makeTexture(descriptor: texDesc)!

func render(mode: Int, music: Bool, name: String) {
    var u = Uniforms()
    u.time = 37
    u.flow = 21
    u.resolution = SIMD2(Float(w), Float(h))
    u.drift = SIMD2(0.01, -0.005)
    u.hue = 0.15
    u.brightness = 0.8 * (music ? 1 : 0.6)
    u.mode = Int32(mode)
    u.flags = ShaderFlag.blackHoleStars
    u.theme = Int32(ProcessInfo.processInfo.environment["THEME"] ?? "0") ?? 0
    if music {
        u.bass = 0.7; u.mid = 0.5; u.treble = 0.35; u.level = 0.75; u.beat = 0.6; u.activity = 1
        u.kick = 0.5
    }
    let bands = (0..<64).map { i -> Float in
        guard music else { return 0 }
        let x = Float(i) / 63
        return max(0, min(1, 0.9 - x * 0.6 + 0.25 * sin(x * 23)))
    }
    let peaks = bands.map { music ? min($0 + 0.08, 1) : 0 }
    let wave = (0..<256).map { j -> Float in
        guard music else { return 0 }
        let t = Float(j) / 255 * 2 * .pi
        return 0.6 * sin(t * 2) + 0.25 * sin(t * 9 + 1) + 0.1 * sin(t * 31)
    }
    // Ripples (age, amp, hold, pitch): a held bass hit, a short bass hit, a snappy treble hit.
    var ripples: [Float] = music ? [0.9, 1.2, 0.8, 0.1, 1.6, 0.9, 0.0, 0.15, 0.3, 0.8, 0.0, 0.85] : []
    ripples += Array(repeating: 0, count: Engine.rippleCount * 4 - ripples.count)
    let data = bands + peaks + wave + Engine.shared.orbitStars() + ripples

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
    Renderer.encode(enc, uniforms: u, data: data)
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    var black = 0
    for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 { black += 1 }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    memcpy(rep.bitmapData!, bytes, bytes.count)
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("\(name).png"))
    print("\(name): \(Int(Double(black) / Double(w * h) * 100))% pixels fully off")
}

for style in Style.allCases {
    render(mode: style.rawValue, music: false, name: "\(style.rawValue)-\(style.title)-ambient")
    render(mode: style.rawValue, music: true, name: "\(style.rawValue)-\(style.title)-music")
}
