//
//  Enhancement.swift
//  scan-analog
//
//  Optional layer on TOP of the faithful positive. The faithful print is never modified:
//  everything here takes it as input and returns a separate image.
//
//  1. Dust and scratches: morphological top-hat, thresholded against the local grain noise,
//     then a connected-component filter (size and shape) so grain is never treated as dust.
//     Only the defect mask is filled; outside it the output is the faithful pixel, exactly.
//  2. Film look: a deterministic per-pixel grade (colour balance, contrast, highlight roll-off).
//     No blur, no sharpening, no local tone mapping, so grain passes through untouched.
//
//  A future Core ML grade must follow the same contract: take the faithful positive and
//  return a residual applied to it, never a new image from scratch.
//

import CoreImage
import Foundation
import os
import simd

nonisolated private let enhanceLog = Logger(subsystem: "scan-analog", category: "enhance")

nonisolated enum DustStrength: String, CaseIterable, Identifiable, Sendable, Codable {
    case off, light, normal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Desligado"
        case .light: return "Leve"
        case .normal: return "Normal"
        }
    }

    /// Top-hat must exceed this many local grain standard deviations.
    var sigmas: Float { self == .light ? 7.5 : 6 }
    /// Smallest blob kept, in analysis pixels; anything smaller is grain.
    var minimumArea: Int { self == .light ? 8 : 6 }
}

nonisolated enum FilmLook: String, CaseIterable, Identifiable, Sendable, Codable {
    case none, portra, gold, monochrome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Nenhum"
        case .portra: return "Portra"
        case .gold: return "Gold"
        case .monochrome: return "P&B"
        }
    }

    /// Looks that make sense for a film type (monochrome for B&W, the colour looks for colour).
    static func available(for filmType: FilmType) -> [FilmLook] {
        switch filmType {
        case .silverBW, .chromogenicBW: return [.none, .monochrome]
        default: return [.none, .portra, .gold]
        }
    }

    /// Linear channel gains, contrast slope around 18 % grey, roll-off knee and strength, mono flag.
    var grade: (gains: SIMD3<Float>, contrast: Float, knee: Float, rolloff: Float, mono: Bool)? {
        switch self {
        case .none: return nil
        // Soft, slightly warm, gentle shoulder.
        case .portra: return (SIMD3(1.025, 1.0, 0.965), 0.93, 0.58, 1.3, false)
        // Warmer, a touch more contrast, earlier warm highlights.
        case .gold: return (SIMD3(1.06, 1.0, 0.91), 1.05, 0.62, 0.9, false)
        // Neutral print, slightly firmer.
        case .monochrome: return (SIMD3(1, 1, 1), 1.08, 0.7, 0.8, true)
        }
    }
}

/// Per-frame enhancement choices. `enabled == false` means the faithful positive is shown and saved.
nonisolated struct EnhanceSettings: Sendable, Equatable {
    var enabled = false
    var dust: DustStrength = .normal
    var look: FilmLook = .none

    var doesAnything: Bool { enabled && (dust != .off || look != .none) }
}

