//
//  PositivePrint.swift
//  scan-analog
//
//  Shared print model: negative density → scene linear → "paper" tone curve.
//  Used by the RAW processor and by the live camera positive.
//

import CoreImage
import Foundation
import os

/// Where the automatic black and white points come from.
nonisolated enum AutoLevels: String, CaseIterable, Identifiable, Sendable {
    /// Median of the roll's frames: one exposure and colour balance for the whole film, like a lab print run.
    case roll
    /// This frame's own 0.2 % / 99.5 % densities: rescues odd frames, but brightness follows content.
    case frame
    /// Rebate Dmin and the first frame's Dmax only.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roll: return "Rolo"
        case .frame: return "Fotograma"
        case .off: return "Desligado"
        }
    }
}

/// Per-channel densities printed as black (`low`) and white (`high`).
nonisolated struct DensityLevels: Sendable, Equatable {
    var low: RGBColor
    var high: RGBColor
}

/// User adjustments for one frame. Neutral values leave the automatic print untouched.
nonisolated struct Adjustments: Sendable, Equatable {
    /// Stops.
    var exposure: Double = 0
    /// Slope around 18 % grey. 1 is the negative's own contrast.
    var contrast: Double = 1
    /// −1 cool … +1 warm.
    var temperature: Double = 0
    /// −1 green … +1 magenta.
    var tint: Double = 0
    /// −1 … +1, only above grey.
    var highlights: Double = 0
    /// −1 … +1, only below grey.
    var shadows: Double = 0
    /// 0 grey … 2 double.
    var saturation: Double = 1
    /// Black and white point per channel (colour balance and levels).
    var autoLevels: AutoLevels = .roll
    /// Find the frame edges instead of trusting the guide.
    var autoCrop = true
    /// Extra crop as a fraction of the frame: positive trims, negative keeps a thin rebate.
    var cropInset: Double = 0
    /// Crop the user dragged, as a fraction of the uncropped capture (top-left origin, unrotated).
    /// Overrides detection; nil means automatic.
    var manualCrop: CGRect?

    static let neutral = Adjustments()

    var isNeutralTone: Bool {
        abs(exposure) < 0.05 && abs(contrast - 1) < 0.05 && abs(highlights) < 0.05 && abs(shadows) < 0.05
    }
}

