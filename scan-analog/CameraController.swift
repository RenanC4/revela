//
//  CameraController.swift
//  scan-analog
//

import AVFoundation
import Combine
import CoreMedia
import ImageIO
import OSLog
import UIKit

/// Optics in front of the phone. The raw values keep earlier saved choices valid.
nonisolated enum CameraLens: String, CaseIterable, Identifiable, Sendable {
    /// No accessory: the ultra wide's own macro, about 2 cm from the film.
    case builtIn = "ultraWide"
    /// Clip-on macro (Moment 75 mm T-Series) over the 1× main camera; focuses ~7–10 cm.
    case clipOnMacro = "wide"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtIn: return "Embutida (ultra-angular)"
        case .clipOnMacro: return "Macro de encaixe (Moment 75 mm)"
        }
    }

    var shortTitle: String {
        switch self {
        case .builtIn: return "Ultra-angular"
        case .clipOnMacro: return "Moment 75 mm"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .builtIn: return .builtInUltraWideCamera
        case .clipOnMacro: return .builtInWideAngleCamera
        }
    }

    /// The add-on changes the working distance, so the native minimum focus is not a limit.
    var usesAddOnLens: Bool { self == .clipOnMacro }

    static var saved: CameraLens {
        CameraLens(rawValue: UserDefaults.standard.string(forKey: "cameraLens") ?? "") ?? .clipOnMacro
    }
}

enum MeteringState: Equatable {
    case automatic
    case locking
    case locked
}

@MainActor
final class CameraController: NSObject, ObservableObject {
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    /// Live inverted viewfinder fed by a video data output on the same session.
    nonisolated let live = LivePositiveRenderer()
    private let sessionQueue = DispatchQueue(label: "scan-analog.camera.session")
    private let pendingLock = NSLock()
    nonisolated(unsafe) private var pending: [Int64: (CaptureGeometry, CaptureKind, CaptureLock)] = [:]
    nonisolated(unsafe) private var isConfigured = false
    nonisolated(unsafe) private var device: AVCaptureDevice?
    nonisolated(unsafe) private var rawFormat: OSType = 0
    nonisolated(unsafe) private var rawFileType: AVFileType = .dng
    nonisolated(unsafe) private var photoDimensions = CMVideoDimensions(width: 0, height: 0)
    nonisolated(unsafe) private var meterGeneration = 0
    nonisolated(unsafe) private var watchGeneration = 0
    nonisolated(unsafe) private var didPrepareRaw = false
    nonisolated(unsafe) private var heldFocus: Float?
    nonisolated(unsafe) private var heldDuration: CMTime?
    nonisolated(unsafe) private var heldISO: Float?
    nonisolated(unsafe) private var heldGains: AVCaptureDevice.WhiteBalanceGains?
    nonisolated(unsafe) private var pendingLens: Float?
    nonisolated(unsafe) private var lensApplyScheduled = false
    nonisolated(unsafe) private var lastPublishedLens = -1.0
    nonisolated(unsafe) private var lastPublishedLabel = ""
    nonisolated(unsafe) private var lensChoice: CameraLens = .saved

    @Published private(set) var isAuthorized = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var isRunning = false
    @Published private(set) var captureID = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var meteringState: MeteringState = .automatic
    @Published private(set) var captureModeLabel = ""
    @Published private(set) var lensPosition: Double = 0.5
    @Published private(set) var minimumFocusCentimeters: Int?
    @Published private(set) var lensLabel = ""
    @Published private(set) var rollLocked = false
    @Published private(set) var whiteBalanceLocked = false
    @Published private(set) var cameraLens: CameraLens = .saved

    var onRawCaptured: ((Data, CaptureGeometry, CaptureKind, CaptureLock) -> Void)?

