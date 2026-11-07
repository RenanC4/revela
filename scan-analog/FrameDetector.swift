//
//  FrameDetector.swift
//  scan-analog
//
//  Finds the film gate (picture area) on the UNINVERTED linear capture with Vision, classifies
//  35 mm vs 6×6 from its aspect, and derives the rebate ring outside it. Dmin is sampled only there.
//

import CoreGraphics
import Foundation
import os
import Vision

nonisolated private let detectorLog = Logger(subsystem: "scan-analog", category: "gate")

/// Picture area found on the negative, in the source image's Core Image coordinates (y up).
nonisolated struct GateDetection: Sendable, Equatable {
    var gate: CGRect
    /// 35 mm (3:2) or 6×6 (1:1) from the gate aspect; nil when it matches neither.
    var format: FilmFormat?
    var confidence: Float
    /// Rotation of the gate's top edge, degrees. The crop stays axis-aligned; this is reported, not corrected.
    var skewDegrees: Double
    var method: String

    /// The gate as a fraction of `extent` (top-left origin), independent of decode resolution.
    func normalized(in extent: CGRect) -> CGRect {
        CGRect(
            x: (gate.minX - extent.minX) / extent.width,
            y: (extent.maxY - gate.maxY) / extent.height,
            width: gate.width / extent.width,
            height: gate.height / extent.height
        )
    }

    static func denormalize(_ rect: CGRect, in extent: CGRect) -> CGRect {
        CGRect(
            x: extent.minX + rect.minX * extent.width,
            y: extent.maxY - rect.maxY * extent.height,
            width: rect.width * extent.width,
            height: rect.height * extent.height
        )
    }
}

nonisolated enum FrameDetector {
    /// Long ÷ short side of each picture area.
    static func aspect(of format: FilmFormat) -> CGFloat {
        switch format {
        case .mm35: return 36.0 / 24.0
        case .square6: return 1
        }
    }

    /// 35 mm vs 6×6 from a gate's long/short ratio, or nil if neither is close.
    static func classify(longOverShort ratio: CGFloat) -> FilmFormat? {
        if abs(ratio - 1.5) <= 0.17 { return .mm35 }
        if abs(ratio - 1.0) <= 0.10 { return .square6 }
        return nil
    }

    /// Vision rectangle detection on a grayscale density proxy of the negative.
    /// - Parameters:
    ///   - proxy: top-left-origin grayscale image covering `extent`.
    ///   - expected: the format the user picked, preferred when two candidates tie.
    ///   - guide: where the on-screen guide says the picture is (image coordinates), if any.
    static func detectGate(proxy: CGImage, extent: CGRect, expected: FilmFormat?, guide: CGRect?) -> GateDetection? {
        let request = VNDetectRectanglesRequest()
        // Vision's aspect ratio is short ÷ long: 35 mm is 0.667, 6×6 is 1.
        request.minimumAspectRatio = 0.5
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 12
        request.minimumSize = 0.25
        request.minimumConfidence = 0.3
        request.maximumObservations = 12
        do {
            try VNImageRequestHandler(cgImage: proxy, options: [:]).perform([request])
        } catch {
            detectorLog.error("rectangles failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }

        var best: (GateDetection, Double)?
        for observation in observations {
            // Vision's normalised box has a bottom-left origin, like Core Image.
            let box = observation.boundingBox
            let rect = CGRect(
                x: extent.minX + box.minX * extent.width,
                y: extent.minY + box.minY * extent.height,
                width: box.width * extent.width,
                height: box.height * extent.height
            )
            let area = (rect.width * rect.height) / (extent.width * extent.height)
            // The whole picture (holder window, bare light) is not the gate.
            guard area > 0.12, area < 0.97 else { continue }
            let ratio = max(rect.width, rect.height) / max(min(rect.width, rect.height), 1)
            guard let format = classify(longOverShort: ratio) else { continue }
            let aspectError = abs(ratio - aspect(of: format)) / aspect(of: format)
            var score = Double(observation.confidence) * exp(-pow(Double(aspectError) / 0.05, 2))
            if let expected, expected == format { score *= 1.5 }
            if let guide {
                score *= 0.25 + 0.75 * Double(intersectionOverUnion(rect, guide))
            }
            let dx = Double(observation.topRight.x - observation.topLeft.x) * Double(extent.width)
            let dy = Double(observation.topRight.y - observation.topLeft.y) * Double(extent.height)
            let detection = GateDetection(
                gate: rect,
                format: format,
                confidence: observation.confidence,
                skewDegrees: atan2(dy, dx) * 180 / .pi,
                method: "vision-rectangle"
            )
            if score > (best?.1 ?? 0) { best = (detection, score) }
        }
        guard let best, best.1 > 0.15 else { return nil }
        detectorLog.info("gate \(best.0.gate.debugDescription, privacy: .public) \(best.0.format?.title ?? "?", privacy: .public) score \(best.1)")
        return best.0
    }

    /// Unexposed film base outside the gate. 35 mm: the sprocket bands along the long sides
    /// (sprocket holes are rejected later as bright neutral pixels) and the thin gaps between frames.
    /// 120: a thin margin all round. A small gap off the gate edge keeps picture spill out.
    static func rebateRects(around gate: CGRect, format: FilmFormat, within extent: CGRect) -> [CGRect] {
        let landscape = gate.width >= gate.height
        let longMM: CGFloat = format == .mm35 ? 36 : 56
        let pixelsPerMM = max(gate.width, gate.height) / longMM
        func band(_ fromMM: CGFloat, _ toMM: CGFloat) -> (CGFloat, CGFloat) { (fromMM * pixelsPerMM, toMM * pixelsPerMM) }
        // (start, end) distance from the gate edge, in pixels, for the long and the short edges.
        let alongLongEdges: (CGFloat, CGFloat)
        let alongShortEdges: (CGFloat, CGFloat)
        switch format {
        case .mm35:
            alongLongEdges = band(0.4, 5.0)
            alongShortEdges = band(0.25, 0.9)
        case .square6:
            alongLongEdges = band(0.3, 2.4)
            alongShortEdges = band(0.3, 2.4)
        }
        let horizontalEdges = landscape ? alongLongEdges : alongShortEdges  // top and bottom
        let verticalEdges = landscape ? alongShortEdges : alongLongEdges     // left and right
        let rects = [
            CGRect(x: gate.minX, y: gate.maxY + horizontalEdges.0, width: gate.width, height: horizontalEdges.1 - horizontalEdges.0),
            CGRect(x: gate.minX, y: gate.minY - horizontalEdges.1, width: gate.width, height: horizontalEdges.1 - horizontalEdges.0),
            CGRect(x: gate.minX - verticalEdges.1, y: gate.minY, width: verticalEdges.1 - verticalEdges.0, height: gate.height),
            CGRect(x: gate.maxX + verticalEdges.0, y: gate.minY, width: verticalEdges.1 - verticalEdges.0, height: gate.height),
        ]
        return rects.map { $0.intersection(extent) }.filter { !$0.isNull && $0.width >= 2 && $0.height >= 2 }
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}
