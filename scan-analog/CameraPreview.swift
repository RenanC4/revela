//
//  CameraPreview.swift
//  scan-analog
//

import AVFoundation
import AVKit
import SwiftUI
import UIKit

final class PreviewBridge {
    weak var preview: PreviewView?
    var onHardwareShutter: (() -> Void)?

    func devicePoint(from viewPoint: CGPoint) -> CGPoint {
        guard let preview else { return viewPoint }
        return preview.devicePoint(from: viewPoint)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var isRunning: Bool
    var bridge: PreviewBridge
    /// Aspect-fill for the single-frame guide; aspect-fit for mosaic tiles so the whole sensor is visible.
    var fill: Bool = true

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.installHardwareShutterIfNeeded()
        bridge.preview = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        bridge.preview = uiView
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if uiView.previewLayer.videoGravity != gravity {
            uiView.previewLayer.videoGravity = gravity
        }
        uiView.onHardwareShutter = { [bridge] in
            bridge.onHardwareShutter?()
        }
        uiView.hardwareShutterEnabled = isRunning
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var onHardwareShutter: (() -> Void)?
    var hardwareShutterEnabled = false {
        didSet { captureInteraction?.isEnabled = hardwareShutterEnabled }
    }

    private var captureInteraction: AVCaptureEventInteraction?

    func devicePoint(from viewPoint: CGPoint) -> CGPoint {
        previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
    }

    func installHardwareShutterIfNeeded() {
        guard captureInteraction == nil else { return }
        let interaction = AVCaptureEventInteraction { [weak self] event in
            guard event.phase == .began else { return }
            self?.onHardwareShutter?()
        }
        addInteraction(interaction)
        interaction.isEnabled = hardwareShutterEnabled
        captureInteraction = interaction
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let connection = previewLayer.connection,
              let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation else {
            return
        }

        let angle = CameraController.rotationAngle(for: orientation)
        guard connection.isVideoRotationAngleSupported(angle),
              connection.videoRotationAngle != angle else {
            return
        }
        connection.videoRotationAngle = angle
    }
}