    private var isRequestingAccess = false
    private let log = Logger(subsystem: "scan-analog", category: "capture")

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            permissionDenied = false
            sessionQueue.async { [weak self] in
                self?.configureAndStart()
            }
        case .notDetermined:
            requestAccess()
        case .denied, .restricted:
            isAuthorized = false
            permissionDenied = true
            sessionQueue.async { [weak self] in
                self?.stopSession()
            }
        @unknown default:
            isAuthorized = false
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.stopSession()
        }
    }

    func capture(_ geometry: CaptureGeometry, kind: CaptureKind = .frame) {
        var geometry = geometry
        geometry.angle = Self.rotationAngle(for: interfaceOrientation)
        sessionQueue.async { [weak self] in
            self?.takePhoto(geometry: geometry, kind: kind)
        }
    }

    func setLensPosition(_ position: Double) {
        let clamped = min(max(position, 0), 1)
        lensPosition = clamped
        sessionQueue.async { [weak self] in
            self?.scheduleLens(Float(clamped))
        }
    }

    /// Switches the rear camera. Exposure, focus and white balance are per camera, so the roll lock is cleared.
    func selectLens(_ lens: CameraLens) {
        guard lens != cameraLens else { return }
        cameraLens = lens
        UserDefaults.standard.set(lens.rawValue, forKey: "cameraLens")
        rollLocked = false
        meteringState = .automatic
        whiteBalanceLocked = false
        captureModeLabel = ""
        statusMessage = lens.usesAddOnLens
            ? "Câmara 1× com a Moment 75 mm (foco a 7–10 cm). Bloqueia o branco e volta a tocar no rebate."
            : "Ultra-angular. Bloqueia o branco e volta a tocar no rebate."
        sessionQueue.async { [weak self] in
            self?.meterGeneration += 1
            self?.switchCamera(to: lens)
        }
    }

    func lockWhiteBalance() {
        sessionQueue.async { [weak self] in
            self?.lockBareLightWhiteBalance()
        }
    }

    func lockMetering(at devicePoint: CGPoint) {
        if rollLocked {
            statusMessage = "Exposição e foco mantêm-se para o rolo. Usa Remedir para voltar a medir."
            return
        }
        let point = CGPoint(
            x: min(max(devicePoint.x, 0), 1),
            y: min(max(devicePoint.y, 0), 1)
        )
        meteringState = .locking
        statusMessage = "A medir o rebate. Backlight no máximo."
        sessionQueue.async { [weak self] in
            self?.meter(at: point)
        }
    }

    func showLockedRequirement() {
        statusMessage = "Bloqueia o rebate antes do campo plano."
    }

    func remeasure() {
        rollLocked = false
        meteringState = .automatic
        statusMessage = "Volta a tocar no rebate para bloquear o rolo."
        sessionQueue.async { [weak self] in
            self?.meterGeneration += 1
            self?.heldFocus = nil
            self?.heldDuration = nil
            self?.heldISO = nil
            guard let device = self?.device else { return }
            self?.applyDeviceSetup(device)
        }
    }

    nonisolated static func rotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeLeft:
            return 180
        case .landscapeRight:
            return 0
        default:
            return 90
        }
    }

    private var interfaceOrientation: UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.effectiveGeometry.interfaceOrientation ?? .portrait
    }

    private func requestAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isRequestingAccess = false
            if granted {
                isAuthorized = true
                permissionDenied = false
                sessionQueue.async { [weak self] in
                    self?.configureAndStart()
                }
            } else {
                isAuthorized = false
                permissionDenied = true
            }
        }
    }

    private func show(_ message: String) {
        statusMessage = message
    }

    nonisolated private func configureAndStart() {
        configureSession()
        guard isConfigured else { return }
        let needsStart = !session.isRunning
        if needsStart {
            session.startRunning()
        }
        if let device {
            applyDeviceSetup(device)
            publishFocusReadout(from: device)
        }
        let running = session.isRunning
        Task { @MainActor in
            self.isRunning = running
            if needsStart, self.heldDuration == nil {
                self.meteringState = .automatic
                self.rollLocked = false
            }
        }
        guard running else { return }
        startLensWatch()
        if !didPrepareRaw {
            prepareRawCapture(attempt: 0)
        }
    }

    nonisolated private func stopSession() {
        watchGeneration += 1
        guard session.isRunning else { return }
        session.stopRunning()
        Task { @MainActor in
            self.isRunning = false
        }
    }

    nonisolated private func configureSession() {
        guard !isConfigured else { return }

        let lens = lensChoice
        guard let camera = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) else {
            report("Este iPhone não tem a câmara \(lens.shortTitle.lowercased()).")
            return
        }
        device = camera

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                report("Não foi possível ligar a câmara \(lens.shortTitle.lowercased()).")
                return
            }
            session.addInput(input)
        } catch {
            report("Não foi possível ligar a câmara \(lens.shortTitle.lowercased()).")
            return
        }

        guard session.canAddOutput(photoOutput) else {
            report("Não foi possível preparar a captura.")
            return
        }
        session.addOutput(photoOutput)
        if session.canAddOutput(live.output) {
            session.addOutput(live.output)
            live.output.setSampleBufferDelegate(live, queue: live.queue)
            if let connection = live.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else {
            log.error("live positive output not added")
        }
        selectHighResolutionFormat(on: camera)
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
        }
        applyMaximumPhotoSize(to: camera)
        isConfigured = true
    }

    nonisolated private func switchCamera(to lens: CameraLens) {
        let previous = lensChoice
        lensChoice = lens
        heldFocus = nil
        heldDuration = nil
        heldISO = nil
        heldGains = nil
        lastPublishedLabel = ""
        guard isConfigured else { return }
        guard let camera = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            // Keep the UI on the camera that is actually running.
            lensChoice = previous
            Task { @MainActor in
                self.cameraLens = previous
                UserDefaults.standard.set(previous.rawValue, forKey: "cameraLens")
                self.show("Este iPhone não tem a câmara \(lens.shortTitle.lowercased()).")
            }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        for old in session.inputs {
            session.removeInput(old)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            Task { @MainActor in
                self.show("Não foi possível ligar a câmara \(lens.shortTitle.lowercased()).")
            }
            return
        }
        session.addInput(input)
        device = camera
        selectHighResolutionFormat(on: camera)
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
        }
        photoDimensions = CMVideoDimensions(width: 0, height: 0)
        session.commitConfiguration()
        applyDeviceSetup(camera)
        publishFocusReadout(from: camera)
        didPrepareRaw = false
        rawFormat = 0
        prepareRawCapture(attempt: 0)
    }

    nonisolated private func prepareRawCapture(attempt: Int) {
        if photoOutput.isAppleProRAWSupported, !photoOutput.isAppleProRAWEnabled {
            session.beginConfiguration()
            photoOutput.isAppleProRAWEnabled = true
            session.commitConfiguration()
            if let device {
                applyDeviceSetup(device)
            }
        }

        guard let selection = selectProRAWFormat() else {
            if attempt < 8 {
                sessionQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.prepareRawCapture(attempt: attempt + 1)
                }
            } else {
                Task { @MainActor in
                    self.show("Esta câmara não oferece ProRAW.")
                }
            }
            return
        }

        // The active format is only final after commitConfiguration, so size the output again here.
        if let device {
            applyMaximumPhotoSize(to: device)
        }
        rawFormat = selection.format
        rawFileType = selection.fileType
        didPrepareRaw = true
        let label = Self.captureLabel(dimensions: photoDimensions)
        Task { @MainActor in
            self.captureModeLabel = label
        }
        if let settings = makeSettings(angle: 90) {
            photoOutput.setPreparedPhotoSettingsArray([settings], completionHandler: nil)
        }
    }

    nonisolated private func selectProRAWFormat() -> (format: OSType, fileType: AVFileType)? {
        guard let format = photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
            AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
        }) else {
            return nil
        }
        let fileType: AVFileType
        if photoOutput.availableRawPhotoFileTypes.contains(.dng) {
            fileType = .dng
        } else if let first = photoOutput.availableRawPhotoFileTypes.first {
            fileType = first
        } else {
            return nil
        }
        let supported = photoOutput.supportedRawPhotoPixelFormatTypes(for: fileType)
        guard supported.contains(format) else { return nil }
        return (format, fileType)
    }

    nonisolated private func applyDeviceSetup(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
        } catch {
            return
        }
        defer { camera.unlockForConfiguration() }

        if camera.activeFormat.isGlobalToneMappingSupported {
            camera.isGlobalToneMappingEnabled = true
        }
        camera.automaticallyAdjustsVideoHDREnabled = false
        if camera.isVideoHDREnabled {
            camera.isVideoHDREnabled = false
        }
        if camera.isLowLightBoostSupported {
            camera.automaticallyEnablesLowLightBoostWhenAvailable = false
        }
        if camera.isGeometricDistortionCorrectionSupported {
            camera.isGeometricDistortionCorrectionEnabled = true
        }
        if camera.isExposureModeSupported(.custom) {
            camera.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
            camera.isFaceDrivenAutoExposureEnabled = false
        }
        if camera.isFocusModeSupported(.locked) {
            camera.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
            camera.isFaceDrivenAutoFocusEnabled = false
        }
        if camera.isSmoothAutoFocusSupported {
            camera.isSmoothAutoFocusEnabled = false
        }
        if camera.isAutoFocusRangeRestrictionSupported {
            camera.autoFocusRangeRestriction = .none
        }

        // A physical device is opened, so this is normally a no-op. If iOS ever hands back a
        // virtual (Fusion) camera, stop it from switching to the ultra wide / macro module.
        if camera.isVirtualDevice, camera.primaryConstituentDeviceSwitchingBehavior != .unsupported {
            camera.setPrimaryConstituentDeviceSwitchingBehavior(.locked, restrictedSwitchingBehaviorConditions: [])
        }
        // Native optics, no digital crop: the clip-on lens is designed for the 1× camera at 1×.
        let minZoom = camera.minAvailableVideoZoomFactor
        let maxZoom = camera.maxAvailableVideoZoomFactor
        if minZoom.isFinite, maxZoom.isFinite, maxZoom >= minZoom {
            camera.videoZoomFactor = min(max(1, minZoom), maxZoom)
        }
        let displayZoom = camera.videoZoomFactor * camera.displayVideoZoomFactorMultiplier
        let focusMillimetres = camera.minimumFocusDistance
        log.info("\(self.lensChoice.rawValue, privacy: .public) zoom \(camera.videoZoomFactor, format: .fixed(precision: 3)) display \(displayZoom, format: .fixed(precision: 2)) minFocus \(focusMillimetres) mm")

        if let heldGains {
            camera.setWhiteBalanceModeLocked(with: heldGains, completionHandler: nil)
        } else if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            camera.whiteBalanceMode = .continuousAutoWhiteBalance
        }

        if let heldFocus {
            camera.setFocusModeLocked(lensPosition: heldFocus, completionHandler: nil)
        } else if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }

        if let heldDuration, let heldISO {
            camera.setExposureModeCustom(duration: heldDuration, iso: heldISO, completionHandler: nil)
        } else if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }
        camera.isSubjectAreaChangeMonitoringEnabled = false
    }

    nonisolated private func makeSettings(angle: CGFloat) -> AVCapturePhotoSettings? {
        guard rawFormat != 0 else { return nil }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: nil)
        settings.photoQualityPrioritization = .quality
        if photoDimensions.width > 0, photoDimensions.height > 0,
           device?.activeFormat.supportedMaxPhotoDimensions.contains(where: {
               $0.width == photoDimensions.width && $0.height == photoDimensions.height
           }) == true {
            settings.maxPhotoDimensions = photoDimensions
        }
        if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }
        settings.isAutoRedEyeReductionEnabled = false
        settings.isAutoContentAwareDistortionCorrectionEnabled = false
        settings.isAutoVirtualDeviceFusionEnabled = false
        settings.isConstantColorEnabled = false
        settings.isDepthDataDeliveryEnabled = false
        settings.isPortraitEffectsMatteDeliveryEnabled = false
        settings.enabledSemanticSegmentationMatteTypes = []
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        return settings
    }

    /// Exposure, focus and white balance as the device holds them right now.
    nonisolated private func currentLock() -> CaptureLock {
        guard let camera = device else {
            return CaptureLock(
                iso: 0, exposureSeconds: 0, whiteBalanceGains: [], lensPosition: 0,
                exposureLocked: false, focusLocked: false, whiteBalanceLocked: false,
                lens: lensChoice.rawValue, minimumFocusDistanceMM: -1
            )
        }
        let gains = camera.deviceWhiteBalanceGains
        return CaptureLock(
            iso: camera.iso,
            exposureSeconds: camera.exposureDuration.seconds,
            whiteBalanceGains: [gains.redGain, gains.greenGain, gains.blueGain],
            lensPosition: camera.lensPosition,
            exposureLocked: camera.exposureMode == .custom || camera.exposureMode == .locked,
            focusLocked: camera.focusMode == .locked,
            whiteBalanceLocked: camera.whiteBalanceMode == .locked,
            lens: lensChoice.rawValue,
            minimumFocusDistanceMM: camera.minimumFocusDistance
        )
    }

    nonisolated private func takePhoto(geometry: CaptureGeometry, kind: CaptureKind) {
        guard isConfigured, session.isRunning, let settings = makeSettings(angle: geometry.angle) else {
            Task { @MainActor in
                self.show("A captura ProRAW ainda não está pronta.")
            }
            return
        }
        let token = settings.uniqueID
        pendingLock.lock()
        pending[token] = (geometry, kind, currentLock())
        pendingLock.unlock()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    nonisolated private func meter(at point: CGPoint) {
        guard let device else { return }
        meterGeneration += 1
        let generation = meterGeneration
        guard beginAdjusting(device, at: point) else {
            Task { @MainActor in
                self.meteringState = .automatic
                self.show("Não foi possível medir o rebate.")
            }
            return
        }
        sessionQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitAndLockExposure(generation: generation, attempt: 0, focusScanStarted: false, stablePasses: 0)
        }
    }

    nonisolated private func beginAdjusting(_ camera: AVCaptureDevice, at point: CGPoint) -> Bool {
        do {
            try camera.lockForConfiguration()
        } catch {
            return false
        }
        defer { camera.unlockForConfiguration() }

        if camera.isSmoothAutoFocusSupported {
            camera.isSmoothAutoFocusEnabled = false
        }
        if camera.isAutoFocusRangeRestrictionSupported {
            camera.autoFocusRangeRestriction = .none
        }
        if camera.isFocusPointOfInterestSupported {
            camera.focusPointOfInterest = point
        }
        if camera.isFocusRectOfInterestSupported {
            camera.focusRectOfInterest = focusRect(around: point, minimum: camera.minFocusRectOfInterestSize)
        }
        if camera.isExposureRectOfInterestSupported {
            camera.exposureRectOfInterest = exposureRect(around: point, minimum: camera.minExposureRectOfInterestSize)
        } else if camera.isExposurePointOfInterestSupported {
            camera.exposurePointOfInterest = point
        }
        if camera.isFocusModeSupported(.autoFocus) {
            camera.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
            camera.isFaceDrivenAutoFocusEnabled = false
            camera.focusMode = .autoFocus
        }
        if camera.isExposureModeSupported(.autoExpose) {
            camera.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
            camera.isFaceDrivenAutoExposureEnabled = false
            camera.exposureMode = .autoExpose
            let bias = min(camera.maxExposureTargetBias, max(camera.minExposureTargetBias, 1))
            camera.setExposureTargetBias(bias, completionHandler: nil)
        }
        return true
    }

    nonisolated private func waitAndLockExposure(
        generation: Int,
        attempt: Int,
        focusScanStarted: Bool,
        stablePasses: Int
    ) {
        guard generation == meterGeneration, let camera = device else { return }
        var scanStarted = focusScanStarted
        if camera.isAdjustingFocus {
            scanStarted = true
        }
        let busy = camera.isAdjustingFocus || camera.isAdjustingExposure || camera.isAdjustingWhiteBalance
        let scanStillPending = !scanStarted && attempt < 24
        let stable = (!busy && !scanStillPending) ? stablePasses + 1 : 0
        if stable < 8, attempt < 80 {
            sessionQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.waitAndLockExposure(
                    generation: generation,
                    attempt: attempt + 1,
                    focusScanStarted: scanStarted,
                    stablePasses: stable
                )
            }
            return
        }
        lockRollExposure(camera)
    }

    nonisolated private func lockRollExposure(_ camera: AVCaptureDevice) {
        // Same exposure the meter chose, moved to base ISO (least noise) with a longer shutter.
        let metered = camera.exposureDuration.seconds * Double(max(camera.iso, 1))
        let (duration, iso) = Self.exposure(forProduct: metered, on: camera.activeFormat)
        let seconds = duration.seconds
        let lens = camera.lensPosition

        do {
            try camera.lockForConfiguration()
        } catch {
            Task { @MainActor in
                self.meteringState = .automatic
                self.show("Não foi possível bloquear a exposição.")
            }
            return
        }
        camera.setFocusModeLocked(lensPosition: lens, completionHandler: nil)
        camera.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
        camera.unlockForConfiguration()

        heldFocus = lens
        heldDuration = duration
        heldISO = iso
        let tooClose = !lensChoice.usesAddOnLens && lens <= 0.02 && camera.minimumFocusDistance > 80
        publishFocusReadout(from: camera)
        let milliseconds = Int((seconds * 1000).rounded())
        Task { @MainActor in
            self.rollLocked = true
            self.meteringState = .locked
            if tooClose, let centimeters = self.minimumFocusCentimeters {
                self.statusMessage = "Muito perto para esta lente. Afasta até cerca de \(centimeters) cm."
            } else if self.whiteBalanceLocked {
                self.statusMessage = "Rolo bloqueado a ISO \(Int(iso)) e \(milliseconds) ms. A exposição não muda entre fotogramas."
            } else {
                self.statusMessage = "Rolo bloqueado a ISO \(Int(iso)) e \(milliseconds) ms. Bloqueia o branco no backlight sem filme."
            }
        }
    }

    /// Shutter and ISO for an exposure product (seconds × ISO): base ISO first, then raise ISO
    /// only for what the longest shutter cannot give, so a clamp never silently darkens the scan.
    nonisolated private static func exposure(forProduct product: Double, on format: AVCaptureDevice.Format) -> (CMTime, Float) {
        let minISO = Double(format.minISO)
        let maxISO = Double(format.maxISO)
        let minSeconds = format.minExposureDuration.seconds
        let maxSeconds = format.maxExposureDuration.seconds
        guard product.isFinite, product > 0 else {
            return (format.minExposureDuration, Float(minISO))
        }
        var seconds = product / minISO
        var iso = minISO
        if seconds > maxSeconds {
            seconds = maxSeconds
            iso = min(product / maxSeconds, maxISO)
        }
        seconds = min(max(seconds, minSeconds), maxSeconds)
        // Rounding to the timescale can land a hair outside the range, which setExposureModeCustom rejects.
        let rounded = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        let clamped = CMTimeMaximum(CMTimeMinimum(rounded, format.maxExposureDuration), format.minExposureDuration)
        return (clamped, Float(iso))
    }

    /// Changes the locked roll exposure by `ev` stops (ETTR). Frames keep matching because
    /// every RAW is scaled by its own ISO × shutter before inversion.
    func adjustLockedExposure(by ev: Double, applied: @escaping @MainActor (Double) -> Void = { _ in }) {
        guard rollLocked else {
            showLockedRequirement()
            return
        }
        sessionQueue.async { [weak self] in
            guard let self, let camera = self.device, let held = self.heldDuration, let heldISO = self.heldISO else { return }
            let product = held.seconds * Double(heldISO) * pow(2, ev)
            let (duration, iso) = Self.exposure(forProduct: product, on: camera.activeFormat)
            do {
                try camera.lockForConfiguration()
            } catch {
                return
            }
            camera.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            camera.unlockForConfiguration()
            self.heldDuration = duration
            self.heldISO = iso
            let achieved = log2(duration.seconds * Double(iso) / (held.seconds * Double(heldISO)))
            let milliseconds = Int((duration.seconds * 1000).rounded())
            Task { @MainActor in
                // Report what the shutter/ISO limits actually allowed, not what was asked.
                applied(achieved)
                self.statusMessage = String(
                    format: "Exposição %+.1f EV: ISO %d e %d ms. Os fotogramas anteriores continuam válidos.",
                    achieved, Int(iso), milliseconds
                )
            }
        }
    }

    nonisolated private func lockBareLightWhiteBalance() {
        guard let camera = device else { return }
        do {
            try camera.lockForConfiguration()
        } catch {
            Task { @MainActor in
                self.show("Não foi possível bloquear o branco.")
            }
            return
        }
        let gains = normalizedGains(camera.deviceWhiteBalanceGains, maxGain: camera.maxWhiteBalanceGain)
        if camera.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            camera.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            heldGains = gains
        } else {
            camera.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains, completionHandler: nil)
            heldGains = camera.deviceWhiteBalanceGains
        }
        camera.unlockForConfiguration()
        Task { @MainActor in
            self.whiteBalanceLocked = true
            self.statusMessage = "Branco bloqueado no backlight. Não serve para tirar a máscara laranja."
        }
    }

    nonisolated private func normalizedGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        maxGain: Float
    ) -> AVCaptureDevice.WhiteBalanceGains {
        var gains = gains
        gains.redGain = min(max(gains.redGain, 1), maxGain)
        gains.greenGain = min(max(gains.greenGain, 1), maxGain)
        gains.blueGain = min(max(gains.blueGain, 1), maxGain)
        return gains
    }

    nonisolated private func focusRect(around point: CGPoint, minimum: CGSize) -> CGRect {
        let width = min(1, max(minimum.width, 0.12))
        let height = min(1, max(minimum.height, 0.12))
        let x = min(max(0, point.x - width / 2), 1 - width)
        let y = min(max(0, point.y - height / 2), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    nonisolated private func exposureRect(around point: CGPoint, minimum: CGSize) -> CGRect {
        let width = min(1, max(minimum.width, 0.28))
        let height = min(1, max(minimum.height, 0.12))
        let x = min(max(0, point.x - width / 2), 1 - width)
        let y = min(max(0, point.y - height / 2), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    nonisolated private func lockLens(at position: Float) {
        guard let camera = device, camera.isLockingFocusWithCustomLensPositionSupported else { return }
        do {
            try camera.lockForConfiguration()
        } catch {
            return
        }
        defer { camera.unlockForConfiguration() }
        camera.setFocusModeLocked(lensPosition: position, completionHandler: nil)
    }

    nonisolated private func startLensWatch() {
        watchGeneration += 1
        pumpLensWatch(watchGeneration)
    }

    nonisolated private func pumpLensWatch(_ generation: Int) {
        guard generation == watchGeneration, session.isRunning, let device else { return }
        publishFocusReadout(from: device)
        sessionQueue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.pumpLensWatch(generation)
        }
    }

    nonisolated private func scheduleLens(_ position: Float) {
        pendingLens = position
        heldFocus = position
        guard !lensApplyScheduled else { return }
        lensApplyScheduled = true
        sessionQueue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.lensApplyScheduled = false
            guard let position = self.pendingLens else { return }
            self.pendingLens = nil
            self.meterGeneration += 1
            self.lockLens(at: position)
        }
    }

    nonisolated private func publishFocusReadout(from camera: AVCaptureDevice) {
        let position = Double(camera.lensPosition)
        let millimeters = camera.minimumFocusDistance
        let displayZoom = camera.videoZoomFactor * camera.displayVideoZoomFactorMultiplier
        let zoom = String(format: "%.1f×", locale: Locale(identifier: "pt_PT"), displayZoom)
        let label = lensChoice.usesAddOnLens
            ? "\(lensChoice.shortTitle) · lente macro"
            : "\(lensChoice.shortTitle) · \(zoom)"
        guard abs(position - lastPublishedLens) > 0.012 || label != lastPublishedLabel else { return }
        lastPublishedLens = position
        lastPublishedLabel = label
        let centimeters = millimeters >= 0 ? max(1, (millimeters + 5) / 10) : nil
        Task { @MainActor in
            self.lensPosition = position
            self.lensLabel = label
            if let centimeters {
                self.minimumFocusCentimeters = centimeters
            }
        }
    }

    /// The `.photo` preset can leave the ultra-wide on a 12 MP format. Pick the format with the
    /// largest photo size (48 MP on recent Pro models), preferring 4:3 full-range 8-bit, and keep it
    /// only if ProRAW is still available.
    nonisolated private func selectHighResolutionFormat(on camera: AVCaptureDevice) {
        func photoPixels(_ format: AVCaptureDevice.Format) -> Int {
            format.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
        }
        func isFourThree(_ format: AVCaptureDevice.Format) -> Int {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard size.height > 0 else { return 0 }
            return abs(Double(size.width) / Double(size.height) - 4.0 / 3.0) < 0.01 ? 1 : 0
        }
        func isFullRange(_ format: AVCaptureDevice.Format) -> Int {
            CMFormatDescriptionGetMediaSubType(format.formatDescription)
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
        }
        let current = camera.activeFormat
        guard let best = camera.formats.max(by: { lhs, rhs in
            (photoPixels(lhs), isFourThree(lhs), isFullRange(lhs))
                < (photoPixels(rhs), isFourThree(rhs), isFullRange(rhs))
        }), photoPixels(best) > photoPixels(current) else {
            log.info("photo format kept, max \(photoPixels(current)) px")
            return
        }
        do {
            try camera.lockForConfiguration()
        } catch {
            return
        }
        camera.activeFormat = best
        camera.unlockForConfiguration()
        if photoOutput.isAppleProRAWSupported {
            log.info("photo format \(best.description, privacy: .public)")
        } else {
            log.error("high-resolution format has no ProRAW, back to .photo preset")
            session.sessionPreset = .photo
        }
    }

    nonisolated private func applyMaximumPhotoSize(to camera: AVCaptureDevice) {
        guard let dimensions = Self.largestPhotoDimensions(in: camera.activeFormat.supportedMaxPhotoDimensions) else {
            return
        }
        let offered = camera.activeFormat.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" }
        log.info("offered photo sizes \(offered.joined(separator: ", "), privacy: .public)")
        photoOutput.maxPhotoDimensions = dimensions
        photoDimensions = dimensions
        log.info("requested maxPhotoDimensions \(dimensions.width)x\(dimensions.height)")
    }

    nonisolated private static func largestPhotoDimensions(in sizes: [CMVideoDimensions]) -> CMVideoDimensions? {
        let deferredPixels = 5712 * 4284
        let direct = sizes.filter { Int($0.width) * Int($0.height) != deferredPixels }
        let pool = direct.isEmpty ? sizes : direct
        return pool.max { lhs, rhs in
            Int(lhs.width) * Int(lhs.height) < Int(rhs.width) * Int(rhs.height)
        }
    }

    nonisolated private static func captureLabel(dimensions: CMVideoDimensions) -> String {
        let pixels = Int(dimensions.width) * Int(dimensions.height)
        guard pixels > 0 else { return "ProRAW" }
        let megapixels = Int((Double(pixels) / 1_000_000).rounded())
        guard megapixels > 0 else { return "ProRAW" }
        return "ProRAW · \(megapixels) MP"
    }

    nonisolated private func report(_ message: String) {
        Task { @MainActor in
            self.isRunning = false
            self.statusMessage = message
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let token = photo.resolvedSettings.uniqueID
        pendingLock.lock()
        let pendingCapture = pending.removeValue(forKey: token)
        pendingLock.unlock()

        let raw = photo.resolvedSettings.rawPhotoDimensions
        let processed = photo.resolvedSettings.photoDimensions
        let requested = photoDimensions
        log.info("resolved raw \(raw.width)x\(raw.height) processed \(processed.width)x\(processed.height) requested max \(requested.width)x\(requested.height)")

        if let error {
            Task { @MainActor in
                self.show(error.localizedDescription)
            }
            return
        }

        guard var pendingCapture, let data = photo.fileDataRepresentation() else {
            Task { @MainActor in
                self.show("Não foi possível ler o ProRAW.")
            }
            return
        }

        // ISO and shutter as recorded in this photo: right after an exposure change the device
        // properties can still report the previous values.
        if let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let seconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue, seconds > 0 {
                pendingCapture.2.exposureSeconds = seconds
            }
            if let isos = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let iso = isos.first?.floatValue, iso > 0 {
                pendingCapture.2.iso = iso
            }
        }
        let requestedPixels = Int(requested.width) * Int(requested.height)
        let rawPixels = Int(raw.width) * Int(raw.height)
        let actual = Self.captureLabel(dimensions: rawPixels > 0 ? raw : requested)
        let capture = pendingCapture
        Task { @MainActor in
            self.captureID += 1
            if rawPixels > 0 {
                self.captureModeLabel = actual
                if requestedPixels > rawPixels * 12 / 10 {
                    self.statusMessage = "Em foco curto saiu \(raw.width)×\(raw.height), pedido \(requested.width)×\(requested.height)."
                }
            }
            self.onRawCaptured?(data, capture.0, capture.1, capture.2)
        }
    }
}
