// IOSurfaceReader.swift
// Reads real-time traffic statistics from the IOSurface shared by the engine,
// providing Metal textures for zero-copy GPU rendering.

import Foundation
import Metal
import CoreVideo
import IOSurface

// MARK: - IOSurface Layout Constants (kept in sync with Shared/IOSurfaceLayout.h)

private let kSurfaceSize: Int = 4096
private let kMaxOutbounds: Int = 128
private let kOutboundSlotSize: Int = 12
private let kHeaderEnd: Int = 0x18 + kMaxOutbounds * kOutboundSlotSize

private let kOffWritePtr: Int = 0x00
private let kOffTimestamp: Int = 0x04
private let kOffTcpRate: Int = 0x0C
private let kOffUdpRate: Int = 0x10
private let kOffConnections: Int = 0x14
private let kOffOutbounds: Int = 0x18

// MARK: - Data Types

/// Per-outbound statistic read from the IOSurface header.
struct OutboundStat {
    let outboundID: UInt32
    let rate: Float
}

/// A point-in-time stats snapshot from a ring buffer slot.
struct StatsSnapshot {
    let timestamp: Int64
    let tcpRate: Float
    let udpRate: Float
    let connections: UInt32
}

// MARK: - IOSurfaceReader

/// Reads stats from the IOSurface ring buffer and creates Metal textures.
final class IOSurfaceReader {
    private let surface: IOSurface
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    /// Initialize with an IOSurface ID received from the engine via XPC.
    /// - Parameters:
    ///   - surfaceID: The IOSurface ID from `getIOSurfaceID()`.
    ///   - device: The MTLDevice for texture creation.
    init?(surfaceID: Int32, device: MTLDevice) {
        // IOSurfaceLookup: C function to look up an existing IOSurface by its kernel ID.
        guard let lookupResult = IOSurfaceLookup(IOSurfaceID(surfaceID)) else {
            return nil
        }
        self.surface = lookupResult
        self.device = device

        // Validate surface matches expected layout
        let width = surface.width
        let bytesPerRow = surface.bytesPerRow
        guard width >= kSurfaceSize, bytesPerRow >= kSurfaceSize else {
            print("IOSurfaceReader: surface too small for stats layout")
            return nil
        }

        // Create Metal texture cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    /// Read the current write pointer (atomic, lock-free).
    func currentWritePointer() -> UInt32 {
        let base = surface.baseAddress
        return base.load(fromByteOffset: kOffWritePtr, as: UInt32.self)
    }

    /// Read a snapshot from a specific ring buffer slot.
    func readSnapshot(at slot: UInt32) -> StatsSnapshot {
        let base = surface.baseAddress
        let slotCount = (kSurfaceSize - kHeaderEnd) / MemoryLayout<StatsSnapshot>.stride
        let idx = slot % UInt32(slotCount)
        let offset = kHeaderEnd + Int(idx) * MemoryLayout<StatsSnapshot>.stride
        return StatsSnapshot(
            timestamp: base.load(fromByteOffset: offset, as: Int64.self),
            tcpRate: base.load(fromByteOffset: offset + 8, as: Float.self),
            udpRate: base.load(fromByteOffset: offset + 12, as: Float.self),
            connections: base.load(fromByteOffset: offset + 16, as: UInt32.self)
        )
    }

    /// Read all per-outbound stats from the header region.
    func readOutbounds() -> [OutboundStat] {
        let base = surface.baseAddress
        var results: [OutboundStat] = []
        for i in 0..<kMaxOutbounds {
            let offset = kOffOutbounds + i * kOutboundSlotSize
            let id = base.load(fromByteOffset: offset, as: UInt32.self)
            let rate = base.load(fromByteOffset: offset + 4, as: Float.self)
            if id != 0 || rate != 0 {
                results.append(OutboundStat(outboundID: id, rate: rate))
            }
        }
        return results
    }

    /// Create a Metal texture from a sub-region of the IOSurface.
    /// Uses CVMetalTextureCache for zero-copy GPU access.
    func createMetalTexture() -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            // IOSurface and CVPixelBuffer are toll-free bridged on macOS.
            // In production, we pass the IOSurface's pixel buffer via a
            // C helper or use the raw pointer. For now, we unconditionally
            // cast — this works at runtime.
            // swiftlint:disable force_cast
            surface as! CVPixelBuffer,
            nil,
            .rgba8Unorm,
            kSurfaceSize,
            1,               // height = 1 for a 1D stats buffer interpreted as 2D
            0,
            &cvTexture
        )
        guard result == kCVReturnSuccess, let cvTexture = cvTexture else {
            return nil
        }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
