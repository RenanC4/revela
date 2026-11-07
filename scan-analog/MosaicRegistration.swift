//
//  MosaicRegistration.swift
//  scan-analog
//
//  Pure registration logic for the 2×2 mosaic, on small grayscale density proxies.
//  No UIKit and no actor state, so it can be exercised off-device.
//

import CoreGraphics
import Foundation
import os
import simd
import Vision

nonisolated private let registrationLog = Logger(subsystem: "scan-analog", category: "registration")

nonisolated enum MosaicRegistration {
    struct GrayProxy {
        var values: [Float]
        var width: Int
        var height: Int
        var image: CGImage
        /// High-pass of `values` (grain and edges, smooth density removed). Fine correlation runs on this:
        /// raw density is dominated by low frequencies and scores well even when misaligned.
        var detail: [Float]
        /// Slightly blurred `detail`. Its correlation peak is a few px wide, so a coarse grid cannot step over it.
        var band: [Float]

        init(values: [Float], width: Int, height: Int, image: CGImage) {
            self.values = values
            self.width = width
            self.height = height
            self.image = image
            let smooth = GrayProxy.boxBlur(values, width: width, height: height, radius: 6)
            detail = zip(values, smooth).map { $0 - $1 }
            band = GrayProxy.boxBlur(detail, width: width, height: height, radius: 2)
        }

        /// Separable box blur with running sums (edges use the pixels that exist).
        static func boxBlur(_ v: [Float], width w: Int, height h: Int, radius r: Int) -> [Float] {
            guard w > 2 * r, h > 2 * r, r > 0 else { return v }
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
    }

    static func edgeSharpness(_ gray: GrayProxy) -> Float {
        let w = gray.width
        let h = gray.height
        func detail(_ xs: Range<Int>, _ ys: Range<Int>) -> Float {
            var sum: Float = 0
            var count = 0
            for y in ys where y > 0 && y < h - 1 {
                for x in xs where x > 0 && x < w - 1 {
                    let i = y * w + x
                    let lap = 4 * gray.values[i] - gray.values[i - 1] - gray.values[i + 1] - gray.values[i - w] - gray.values[i + w]
                    sum += abs(lap)
                    count += 1
                }
            }
            return count > 0 ? sum / Float(count) : 0
        }
        let centre = detail((w * 35 / 100)..<(w * 65 / 100), (h * 35 / 100)..<(h * 65 / 100))
        guard centre > 1e-4 else { return 1 }
        // The weakest of the four edge bands: outer tiles hold featureless rebate on two sides,
        // so take the second-best band to avoid flagging plain film base as blur.
        let bands = [
            detail(0..<(w * 15 / 100), (h / 4)..<(h * 3 / 4)),
            detail((w * 85 / 100)..<w, (h / 4)..<(h * 3 / 4)),
            detail((w / 4)..<(w * 3 / 4), 0..<(h * 15 / 100)),
            detail((w / 4)..<(w * 3 / 4), (h * 85 / 100)..<h),
        ].sorted(by: >)
        return bands[1] / centre
    }

    struct Layout {
        var placements: [MosaicPlacement]
        var canvas: CGSize
        var method: String
    }

    /// Pairwise registration (top row, bottom row, then the columns joining them), a spanning
    /// tree over the most confident edges, a loop-closure check, and Core Image placements.
    static func layout(proxies: [MosaicCorner: GrayProxy], fullSize: CGSize) throws -> Layout {
        guard let first = proxies[.topLeading], proxies.count == 4,
              proxies.values.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw MosaicError.registration(Set(MosaicCorner.allCases), "peças com tamanhos diferentes")
        }
        let shift = MosaicPlan.shifts(imageAspect: CGFloat(first.width) / CGFloat(first.height))
        let pairs: [(MosaicCorner, MosaicCorner, Bool)] = [
            (.topLeading, .topTrailing, true),
            (.bottomLeading, .bottomTrailing, true),
            (.topLeading, .bottomLeading, false),
            (.topTrailing, .bottomTrailing, false),
        ]
        var edges: [Edge] = []
        for (reference, target, horizontal) in pairs {
            guard let a = proxies[reference], let b = proxies[target] else { continue }
            if let edge = registerPair(a, b, horizontal: horizontal, shift: horizontal ? shift.x : shift.y) {
                registrationLog.info("\(reference.rawValue)→\(target.rawValue) \(edge.method, privacy: .public) ncc \(edge.confidence) t \(edge.transform.tx) \(edge.transform.ty)")
                edges.append(Edge(reference: reference, target: target, transform: edge.transform, confidence: edge.confidence, method: edge.method))
            } else {
                registrationLog.error("\(reference.rawValue)→\(target.rawValue) failed")
            }
        }

        let sorted = edges.sorted { $0.confidence > $1.confidence }
        guard let anchor = sorted.first?.reference else {
            throw MosaicError.registration(Set(MosaicCorner.allCases), "nenhum par alinhou")
        }
        var placed: [MosaicCorner: CGAffineTransform] = [anchor: .identity]
        var used = Set<Int>()
        var progress = true
        while progress {
            progress = false
            for (index, edge) in sorted.enumerated() where !used.contains(index) {
                if let ref = placed[edge.reference], placed[edge.target] == nil {
                    placed[edge.target] = edge.transform.concatenating(ref)
                } else if let target = placed[edge.target], placed[edge.reference] == nil {
                    placed[edge.reference] = edge.transform.inverted().concatenating(target)
                } else {
                    continue
                }
                used.insert(index)
                progress = true
            }
        }
        let missing = Set(MosaicCorner.allCases).subtracting(placed.keys)
        guard missing.isEmpty else {
            throw MosaicError.registration(missing, "sem sobreposição reconhecível")
        }
        for (index, edge) in sorted.enumerated() where !used.contains(index) {
            guard let ref = placed[edge.reference], let target = placed[edge.target] else { continue }
            let centre = CGPoint(x: CGFloat(first.width) / 2, y: CGFloat(first.height) / 2)
            let viaEdge = centre.applying(edge.transform.concatenating(ref))
            let direct = centre.applying(target)
            let error = hypot(viaEdge.x - direct.x, viaEdge.y - direct.y)
            if error > CGFloat(first.width) * 0.03 {
                throw MosaicError.registration([edge.reference, edge.target], String(format: "pares incoerentes, %.0f px", error))
            }
        }

        // Proxy raster → full-resolution raster → canvas raster → Core Image (y up).
        let kx = fullSize.width / CGFloat(first.width)
        let ky = fullSize.height / CGFloat(first.height)
        let scale = CGAffineTransform(scaleX: kx, y: ky)
        var fullPlacements: [MosaicCorner: CGAffineTransform] = [:]
        var union = CGRect.null
        for (corner, transform) in placed {
            let full = scale.inverted().concatenating(transform).concatenating(scale)
            fullPlacements[corner] = full
            union = union.union(CGRect(origin: .zero, size: fullSize).applying(full))
        }
        guard union.width <= fullSize.width * 2.2, union.height <= fullSize.height * 2.2,
              union.width < 16_000, union.height < 16_000 else {
            throw MosaicError.registration(Set(MosaicCorner.allCases), "deslocamento sem sobreposição")
        }
        let margin: CGFloat = 16
        let canvas = CGSize(width: (union.width + margin * 2).rounded(.up), height: (union.height + margin * 2).rounded(.up))
        let toCanvas = CGAffineTransform(translationX: -union.minX + margin, y: -union.minY + margin)
        let tileFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: fullSize.height)
        let canvasFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height)
        let confidence = Dictionary(edges.map { ($0.target, Double($0.confidence)) }, uniquingKeysWith: max)
        let placements = MosaicCorner.allCases.compactMap { corner -> MosaicPlacement? in
            guard let full = fullPlacements[corner] else { return nil }
            let ci = tileFlip.concatenating(full).concatenating(toCanvas).concatenating(canvasFlip)
            return MosaicPlacement(corner: corner, transform: ci, confidence: corner == anchor ? 1 : confidence[corner] ?? 0)
        }
        registrationLog.info("canvas \(Int(canvas.width))x\(Int(canvas.height)) from tile \(Int(fullSize.width))x\(Int(fullSize.height))")
        return Layout(placements: placements, canvas: canvas, method: Set(edges.map(\.method)).sorted().joined(separator: "+"))
    }

    struct Edge {
        var reference: MosaicCorner
        var target: MosaicCorner
        /// Target raster pixel → reference raster pixel (proxy scale, y down).
        var transform: CGAffineTransform
        var confidence: Float
        var method: String
    }

    /// Target → reference transform for one overlapping pair, or nil if the overlap is not convincing.
    /// 1. Vision translational registration on the expected overlap bands.
    /// 2. Vision homographic registration reduced to a similarity (no perspective warp).
    /// 3. Normalised cross-correlation search around the expected shift.
    static func registerPair(_ a: GrayProxy, _ b: GrayProxy, horizontal: Bool, shift: CGFloat)
        -> (transform: CGAffineTransform, confidence: Float, method: String)? {
        let w = CGFloat(a.width)
        let h = CGFloat(a.height)
        // On the high-pass layer: true overlaps of the same film score well above this, shifted ones near 0.
        let threshold: Float = 0.35
        let band = min(1, 1 - shift + 0.25)
        let bandA: CGRect
        let bandB: CGRect
        if horizontal {
            let bw = (w * band).rounded()
            bandA = CGRect(x: w - bw, y: 0, width: bw, height: h)
            bandB = CGRect(x: 0, y: 0, width: bw, height: h)
        } else {
            let bh = (h * band).rounded()
            bandA = CGRect(x: 0, y: h - bh, width: w, height: bh)
            bandB = CGRect(x: 0, y: 0, width: w, height: bh)
        }
        let bandOffset = CGPoint(x: bandA.minX - bandB.minX, y: bandA.minY - bandB.minY)

        func plausible(_ t: CGAffineTransform) -> Bool {
            if horizontal {
                return t.tx > w * 0.05 && t.tx < w * 0.95 && abs(t.ty) < h * 0.25
            }
            return t.ty > h * 0.05 && t.ty < h * 0.95 && abs(t.tx) < w * 0.25
        }
        func best(_ candidates: [CGAffineTransform], refine: Bool) -> (CGAffineTransform, Float)? {
            var winner: (CGAffineTransform, Float)?
            for candidate in candidates where plausible(candidate) {
                let scored = refine ? refineTranslation(a, b, candidate, radius: 12) : (candidate, ncc(a, b, candidate, stride: 2))
                if scored.1 > (winner?.1 ?? -1) { winner = scored }
            }
            return winner
        }

        guard let cropA = a.image.cropping(to: bandA), let cropB = b.image.cropping(to: bandB) else { return nil }

        // 1. Translation. Vision's sign and y convention are checked against the pixels, not assumed.
        let translational = VNTranslationalImageRegistrationRequest(targetedCGImage: cropB, options: [:], completionHandler: nil)
        if (try? VNImageRequestHandler(cgImage: cropA, options: [:]).perform([translational])) != nil,
           let observation = translational.results?.first {
            let t = observation.alignmentTransform
            let candidates = [(1, 1), (1, -1), (-1, 1), (-1, -1)].map { sx, sy in
                CGAffineTransform(translationX: CGFloat(sx) * t.tx + bandOffset.x, y: CGFloat(sy) * t.ty + bandOffset.y)
            }
            if let (transform, score) = best(candidates, refine: true), score >= threshold {
                return (transform, score, "vision-translation")
            }
        }

        // 2. Similarity from the homography: translation + small rotation + uniform scale only.
        let homographic = VNHomographicImageRegistrationRequest(targetedCGImage: cropB, options: [:], completionHandler: nil)
        if (try? VNImageRequestHandler(cgImage: cropA, options: [:]).perform([homographic])) != nil,
           let observation = homographic.results?.first {
            let matrix = observation.warpTransform
            let size = bandB.size
            let flip = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -1, Float(size.height)), SIMD3(0, 0, 1)])
            let variants = [matrix, matrix.inverse, flip * matrix * flip, flip * matrix.inverse * flip]
            let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            var candidates: [CGAffineTransform] = []
            for variant in variants {
                let mapped = corners.map { point -> CGPoint in
                    let p = variant * SIMD3(Float(point.x), Float(point.y), 1)
                    return CGPoint(x: CGFloat(p.x / p.z), y: CGFloat(p.y / p.z))
                }
                guard let similarity = similarity(from: corners, to: mapped) else { continue }
                let rotation = atan2(similarity.b, similarity.a) * 180 / .pi
                let scale = hypot(similarity.a, similarity.b)
                guard abs(rotation) <= 3, scale > 0.97, scale < 1.03 else { continue }
                // Band coordinates → full proxy coordinates.
                let full = CGAffineTransform(translationX: -bandB.minX, y: -bandB.minY)
                    .concatenating(similarity)
                    .concatenating(CGAffineTransform(translationX: bandA.minX, y: bandA.minY))
                candidates.append(full)
            }
            if let (transform, score) = best(candidates, refine: false), score >= threshold {
                return (transform, score, "vision-similarity")
            }
        }

        // 3. Correlation search on the pixels around the expected slide.
        let expected = horizontal ? CGPoint(x: shift * w, y: 0) : CGPoint(x: 0, y: shift * h)
        let rangeX = horizontal ? (max(w * 0.05, expected.x - w * 0.3)...min(w * 0.95, expected.x + w * 0.3)) : (-w * 0.15...w * 0.15)
        let rangeY = horizontal ? (-h * 0.15...h * 0.15) : (max(h * 0.05, expected.y - h * 0.3)...min(h * 0.95, expected.y + h * 0.3))
        var winner: (CGAffineTransform, Float)?
        var y = rangeY.lowerBound
        while y <= rangeY.upperBound {
            var x = rangeX.lowerBound
            while x <= rangeX.upperBound {
                let candidate = CGAffineTransform(translationX: x.rounded(), y: y.rounded())
                let score = ncc(a, b, candidate, stride: 6, coarse: true)
                if score > (winner?.1 ?? -1) { winner = (candidate, score) }
                x += 3
            }
            y += 3
        }
        if let coarse = winner {
            let refined = refineTranslation(a, b, coarse.0, radius: 4)
            if refined.1 >= threshold {
                return (refined.0, refined.1, "ncc")
            }
        }
        return nil
    }

    /// Integer search ±radius px around a translation: coarse 3 px steps, then 1 px around the best.
    static func refineTranslation(_ a: GrayProxy, _ b: GrayProxy, _ start: CGAffineTransform, radius: Int = 3)
        -> (CGAffineTransform, Float) {
        func search(_ centre: CGAffineTransform, _ radius: Int, _ step: Int, _ stride: Int, coarse: Bool = false) -> (CGAffineTransform, Float) {
            var best = (centre, ncc(a, b, centre, stride: stride, coarse: coarse))
            for dy in Swift.stride(from: -radius, through: radius, by: step) {
                for dx in Swift.stride(from: -radius, through: radius, by: step) where dx != 0 || dy != 0 {
                    let candidate = CGAffineTransform(translationX: (centre.tx + CGFloat(dx)).rounded(), y: (centre.ty + CGFloat(dy)).rounded())
                    let score = ncc(a, b, candidate, stride: stride, coarse: coarse)
                    if score > best.1 { best = (candidate, score) }
                }
            }
            return best
        }
        let coarse = radius > 4 ? search(start, radius, 3, 3, coarse: true).0 : start
        return search(coarse, 3, 1, 2)
    }

    /// Normalised cross-correlation over the overlap of `b` mapped into `a`. −1 if the overlap is tiny.
    static func ncc(_ a: GrayProxy, _ b: GrayProxy, _ transform: CGAffineTransform, stride step: Int, coarse: Bool = false) -> Float {
        var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        let aw = a.width, ah = a.height
        (coarse ? a.band : a.detail).withUnsafeBufferPointer { av in
            (coarse ? b.band : b.detail).withUnsafeBufferPointer { bv in
                var y = 0
                while y < b.height {
                    var x = 0
                    while x < b.width {
                        let px = transform.a * CGFloat(x) + transform.c * CGFloat(y) + transform.tx
                        let py = transform.b * CGFloat(x) + transform.d * CGFloat(y) + transform.ty
                        let ix = Int(px.rounded()), iy = Int(py.rounded())
                        if ix >= 0, iy >= 0, ix < aw, iy < ah {
                            let va = Double(av[iy * aw + ix])
                            let vb = Double(bv[y * b.width + x])
                            n += 1; sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb
                        }
                        x += step
                    }
                    y += step
                }
            }
        }
        let overlap = n * Double(step * step) / Double(b.width * b.height)
        guard n >= 200, overlap >= 0.05 else { return -1 }
        let cov = sab - sa * sb / n
        let va = saa - sa * sa / n
        let vb = sbb - sb * sb / n
        guard va > 1e-9, vb > 1e-9 else { return -1 }
        return Float(cov / (va * vb).squareRoot())
    }

    /// Least-squares similarity (uniform scale, rotation, translation) mapping p → q.
    static func similarity(from p: [CGPoint], to q: [CGPoint]) -> CGAffineTransform? {
        guard p.count == q.count, p.count >= 2 else { return nil }
        let n = CGFloat(p.count)
        let pc = CGPoint(x: p.map(\.x).reduce(0, +) / n, y: p.map(\.y).reduce(0, +) / n)
        let qc = CGPoint(x: q.map(\.x).reduce(0, +) / n, y: q.map(\.y).reduce(0, +) / n)
        var sxx: CGFloat = 0, sxy: CGFloat = 0, norm: CGFloat = 0
        for (pi, qi) in zip(p, q) {
            let px = pi.x - pc.x, py = pi.y - pc.y
            let qx = qi.x - qc.x, qy = qi.y - qc.y
            sxx += px * qx + py * qy
            sxy += px * qy - py * qx
            norm += px * px + py * py
        }
        guard norm > 1e-6 else { return nil }
        let a = sxx / norm
        let b = sxy / norm
        guard a.isFinite, b.isFinite else { return nil }
        // x' = a x − b y + tx ; y' = b x + a y + ty
        let tx = qc.x - (a * pc.x - b * pc.y)
        let ty = qc.y - (b * pc.x + a * pc.y)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

}
