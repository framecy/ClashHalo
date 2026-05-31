// Metal traffic rendering (v0.5).
//
//   StatsReader      — mmaps the engine's shared stats file read-only and
//                      samples the lock-free ring buffer.
//   MetalTrafficView — an MTKView that renders the rolling download/upload
//                      series on the GPU at up to 120fps (ProMotion), with
//                      shaders compiled at runtime (no .metal build step).
//                      Pauses when off-screen for power saving.

import SwiftUI
import MetalKit
import simd

// MARK: - Shared stats reader (mmap)

final class StatsReader {
    static let path = "/tmp/clashpow-stats.bin"
    private var base: UnsafeMutableRawPointer?
    private var fd: Int32 = -1
    private var mappedSize = 0

    // layout (must match Engine/stats/pusher.go)
    private let headerSize = 16
    private let slotSize = 56
    private let offDownRate = 16   // within slot
    private let offUpRate = 8

    init() { mapIfNeeded() }
    deinit { unmap() }

    private func mapIfNeeded() {
        guard base == nil else { return }
        fd = open(Self.path, O_RDONLY)
        guard fd >= 0 else { return }
        var st = stat(); guard fstat(fd, &st) == 0, st.st_size > 0 else { close(fd); fd = -1; return }
        mappedSize = Int(st.st_size)
        let p = mmap(nil, mappedSize, PROT_READ, MAP_SHARED, fd, 0)
        if p == MAP_FAILED { close(fd); fd = -1; return }
        base = p
    }
    private func unmap() {
        if let b = base { munmap(b, mappedSize); base = nil }
        if fd >= 0 { close(fd); fd = -1 }
    }

    var available: Bool { mapIfNeeded(); return base != nil }

    /// Most-recent `n` samples as (down, up) bytes/sec, oldest→newest.
    func series(_ n: Int) -> (down: [Float], up: [Float]) {
        mapIfNeeded()
        guard let b = base else { return ([], []) }
        let wp = Int(b.load(fromByteOffset: 0, as: UInt32.self))
        let slotCount = Int(b.load(fromByteOffset: 4, as: UInt32.self))
        guard slotCount > 0 else { return ([], []) }
        var down = [Float](repeating: 0, count: n)
        var up = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let logical = wp - n + i
            if logical < 0 { continue }
            let idx = logical % slotCount
            let off = headerSize + idx * slotSize
            let d = b.load(fromByteOffset: off + offDownRate, as: Int64.self)
            let u = b.load(fromByteOffset: off + offUpRate, as: Int64.self)
            down[i] = Float(max(0, d))
            up[i] = Float(max(0, u))
        }
        return (down, up)
    }
}

// MARK: - Metal traffic view

struct MetalTrafficView: NSViewRepresentable {
    var accent: NSColor

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 120
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        context.coordinator.configure(view)
        // Power throttle: stop GPU work when the app is not active (≤20mW idle goal).
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak view] _ in
            view?.isPaused = true
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak view] _ in
            view?.isPaused = false
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.accent = accent
    }

    func makeCoordinator() -> Renderer { Renderer(accent: accent) }

    // MARK: Renderer

    final class Renderer: NSObject, MTKViewDelegate {
        var accent: NSColor
        private let reader = StatsReader()
        private var device: MTLDevice?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var vbuf: MTLBuffer?
        private let points = 240          // rolling window
        private var maxSeen: Float = 1

        init(accent: NSColor) { self.accent = accent }

        func configure(_ view: MTKView) {
            guard let dev = view.device else { return }
            device = dev
            queue = dev.makeCommandQueue()
            let src = """
            #include <metal_stdlib>
            using namespace metal;
            struct VIn { float2 pos [[attribute(0)]]; };
            vertex float4 v_main(const device float2* verts [[buffer(0)]], uint vid [[vertex_id]]) {
                float2 p = verts[vid];
                return float4(p.x * 2.0 - 1.0, p.y * 2.0 - 1.0, 0, 1);
            }
            fragment float4 f_main(constant float4& color [[buffer(0)]]) { return color; }
            """
            guard let lib = try? dev.makeLibrary(source: src, options: nil) else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "v_main")
            desc.fragmentFunction = lib.makeFunction(name: "f_main")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            // alpha blending for the translucent area fill
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try? dev.makeRenderPipelineState(descriptor: desc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let dev = device, let queue, let pipeline,
                  let rpd = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

            let (down, _) = reader.series(points)
            // adaptive max with decay so the chart auto-scales smoothly
            let localMax = max(down.max() ?? 0, 1)
            maxSeen = max(localMax, maxSeen * 0.96)
            let scale = max(maxSeen, 1)

            // Build a triangle strip: for each x, two verts (baseline, value).
            var verts = [SIMD2<Float>]()
            verts.reserveCapacity(points * 2)
            for i in 0..<points {
                let x = Float(i) / Float(points - 1)
                let y = min(1, down[i] / scale) * 0.92
                verts.append(SIMD2<Float>(x, 0))
                verts.append(SIMD2<Float>(x, y))
            }
            let byteLen = verts.count * MemoryLayout<SIMD2<Float>>.stride
            if vbuf == nil || vbuf!.length < byteLen {
                vbuf = dev.makeBuffer(length: max(byteLen, 64), options: .storageModeShared)
            }
            verts.withUnsafeBytes { vbuf!.contents().copyMemory(from: $0.baseAddress!, byteCount: byteLen) }

            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(vbuf, offset: 0, index: 0)

            let c = accent.usingColorSpace(.sRGB) ?? accent
            var fill = SIMD4<Float>(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 0.28)
            enc.setFragmentBytes(&fill, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: verts.count)

            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
