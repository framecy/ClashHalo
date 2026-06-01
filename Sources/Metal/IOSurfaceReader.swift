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

    /// Most-recent `n` samples with offset as (down, up) bytes/sec, oldest→newest.
    func series(_ n: Int, offset: Int = 0) -> (down: [Float], up: [Float]) {
        mapIfNeeded()
        var down = [Float](repeating: 0, count: n)
        var up = [Float](repeating: 0, count: n)
        guard let b = base else { return (down, up) }
        let wp = Int(b.load(fromByteOffset: 0, as: UInt32.self))
        let slotCount = Int(b.load(fromByteOffset: 4, as: UInt32.self))
        guard slotCount > 0 else { return (down, up) }
        for i in 0..<n {
            let logical = wp - n + i - offset
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
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        context.coordinator.configure(view)

        // Setup gestures for panning history
        let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Renderer.handlePan(_:)))
        view.addGestureRecognizer(pan)

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Renderer.handleDoubleClick(_:)))
        click.numberOfClicksRequired = 2
        view.addGestureRecognizer(click)

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
        private let points = 240
        private var maxSeen: Float = 1

        // Gestures & history navigation state
        var scrollOffset = 0
        private var startScrollOffset = 0

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
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try? dev.makeRenderPipelineState(descriptor: desc)
        }

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                startScrollOffset = scrollOffset
            case .changed:
                // Swipe right (translation.x > 0) to navigate back in time (increase offset)
                let delta = Int(translation.x * 1.5)
                scrollOffset = max(0, min(1800, startScrollOffset + delta))
            default:
                break
            }
        }

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            scrollOffset = 0
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let dev = device, let queue, let pipeline,
                  let rpd = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

            let (down, up) = reader.series(points, offset: scrollOffset)
            let localMax = max(down.max() ?? 0, up.max() ?? 0, 1)
            maxSeen = max(localMax, maxSeen * 0.96)
            let scale = max(maxSeen, 1)

            enc.setRenderPipelineState(pipeline)

            // Prepare Upload coordinates
            var upFill = [SIMD2<Float>]()
            var upLine = [SIMD2<Float>]()
            upFill.reserveCapacity(points * 2)
            upLine.reserveCapacity(points)
            for i in 0..<points {
                let x = Float(i) / Float(points - 1)
                let y = min(1, up[i] / scale) * 0.88
                upFill.append(SIMD2<Float>(x, 0))
                upFill.append(SIMD2<Float>(x, y))
                upLine.append(SIMD2<Float>(x, y))
            }

            // Prepare Download coordinates
            var downFill = [SIMD2<Float>]()
            var downLine = [SIMD2<Float>]()
            downFill.reserveCapacity(points * 2)
            downLine.reserveCapacity(points)
            for i in 0..<points {
                let x = Float(i) / Float(points - 1)
                let y = min(1, down[i] / scale) * 0.88
                downFill.append(SIMD2<Float>(x, 0))
                downFill.append(SIMD2<Float>(x, y))
                downLine.append(SIMD2<Float>(x, y))
            }

            // Helper to build a temporary buffer and draw primitives
            func drawVerts(_ verts: [SIMD2<Float>], type: MTLPrimitiveType, color: NSColor, alpha: Float) {
                let byteLen = verts.count * MemoryLayout<SIMD2<Float>>.stride
                guard byteLen > 0 else { return }
                guard let tempBuf = dev.makeBuffer(bytes: verts, length: byteLen, options: .storageModeShared) else { return }
                enc.setVertexBuffer(tempBuf, offset: 0, index: 0)

                let c = color.usingColorSpace(.sRGB) ?? color
                var col = SIMD4<Float>(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), alpha)
                enc.setFragmentBytes(&col, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: type, vertexStart: 0, vertexCount: verts.count)
            }

            // Upload is Orange, Download is primary Accent color
            let upColor = NSColor.systemOrange
            let downColor = accent

            // Multi-pass draw order:
            // 1. Upload Fill
            drawVerts(upFill, type: .triangleStrip, color: upColor, alpha: 0.12)
            // 2. Download Fill
            drawVerts(downFill, type: .triangleStrip, color: downColor, alpha: 0.22)
            // 3. Upload line
            drawVerts(upLine, type: .lineStrip, color: upColor, alpha: 0.75)
            // 4. Download line
            drawVerts(downLine, type: .lineStrip, color: downColor, alpha: 0.90)

            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
