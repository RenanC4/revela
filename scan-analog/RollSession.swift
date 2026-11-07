//
//  RollSession.swift
//  scan-analog
//

import Combine
import Photos
import UIKit
import UniformTypeIdentifiers

struct RollFrame: Identifiable {
    let id: UUID
    let rawURL: URL
    let geometry: CaptureGeometry
    var previewJPEG: Data?
    var preview: UIImage?
    var savedToLibrary = false
    var isProcessing = true
    var adjustments = Adjustments.neutral
    var quarterTurns = 0
    var cropDetected = false
    /// Set for a stitched 6×6: the frame renders from its four tiles, not from `rawURL`.
    var mosaic: MosaicRecord?
    /// ISO, shutter, focus and white balance read from the device when the frame was shot.
    var lock: CaptureLock?
    var fileBaselineExposure: Float?
    /// This frame's own black/white densities, pooled into the roll's levels.
    var frameLevels: DensityLevels?
    /// Photos asset created for this frame, so re-saving replaces it instead of duplicating.
    var assetIdentifier: String?
    /// Saved, but the print changed since (adjustments, or the roll's levels moved).
    var libraryStale = false
    /// Bumped on every change to the print, so an export started earlier cannot mark it up to date.
    var revision = 0
    /// Optional cleanup and look. Off by default; the faithful positive is always kept.
    var enhance = EnhanceSettings()
    var enhancedJPEG: Data?
    var enhancedPreview: UIImage?
    var maskPreview: UIImage?
    var defects = 0
    /// 35 mm / 6×6 read from the detected gate.
    var detectedFormat: FilmFormat?
    /// Full-resolution files written for this frame (faithful always, enhanced when enabled).
    var faithfulFile: URL?
    var enhancedFile: URL?

    /// Exposure that shot this frame (a mosaic's tiles share one lock).
    var exposureLock: CaptureLock? { mosaic?.tiles.first?.lock ?? lock }
}

@MainActor
final class RollSession: ObservableObject {
    @Published private(set) var frames: [RollFrame] = []
    @Published private(set) var mask: RGBColor?
    @Published private(set) var message: String?
    @Published private(set) var filmType: FilmType = .colorNegative
    @Published private(set) var hasFlatField = false
    /// Normalized preview point (top-left origin) of a clear-base tap. Nil uses the rebate guide.
    @Published private(set) var clearBase: CGPoint?
    /// The next tap on the preview should mark the clear base.
    @Published private(set) var needsClearBase = false
    /// Frames with an export in flight; a second export of the same frame waits its turn instead of duplicating.
    @Published private(set) var exportingFrameIDs: Set<UUID> = []
    /// Stops the locked exposure could rise before the brightest raw value (bare light, or the
    /// rebate and sprocket holes) nears clipping. Negative when it already clips.
    @Published private(set) var exposureHeadroomEV: Double?
    /// The gate on the last single frame looked like another format than the one selected.
    @Published private(set) var formatSuggestion: FilmFormat?

    var onNewRoll: (() -> Void)?

    private var rollDirectory: URL
    private var flatFieldURL: URL?
    private var flatFieldLock: CaptureLock?
    private var profile: RollProfile?
    /// Median of the frames' levels; nil until a frame has been measured.
    private var rollLevels: DensityLevels?
    private var generation = 0
    private var rollToken = 0
    private var frameTokens: [UUID: Int] = [:]
    private var enhanceTokens: [UUID: Int] = [:]
    /// Enhancement choices new frames start with: off until the user turns it on once.
    private var enhanceDefaults = EnhanceSettings()

    init() {
        rollDirectory = Self.makeDirectory()
    }

    /// Folder of the current roll; mosaic tiles are stored inside it.
    var directory: URL { rollDirectory }

    /// Flat field of the current roll, applied to every mosaic tile before stitching.
    var currentFlatFieldURL: URL? { flatFieldURL }

    var staleCount: Int { frames.filter(\.libraryStale).count }

    func isExporting(_ frameID: UUID) -> Bool { exportingFrameIDs.contains(frameID) }

    // MARK: Capture

    func ingest(data: Data, geometry: CaptureGeometry, kind: CaptureKind, lock: CaptureLock? = nil) {
        switch kind {
        case .flatField:
            storeFlatField(data, lock: lock, angle: geometry.angle)
        case .frame:
            storeFrame(data: data, geometry: geometry, lock: lock)
        case .tile:
            // Tiles belong to the MosaicSession until they are stitched.
            break
        }
    }