/// Everything the print kernel needs for one frame.
nonisolated struct PrintParameters: Sendable, Equatable {
    /// 0 slide, 1 silver, 2 chromogenic, 3 colour negative.
    var mode: Float
    /// Density printed as black (per channel). Slides ignore it.
    var black: RGBColor
    /// 1 / (density printed as white − black). Slides use `gain.r` as a linear scale.
    var gain: RGBColor
    /// Log10 scene range between black and white: density span / negative gamma.
    var range: Float
    var exposure: Float
    var contrast: Float
    var temperature: Float
    var tint: Float
    var highlights: Float
    var shadows: Float
    var saturation: Float

    init(mode: Float, black: RGBColor, gain: RGBColor, range: Float, adjustments: Adjustments) {
        self.mode = mode
        self.black = black
        self.gain = gain
        self.range = range
        exposure = Float(adjustments.exposure)
        contrast = Float(max(adjustments.contrast, 0.05))
        temperature = Float(adjustments.temperature)
        tint = Float(adjustments.tint)
        highlights = Float(adjustments.highlights)
        shadows = Float(adjustments.shadows)
        saturation = Float(max(adjustments.saturation, 0))
    }

    var kernelArguments: [Any] {
        [
            mode,
            black.r, black.g, black.b,
            gain.r, gain.g, gain.b,
            range, exposure, contrast,
            temperature, tint, highlights, shadows, saturation,
        ].map { NSNumber(value: $0) }
    }

    // MARK: CPU mirror of the Metal kernel

    func apply(red: Float, green: Float, blue: Float) -> RGBColor {
        let eps: Float = 1e-4
        let r = max(red, eps)
        let g = max(green, eps)
        let b = max(blue, eps)
        if mode < 0.5 {
            return finish(RGBColor(r: r * gain.r, g: g * gain.r, b: b * gain.r))
        }
        var x: RGBColor
        if mode < 1.5 {
            let luma = 0.2627 * r + 0.6780 * g + 0.0593 * b
            let value = max(-log10(max(luma, eps)) - black.r, 0) * gain.r
            x = RGBColor(r: value, g: value, b: value)
        } else {
            x = RGBColor(
                r: max(-log10(r) - black.r, 0) * gain.r,
                g: max(-log10(g) - black.g, 0) * gain.g,
                b: max(-log10(b) - black.b, 0) * gain.b
            )
            if mode < 2.5 {
                let average = (x.r + x.g + x.b) / 3
                x = RGBColor(r: average, g: average, b: average)
            }
        }
        return finish(RGBColor(r: sceneLinear(x.r), g: sceneLinear(x.g), b: sceneLinear(x.b)))
    }

    /// Stretched density 0 (black) … 1 (white) to scene linear 0 … 1.
    func sceneLinear(_ x: Float) -> Float {
        let floor = pow(10, -range)
        return (pow(10, range * (x - 1)) - floor) / max(1 - floor, 1e-4)
    }

    /// White balance, exposure, contrast, highlights, shadows, shoulder, saturation.
    func finish(_ input: RGBColor) -> RGBColor {
        var c = RGBColor(
            r: input.r * exp2(temperature * 0.35),
            g: input.g * exp2(-tint * 0.3),
            b: input.b * exp2(-temperature * 0.35)
        )
        let lift = exp2(exposure)
        c = RGBColor(r: c.r * lift, g: c.g * lift, b: c.b * lift)
        func tone(_ value: Float) -> Float {
            guard value > 1e-6 else { return 0 }
            var stops = log2(value / 0.18) * contrast
            stops += shadows * 1.5 * min(max(-stops / 4, 0), 1)
            stops += highlights * min(max(stops / 2.5, 0), 1)
            let linear = 0.18 * exp2(stops)
            let knee: Float = 0.7
            let over = max(linear - knee, 0)
            return min(linear, knee) + (1 - knee) * (1 - exp(-over / (1 - knee)))
        }
        var y = RGBColor(r: tone(c.r), g: tone(c.g), b: tone(c.b))
        let luma = 0.2627 * y.r + 0.6780 * y.g + 0.0593 * y.b
        y = RGBColor(
            r: min(max(luma + (y.r - luma) * saturation, 0), 1),
            g: min(max(luma + (y.g - luma) * saturation, 0), 1),
            b: min(max(luma + (y.b - luma) * saturation, 0), 1)
        )
        return y
    }

    /// Display code (0…255, sRGB curve) of a neutral stretched density through the whole print.
    func code(atStretched x: Float) -> Float {
        let value: Float
        if mode < 0.5 {
            value = finish(RGBColor(r: x, g: x, b: x)).g
        } else {
            let linear = sceneLinear(x)
            value = finish(RGBColor(r: linear, g: linear, b: linear)).g
        }
        return PositiveKernels.displayCode(value)
    }
}

nonisolated private let kernelLog = Logger(subsystem: "scan-analog", category: "kernel")

