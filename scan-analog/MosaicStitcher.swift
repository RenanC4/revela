//
//  MosaicStitcher.swift
//  scan-analog
//
//  Registers four overlapping ProRAW tiles on small proxies, then assembles the
//  linear negative (orange mask intact) before the density inversion runs on it.
//
//  Memory: registration uses ≤1024 px proxies. Full-resolution assembly decodes one
//  48 MP tile at a time and adds it into a single half-float canvas with
//  CIRenderDestination + CIBlendKernel.componentAdd, so only one tile is ever decoded.
//

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import os
import simd
import Vision

nonisolated private let stitchLog = Logger(subsystem: "scan-analog", category: "stitch")

extension NegativeProcessor {
    typealias GrayProxy = MosaicRegistration.GrayProxy

    struct TileProxy: @unchecked Sendable {
        let image: CGImage
        /// Detail at the tile's inner edges relative to its centre (1 = equally sharp).
        let edgeSharpness: Float
    }

    // MARK: Proxies

    /// Small display-referred copy for the onion skin, plus an edge-softness check.
    func tileProxy(url: URL, angle: CGFloat) throws -> TileProxy {
        guard let image = linearImage(at: url, maxEdge: 900, angle: angle),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: srgb) else {
            throw ProcessorError.unreadableRAW
        }
        let gray = try grayProxy(url: url, angle: angle, light: nil, longest: 480)
        return TileProxy(image: cg, edgeSharpness: MosaicRegistration.edgeSharpness(gray))
    }

    /// Density of the linear negative on a small proxy: even detail across the orange mask.
    private func grayProxy(url: URL, angle: CGFloat, light: URL?, longest: CGFloat) throws -> GrayProxy {
        guard var image = linearImage(at: url, maxEdge: longest, angle: angle) else {
            throw ProcessorError.unreadableRAW
        }
        if let light, let flat = linearImage(at: light, maxEdge: longest, angle: angle) {
            image = divide(image, by: flat)
        }
        let bitmap = linearBitmap(of: image, in: image.extent, longest: longest)
        guard bitmap.width > 16, bitmap.height > 16 else { throw ProcessorError.unreadableRAW }
        let values = bitmap.pixels.map { -log10(max(0.2627 * $0.r + 0.6780 * $0.g + 0.0593 * $0.b, 1e-4)) }
        let low = percentileValue(values, 0.01)
        let high = max(percentileValue(values, 0.99), low + 1e-3)
        var bytes = [UInt8](repeating: 0, count: values.count)
        for index in values.indices {
            bytes[index] = UInt8(min(max((values[index] - low) / (high - low), 0), 1) * 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(
                  width: bitmap.width, height: bitmap.height,
                  bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bitmap.width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { throw ProcessorError.unreadableRAW }
        return GrayProxy(values: values, width: bitmap.width, height: bitmap.height, image: cg)
    }

    // MARK: Registration

    /// Registers the four tiles and returns their placements on a common canvas.
    func registerMosaic(directory: URL, tiles: [MosaicTile], flatFieldURL: URL?) throws -> MosaicRecord {
        var proxies: [MosaicCorner: GrayProxy] = [:]
        var fullSize: CGSize?
        for tile in tiles {
            let url = directory.appendingPathComponent(tile.fileName)
            guard let full = linearImage(at: url, maxEdge: nil, angle: CGFloat(tile.angle)) else {
                throw MosaicError.unreadableTile(tile.corner)
            }
            if tile.corner == .topLeading { fullSize = full.extent.size }
            proxies[tile.corner] = try grayProxy(url: url, angle: CGFloat(tile.angle), light: flatFieldURL, longest: 1024)
        }
        guard let fullSize else { throw MosaicError.incomplete }
        let layout = try MosaicRegistration.layout(proxies: proxies, fullSize: fullSize)
        return MosaicRecord(
            id: UUID(),
            directory: directory,
            tiles: tiles,
            placements: layout.placements,
            tileWidth: Double(fullSize.width),
            tileHeight: Double(fullSize.height),
            canvasWidth: Double(layout.canvas.width),
            canvasHeight: Double(layout.canvas.height),
            method: layout.method
        )
    }

    // MARK: Assembly

    /// The stitched linear negative. `maxEdge` builds a small lazy composite for previews;
    /// nil assembles full resolution one tile at a time into a half-float canvas.
    func assembleMosaic(_ record: MosaicRecord, flatFieldURL: URL?, maxEdge: CGFloat?) throws -> CIImage {
        guard let kernel = PositiveKernels.compiled?.mosaicContribution else { throw ProcessorError.renderFailed }
        let canvasLong = max(record.canvasWidth, record.canvasHeight)
        let scale = maxEdge.map { min(1, Double($0) / canvasLong) } ?? 1
        let canvas = CGRect(x: 0, y: 0, width: (record.canvasWidth * scale).rounded(.up), height: (record.canvasHeight * scale).rounded(.up))
        let tileSize = CGSize(width: record.tileWidth, height: record.tileHeight)
        let canvasScale = CGAffineTransform(scaleX: scale, y: scale)
        let feather = 0.1 * min(record.tileWidth, record.tileHeight)

        // Canvas → tile-normalised maps for the weight of every tile.
        let ordered = MosaicCorner.allCases.compactMap { corner in record.placements.first { $0.corner == corner } }
        guard ordered.count == 4 else { throw ProcessorError.renderFailed }
        var weightArguments: [Any] = []
        for placement in ordered {
            let toCanvas = placement.transform.concatenating(canvasScale)
            let normalised = toCanvas.inverted()
                .concatenating(CGAffineTransform(scaleX: 1 / tileSize.width, y: 1 / tileSize.height))
            weightArguments.append(CIVector(x: normalised.a, y: normalised.b, z: normalised.c, w: normalised.d))
            weightArguments.append(CIVector(x: normalised.tx, y: normalised.ty, z: feather / tileSize.width, w: feather / tileSize.height))
        }

        func contribution(_ index: Int) throws -> (image: CIImage, rect: CGRect) {
            let placement = ordered[index]
            guard let tile = record.tiles.first(where: { $0.corner == placement.corner }) else {
                throw MosaicError.unreadableTile(placement.corner)
            }
            let decodeEdge = scale < 1 ? CGFloat(max(record.tileWidth, record.tileHeight) * scale) * 1.15 : nil
            guard var image = linearImage(at: record.url(for: tile), maxEdge: decodeEdge, angle: CGFloat(tile.angle)) else {
                throw MosaicError.unreadableTile(placement.corner)
            }
            if let flatFieldURL, let light = linearImage(at: flatFieldURL, maxEdge: decodeEdge, angle: CGFloat(tile.angle)) {
                image = divide(image, by: light)
            }
            // Decoded pixels → full-resolution tile pixels → canvas at this scale.
            let decoded = image.extent
            let toFull = CGAffineTransform(translationX: -decoded.minX, y: -decoded.minY)
                .concatenating(CGAffineTransform(scaleX: tileSize.width / decoded.width, y: tileSize.height / decoded.height))
            let transform = toFull.concatenating(placement.transform).concatenating(canvasScale)
            let placed = image.transformed(by: transform, highQualityDownsample: scale < 1)
            let rect = placed.extent.intersection(canvas).integral
            guard let weighted = kernel.apply(
                extent: rect,
                roiCallback: { _, r in r },
                arguments: [placed, Float(index)] + weightArguments
            ) else { throw ProcessorError.renderFailed }
            return (weighted, rect)
        }

        if scale < 1 {
            var sum: CIImage?
            for index in 0..<4 {
                let piece = try contribution(index).image
                sum = sum.map { CIBlendKernel.componentAdd.apply(foreground: piece, background: $0) ?? $0 } ?? piece
            }
            guard let sum else { throw ProcessorError.renderFailed }
            return sum.cropped(to: canvas).unpremultiplyingAlpha().settingAlphaOne(in: canvas)
        }

        // Full resolution: one decoded tile at a time, added into the same half-float buffer.
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(canvas.width), Int(canvas.height),
            kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            stitchLog.error("canvas buffer \(Int(canvas.width))x\(Int(canvas.height)) failed \(status)")
            throw ProcessorError.renderFailed
        }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = linear
        destination.alphaMode = .premultiplied
        destination.isClamped = false
        try context.startTask(toClear: destination).waitUntilCompleted()
        destination.blendKernel = .componentAdd
        for index in 0..<4 {
            try autoreleasepool {
                let piece = try contribution(index)
                try context.startTask(toRender: piece.image, from: piece.rect, to: destination, at: piece.rect.origin)
                    .waitUntilCompleted()
            }
        }
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: linear])
            .unpremultiplyingAlpha()
            .settingAlphaOne(in: canvas)
    }
}