/// Defect mask in the frame's normalised coordinates, independent of render resolution.
nonisolated struct DustMask: @unchecked Sendable {
    /// 0/255 per pixel, row 0 at the top.
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let defects: Int
    let coverage: Double

    /// The mask scaled onto `extent` (a single-channel image in .r).
    func image(fitting extent: CGRect) -> CIImage {
        let data = Data(bytes)
        let base = CIImage(
            bitmapData: data,
            bytesPerRow: width,
            size: CGSize(width: width, height: height),
            format: .R8,
            colorSpace: nil
        )
        return base
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}

nonisolated enum Enhancement {
    // MARK: Dust detection

    /// Finds dust specks, hairs and scratches on the faithful positive (linear, any resolution).
    /// Work happens at ≤ `analysisLongSide` px so preview and export use the same mask.
    static func detectDust(
        in positive: CIImage,
        strength: DustStrength,
        context: CIContext,
        analysisLongSide: CGFloat = 3000
    ) -> DustMask? {
        guard strength != .off else { return nil }
        let extent = positive.extent
        let scale = min(1, analysisLongSide / max(extent.width, extent.height))
        let w = Int((extent.width * scale).rounded(.down))
        let h = Int((extent.height * scale).rounded(.down))
        guard w > 32, h > 32 else { return nil }

        // Perceptual luma (≈ gamma 2.2), so dust contrast is judged as the eye sees it.
        let small = positive
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
        let luma = small.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2627, y: 0.6780, z: 0.0593, w: 0),
            "inputGVector": CIVector(x: 0.2627, y: 0.6780, z: 0.0593, w: 0),
            "inputBVector": CIVector(x: 0.2627, y: 0.6780, z: 0.0593, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / 2.2])
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let clamped = luma.clampedToExtent()

        // Structuring element a bit larger than the biggest speck we want to catch (≈1 % of the frame across).
        let radius = max(3, Double(max(w, h)) * 0.006)
        func morph(_ name: String, _ image: CIImage) -> CIImage {
            image.applyingFilter(name, parameters: ["inputRadius": radius]).cropped(to: bounds).clampedToExtent()
        }
        let opened = morph("CIMorphologyMaximum", morph("CIMorphologyMinimum", clamped))
        let closed = morph("CIMorphologyMinimum", morph("CIMorphologyMaximum", clamped))
        // Local grain level: RMS of the finest detail, averaged over a neighbourhood.
        let fine = clamped.applyingGaussianBlur(sigma: 1.0)

        let l = render(luma, bounds, context)
        let o = render(opened, bounds, context)
        let c = render(closed, bounds, context)
        let f = render(fine, bounds, context)
        guard l.count == w * h, o.count == l.count, c.count == l.count, f.count == l.count else { return nil }
        // Signed finest detail (grain): luma minus a 1 px blur.
        let d = zip(l, f).map { $0 - $1 }

        // Local grain sigma by box average of detail², a few grain sizes wide. Detail is clipped at
        // 3× the frame's robust grain level first, so a defect's own hard edges cannot raise its threshold.
        let globalSigma = 1.4826 * median(d.map(abs))
        let clip = max(3 * globalSigma, 1e-4)
        let variance = boxMean(d.map { let c = min(max($0, -clip), clip); return c * c }, width: w, height: h, radius: 8)
        let k = strength.sigmas
        let floorContrast: Float = 0.03
        var bright = [Bool](repeating: false, count: l.count)
        var dark = [Bool](repeating: false, count: l.count)
        for i in l.indices {
            let sigma = variance[i].squareRoot()
            let threshold = max(k * sigma, floorContrast)
            bright[i] = l[i] - o[i] > threshold
            dark[i] = c[i] - l[i] > threshold
        }

        var mask = [UInt8](repeating: 0, count: l.count)
        var defects = 0
        let maxSpeckArea = Int(Double.pi * radius * radius)
        for candidates in [bright, dark] {
            for component in components(candidates, width: w, height: h) {
                let area = component.pixels.count
                guard area >= strength.minimumArea else { continue }  // grain
                let bw = component.maxX - component.minX + 1
                let bh = component.maxY - component.minY + 1
                let length = Double(max(bw, bh))
                let isSpeck = area <= maxSpeckArea
                // Hairs and scratches: long and thin, so wide scene detail is left alone.
                let isLine = length >= 6 * radius && Double(area) / length <= 0.6 * radius
                guard isSpeck || isLine else { continue }
                defects += 1
                for index in component.pixels { mask[index] = 255 }
            }
        }
        // Grow by 1–2 px so the defect's soft halo is filled too.
        mask = dilate(mask, width: w, height: h, radius: 2)
        let coverage = Double(mask.lazy.filter { $0 > 0 }.count) / Double(mask.count)
        enhanceLog.info("dust: \(defects) defects, \(coverage * 100, format: .fixed(precision: 3)) % of frame")
        // Rows are top-first, as both render(toBitmap:) and CIImage(bitmapData:) expect.
        return DustMask(bytes: mask, width: w, height: h, defects: defects, coverage: coverage)
    }

    // MARK: Fill

    /// Replaces only masked pixels: a normalised-convolution fill from the clean surroundings
    /// (two scales, so specks and hairs both close) plus grain borrowed from a nearby clean spot,
    /// so the patch does not read as a smooth blotch. Where the mask is 0 the faithful pixel is returned.
    static func removeDust(from positive: CIImage, mask: DustMask) -> CIImage {
        guard mask.defects > 0, let kernels = EnhanceKernels.compiled else { return positive }
        let extent = positive.extent
        let m = mask.image(fitting: extent)
        let scale = max(extent.width, extent.height) / CGFloat(max(mask.width, mask.height))
        guard let holed = kernels.hole.apply(extent: extent, roiCallback: { _, r in r }, arguments: [positive, m]) else {
            return positive
        }
        let smallSigma = Double(2 * scale)
        let largeSigma = max(3, Double(max(mask.width, mask.height)) * 0.006) * Double(scale) * 1.2
        let small = holed.clampedToExtent().applyingGaussianBlur(sigma: smallSigma).cropped(to: extent)
        let large = holed.clampedToExtent().applyingGaussianBlur(sigma: largeSigma).cropped(to: extent)
        // Grain texture from a spot a few defect-widths away, and where that spot is itself clean.
        let blurred = positive.clampedToExtent().applyingGaussianBlur(sigma: Double(scale)).cropped(to: extent)
        guard let grain = kernels.difference.apply(extent: extent, roiCallback: { _, r in r }, arguments: [positive, blurred]) else {
            return positive
        }
        let offset = CGAffineTransform(translationX: CGFloat(largeSigma * 2.5), y: CGFloat(largeSigma * 1.2))
        let shiftedGrain = grain.clampedToExtent().transformed(by: offset).cropped(to: extent)
        let shiftedMask = m.clampedToExtent().transformed(by: offset).cropped(to: extent)
        return kernels.fill.apply(
            extent: extent,
            roiCallback: { _, r in r },
            arguments: [positive, m, small, large, shiftedGrain, shiftedMask]
        ) ?? positive
    }

    /// Red overlay of the mask on the positive, for the debug view.
    static func maskOverlay(_ positive: CIImage, mask: DustMask) -> CIImage {
        let extent = positive.extent
        let m = mask.image(fitting: extent)
        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: extent)
        let alpha = m.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0.85, y: 0, z: 0, w: 0),
        ])
        return red.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: positive,
            kCIInputMaskImageKey: alpha,
        ]).cropped(to: extent)
    }

    // MARK: Film look

    /// Deterministic grade on the (cleaned) positive. Monotonic per pixel: grain is untouched.
    static func applyLook(_ look: FilmLook, to positive: CIImage) -> CIImage {
        guard let grade = look.grade, let kernel = EnhanceKernels.compiled?.look else { return positive }
        return kernel.apply(
            extent: positive.extent,
            roiCallback: { _, r in r },
            arguments: [
                positive,
                NSNumber(value: grade.gains.x), NSNumber(value: grade.gains.y), NSNumber(value: grade.gains.z),
                NSNumber(value: grade.contrast), NSNumber(value: grade.knee), NSNumber(value: grade.rolloff),
                NSNumber(value: grade.mono ? 1 : 0),
            ]
        ) ?? positive
    }

    /// CPU mirror of the look kernel, for tests.
    static func look(_ look: FilmLook, _ rgb: SIMD3<Float>) -> SIMD3<Float> {
        guard let g = look.grade else { return rgb }
        var c = simd_max(rgb, SIMD3(repeating: 0)) * g.gains
        if g.mono {
            let y = 0.2627 * c.x + 0.6780 * c.y + 0.0593 * c.z
            c = SIMD3(repeating: y)
        }
        func channel(_ v: Float) -> Float {
            guard v > 1e-6 else { return 0 }
            var x = 0.18 * exp2(log2(v / 0.18) * g.contrast)
            if x > g.knee {
                let over = x - g.knee
                x = g.knee + over / (1 + g.rolloff * over / (1 - g.knee))
            }
            return min(max(x, 0), 1)
        }
        return SIMD3(channel(c.x), channel(c.y), channel(c.z))
    }

    // MARK: Helpers

    private static func render(_ image: CIImage, _ bounds: CGRect, _ context: CIContext) -> [Float] {
        let w = Int(bounds.width), h = Int(bounds.height)
        var rgba = [Float](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(image.cropped(to: bounds), toBitmap: base, rowBytes: w * 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        return stride(from: 0, to: rgba.count, by: 4).map { rgba[$0] }
    }

    struct Component {
        var pixels: [Int] = []
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    }

    /// 8-connected components of a boolean mask (iterative flood fill).
    static func components(_ mask: [Bool], width w: Int, height h: Int) -> [Component] {
        var seen = [Bool](repeating: false, count: mask.count)
        var result: [Component] = []
        var stack: [Int] = []
        for start in mask.indices where mask[start] && !seen[start] {
            var component = Component()
            seen[start] = true
            stack.append(start)
            while let index = stack.popLast() {
                let x = index % w, y = index / w
                component.pixels.append(index)
                component.minX = min(component.minX, x); component.maxX = max(component.maxX, x)
                component.minY = min(component.minY, y); component.maxY = max(component.maxY, y)
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        let n = ny * w + nx
                        if mask[n] && !seen[n] {
                            seen[n] = true
                            stack.append(n)
                        }
                    }
                }
                // Huge regions are scene content, not defects: stop growing, it will be rejected.
                if component.pixels.count > 200_000 { stack.removeAll(); break }
            }
            result.append(component)
        }
        return result
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var copy = values
        let mid = copy.count / 2
        copy.withUnsafeMutableBufferPointer { buffer in
            buffer.sort()
        }
        return copy[mid]
    }

    static func boxMean(_ v: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
        var horizontal = [Float](repeating: 0, count: v.count)
        for y in 0..<h {
            var sum: Float = 0
            let row = y * w
            for x in 0..<min(r, w) { sum += v[row + x] }
            for x in 0..<w {
                if x + r < w { sum += v[row + x + r] }
                if x - r - 1 >= 0 { sum -= v[row + x - r - 1] }
                horizontal[row + x] = sum / Float(min(x + r, w - 1) - max(x - r, 0) + 1)
            }
        }
        var out = [Float](repeating: 0, count: v.count)
        for x in 0..<w {
            var sum: Float = 0
            for y in 0..<min(r, h) { sum += horizontal[y * w + x] }
            for y in 0..<h {
                if y + r < h { sum += horizontal[(y + r) * w + x] }
                if y - r - 1 >= 0 { sum -= horizontal[(y - r - 1) * w + x] }
                out[y * w + x] = sum / Float(min(y + r, h - 1) - max(y - r, 0) + 1)
            }
        }
        return out
    }

    static func dilate(_ mask: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        var out = mask
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] > 0 {
                for dy in -r...r {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -r...r where dx * dx + dy * dy <= r * r {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        out[ny * w + nx] = 255
                    }
                }
            }
        }
        return out
    }
}

