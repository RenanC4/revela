//
//  NegativeProcessor.swift
//  scan-analog
//

import CoreImage
import Foundation
import ImageIO
import os
import UIKit

nonisolated struct PreparedPositive: Sendable {
    var profile: RollProfile
    var previewJPEG: Data
    var flatFieldApplied: Bool
    var cropDetected: Bool
    /// BaselineExposure stored in the DNG (EV) before the decoder overrides it. Nil for mosaics.
    var fileBaselineExposure: Float?
    /// This frame's own black/white densities (slides: linear white in `high`), for roll-wide levels.
    var frameLevels: DensityLevels?
}

nonisolated private let invertLog = Logger(subsystem: "scan-analog", category: "invert")

actor NegativeProcessor {
    static let shared = NegativeProcessor()

    let context: CIContext
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    private var mosaicCache: [(key: String, image: CIImage)] = []
    /// DNG BaselineExposure per file, read once. ProRAW may vary it from shot to shot.
    private var fileBaselines: [URL: Float] = [:]

    private init() {
        context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
        ])
    }

    /// Everything needed to print one frame. Built by the roll, consumed by the processor.
    struct FrameRequest: Sendable {
        var rawURL: URL
        var geometry: CaptureGeometry
        var filmType: FilmType
        var profile: RollProfile?
        var flatFieldURL: URL?
        var clearBase: CGPoint?
        var adjustments: Adjustments
        var quarterTurns: Int
        var mosaic: MosaicRecord?
        /// Puts this frame's ISO × shutter on the roll's reference exposure.
        var radiometricScale: Float
        /// Roll median black/white densities for `AutoLevels.roll`.
        var rollLevels: DensityLevels?
    }

    /// Preview positive (≤1200 px) and the measurements the roll keeps.
    func prepare(_ request: FrameRequest) throws -> PreparedPositive {
        let rendered = try render(request, maxEdge: 1200)
        guard let preview = jpegData(from: rendered.image) else {
            throw ProcessorError.renderFailed
        }
        return PreparedPositive(
            profile: rendered.profile,
            previewJPEG: preview,
            flatFieldApplied: rendered.source.flatFieldApplied,
            cropDetected: rendered.source.cropDetected,
            fileBaselineExposure: request.mosaic == nil ? fileBaselines[request.rawURL] : nil,
            frameLevels: rendered.source.levels
        )
    }

    /// Only the frame's black/white densities (and the roll profile, measured if missing). No print, no JPEG.
    func measureLevels(_ request: FrameRequest) throws -> (levels: DensityLevels?, profile: RollProfile) {
        let source = try frameSource(request, maxEdge: 1200)
        return (source.levels, source.profile)
    }

    /// Full-resolution 10-bit HEIF, with a 4500 px fallback if the encoder refuses the full size.
    func exportHEIF(_ request: FrameRequest) throws -> Data {
        for maxEdge in [nil, CGFloat(4500)] {
            let rendered = try render(request, maxEdge: maxEdge)
            if let data = heif10Data(from: rendered.image) {
                return data
            }
        }
        throw ProcessorError.renderFailed
    }

    /// Linear transmittance cropped to the frame, plus what was measured on the way.
    private struct FrameSource {
        var cropped: CIImage
        var profile: RollProfile
        var levels: DensityLevels?
        var flatFieldApplied: Bool
        var cropDetected: Bool
    }

    private struct Rendered {
        var image: CIImage
        var profile: RollProfile
        var source: FrameSource
    }

    /// Decode (or assemble the mosaic), flat-field, normalise exposure, measure the roll profile if needed,
    /// find the frame and measure its levels. Everything before the print.
    private func frameSource(_ request: FrameRequest, maxEdge: CGFloat?) throws -> FrameSource {
        var source: CIImage
        var flatFieldApplied = false
        let geometry: CaptureGeometry
        let filmType = request.filmType
        if let mosaic = request.mosaic {
            // Stitched in linear light, still a negative; flat field applied per tile.
            source = try mosaicSource(mosaic, flatFieldURL: request.flatFieldURL, maxEdge: maxEdge)
            flatFieldApplied = request.flatFieldURL != nil
            geometry = mosaic.geometry(for: source.extent.size)
        } else {
            geometry = request.geometry
            guard let decoded = linearImage(at: request.rawURL, maxEdge: maxEdge, angle: geometry.angle) else {
                throw ProcessorError.unreadableRAW
            }
            source = decoded
            if let flatFieldURL = request.flatFieldURL,
               let light = linearImage(at: flatFieldURL, maxEdge: maxEdge, angle: geometry.angle) {
                source = divide(source, by: light)
                flatFieldApplied = true
            }
        }
        // Frames shot at another ISO × shutter (e.g. after ETTR) go onto the roll's scale,
        // so one Dmin keeps holding. 1 when nothing changed.
        let scale = request.radiometricScale
        if abs(scale - 1) > 1e-4, scale.isFinite, scale > 0 {
            let s = CGFloat(scale)
            source = source.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
        }

        let profile = try profileFor(
            filmType: filmType,
            existing: request.profile,
            transmittance: source,
            geometry: geometry,
            clearBase: request.mosaic == nil ? request.clearBase : nil
        )
        let adjustments = request.adjustments
        var frame = GuideMapping.imageRect(
            viewRect: geometry.inner,
            viewSize: geometry.viewSize,
            extent: source.extent
        ).intersection(source.extent).integral
        var cropDetected = false
        if adjustments.autoCrop,
           let found = detectFrame(in: source, geometry: geometry, profile: profile, guide: frame) {
            frame = found
            cropDetected = true
        }
        if abs(adjustments.cropInset) > 0.0005 {
            // Positive trims inward; negative widens to keep a thin rebate.
            let inset = CGFloat(adjustments.cropInset)
            frame = frame.insetBy(dx: frame.width * inset, dy: frame.height * inset)
                .intersection(source.extent).integral
        }
        guard frame.width > 2, frame.height > 2 else {
            throw ProcessorError.renderFailed
        }
        let cropped = source.cropped(to: frame)
        let levels = filmType.inverts
            ? densityStats(in: cropped, silver: filmType == .silverBW)
            : slideWhite(in: cropped).map { DensityLevels(low: .zero, high: RGBColor(r: $0, g: $0, b: $0)) }
        return FrameSource(
            cropped: cropped,
            profile: profile,
            levels: levels,
            flatFieldApplied: flatFieldApplied,
            cropDetected: cropDetected
        )
    }

    private func render(_ request: FrameRequest, maxEdge: CGFloat?) throws -> Rendered {
        let source = try frameSource(request, maxEdge: maxEdge)
        var profile = source.profile
        let adjustments = request.adjustments
        let levels: DensityLevels?
        switch adjustments.autoLevels {
        case .roll: levels = request.rollLevels ?? source.levels
        case .frame: levels = source.levels
        case .off: levels = nil
        }
        let parameters = printParameters(profile: profile, adjustments: adjustments, levels: levels)
        guard let positive = applyPositive(source.cropped, parameters: parameters) else {
            throw ProcessorError.renderFailed
        }
        let rotated = Self.rotate(positive, quarterTurns: request.quarterTurns)
        let origin = rotated.extent.origin
        let placed = rotated.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        if request.filmType.inverts, var stretch = profile.stretch {
            stretch.rebateCode = parameters.code(atStretched: 0)
            stretch.highlightCode = parameters.code(atStretched: 1)
            let spread = try outputSpread(of: placed)
            stretch.outputLow = spread.low
            stretch.outputHigh = spread.high
            profile.stretch = stretch
            invertLog.info("\(stretch.rangeText, privacy: .public)")
            let mid = (spread.low + spread.high) * 0.5
            let curveBroken = adjustments.isNeutralTone
                && (stretch.rebateCode > 15 || stretch.highlightCode < 200)
            if curveBroken || (spread.high - spread.low < 20 && mid > 40 && mid < 220) {
                throw ProcessorError.collapsed(stretch)
            }
        }
        return Rendered(image: placed, profile: profile, source: source)
    }

    /// Small mosaics are cached as bitmaps so slider changes do not re-decode four RAWs.
    private func mosaicSource(_ record: MosaicRecord, flatFieldURL: URL?, maxEdge: CGFloat?) throws -> CIImage {
        // Only preview sizes are cached; a 4500 px export fallback would pin ~300 MB.
        guard let maxEdge, maxEdge <= 1200 else {
            return try assembleMosaic(record, flatFieldURL: flatFieldURL, maxEdge: maxEdge)
        }
        let key = "\(record.id.uuidString)|\(flatFieldURL?.path ?? "-")|\(Int(maxEdge))"
        if let cached = mosaicCache.first(where: { $0.key == key }) {
            return cached.image
        }
        let assembled = try assembleMosaic(record, flatFieldURL: flatFieldURL, maxEdge: maxEdge)
        let extent = assembled.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        var floats = [Float](repeating: 0, count: width * height * 4)
        floats.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(assembled, toBitmap: base, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: linear)
        }
        guard let image = imageFromFloats(floats, width: width, height: height) else {
            throw ProcessorError.renderFailed
        }
        mosaicCache.append((key, image))
        if mosaicCache.count > 4 { mosaicCache.removeFirst() }
        return image
    }

    private static func rotate(_ image: CIImage, quarterTurns: Int) -> CIImage {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return image.oriented(.right)
        case 2: return image.oriented(.down)
        case 3: return image.oriented(.left)
        default: return image
        }
    }

    // MARK: Per-frame print

    /// Roll Dmin and span, optionally replaced per channel by automatic black and white points
    /// (this frame's, or the roll's median).
    private func printParameters(
        profile: RollProfile,
        adjustments: Adjustments,
        levels: DensityLevels?
    ) -> PrintParameters {
        let filmType = profile.filmType
        if !filmType.inverts {
            var scale: Float = 1
            if let white = levels?.high.g, white.isFinite, white > 0 {
                scale = 1 / max(white, 1e-3)
            }
            return PrintParameters(
                mode: 0,
                black: .zero,
                gain: RGBColor(r: scale, g: scale, b: scale),
                range: 1,
                adjustments: adjustments
            )
        }
        var black = profile.dmin
        var gain = profile.gain
        if let stats = levels {
            func level(_ base: Float, _ low: Float, _ high: Float, _ fallback: Float, _ fallbackGain: Float) -> (Float, Float) {
                // The darkest picture point cannot be clearer than the base, and only a little denser.
                let floor = min(max(low, base), base + 0.3)
                guard high - floor >= 0.2, high.isFinite, floor.isFinite else { return (fallback, fallbackGain) }
                return (floor, 1 / (high - floor))
            }
            let r = level(profile.dmin.r, stats.low.r, stats.high.r, black.r, gain.r)
            let g = level(profile.dmin.g, stats.low.g, stats.high.g, black.g, gain.g)
            let b = level(profile.dmin.b, stats.low.b, stats.high.b, black.b, gain.b)
            black = RGBColor(r: r.0, g: g.0, b: b.0)
            gain = RGBColor(r: r.1, g: g.1, b: b.1)
        }
        let spans = [gain.r, gain.g, gain.b].map { 1 / max($0, 1e-3) }
        var range = spans.reduce(0, +) / 3 / filmType.negativeGamma
        if !range.isFinite { range = 2 }
        return PrintParameters(
            mode: filmType.kernelMode,
            black: black,
            gain: gain,
            range: min(max(range, 1), 4),
            adjustments: adjustments
        )
    }

    /// 0.2 % and 99.5 % density per channel inside the frame, a small border excluded.
    private func densityStats(in frame: CIImage, silver: Bool) -> DensityLevels? {
        let inner = frame.extent.insetBy(dx: frame.extent.width * 0.03, dy: frame.extent.height * 0.03)
        let pixels = linearPixels(of: frame, in: inner, longest: 256)
        guard pixels.count >= 64 else { return nil }
        if silver {
            let tone = pixels.map { -log10(max(0.2627 * $0.r + 0.6780 * $0.g + 0.0593 * $0.b, 1e-4)) }
            let low = percentileValue(tone, 0.002)
            let high = percentileValue(tone, 0.995)
            return DensityLevels(low: RGBColor(r: low, g: low, b: low), high: RGBColor(r: high, g: high, b: high))
        }
        let red = density(pixels.map(\.r))
        let green = density(pixels.map(\.g))
        let blue = density(pixels.map(\.b))
        return DensityLevels(
            low: RGBColor(r: percentileValue(red, 0.002), g: percentileValue(green, 0.002), b: percentileValue(blue, 0.002)),
            high: RGBColor(r: percentileValue(red, 0.995), g: percentileValue(green, 0.995), b: percentileValue(blue, 0.995))
        )
    }

    private func slideWhite(in frame: CIImage) -> Float? {
        let inner = frame.extent.insetBy(dx: frame.extent.width * 0.03, dy: frame.extent.height * 0.03)
        let pixels = linearPixels(of: frame, in: inner, longest: 256)
        guard pixels.count >= 64 else { return nil }
        let luma = pixels.map { 0.2627 * $0.r + 0.6780 * $0.g + 0.0593 * $0.b }
        return percentileValue(luma, 0.995)
    }

    // MARK: Frame detection

    /// Finds the picture edges near the guide. Negatives: the border is film base (as clear as Dmin)
    /// or a sprocket hole. Slides: the border is opaque. Returns nil when the edges are not convincing.
    private func detectFrame(
        in image: CIImage,
        geometry: CaptureGeometry,
        profile: RollProfile,
        guide: CGRect
    ) -> CGRect? {
        guard guide.width > 8, guide.height > 8 else { return nil }
        let searchView = geometry.outer.insetBy(dx: -geometry.inner.width * 0.04, dy: -geometry.inner.height * 0.04)
        let region = GuideMapping.imageRect(
            viewRect: searchView,
            viewSize: geometry.viewSize,
            extent: image.extent
        ).intersection(image.extent).integral
        guard region.width > 16, region.height > 16 else { return nil }
        let bitmap = linearBitmap(of: image, in: region, longest: 420)
        let w = bitmap.width
        let h = bitmap.height
        guard w > 16, h > 16, bitmap.pixels.count == w * h else { return nil }

        let lumas = bitmap.pixels.map { 0.2627 * $0.r + 0.6780 * $0.g + 0.0593 * $0.b }
        var isBorder = [Bool](repeating: false, count: w * h)
        if profile.filmType.inverts {
            let base = profile.linearBase
            let baseLuma = 0.2627 * base.r + 0.6780 * base.g + 0.0593 * base.b
            let baseDensity = -log10(max(baseLuma, 1e-4))
            for index in lumas.indices {
                isBorder[index] = -log10(max(lumas[index], 1e-4)) < baseDensity + 0.10
            }
        } else {
            let white = percentileValue(lumas, 0.99)
            for index in lumas.indices {
                isBorder[index] = lumas[index] < white * 0.04
            }
        }

        // Guide edges in bitmap coordinates (row 0 is the top of the image).
        func column(_ x: CGFloat) -> Int { Int(((x - region.minX) / region.width * CGFloat(w)).rounded()) }
        func row(_ y: CGFloat) -> Int { Int(((region.maxY - y) / region.height * CGFloat(h)).rounded()) }
        let left = column(guide.minX)
        let right = column(guide.maxX)
        let top = row(guide.maxY)
        let bottom = row(guide.minY)
        guard right - left > 8, bottom - top > 8 else { return nil }

        let rowBand = (top + (bottom - top) / 10)..<(bottom - (bottom - top) / 10)
        let columnBand = (left + (right - left) / 10)..<(right - (right - left) / 10)
        func columnFraction(_ x: Int) -> Float {
            guard x >= 0, x < w else { return 1 }
            var count = 0
            var total = 0
            for y in rowBand where y >= 0 && y < h {
                total += 1
                if isBorder[y * w + x] { count += 1 }
            }
            return total > 0 ? Float(count) / Float(total) : 1
        }
        func rowFraction(_ y: Int) -> Float {
            guard y >= 0, y < h else { return 1 }
            var count = 0
            var total = 0
            for x in columnBand where x >= 0 && x < w {
                total += 1
                if isBorder[y * w + x] { count += 1 }
            }
            return total > 0 ? Float(count) / Float(total) : 1
        }
        /// Walks from inside the picture outward and stops at the first two border lines in a row.
        func edge(from start: Int, outward step: Int, limit: Int, fraction: (Int) -> Float) -> Int? {
            var position = start
            while (step < 0 ? position >= limit : position <= limit) {
                if fraction(position) > 0.6, fraction(position + step) > 0.6 {
                    return position - step
                }
                position += step
            }
            return nil
        }
        let insideX = (right - left) * 12 / 100
        let insideY = (bottom - top) * 12 / 100
        let outsideX = (right - left) * 10 / 100
        let outsideY = (bottom - top) * 10 / 100
        let foundLeft = edge(from: left + insideX, outward: -1, limit: max(left - outsideX, 0), fraction: columnFraction)
        let foundRight = edge(from: right - insideX, outward: 1, limit: min(right + outsideX, w - 1), fraction: columnFraction)
        let foundTop = edge(from: top + insideY, outward: -1, limit: max(top - outsideY, 0), fraction: rowFraction)
        let foundBottom = edge(from: bottom - insideY, outward: 1, limit: min(bottom + outsideY, h - 1), fraction: rowFraction)
        guard foundLeft != nil || foundRight != nil || foundTop != nil || foundBottom != nil else { return nil }

        let l = foundLeft ?? left
        let r = foundRight ?? right
        let t = foundTop ?? top
        let b = foundBottom ?? bottom
        let minX = region.minX + CGFloat(l) / CGFloat(w) * region.width
        let maxX = region.minX + CGFloat(r + 1) / CGFloat(w) * region.width
        let maxY = region.maxY - CGFloat(t) / CGFloat(h) * region.height
        let minY = region.maxY - CGFloat(b + 1) / CGFloat(h) * region.height
        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        rect = rect.insetBy(dx: rect.width * 0.006, dy: rect.height * 0.006).intersection(image.extent).integral
        let guideAspect = guide.width / guide.height
        let aspect = rect.width / max(rect.height, 1)
        guard rect.width >= guide.width * 0.7, rect.height >= guide.height * 0.7,
              aspect / guideAspect > 0.8, aspect / guideAspect < 1.25 else {
            invertLog.info("Recorte automático recusado \(rect.debugDescription, privacy: .public)")
            return nil
        }
        return rect
    }

    func linearImage(at url: URL, maxEdge: CGFloat?, angle: CGFloat) -> CIImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let longEdge = max(filter.nativeSize.width, filter.nativeSize.height)
        if let maxEdge, longEdge > 1 {
            filter.scaleFactor = Float(min(1, maxEdge / longEdge))
        } else {
            filter.scaleFactor = 1
        }
        filter.exposure = 0
        if fileBaselines[url] == nil {
            fileBaselines[url] = filter.baselineExposure
        }
        filter.baselineExposure = 0
        filter.shadowBias = 0
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
        filter.extendedDynamicRangeAmount = 1
        if filter.isLocalToneMapSupported {
            filter.localToneMapAmount = 0
        }
        if filter.isHighlightRecoverySupported {
            filter.isHighlightRecoveryEnabled = false
        }
        if filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = 0
        }
        if filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = 0
        }
        if filter.isSharpnessSupported {
            filter.sharpnessAmount = 0
        }
        if filter.isContrastSupported {
            filter.contrastAmount = 0
        }
        if filter.isDetailSupported {
            filter.detailAmount = 0
        }
        if filter.isMoireReductionSupported {
            filter.moireReductionAmount = 0
        }
        if filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = true
        }
        let oriented = applyFileOrientation(to: filter)
        guard let image = filter.outputImage else { return nil }
        if oriented {
            return image
        }
        return upright(image, angle: angle)
    }

    private func applyFileOrientation(to filter: CIRAWFilter) -> Bool {
        let properties = filter.properties
        let raw = properties[kCGImagePropertyOrientation as String]
            ?? properties[kCGImagePropertyOrientation as NSString]
        let number = (raw as? NSNumber)?.uint32Value
        guard let number, let orientation = CGImagePropertyOrientation(rawValue: number) else {
            return false
        }
        filter.orientation = orientation
        return true
    }

    private func upright(_ image: CIImage, angle: CGFloat) -> CIImage {
        let landscape = image.extent.width > image.extent.height
        if landscape, angle == 90 || angle == 270 {
            return image.oriented(angle == 270 ? .left : .right)
        }
        if landscape, angle == 180 {
            return image.oriented(.down)
        }
        return image
    }

    func divide(_ image: CIImage, by light: CIImage) -> CIImage {
        let imageExtent = image.extent
        let lightExtent = light.extent
        guard imageExtent.width > 1, imageExtent.height > 1, lightExtent.width > 1, lightExtent.height > 1 else {
            return image
        }
        let scaleX = imageExtent.width / lightExtent.width
        let scaleY = imageExtent.height / lightExtent.height
        // Illumination falloff is smooth; sensor noise and diffuser texture are not.
        // Blur the flat field so the division corrects vignetting without printing that noise into every frame.
        let sigma = max(1.5, max(lightExtent.width, lightExtent.height) * 0.002)
        let smoothLight = light.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: lightExtent)
        let aligned = smoothLight
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(
                translationX: imageExtent.minX - lightExtent.minX * scaleX,
                y: imageExtent.minY - lightExtent.minY * scaleY
            ))
        if let flatKernel = PositiveKernels.compiled?.flatField, let divided = flatKernel.apply(
            extent: imageExtent,
            roiCallback: { _, rect in rect },
            arguments: [image, aligned]
        ) {
            return divided
        }
        return cpuDivide(image, by: aligned) ?? image
    }

    /// 99.5th percentile of the brightest channel in raw units (1 = sensor white, BaselineExposure ignored).
    /// With `geometry`, only the film guide (rebate and sprocket holes included); otherwise the central 80 %.
    func rawPeak(url: URL, angle: CGFloat, geometry: CaptureGeometry?) -> Float? {
        guard let image = linearImage(at: url, maxEdge: 768, angle: angle) else { return nil }
        let region: CGRect
        if let geometry {
            region = GuideMapping.imageRect(viewRect: geometry.outer, viewSize: geometry.viewSize, extent: image.extent)
                .intersection(image.extent)
        } else {
            region = image.extent.insetBy(dx: image.extent.width * 0.1, dy: image.extent.height * 0.1)
        }
        guard region.width > 4, region.height > 4 else { return nil }
        let peaks = linearPixels(of: image, in: region, longest: 384).map { max($0.r, $0.g, $0.b) }.filter(\.isFinite)
        guard peaks.count >= 64 else { return nil }
        return percentileValue(peaks, 0.995)
    }

    private func profileFor(
        filmType: FilmType,
        existing: RollProfile?,
        transmittance: CIImage,
        geometry: CaptureGeometry,
        clearBase: CGPoint?
    ) throws -> RollProfile {
        if let existing, existing.filmType == filmType {
            return existing
        }
        if !filmType.inverts {
            return RollProfile(
                filmType: filmType,
                dmin: .zero,
                gain: RGBColor(r: 1, g: 1, b: 1),
                linearBase: .white,
                stretch: nil
            )
        }
        return try measure(
            filmType: filmType,
            in: transmittance,
            geometry: geometry,
            clearBase: clearBase
        )
    }

    /// Dmin is the robust median density of the unexposed rebate (or a tapped clear-base patch).
    /// The picture is never the mask. Dmax is the 99.8th percentile of density inside the gate.
    private func measure(
        filmType: FilmType,
        in image: CIImage,
        geometry: CaptureGeometry,
        clearBase: CGPoint?
    ) throws -> RollProfile {
        let rebate: SampleSet
        if let clearBase {
            let patch = clearBaseRect(clearBase, viewSize: geometry.viewSize)
            guard let sampled = tappedBase(
                samples(in: image, viewRects: [patch], geometry: geometry, rejectHoles: false)
            ) else {
                throw ProcessorError.unevenBase
            }
            rebate = sampled
        } else {
            guard let sampled = baseCluster(
                samples(in: image, viewRects: baseViewRects(geometry), geometry: geometry, rejectHoles: false),
                warm: filmType != .silverBW
            ) else {
                throw ProcessorError.missingRebate
            }
            rebate = sampled
        }

        let gateRect = geometry.inner.insetBy(
            dx: geometry.inner.width * 0.015,
            dy: geometry.inner.height * 0.015
        )
        guard let gate = samples(
            in: image,
            viewRects: [gateRect.width > 2 ? gateRect : geometry.inner],
            geometry: geometry,
            rejectHoles: false
        ), gate.count >= 24 else {
            throw ProcessorError.renderFailed
        }

        let dmin = dmin(fromRebate: rebate, filmType: filmType)
        let dmax = dmax(inGate: gate, filmType: filmType)
        let span = RGBColor(r: dmax.r - dmin.r, g: dmax.g - dmin.g, b: dmax.b - dmin.b)
        let linearBase = medianLinear(rebate) ?? .white
        let stretch = DensityStretch(
            rebateLinear: linearBase,
            dmin: dmin,
            dmax: dmax,
            span: span,
            rebateCode: 0,
            highlightCode: 0,
            outputLow: 0,
            outputHigh: 0
        )

        if clearBase == nil {
            let clearestPicture = percentileValue(chromaticDensity(gate), 0.20)
            // Both sides are luma density, so an orange base is not compared against a green-only value.
            let rebateLuma = median(lumaDensity(rebate))
            if rebateLuma > clearestPicture + 0.35 {
                invertLog.error("Margem mais densa que a imagem. Dmin luma \(rebateLuma) · p20 \(clearestPicture)")
                throw ProcessorError.missingRebate
            }
        }

        guard span.r.isFinite, span.g.isFinite, span.b.isFinite,
              span.r >= 0.03, span.g >= 0.03, span.b >= 0.03 else {
            throw ProcessorError.flatDensity(stretch)
        }

        let gain = RGBColor(r: 1 / span.r, g: 1 / span.g, b: 1 / span.b)
        invertLog.info("Dmin \(dmin.r) \(dmin.g) \(dmin.b) · Δ \(span.r) \(span.g) \(span.b)")
        return RollProfile(
            filmType: filmType,
            dmin: dmin,
            gain: gain,
            linearBase: linearBase,
            stretch: stretch
        )
    }

    /// Median density of the clear base. This is the only Dmin.
    private func dmin(fromRebate samples: SampleSet, filmType: FilmType) -> RGBColor {
        if filmType == .silverBW {
            let tone = median(lumaDensity(samples))
            return RGBColor(r: tone, g: tone, b: tone)
        }
        return RGBColor(
            r: median(density(samples.red)),
            g: median(density(samples.green)),
            b: median(density(samples.blue))
        )
    }

    /// 99.8th percentile of absolute density inside the film gate, rebate excluded.
    private func dmax(inGate samples: SampleSet, filmType: FilmType) -> RGBColor {
        if filmType == .silverBW {
            let tone = percentileValue(lumaDensity(samples), 0.998)
            return RGBColor(r: tone, g: tone, b: tone)
        }
        return RGBColor(
            r: percentileValue(density(samples.red), 0.998),
            g: percentileValue(density(samples.green), 0.998),
            b: percentileValue(density(samples.blue), 0.998)
        )
    }

    /// Rebate bands plus a thin lip inside the gate, so a small misalignment still hits the film base.
    private func baseViewRects(_ geometry: CaptureGeometry) -> [CGRect] {
        let bands = geometry.layout.rebateRects(sidesOnly: false).map { coreOfRebate($0, fraction: 0.08) }
        let inner = geometry.inner
        let dx = inner.width * 0.05
        let dy = inner.height * 0.05
        let lips = [
            CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: dy),
            CGRect(x: inner.minX, y: inner.maxY - dy, width: inner.width, height: dy),
            CGRect(x: inner.minX, y: inner.minY, width: dx, height: inner.height),
            CGRect(x: inner.maxX - dx, y: inner.minY, width: dx, height: inner.height),
        ]
        return (bands + lips).filter { $0.width >= 2 && $0.height >= 2 }
    }

    /// Clearest film in the border. Picture spill is darker, so it stays out of this cluster.
    /// Bright neutral pixels are sprocket holes or bare backlight and are dropped.
    private func baseCluster(_ samples: SampleSet?, warm: Bool) -> SampleSet? {
        guard let samples else {
            invertLog.error("Rebate sem pixels na margem do guia")
            return nil
        }
        let split = splitBase(samples)
        var pool = split.colored
        if split.colored.isEmpty {
            guard !warm else {
                invertLog.error("Margem sem base laranja. Pixels \(samples.count)")
                return nil
            }
            pool = split.neutral
        } else {
            let center = median(split.colored.map(\.density))
            pool.append(contentsOf: split.neutral.filter { $0.density >= center - 0.02 })
        }
        guard pool.count >= 12 else { return nil }
        let floor = percentileValue(pool.map(\.density), 0.05)
        let kept = pool.filter { $0.density <= floor + 0.10 }
        guard kept.count >= 12 else { return nil }
        if warm {
            let red = median(kept.map(\.red))
            let blue = median(kept.map(\.blue))
            if red < blue * 1.05 {
                invertLog.error("Base da margem não é laranja. R \(red) B \(blue)")
                return nil
            }
        }
        return sampleSet(from: kept)
    }

    /// The user pointed at the base. Use that patch, and only refuse a detailed picture.
    private func tappedBase(_ samples: SampleSet?) -> SampleSet? {
        guard let samples else { return nil }
        let split = splitBase(samples)
        var pool = split.colored
        if pool.isEmpty {
            pool = split.neutral
        } else {
            let center = median(pool.map(\.density))
            pool.append(contentsOf: split.neutral.filter { $0.density >= center - 0.02 })
        }
        guard pool.count >= 12 else { return nil }
        let green = density(pool.map(\.green))
        let spread = percentileValue(green, 0.75) - percentileValue(green, 0.25)
        guard spread <= 0.45 else { return nil }
        return sampleSet(from: pool)
    }

    private struct BasePixel {
        var red: Float
        var green: Float
        var blue: Float
        var density: Float
    }

    private func splitBase(_ samples: SampleSet) -> (colored: [BasePixel], neutral: [BasePixel]) {
        var colored: [BasePixel] = []
        var neutral: [BasePixel] = []
        for index in samples.red.indices {
            let red = samples.red[index]
            let green = samples.green[index]
            let blue = samples.blue[index]
            let peak = max(red, green, blue)
            let floor = min(red, green, blue)
            guard peak.isFinite, floor.isFinite, peak >= 0.004 else { continue }
            let luma = 0.2627 * red + 0.6780 * green + 0.0593 * blue
            let pixel = BasePixel(
                red: red,
                green: green,
                blue: blue,
                density: -log10(max(luma, 1e-4))
            )
            if floor / max(peak, 1e-4) > 0.82 {
                neutral.append(pixel)
            } else {
                colored.append(pixel)
            }
        }
        return (colored, neutral)
    }

    private func sampleSet(from pixels: [BasePixel]) -> SampleSet {
        var set = SampleSet()
        set.red.reserveCapacity(pixels.count)
        set.green.reserveCapacity(pixels.count)
        set.blue.reserveCapacity(pixels.count)
        for pixel in pixels {
            set.red.append(pixel.red)
            set.green.append(pixel.green)
            set.blue.append(pixel.blue)
        }
        return set
    }

    /// Luma density of pixels that are not bare backlight, so a few sprocket holes do not set the floor.
    private func chromaticDensity(_ samples: SampleSet) -> [Float] {
        let split = splitBase(samples)
        let pool = split.colored.isEmpty ? split.neutral : split.colored
        return pool.map(\.density)
    }

    private func coreOfRebate(_ rect: CGRect, fraction: CGFloat) -> CGRect {
        let dx = min(rect.width * fraction, max(rect.width - 2, 0) / 2)
        let dy = min(rect.height * fraction, max(rect.height - 2, 0) / 2)
        let inset = rect.insetBy(dx: dx, dy: dy)
        return inset.width >= 2 && inset.height >= 2 ? inset : rect
    }

    private func clearBaseRect(_ normalized: CGPoint, viewSize: CGSize) -> CGRect {
        let side = max(28, min(viewSize.width, viewSize.height) * 0.05)
        let center = CGPoint(x: normalized.x * viewSize.width, y: normalized.y * viewSize.height)
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    private func medianLinear(_ samples: SampleSet) -> RGBColor? {
        guard samples.count >= 12 else { return nil }
        return RGBColor(
            r: median(samples.red),
            g: median(samples.green),
            b: median(samples.blue)
        )
    }

    private func lumaDensity(_ samples: SampleSet) -> [Float] {
        samples.red.indices.map { index in
            let luma = 0.2627 * samples.red[index] + 0.6780 * samples.green[index] + 0.0593 * samples.blue[index]
            return -log10(max(luma, 1e-4))
        }
    }

    private func density(_ values: [Float]) -> [Float] {
        values.map { -log10(max($0, 1e-4)) }
    }

    private struct SampleSet {
        var red: [Float] = []
        var green: [Float] = []
        var blue: [Float] = []

        var count: Int { red.count }
    }

    private func samples(
        in image: CIImage,
        viewRects: [CGRect],
        geometry: CaptureGeometry,
        rejectHoles: Bool
    ) -> SampleSet? {
        var set = SampleSet()
        for viewRect in viewRects {
            let rect = GuideMapping.imageRect(
                viewRect: viewRect,
                viewSize: geometry.viewSize,
                extent: image.extent
            ).intersection(image.extent)
            guard rect.width >= 2, rect.height >= 2 else { continue }
            let pixels = linearPixels(of: image, in: rect, longest: rejectHoles ? 96 : 180)
            for sample in pixels {
                let peak = max(sample.r, sample.g, sample.b)
                let floor = min(sample.r, sample.g, sample.b)
                if !peak.isFinite || !floor.isFinite || peak < 0.004 { continue }
                if rejectHoles {
                    if peak < 0.02 { continue }
                    let neutral = peak > 1e-4 && floor / peak > 0.82
                    if neutral && peak > 0.5 { continue }
                }
                set.red.append(sample.r)
                set.green.append(sample.g)
                set.blue.append(sample.b)
            }
        }
        return set.count >= 12 ? set : nil
    }

    private func linearPixels(of image: CIImage, in rect: CGRect, longest target: CGFloat) -> [RGBColor] {
        linearBitmap(of: image, in: rect, longest: target).pixels
    }

    /// Linear RGB of `rect`, scaled so its long side is at most `target`. Row 0 is the top.
    func linearBitmap(
        of image: CIImage,
        in rect: CGRect,
        longest target: CGFloat
    ) -> (pixels: [RGBColor], width: Int, height: Int) {
        let longest = max(rect.width, rect.height)
        let scale = min(1, target / max(longest, 1))
        // Only whole pixels inside the rect: rounding the extent outward would add partly transparent
        // border pixels whose density reads as ~4 and drags every percentile. Clamping first keeps
        // the resampling at the crop edge from mixing in transparency.
        let crop = rect.intersection(image.extent)
        let scaledRect = crop.applying(CGAffineTransform(scaleX: scale, y: scale))
        let extent = CGRect(
            x: scaledRect.minX.rounded(.up),
            y: scaledRect.minY.rounded(.up),
            width: scaledRect.maxX.rounded(.down) - scaledRect.minX.rounded(.up),
            height: scaledRect.maxY.rounded(.down) - scaledRect.minY.rounded(.up)
        )
        guard extent.width >= 1, extent.height >= 1, !crop.isNull else { return ([], 0, 0) }
        let scaled = image
            .cropped(to: crop)
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: extent)
        let width = Int(extent.width)
        let height = Int(extent.height)

        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(
                scaled,
                toBitmap: base,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: extent,
                format: .RGBAf,
                colorSpace: linear
            )
        }
        var samples: [RGBColor] = []
        samples.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            samples.append(RGBColor(r: pixels[index], g: pixels[index + 1], b: pixels[index + 2]))
        }
        return (samples, width, height)
    }

    private func outputSpread(of image: CIImage) throws -> (low: Float, high: Float) {
        let longest = max(image.extent.width, image.extent.height)
        let scale = min(1, 160 / max(longest, 1))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let pixels = linearPixels(of: small, in: small.extent, longest: 160)
        guard pixels.count >= 24 else { throw ProcessorError.renderFailed }
        let codes = pixels.map { sample -> Float in
            let luma = 0.2627 * sample.r + 0.6780 * sample.g + 0.0593 * sample.b
            return Self.displayCode(luma)
        }
        return (percentileValue(codes, 0.01), percentileValue(codes, 0.99))
    }

    private func applyPositive(_ image: CIImage, parameters: PrintParameters) -> CIImage? {
        if let filtered = PositiveKernels.positive(image, parameters) {
            return filtered
        }
        return cpuPositive(image, parameters: parameters)
    }

    private static func displayCode(_ linear: Float) -> Float {
        PositiveKernels.displayCode(linear)
    }

    private func cpuDivide(_ image: CIImage, by light: CIImage) -> CIImage? {
        let fitted = fitted(image, pairedWith: light, pixelCap: 6_000_000)
        guard let fitted else { return nil }
        var pixels = fitted.pixels
        let lightPixels = fitted.other
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = pixels[index] / max(lightPixels[index], 1e-4)
            pixels[index + 1] = pixels[index + 1] / max(lightPixels[index + 1], 1e-4)
            pixels[index + 2] = pixels[index + 2] / max(lightPixels[index + 2], 1e-4)
            pixels[index + 3] = 1
        }
        return imageFromFloats(pixels, width: fitted.width, height: fitted.height)
    }

    private func cpuPositive(_ image: CIImage, parameters: PrintParameters) -> CIImage? {
        guard let fitted = fitted(image, pairedWith: nil, pixelCap: 6_000_000) else { return nil }
        var pixels = fitted.pixels
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let printed = parameters.apply(red: pixels[index], green: pixels[index + 1], blue: pixels[index + 2])
            pixels[index] = printed.r
            pixels[index + 1] = printed.g
            pixels[index + 2] = printed.b
            pixels[index + 3] = 1
        }
        let output = imageFromFloats(pixels, width: fitted.width, height: fitted.height)
        // The CPU path may have downsampled; put it back on the frame's extent.
        guard let output else { return nil }
        let sx = image.extent.width / output.extent.width
        let sy = image.extent.height / output.extent.height
        return output
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
    }

    private struct FittedPixels {
        var pixels: [Float]
        var other: [Float]
        var width: Int
        var height: Int
    }

    private func fitted(_ image: CIImage, pairedWith other: CIImage?, pixelCap: Int) -> FittedPixels? {
        let extent = image.extent
        let count = extent.width * extent.height
        let scale = count > CGFloat(pixelCap) ? sqrt(CGFloat(pixelCap) / max(count, 1)) : 1
        let primary = renderFloats(image, scale: scale)
        guard let primary else { return nil }
        let secondary: [Float]
        if let other {
            guard let rendered = renderFloats(other, scale: scale), rendered.pixels.count == primary.pixels.count else {
                return nil
            }
            secondary = rendered.pixels
        } else {
            secondary = []
        }
        return FittedPixels(pixels: primary.pixels, other: secondary, width: primary.width, height: primary.height)
    }

    private func renderFloats(_ image: CIImage, scale: CGFloat) -> (pixels: [Float], width: Int, height: Int)? {
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaled.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 1, height > 1 else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(
                scaled,
                toBitmap: base,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: extent,
                format: .RGBAf,
                colorSpace: linear
            )
        }
        return (pixels, width, height)
    }

    private func imageFromFloats(_ pixels: [Float], width: Int, height: Int) -> CIImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(
            bitmapData: data,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: linear
        )
    }

    private func jpegData(from image: CIImage) -> Data? {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1 else { return nil }
        return context.jpegRepresentation(
            of: image,
            colorSpace: displayP3,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        )
    }

    private func heif10Data(from image: CIImage) -> Data? {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1 else { return nil }
        return try? context.heif10Representation(
            of: image,
            colorSpace: displayP3,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        )
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    func percentileValue(_ values: [Float], _ fraction: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Float(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

}

nonisolated enum ProcessorError: LocalizedError {
    case unreadableRAW
    case renderFailed
    case missingRebate
    case unevenBase
    case flatDensity(DensityStretch)
    case collapsed(DensityStretch)

    var asksForClearBase: Bool {
        switch self {
        case .missingRebate, .unevenBase:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unreadableRAW:
            return "Não foi possível ler o ProRAW."
        case .renderFailed:
            return "Não foi possível inverter o negativo."
        case .missingRebate:
            return "Toca na margem laranja do filme, fora da imagem."
        case .unevenBase:
            return "Essa zona não parece base clara. Toca outra vez na margem, fora da imagem."
        case .flatDensity(let stretch):
            return String(
                format: "Densidade quase constante (Δ %.3f %.3f %.3f). Estiramento recusado.",
                stretch.span.r, stretch.span.g, stretch.span.b
            )
        case .collapsed(let stretch):
            return "Positivo preso numa banda de \(Int(stretch.outputSpan.rounded())) códigos. \(stretch.rangeText)"
        }
    }
}