nonisolated enum PositiveKernels {
    struct Compiled: @unchecked Sendable {
        let flatField: CIKernel
        let positive: CIKernel
        /// Feathered, normalised mosaic weight times one tile (premultiplied: rgb·w, w).
        let mosaicContribution: CIKernel
    }

    /// Compiled once, on first use, from any thread.
    static let compiled: Compiled? = {
        do {
            let kernels = try CIKernel.kernels(withMetalString: metal)
            guard let flat = kernels.first(where: { $0.name == "flatField" }),
                  let positive = kernels.first(where: { $0.name == "positive" }),
                  let mosaic = kernels.first(where: { $0.name == "mosaicContribution" }) else {
                kernelLog.error("CIKernel sem as funções esperadas: \(kernels.map(\.name), privacy: .public)")
                return nil
            }
            return Compiled(flatField: flat, positive: positive, mosaicContribution: mosaic)
        } catch {
            kernelLog.error("CIKernel não compilou: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func displayCode(_ linear: Float) -> Float {
        let x = min(max(linear, 0), 1)
        let encoded: Float = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return min(max(encoded, 0), 1) * 255
    }

    static func positive(_ image: CIImage, _ parameters: PrintParameters) -> CIImage? {
        guard let kernel = compiled?.positive else { return nil }
        return kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image] + parameters.kernelArguments
        )
    }

    static let metal = """
    #include <CoreImage/CoreImage.h>

    using namespace coreimage;

    [[stitchable]] float4 flatField(sample_t image, sample_t light) {
        float eps = 0.0001;
        return float4(
            image.r / max(light.r, eps),
            image.g / max(light.g, eps),
            image.b / max(light.b, eps),
            1.0
        );
    }

    // Weight of one tile at canvas point p: m/t map p into the tile's 0…1 square,
    // t.zw are the feather widths. A cosine-like ramp only near the tile's own edges.
    inline float mosaicWeight(float2 p, float4 m, float4 t) {
        float2 u = float2(m.x * p.x + m.z * p.y + t.x, m.y * p.x + m.w * p.y + t.y);
        if (u.x <= 0.0 || u.x >= 1.0 || u.y <= 0.0 || u.y >= 1.0) { return 0.0; }
        float wx = smoothstep(0.0, t.z, u.x) * smoothstep(0.0, t.z, 1.0 - u.x);
        float wy = smoothstep(0.0, t.w, u.y) * smoothstep(0.0, t.w, 1.0 - u.y);
        // Never exactly zero inside a tile, so a lone tile keeps full weight after normalising.
        return max(wx * wy, 0.000001);
    }

    [[stitchable]] float4 mosaicContribution(
        sample_t tile, float index,
        float4 m0, float4 t0, float4 m1, float4 t1,
        float4 m2, float4 t2, float4 m3, float4 t3,
        destination dest
    ) {
        float2 p = dest.coord();
        float w0 = mosaicWeight(p, m0, t0);
        float w1 = mosaicWeight(p, m1, t1);
        float w2 = mosaicWeight(p, m2, t2);
        float w3 = mosaicWeight(p, m3, t3);
        float total = w0 + w1 + w2 + w3;
        float mine = index < 0.5 ? w0 : (index < 1.5 ? w1 : (index < 2.5 ? w2 : w3));
        float weight = total > 0.0 ? mine / total : 0.0;
        // `tile` is premultiplied; un-premultiply so its own resampled edge does not darken the blend.
        float3 rgb = tile.a > 0.0001 ? tile.rgb / tile.a : float3(0.0);
        if (tile.a <= 0.0001) { weight = 0.0; }
        return float4(rgb * weight, weight);
    }

    inline float3 pow10v(float3 x) { return exp2(x * 3.3219281); }
    inline float pow10s(float x) { return exp2(x * 3.3219281); }
    inline float3 log10v(float3 x) { return log2(x) * 0.30103; }
    inline float log10s(float x) { return log2(x) * 0.30103; }

    inline float toneChannel(float value, float contrast, float highlights, float shadows) {
        if (value <= 0.000001) { return 0.0; }
        float stops = log2(value / 0.18) * contrast;
        stops += shadows * 1.5 * clamp(-stops / 4.0, 0.0, 1.0);
        stops += highlights * clamp(stops / 2.5, 0.0, 1.0);
        float linear = 0.18 * exp2(stops);
        float knee = 0.7;
        float over = max(linear - knee, 0.0);
        return min(linear, knee) + (1.0 - knee) * (1.0 - exp(-over / (1.0 - knee)));
    }

    inline float3 finishPrint(
        float3 c, float exposure, float contrast, float temperature, float tint,
        float highlights, float shadows, float saturation
    ) {
        c *= float3(exp2(temperature * 0.35), exp2(-tint * 0.3), exp2(-temperature * 0.35));
        c *= exp2(exposure);
        float3 y = float3(
            toneChannel(c.r, contrast, highlights, shadows),
            toneChannel(c.g, contrast, highlights, shadows),
            toneChannel(c.b, contrast, highlights, shadows)
        );
        float luma = dot(y, float3(0.2627, 0.6780, 0.0593));
        y = float3(luma) + (y - float3(luma)) * saturation;
        return clamp(y, float3(0.0), float3(1.0));
    }

    // Negative: density above the black point, stretched to 0…1, printed so that
    // the clear base is black and the densest picture is white.
    [[stitchable]] float4 positive(
        sample_t sample,
        float mode,
        float blackR, float blackG, float blackB,
        float gainR, float gainG, float gainB,
        float range, float exposure, float contrast,
        float temperature, float tint, float highlights, float shadows, float saturation
    ) {
        float eps = 0.0001;
        float3 rgb = max(sample.rgb, float3(eps));
        float3 scene;
        if (mode < 0.5) {
            scene = rgb * gainR;
        } else {
            float3 x;
            if (mode < 1.5) {
                float luma = dot(rgb, float3(0.2627, 0.6780, 0.0593));
                x = float3(max(-log10s(max(luma, eps)) - blackR, 0.0) * gainR);
            } else {
                x = max(-log10v(rgb) - float3(blackR, blackG, blackB), float3(0.0));
                x *= float3(gainR, gainG, gainB);
                if (mode < 2.5) {
                    x = float3((x.r + x.g + x.b) / 3.0);
                }
            }
            float floorValue = pow10s(-range);
            scene = (pow10v(range * (x - 1.0)) - floorValue) / max(1.0 - floorValue, eps);
        }
        float3 printed = finishPrint(
            scene, exposure, contrast, temperature, tint, highlights, shadows, saturation
        );
        return float4(printed, 1.0);
    }
    """
}