nonisolated enum EnhanceKernels {
    struct Compiled: @unchecked Sendable {
        let hole: CIKernel
        let fill: CIKernel
        let look: CIKernel
        let difference: CIKernel
    }

    static let compiled: Compiled? = {
        do {
            let kernels = try CIKernel.kernels(withMetalString: metal)
            guard let hole = kernels.first(where: { $0.name == "dustHole" }),
                  let fill = kernels.first(where: { $0.name == "dustFill" }),
                  let look = kernels.first(where: { $0.name == "filmLook" }),
                  let difference = kernels.first(where: { $0.name == "signedDifference" }) else { return nil }
            return Compiled(hole: hole, fill: fill, look: look, difference: difference)
        } catch {
            enhanceLog.error("enhance kernels: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static let metal = """
    #include <CoreImage/CoreImage.h>
    using namespace coreimage;

    // Premultiplied "known pixels": rgb·(1−m), alpha (1−m). Blurring this and un-premultiplying
    // is a normalised convolution: the fill is an average of clean neighbours only.
    [[stitchable]] float4 dustHole(sample_t image, sample_t mask) {
        float keep = 1.0 - clamp(mask.r, 0.0, 1.0);
        return float4(image.rgb * keep, keep);
    }

    [[stitchable]] float4 dustFill(
        sample_t image, sample_t mask, sample_t small, sample_t large,
        sample_t grain, sample_t grainMask
    ) {
        float m = clamp(mask.r, 0.0, 1.0);
        if (m <= 0.0) { return image; }   // clean pixel: exactly the faithful value
        float3 fill = small.a > 0.4 ? small.rgb / small.a : large.rgb / max(large.a, 0.0001);
        float grainWeight = 1.0 - clamp(grainMask.r, 0.0, 1.0);
        fill += grain.rgb * grainWeight;
        return float4(mix(image.rgb, max(fill, float3(0.0)), m), image.a);
    }

    // a − b, signed (blend-mode filters may clamp at 0).
    [[stitchable]] float4 signedDifference(sample_t a, sample_t b) {
        return float4(a.rgb - b.rgb, 1.0);
    }

    // Colour balance (linear gains), contrast around 18 % grey, highlight roll-off above a knee.
    [[stitchable]] float4 filmLook(
        sample_t s, float gainR, float gainG, float gainB,
        float contrast, float knee, float rolloff, float mono
    ) {
        float3 c = max(s.rgb, float3(0.0)) * float3(gainR, gainG, gainB);
        if (mono > 0.5) {
            float y = dot(c, float3(0.2627, 0.6780, 0.0593));
            c = float3(y);
        }
        float3 outc;
        for (int i = 0; i < 3; i++) {
            float v = c[i];
            if (v <= 0.000001) { outc[i] = 0.0; continue; }
            float x = 0.18 * exp2(log2(v / 0.18) * contrast);
            if (x > knee) {
                float over = x - knee;
                x = knee + over / (1.0 + rolloff * over / (1.0 - knee));
            }
            outc[i] = clamp(x, 0.0, 1.0);
        }
        return float4(outc, s.a);
    }
    """
}
