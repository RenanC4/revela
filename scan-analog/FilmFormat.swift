//
//  FilmFormat.swift
//  scan-analog
//

import CoreGraphics
import Foundation

nonisolated enum FilmFormat: String, CaseIterable, Identifiable, Sendable {
    case mm35
    case square6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mm35: return "35 mm"
        case .square6: return "6×6"
        }
    }

    private var imageMillimetres: CGSize {
        switch self {
        case .mm35: return CGSize(width: 36, height: 24)
        case .square6: return CGSize(width: 56, height: 56)
        }
    }

    /// Film base outside the picture, on each side.
    /// 35 mm stock is 35 mm wide across the 24 mm frame, with about 2 mm of base between frames.
    /// 120 stock is about 61.5 mm wide across a 56 mm square.
    private var rebateMillimetres: (horizontal: CGFloat, vertical: CGFloat) {
        switch self {
        case .mm35:
            return (horizontal: 2, vertical: (35 - 24) / 2)
        case .square6:
            let side = (61.5 - 56) / 2
            return (horizontal: side, vertical: side)
        }
    }

    func layout(filling rect: CGRect) -> FilmLayout {
        let image = imageMillimetres
        let rebate = rebateMillimetres
        let outerMillimetres = CGSize(
            width: image.width + rebate.horizontal * 2,
            height: image.height + rebate.vertical * 2
        )
        let scale = min(rect.width / outerMillimetres.width, rect.height / outerMillimetres.height)
        let outerSize = CGSize(width: outerMillimetres.width * scale, height: outerMillimetres.height * scale)
        let outer = CGRect(
            x: rect.midX - outerSize.width / 2,
            y: rect.midY - outerSize.height / 2,
            width: outerSize.width,
            height: outerSize.height
        )
        let innerSize = CGSize(width: image.width * scale, height: image.height * scale)
        let inner = CGRect(
            x: outer.midX - innerSize.width / 2,
            y: outer.midY - innerSize.height / 2,
            width: innerSize.width,
            height: innerSize.height
        )
        return FilmLayout(outer: outer, inner: inner)
    }
}

nonisolated struct FilmLayout: Equatable, Sendable {
    var outer: CGRect
    var inner: CGRect

    func rebateRects(sidesOnly: Bool) -> [CGRect] {
        let top = CGRect(
            x: outer.minX,
            y: outer.minY,
            width: outer.width,
            height: max(0, inner.minY - outer.minY)
        )
        let bottom = CGRect(
            x: outer.minX,
            y: inner.maxY,
            width: outer.width,
            height: max(0, outer.maxY - inner.maxY)
        )
        let left = CGRect(
            x: outer.minX,
            y: inner.minY,
            width: max(0, inner.minX - outer.minX),
            height: inner.height
        )
        let right = CGRect(
            x: inner.maxX,
            y: inner.minY,
            width: max(0, outer.maxX - inner.maxX),
            height: inner.height
        )
        let rects = sidesOnly ? [left, right] : [top, bottom, left, right]
        return rects.filter { $0.width >= 1 && $0.height >= 1 }
    }
}

nonisolated struct CaptureGeometry: Sendable {
    var format: FilmFormat
    var viewSize: CGSize
    var outer: CGRect
    var inner: CGRect
    var angle: CGFloat

    var layout: FilmLayout {
        FilmLayout(outer: outer, inner: inner)
    }
}

nonisolated enum FilmType: String, CaseIterable, Identifiable, Sendable {
    case colorNegative
    case chromogenicBW
    case silverBW
    case slideE6
    case ecn2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .colorNegative: return "Negativo cor"
        case .chromogenicBW: return "Cromogénico P&B"
        case .silverBW: return "Prata P&B"
        case .slideE6: return "Diapositivo E-6"
        case .ecn2: return "ECN-2"
        }
    }

    /// 0 slide, 1 silver, 2 chromogenic, 3 color negative and ECN-2.
    var kernelMode: Float {
        switch self {
        case .slideE6: return 0
        case .silverBW: return 1
        case .chromogenicBW: return 2
        case .colorNegative, .ecn2: return 3
        }
    }

    /// Slope of the negative's characteristic curve (density per log10 exposure).
    var negativeGamma: Float {
        switch self {
        case .silverBW: return 0.65
        default: return 0.6
        }
    }

    var inverts: Bool {
        self != .slideE6
    }
}

nonisolated enum CaptureKind: Sendable, Equatable {
    case frame
    case flatField
    /// One corner of a 2×2 mosaic (6×6 through a clip-on macro).
    case tile(MosaicCorner)
}

nonisolated struct RGBColor: Sendable, Equatable {
    var r: Float
    var g: Float
    var b: Float

    static let white = RGBColor(r: 1, g: 1, b: 1)
    static let zero = RGBColor(r: 0, g: 0, b: 0)

    var isUsable: Bool {
        r > 0.02 && g > 0.02 && b > 0.02
    }
}

/// Densities are −log10 of flat-fielded linear transmittance.
/// `span` is Dmax − Dmin, the divisor that stretches D' onto 0…1.
nonisolated struct DensityStretch: Sendable, Equatable {
    var rebateLinear: RGBColor
    var dmin: RGBColor
    var dmax: RGBColor
    var span: RGBColor
    /// Display code of D'' = 0 (rebate, prints black) and D'' = 1 (gate Dmax, prints white) through the print curve.
    var rebateCode: Float
    var highlightCode: Float
    /// Display codes (0…255) of the rendered positive, 1st and 99th percentile of luma.
    var outputLow: Float
    var outputHigh: Float

    var outputSpan: Float { outputHigh - outputLow }

    var rangeText: String {
        String(
            format: "rebate %.2f %.2f %.2f · Dmin %.3f %.3f %.3f · Δ %.3f %.3f %.3f · curva %.0f→%.0f · foto %.0f–%.0f",
            rebateLinear.r, rebateLinear.g, rebateLinear.b,
            dmin.r, dmin.g, dmin.b,
            span.r, span.g, span.b,
            rebateCode, highlightCode,
            outputLow, outputHigh
        )
    }
}

nonisolated struct RollProfile: Sendable, Equatable {
    var filmType: FilmType
    var dmin: RGBColor
    var gain: RGBColor
    var linearBase: RGBColor
    var stretch: DensityStretch?
}

nonisolated enum GuideMapping {
    /// Maps a rect drawn on the aspect-fill preview into the upright image.
    /// View space has its origin at the top left. Core Image has its origin at the bottom left.
    nonisolated static func imageRect(viewRect: CGRect, viewSize: CGSize, extent: CGRect) -> CGRect {
        guard viewSize.width > 1, viewSize.height > 1, extent.width > 1, extent.height > 1 else {
            return .null
        }
        let scale = max(viewSize.width / extent.width, viewSize.height / extent.height)
        let displayedWidth = extent.width * scale
        let displayedHeight = extent.height * scale
        let cropX = (displayedWidth - viewSize.width) / 2
        let cropY = (displayedHeight - viewSize.height) / 2

        let width = viewRect.width / scale
        let height = viewRect.height / scale
        let x = extent.minX + (viewRect.minX + cropX) / scale
        let yFromTop = (viewRect.minY + cropY) / scale
        let y = extent.minY + extent.height - yFromTop - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