    /// Adds a stitched mosaic as one frame. The roll profile (Dmin, gains) is shared with the other frames.
    func ingestMosaic(_ record: MosaicRecord, geometry: CaptureGeometry) {
        let frame = RollFrame(
            id: UUID(),
            rawURL: record.directory.appendingPathComponent(MosaicRecord.fileName),
            geometry: geometry,
            mosaic: record,
            enhance: enhanceDefaults
        )
        frames.append(frame)
        integrate(frame.id)
    }

    private func storeFrame(data: Data, geometry: CaptureGeometry, lock: CaptureLock?) {
        let id = UUID()
        let url = rollDirectory.appendingPathComponent("\(id.uuidString).dng")
        do {
            try FileManager.default.createDirectory(at: rollDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            message = "Não foi possível guardar o RAW."
            return
        }
        frames.append(RollFrame(id: id, rawURL: url, geometry: geometry, lock: lock, enhance: enhanceDefaults))
        if flatFieldURL == nil, exposureHeadroomEV == nil {
            measureHeadroom(url: url, angle: geometry.angle, geometry: geometry)
        }
        integrate(id)
    }

    private func storeFlatField(_ data: Data, lock: CaptureLock?, angle: CGFloat) {
        // A new name per capture: caches and per-file measurements are keyed by URL.
        let url = rollDirectory.appendingPathComponent("flat-field-\(UUID().uuidString).dng")
        do {
            try FileManager.default.createDirectory(at: rollDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            message = "Não foi possível guardar o campo plano."
            return
        }
        flatFieldURL = url
        flatFieldLock = lock
        hasFlatField = true
        message = "Campo plano guardado com a exposição do rolo."
        // Bare backlight is the brightest thing the camera sees: keep it just under clipping.
        measureHeadroom(url: url, angle: angle, geometry: nil)
        // Densities are now relative to the light: Dmin and the roll levels must be measured again.
        remeasureRoll()
    }

    // MARK: Roll settings

    func setFilmType(_ type: FilmType) {
        guard type != filmType else { return }
        filmType = type
        message = type == .slideE6 ? "E-6 não se inverte. A base clara não deve estourar." : nil
        remeasureRoll()
    }

    func setClearBase(_ normalized: CGPoint?) {
        clearBase = normalized
        message = normalized == nil
            ? "Base limpa. O Dmin volta a sair do rebate."
            : "Base clara marcada. O Dmin sai só dessa zona."
        remeasureRoll()
    }

    /// The camera exposure moved by `ev` stops; the headroom moves the other way.
    func exposureChanged(by ev: Double) {
        if let headroom = exposureHeadroomEV {
            exposureHeadroomEV = headroom - ev
        }
    }

    func beginNewRoll() {
        generation += 1
        rollToken += 1
        frames = []
        mask = nil
        profile = nil
        rollLevels = nil
        flatFieldURL = nil
        flatFieldLock = nil
        hasFlatField = false
        exposureHeadroomEV = nil
        formatSuggestion = nil
        clearBase = nil
        needsClearBase = false
        message = nil
        frameTokens = [:]
        exportingFrameIDs = []
        rollDirectory = Self.makeDirectory()
        onNewRoll?()
    }

    // MARK: Frame edits

    /// Edits one frame and re-renders only that frame, debounced.
    func setAdjustments(_ adjustments: Adjustments, for frameID: UUID) {
        guard let current = frames.first(where: { $0.id == frameID }), current.adjustments != adjustments else { return }
        let cropChanged = current.adjustments.autoCrop != adjustments.autoCrop
            || current.adjustments.cropInset != adjustments.cropInset
        update(frameID) { item in
            item.adjustments = adjustments
            item.revision += 1
            item.libraryStale = item.savedToLibrary
        }
        // A new crop changes what this frame contributes to the roll's levels: re-measure, debounced.
        scheduleFrame(frameID, delay: cropChanged ? 250 : 150, remeasure: cropChanged)
    }

    func rotate(frameID: UUID) {
        update(frameID) { item in
            item.quarterTurns = (item.quarterTurns + 1) % 4
            item.revision += 1
            item.libraryStale = item.savedToLibrary
        }
        scheduleFrame(frameID, delay: 0)
    }

    /// Enhancement changed: only the enhanced preview is recomputed. The faithful preview is not
    /// re-rendered, so switching Enhance off shows exactly the same faithful bytes as before.
    func setEnhance(_ settings: EnhanceSettings, for frameID: UUID) {
        guard let current = frames.first(where: { $0.id == frameID }), current.enhance != settings else { return }
        enhanceDefaults = settings
        update(frameID) { item in
            item.enhance = settings
            item.revision += 1
            item.libraryStale = item.savedToLibrary
            if !settings.doesAnything {
                item.enhancedJPEG = nil
                item.enhancedPreview = nil
                item.maskPreview = nil
                item.defects = 0
            }
        }
        guard settings.doesAnything else { return }
        let token = (enhanceTokens[frameID] ?? 0) + 1
        enhanceTokens[frameID] = token
        let generation = generation
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard enhanceTokens[frameID] == token, generation == self.generation,
                  let frame = frames.first(where: { $0.id == frameID }) else { return }
            update(frameID) { $0.isProcessing = true }
            do {
                let enhancement = try await NegativeProcessor.shared.prepareEnhancement(request(for: frame))
                guard enhanceTokens[frameID] == token, generation == self.generation else { return }
                update(frameID) { item in
                    Self.store(enhancement, in: &item)
                    item.isProcessing = false
                }
            } catch {
                update(frameID) { $0.isProcessing = false }
                report(error)
            }
        }
    }

    /// User-dragged crop (fraction of the capture, top-left origin, unrotated); nil returns to detection.
    func setManualCrop(_ crop: CGRect?, for frameID: UUID) {
        guard var adjustments = frames.first(where: { $0.id == frameID })?.adjustments else { return }
        adjustments.manualCrop = crop
        setAdjustments(adjustments, for: frameID)
    }

    /// Whole capture printed with this frame's settings, plus its current crop, for the crop editor.
    func cropEditorPreview(for frameID: UUID) async -> (image: UIImage, crop: CGRect)? {
        guard let frame = frames.first(where: { $0.id == frameID }),
              let result = try? await NegativeProcessor.shared.cropEditorPreview(request(for: frame)),
              let image = UIImage(data: result.jpeg) else { return nil }
        return (image, result.crop)
    }

    func dismissFormatSuggestion() { formatSuggestion = nil }

    private static func store(_ enhancement: PreparedEnhancement?, in item: inout RollFrame) {
        item.enhancedJPEG = enhancement?.previewJPEG
        item.enhancedPreview = enhancement.flatMap { UIImage(data: $0.previewJPEG) }
        item.maskPreview = enhancement?.maskJPEG.flatMap { UIImage(data: $0) }
        item.defects = enhancement?.defects ?? 0
    }

    func resetAdjustments(frameID: UUID) {
        setAdjustments(.neutral, for: frameID)
    }

    /// Copies this frame's adjustments and rotation to the whole roll.
    func applyToRoll(from frameID: UUID) {
        guard let source = frames.first(where: { $0.id == frameID }) else { return }
        for frame in frames where frame.id != frameID {
            guard frame.adjustments != source.adjustments || frame.quarterTurns != source.quarterTurns else { continue }
            update(frame.id) { item in
                item.adjustments = source.adjustments
                // A dragged crop belongs to one capture; the others keep finding their own.
                item.adjustments.manualCrop = frame.adjustments.manualCrop
                item.quarterTurns = source.quarterTurns
                item.enhance = source.enhance
                item.revision += 1
                item.libraryStale = item.savedToLibrary
            }
            scheduleFrame(frame.id, delay: 0)
        }
        message = "Ajustes copiados para o rolo."
    }

    func export(frameID: UUID) {
        let generation = generation
        Task {
            await export(frameID: frameID, generation: generation, announceFailure: true)
        }
    }

    /// Re-saves every frame whose saved photo no longer matches the app.
    func exportStale() {
        let generation = generation
        let ids = frames.filter(\.libraryStale).map(\.id)
        Task {
            for id in ids {
                guard generation == self.generation else { return }
                await export(frameID: id, generation: generation, announceFailure: true)
            }
        }
    }

    // MARK: Pipeline

    private func request(for frame: RollFrame) -> NegativeProcessor.FrameRequest {
        NegativeProcessor.FrameRequest(
            rawURL: frame.rawURL,
            geometry: frame.geometry,
            filmType: filmType,
            profile: profile,
            flatFieldURL: flatFieldURL,
            clearBase: clearBase,
            adjustments: frame.adjustments,
            quarterTurns: frame.quarterTurns,
            mosaic: frame.mosaic,
            radiometricScale: radiometricScale(for: frame),
            rollLevels: rollLevels,
            enhance: frame.enhance
        )
    }

    /// New (or re-cropped) frame: measure its levels, fold them into the roll median, render it,
    /// refresh the other "Rolo" frames if the median moved, then save.
    private func integrate(_ frameID: UUID) {
        let generation = generation
        let token = rollToken
        Task {
            guard await measure(frameID, generation: generation, rollToken: token) else { return }
            let moved = updateRollLevels()
            await renderFrame(frameID, generation: generation) { [weak self] in self?.rollToken == token }
            if moved {
                refreshRollFrames(except: frameID)
            }
            if generation == self.generation, token == rollToken {
                await export(frameID: frameID, generation: generation, announceFailure: true)
            }
        }
    }

    /// Profile, flat field or film type changed: measure every frame first, then render each once.
    private func remeasureRoll() {
        rollToken += 1
        let token = rollToken
        let generation = generation
        profile = nil
        mask = nil
        rollLevels = nil
        for index in frames.indices {
            frames[index].frameLevels = nil
            frames[index].isProcessing = true
        }
        Task {
            for frame in frames {
                guard generation == self.generation, token == rollToken else { return }
                _ = await measure(frame.id, generation: generation, rollToken: token)
            }
            guard token == rollToken else { return }
            _ = updateRollLevels()
            for frame in frames {
                guard generation == self.generation, token == rollToken else { return }
                update(frame.id) { item in
                    item.revision += 1
                    item.libraryStale = item.savedToLibrary
                }
                await renderFrame(frame.id, generation: generation) { [weak self] in self?.rollToken == token }
            }
            // Frames whose first save was cut short by this re-measure still get their photo.
            for frame in frames where !frame.savedToLibrary && frame.previewJPEG != nil {
                guard generation == self.generation, token == rollToken else { return }
                await export(frameID: frame.id, generation: generation, announceFailure: false)
            }
        }
    }

    /// Re-renders the frames that follow the roll median.
    private func refreshRollFrames(except frameID: UUID) {
        for frame in frames where frame.id != frameID && frame.adjustments.autoLevels == .roll && frame.previewJPEG != nil {
            update(frame.id) { item in
                item.revision += 1
                item.libraryStale = item.savedToLibrary
            }
            scheduleFrame(frame.id, delay: 300)
        }
    }

    /// Debounced re-render of one frame (optionally re-measuring its levels first). A newer call cancels this one.
    private func scheduleFrame(_ frameID: UUID, delay milliseconds: Int, remeasure: Bool = false) {
        let token = (frameTokens[frameID] ?? 0) + 1
        frameTokens[frameID] = token
        let generation = generation
        let roll = rollToken
        Task {
            if milliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
            guard frameTokens[frameID] == token, generation == self.generation else { return }
            var moved = false
            if remeasure {
                guard await measure(frameID, generation: generation, rollToken: roll),
                      frameTokens[frameID] == token else { return }
                moved = updateRollLevels()
            }
            await renderFrame(frameID, generation: generation) { [weak self] in
                self?.frameTokens[frameID] == token && self?.rollToken == roll
            }
            if moved {
                refreshRollFrames(except: frameID)
            }
        }
    }

    /// Measures one frame's levels (and the roll profile, the first time). False if it failed or
    /// the roll was re-measured meanwhile (its profile would be stale: no flat field, old base).
    private func measure(_ frameID: UUID, generation: Int, rollToken token: Int) async -> Bool {
        guard let frame = frames.first(where: { $0.id == frameID }) else { return false }
        do {
            let measured = try await NegativeProcessor.shared.measureLevels(request(for: frame))
            guard generation == self.generation, token == rollToken else { return false }
            adoptProfile(measured.profile)
            update(frameID) { $0.frameLevels = measured.levels }
            return true
        } catch {
            guard generation == self.generation else { return false }
            update(frameID) { $0.isProcessing = false }
            report(error)
            return false
        }
    }

    /// Renders one frame's preview with the roll profile and its own adjustments.
    private func renderFrame(_ frameID: UUID, generation: Int, stillWanted: @escaping () -> Bool) async {
        guard generation == self.generation, stillWanted(),
              let frame = frames.first(where: { $0.id == frameID }) else { return }
        update(frameID) { $0.isProcessing = true }
        do {
            let rendered = try await NegativeProcessor.shared.prepare(request(for: frame))
            guard generation == self.generation, stillWanted() else { return }
            adoptProfile(rendered.profile)
            needsClearBase = false
            if let stretch = rendered.profile.stretch {
                var text = stretch.rangeText
                if rendered.flatFieldApplied {
                    text = "Campo plano aplicado. " + text
                }
                message = Self.exposureText(frame.lock, baseline: rendered.fileBaselineExposure, frames: frames) + text
            }
            if frame.mosaic == nil, let detected = rendered.detectedFormat, detected != frame.geometry.format {
                formatSuggestion = detected
            }
            update(frameID) { item in
                item.detectedFormat = rendered.detectedFormat
                Self.store(rendered.enhancement, in: &item)
                item.frameLevels = item.frameLevels ?? rendered.frameLevels
                item.fileBaselineExposure = rendered.fileBaselineExposure
                item.previewJPEG = rendered.previewJPEG
                item.preview = UIImage(data: rendered.previewJPEG)
                item.isProcessing = false
                item.cropDetected = rendered.cropDetected
            }
        } catch {
            guard generation == self.generation else { return }
            update(frameID) { $0.isProcessing = false }
            report(error)
        }
    }

    private func adoptProfile(_ measured: RollProfile) {
        guard profile == nil || profile?.filmType != filmType else { return }
        profile = measured
        mask = measured.linearBase
    }

    private func report(_ error: Error) {
        if let error = error as? ProcessorError {
            needsClearBase = error.asksForClearBase
            message = error.errorDescription
        } else {
            needsClearBase = false
            message = "Não foi possível inverter o negativo."
        }
    }

    private func export(frameID: UUID, generation: Int, announceFailure: Bool) async {
        guard generation == self.generation,
              let frame = frames.first(where: { $0.id == frameID }),
              profile != nil,
              !exportingFrameIDs.contains(frameID) else { return }
        exportingFrameIDs.insert(frameID)
        defer { exportingFrameIDs.remove(frameID) }
        let revision = frame.revision
        do {
            let exported = try await NegativeProcessor.shared.exportHEIF(request(for: frame))
            guard generation == self.generation else { return }
            // Both versions live next to the RAW; the faithful file is only ever written by the faithful render.
            let faithfulFile = rollDirectory.appendingPathComponent("\(frame.id.uuidString)-faithful.heic")
            try exported.faithful.write(to: faithfulFile, options: .atomic)
            var enhancedFile: URL?
            if let enhanced = exported.enhanced {
                let url = rollDirectory.appendingPathComponent("\(frame.id.uuidString)-enhanced.heic")
                try enhanced.write(to: url, options: .atomic)
                enhancedFile = url
            }
            update(frameID) { item in
                item.faithfulFile = faithfulFile
                item.enhancedFile = enhancedFile
            }
            let identifier = await saveToLibrary(exported.enhanced ?? exported.faithful, replacing: frame.assetIdentifier)
            guard generation == self.generation else { return }
            update(frameID) { item in
                item.savedToLibrary = identifier != nil || item.savedToLibrary
                item.assetIdentifier = identifier ?? item.assetIdentifier
                // Only up to date if nothing changed while the full-resolution render ran.
                if identifier != nil { item.libraryStale = item.revision != revision }
            }
            if identifier == nil, announceFailure {
                message = "Sem acesso à Fototeca. O DNG ficou na app."
            }
        } catch {
            if announceFailure {
                message = (error as? LocalizedError)?.errorDescription ?? "Não foi possível guardar o positivo."
            }
        }
    }

    // MARK: Exposure

    /// Scale that puts a frame on the roll's exposure. With a flat field, frame ÷ flat has already
    /// cancelled the light, so only the ISO × shutter ratio to the flat field is left; without one,
    /// the first frame is the reference. 1 when the exposure never changed.
    private func radiometricScale(for frame: RollFrame) -> Float {
        guard let lock = frame.exposureLock, lock.exposureSeconds > 0, lock.iso > 0 else { return 1 }
        let reference = flatFieldURL != nil ? flatFieldLock : frames.lazy.compactMap(\.exposureLock).first
        guard let reference, reference.exposureSeconds > 0, reference.iso > 0 else { return 1 }
        let scale = (reference.exposureSeconds * Double(reference.iso)) / (lock.exposureSeconds * Double(lock.iso))
        return scale.isFinite && scale > 0 ? Float(scale) : 1
    }

    /// Per-channel median of every frame's black and white densities. True if it moved visibly.
    private func updateRollLevels() -> Bool {
        let all = frames.compactMap(\.frameLevels)
        guard !all.isEmpty else { return false }
        func median(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let levels = DensityLevels(
            low: RGBColor(r: median(all.map(\.low.r)), g: median(all.map(\.low.g)), b: median(all.map(\.low.b))),
            high: RGBColor(r: median(all.map(\.high.r)), g: median(all.map(\.high.g)), b: median(all.map(\.high.b)))
        )
        defer { rollLevels = levels }
        guard let old = rollLevels else { return false }
        let moved = [
            levels.low.r - old.low.r, levels.low.g - old.low.g, levels.low.b - old.low.b,
            levels.high.r - old.high.r, levels.high.g - old.high.g, levels.high.b - old.high.b,
        ].map(abs).max() ?? 0
        return moved > 0.01
    }

    /// How far the brightest raw value is from clipping (target 0.8 of sensor white), to suggest ETTR.
    private func measureHeadroom(url: URL, angle: CGFloat, geometry: CaptureGeometry?) {
        let generation = generation
        Task {
            guard let peak = await NegativeProcessor.shared.rawPeak(url: url, angle: angle, geometry: geometry),
                  peak > 1e-4, generation == self.generation else { return }
            exposureHeadroomEV = Double(log2(0.8 / peak))
        }
    }

    // MARK: Photos

    /// Saves the positive. A frame saved before is replaced in place (an edit of the same asset,
    /// revertible in Photos) when full library access is granted; otherwise a new photo is added.
    private func saveToLibrary(_ data: Data, replacing identifier: String?) async -> String? {
        if let identifier {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if status == .authorized || status == .limited,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
               await Self.replace(asset, with: data) {
                return identifier
            }
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return nil }
        return await withCheckedContinuation { continuation in
            var created: String?
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                created = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, _ in
                continuation.resume(returning: success ? created : nil)
            }
        }
    }

    private static func replace(_ asset: PHAsset, with data: Data) async -> Bool {
        let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false
            options.canHandleAdjustmentData = { _ in false }
            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input)
            }
        }
        guard let input else { return false }
        let output = PHContentEditingOutput(contentEditingInput: input)
        do {
            try data.write(to: try output.renderedContentURL(for: .heic), options: .atomic)
        } catch {
            return false
        }
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: "scan-analog.positive",
            formatVersion: "1",
            data: Data("reprint".utf8)
        )
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).contentEditingOutput = output
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: Helpers

    /// "ISO 50 · 1/125 s · DNG BE +0.62 EV", flagging any difference from the roll's other frames.
    private static func exposureText(_ lock: CaptureLock?, baseline: Float?, frames: [RollFrame]) -> String {
        var parts: [String] = []
        if let lock {
            let shutter = lock.exposureSeconds > 0 ? String(format: "1/%.0f s", 1 / lock.exposureSeconds) : "?"
            parts.append(String(format: "ISO %.0f · %@", lock.iso, shutter))
            if !lock.allLocked { parts.append("SEM BLOQUEIO") }
            if frames.compactMap(\.lock).contains(where: { $0 != lock && !$0.matches(lock) }) {
                parts.append("≠ outros fotogramas (normalizado)")
            }
        }
        if let baseline {
            parts.append(String(format: "DNG BE %+.2f EV", baseline))
            let others = frames.compactMap(\.fileBaselineExposure)
            if let low = others.min(), let high = others.max(), high - low > 0.05 {
                parts.append(String(format: "varia %+.2f…%+.2f", low, high))
            }
        }
        return parts.isEmpty ? "" : parts.joined(separator: " · ") + "\n"
    }

    private func update(_ id: UUID, _ change: (inout RollFrame) -> Void) {
        guard let index = frames.firstIndex(where: { $0.id == id }) else { return }
        var frame = frames[index]
        change(&frame)
        frames[index] = frame
    }

    private static func makeDirectory() -> URL {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rolls", isDirectory: true)
        return root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
