//
//  LivePositive.swift
//  scan-analog
//
//  Live inverted viewfinder. Video frames go through the same print kernel as the RAW,
//  calibrated a few times per second from the rebate and the picture inside the guide.
//  The video is already processed by the ISP, so this is a preview, not the final colour.
//

import AVFoundation
import CoreImage
import Metal
import os
import QuartzCore
import SwiftUI
import UIKit

nonisolated final class LivePositiveRenderer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let output = AVCaptureVideoDataOutput()
    let queue = DispatchQueue(label: "scan-analog.live", qos: .userInteractive)

    private struct Shared: @unchecked Sendable {
        var enabled = false
        var filmType: FilmType = .colorNegative
        var geometry: CaptureGeometry?
        var layer: CAMetalLayer?
        var drawableSize: CGSize = .zero
        var rotationAngle: CGFloat = 90
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    // Touched only on `queue`.
    private var calibration: PrintParameters?
    private var calibratedFilm: FilmType?
    private var lastCalibration: CFTimeInterval = 0
    private var inFlight = false

    override init() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
        ]
        if let device {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
    }

    var metalDevice: MTLDevice? { device }

    func setEnabled(_ enabled: Bool) {
        shared.withLock { $0.enabled = enabled }
    }

    func update(filmType: FilmType, geometry: CaptureGeometry?) {
        shared.withLock { state in
            state.filmType = filmType
            if let geometry { state.geometry = geometry }
        }
    }

    func attach(layer: CAMetalLayer, drawableSize: CGSize, rotationAngle: CGFloat) {
        shared.withLockUnchecked { state in
            state.layer = layer
            state.drawableSize = drawableSize
            state.rotationAngle = rotationAngle
        }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let state = shared.withLock { $0 }
        if connection.isVideoRotationAngleSupported(state.rotationAngle), connection.videoRotationAngle != state.rotationAngle {
            connection.videoRotationAngle = state.rotationAngle
        }
        guard state.enabled, !inFlight,
              let layer = state.layer, let geometry = state.geometry,
              state.drawableSize.width > 1, state.drawableSize.height > 1,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let commandQueue else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let now = CACurrentMediaTime()
        if calibration == nil || calibratedFilm != state.filmType || now - lastCalibration > 0.3 {
            if let measured = calibrate(image, geometry: geometry, filmType: state.filmType) {
                calibration = blend(calibration, measured, sameFilm: calibratedFilm == state.filmType)
                calibratedFilm = state.filmType
            }
            lastCalibration = now
        }
        guard let calibration else { return }

        // Aspect-fill into the drawable, like the preview layer.
        let size = state.drawableSize
        let extent = image.extent
        let scale = max(size.width / extent.width, size.height / extent.height)
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: (size.width - extent.width * scale) / 2,
                y: (size.height - extent.height * scale) / 2
            ))
        let bounds = CGRect(origin: .zero, size: size)
        guard let positive = PositiveKernels.positive(placed.cropped(to: bounds), calibration),
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        inFlight = true
        context.render(
            positive,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: displayP3
        )
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.queue.async { self?.inFlight = false }
        }
        commandBuffer.commit()
    }

    // MARK: Calibration

    /// Base from the rebate band, black and white points from the picture, on a tiny copy of the frame.
    private func calibrate(_ image: CIImage, geometry: CaptureGeometry, filmType: FilmType) -> PrintParameters? {
        let extent = image.extent
        let scale = min(1, 220 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = small.extent.integral
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 8, height > 8 else { return nil }
        var floats = [Float](repeating: 0, count: width * height * 4)
        floats.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(small, toBitmap: base, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: linear)
        }

        func pixels(inView rects: [CGRect]) -> [RGBColor] {
            var result: [RGBColor] = []
            for viewRect in rects {
                let rect = GuideMapping.imageRect(viewRect: viewRect, viewSize: geometry.viewSize, extent: bounds)
                    .intersection(bounds)
                guard rect.width >= 1, rect.height >= 1 else { continue }
                let x0 = Int(rect.minX - bounds.minX)
                let x1 = min(Int(rect.maxX - bounds.minX), width)
                // Bitmap row 0 is the top of the image.
                let y0 = max(Int(bounds.maxY - rect.maxY), 0)
                let y1 = min(Int(bounds.maxY - rect.minY), height)
                guard x1 > x0, y1 > y0 else { continue }
                for y in y0..<y1 {
                    for x in max(x0, 0)..<x1 {
                        let i = (y * width + x) * 4
                        result.append(RGBColor(r: floats[i], g: floats[i + 1], b: floats[i + 2]))
                    }
                }
            }
            return result
        }

        let inner = geometry.inner.insetBy(dx: geometry.inner.width * 0.04, dy: geometry.inner.height * 0.04)
        let picture = pixels(inView: [inner])
        guard picture.count >= 32 else { return nil }
        let neutral = Adjustments.neutral

        if !filmType.inverts {
            let luma = picture.map { 0.2627 * $0.r + 0.6780 * $0.g + 0.0593 * $0.b }
            let white = max(Self.percentile(luma, 0.995), 1e-3)
            return PrintParameters(mode: 0, black: .zero, gain: RGBColor(r: 1 / white, g: 1 / white, b: 1 / white), range: 1, adjustments: neutral)
        }

        func density(_ value: Float) -> Float { -log10(max(value, 1e-4)) }
        let silver = filmType == .silverBW
        let channels: [(RGBColor) -> Float] = silver
            ? [{ 0.2627 * $0.r + 0.6780 * $0.g + 0.0593 * $0.b }]
            : [{ $0.r }, { $0.g }, { $0.b }]

        // Base: the clearest non-neutral rebate pixels. Bright neutral pixels are sprocket holes.
        let rebate = pixels(inView: geometry.layout.rebateRects(sidesOnly: false)).filter { pixel in
            let peak = max(pixel.r, pixel.g, pixel.b)
            let floor = min(pixel.r, pixel.g, pixel.b)
            return peak > 0.004 && !(floor / max(peak, 1e-4) > 0.82 && peak > 0.5)
        }
        var base: [Float] = []
        var low: [Float] = []
        var high: [Float] = []
        for channel in channels {
            let pictureDensity = picture.map { density(channel($0)) }
            let pictureLow = Self.percentile(pictureDensity, 0.005)
            if rebate.count >= 16 {
                let rebateDensity = rebate.map { density(channel($0)) }
                base.append(Self.percentile(rebateDensity, 0.3))
            } else {
                base.append(pictureLow)
            }
            low.append(pictureLow)
            high.append(Self.percentile(pictureDensity, 0.995))
        }
        var black: [Float] = []
        var gain: [Float] = []
        for index in base.indices {
            let floor = min(max(low[index], base[index]), base[index] + 0.3)
            let span = max(high[index] - floor, 0.2)
            black.append(floor)
            gain.append(1 / span)
        }
        if silver {
            black = [black[0], black[0], black[0]]
            gain = [gain[0], gain[0], gain[0]]
        }
        let meanSpan = (1 / gain[0] + 1 / gain[1] + 1 / gain[2]) / 3
        let range = min(max(meanSpan / filmType.negativeGamma, 1), 4)
        return PrintParameters(
            mode: filmType.kernelMode,
            black: RGBColor(r: black[0], g: black[1], b: black[2]),
            gain: RGBColor(r: gain[0], g: gain[1], b: gain[2]),
            range: range,
            adjustments: neutral
        )
    }

    /// Smooths calibration so the viewfinder does not flicker as the strip moves.
    private func blend(_ old: PrintParameters?, _ new: PrintParameters, sameFilm: Bool) -> PrintParameters {
        guard let old, sameFilm, old.mode == new.mode else { return new }
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * 0.35 }
        var result = new
        result.black = RGBColor(r: mix(old.black.r, new.black.r), g: mix(old.black.g, new.black.g), b: mix(old.black.b, new.black.b))
        result.gain = RGBColor(r: mix(old.gain.r, new.gain.r), g: mix(old.gain.g, new.gain.g), b: mix(old.gain.b, new.gain.b))
        result.range = mix(old.range, new.range)
        return result
    }

    private static func percentile(_ values: [Float], _ fraction: Float) -> Float {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return 0 }
        let sorted = finite.sorted()
        let index = min(sorted.count - 1, max(0, Int((Float(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}

/// Metal layer that shows the live positive above the camera preview.
struct LivePositiveView: UIViewRepresentable {
    let renderer: LivePositiveRenderer

    func makeUIView(context: Context) -> LiveMetalView {
        let view = LiveMetalView()
        view.renderer = renderer
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: LiveMetalView, context: Context) {
        uiView.renderer = renderer
        uiView.setNeedsLayout()
    }
}

final class LiveMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var renderer: LivePositiveRenderer?

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        metalLayer.contentsGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let renderer else { return }
        if metalLayer.device == nil {
            metalLayer.device = renderer.metalDevice
        }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metalLayer.drawableSize = size
        let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        renderer.attach(
            layer: metalLayer,
            drawableSize: size,
            rotationAngle: CameraController.rotationAngle(for: orientation)
        )
    }
}
