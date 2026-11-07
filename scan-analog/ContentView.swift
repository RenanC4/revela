//
//  ContentView.swift
//  scan-analog
//

import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraController()
    @StateObject private var roll = RollSession()
    @StateObject private var level = LevelMonitor()
    @StateObject private var mosaic = MosaicSession()
    @State private var bridge = PreviewBridge()
    @State private var format = FilmFormat.mm35
    @State private var showsRoll = false
    @State private var shutterFlash = false
    @State private var lockPoint: CGPoint?
    @State private var lens = 0.5
    @State private var draggingFocus = false
    @State private var lastShutter = Date.distantPast
    @State private var useTimer = false
    @State private var countdown: Int?
    @State private var frameSnapshot = FrameSnapshot()
    @State private var safeInsets = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
    @State private var pickingBase = false
    @State private var livePositive = false

    var body: some View {
        GeometryReader { geo in
            let layout = format.layout(filling: guideRect(in: geo.size))
            let markingBase = pickingBase || roll.needsClearBase
            let mosaicMode = isMosaicMode
            let fullTap = markingBase || mosaicMode
            let _ = frameSnapshot.store(format: format, viewSize: geo.size, layout: layout)
            let _ = frameSnapshot.mosaicMode = mosaicMode
            let _ = camera.live.update(filmType: roll.filmType, geometry: frameSnapshot.geometry)
            ZStack {
                CameraPreview(session: camera.session, isRunning: camera.isRunning, bridge: bridge, fill: !mosaicMode)
                    .ignoresSafeArea()
                if livePositive && !mosaicMode {
                    LivePositiveView(renderer: camera.live)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                if camera.isAuthorized {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(
                            width: fullTap ? geo.size.width : layout.outer.width,
                            height: fullTap ? geo.size.height : max(layout.outer.height, 1)
                        )
                        .position(
                            x: fullTap ? geo.size.width / 2 : layout.outer.midX,
                            y: fullTap ? geo.size.height / 2 : layout.outer.midY
                        )
                        .gesture(
                            SpatialTapGesture().onEnded { value in
                                guard camera.isRunning else { return }
                                let point = CGPoint(
                                    x: (fullTap ? 0 : layout.outer.minX) + value.location.x,
                                    y: (fullTap ? 0 : layout.outer.minY) + value.location.y
                                )
                                if markingBase {
                                    pickingBase = false
                                    roll.setClearBase(CGPoint(
                                        x: point.x / geo.size.width,
                                        y: point.y / geo.size.height
                                    ))
                                    return
                                }
                                lockPoint = point
                                camera.lockMetering(at: bridge.devicePoint(from: point))
                            }
                        )
                    if mosaicMode {
                        MosaicGuideOverlay(mosaic: mosaic, viewSize: geo.size, imageAspect: tileAspect)
                    } else {
                        CropGuideOverlay(layout: layout)
                    }
                    if let clearBase = roll.clearBase {
                        Circle()
                            .strokeBorder(.yellow, lineWidth: 2)
                            .frame(width: 36, height: 36)
                            .position(x: clearBase.x * geo.size.width, y: clearBase.y * geo.size.height)
                            .allowsHitTesting(false)
                    }
                    if let lockPoint, camera.meteringState != .automatic {
                        LockReticle(locked: camera.meteringState == .locked)
                            .position(lockPoint)
                    }
                }

                if camera.permissionDenied {
                    permissionDeniedView
                } else if camera.isAuthorized, !camera.isRunning {
                    startingView
                }

                Color.white
                    .opacity(shutterFlash ? 0.9 : 0)
                    .allowsHitTesting(false)

                VStack(spacing: 10) {
                    topBar
                        .padding(.horizontal, 16)
                    if camera.isRunning {
                        Text(markingBase
                             ? "Toca na margem laranja, fora da imagem."
                             : mosaicMode && !camera.rollLocked
                             ? "Toca na margem laranja (ou num meio-tom do filme, nunca na luz nua) para bloquear."
                             : camera.rollLocked
                             ? (mosaicMode ? "Bloqueado para as 4 peças. Só desliza X/Y." : "Exposição bloqueada. Dispara o rolo.")
                             : "Toca no rebate para bloquear o rolo.")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.45), in: Capsule())
                            .allowsHitTesting(false)
                    }
                    if let countdown {
                        Text("\(countdown)")
                            .font(.system(size: 72, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(radius: 8)
                            .allowsHitTesting(false)
                    }
                    Spacer()
                        .allowsHitTesting(false)
                    if let statusMessage = camera.statusMessage {
                        statusBanner(statusMessage)
                            .allowsHitTesting(false)
                    }
                    if let message = roll.message {
                        Text(message)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                            .padding(8)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .allowsHitTesting(false)
                    }
                    if mosaicMode {
                        MosaicPanel(mosaic: mosaic, onStitch: stitchMosaic)
                            .padding(.horizontal, 16)
                    }
                    focusSlider
                        .padding(.horizontal, 28)
                    toolRow
                        .padding(.horizontal, 16)
                    controls(layout: layout, viewSize: geo.size)
                        .padding(.bottom, 4)
                }
                .padding(.top, safeInsets.top + 8)
                .padding(.bottom, safeInsets.bottom + 8)
                .padding(.leading, max(safeInsets.left, 16))
                .padding(.trailing, max(safeInsets.right, 16))
                .zIndex(1)

                SafeAreaProbe { insets in
                    if insets != safeInsets {
                        safeInsets = insets
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(camera.isAuthorized && !showsRoll)
        .sensoryFeedback(.impact(weight: .medium), trigger: camera.captureID)
        .sensoryFeedback(.selection, trigger: camera.meteringState == .locked)
        .onAppear {
            camera.onRawCaptured = { [roll, mosaic] data, geometry, kind, lock in
                if case .tile(let corner) = kind {
                    mosaic.store(data: data, geometry: geometry, lock: lock, corner: corner, rollDirectory: roll.directory)
                } else {
                    roll.ingest(data: data, geometry: geometry, kind: kind, lock: lock)
                }
            }
            roll.onNewRoll = { [mosaic] in
                pickingBase = false
                mosaic.discard()
                camera.remeasure()
            }
            bridge.onHardwareShutter = { [camera, frameSnapshot, mosaic, level] in
                guard let geometry = frameSnapshot.geometry else { return }
                Task { @MainActor in
                    guard frameSnapshot.mosaicMode else {
                        camera.capture(geometry, kind: .frame)
                        return
                    }
                    guard !mosaic.isStitching, !mosaic.finished else { return }
                    if let reason = Self.tileBlocker(camera: camera, level: level) {
                        mosaic.refuse(reason)
                        return
                    }
                    camera.capture(geometry, kind: .tile(mosaic.target))
                }
            }
            camera.start()
            level.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            level.stop()
            camera.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.start()
                level.start()
            case .background:
                level.stop()
                camera.stop()
            default:
                break
            }
        }
        .onChange(of: isMosaicMode) { _, mosaicMode in
            camera.live.setEnabled(livePositive && !mosaicMode)
        }
        .onChange(of: camera.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onChange(of: camera.lensPosition) { _, position in
            if !draggingFocus {
                lens = position
            }
        }
        .onChange(of: camera.captureID) { _, _ in
            shutterFlash = true
            Task {
                try? await Task.sleep(for: .milliseconds(90))
                shutterFlash = false
            }
        }
        .fullScreenCover(isPresented: $showsRoll) {
            RollReviewView(roll: roll)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            LevelBadge(level: level)
            Spacer()
            if !camera.captureModeLabel.isEmpty {
                Text(camera.captureModeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
            }
            Picker("Formato", selection: $format) {
                ForEach(FilmFormat.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
    }

    private var focusSlider: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Perto")
                Spacer()
                Text(focusCaption)
                Spacer()
                Text("Longe")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            Slider(
                value: $lens,
                in: 0...1,
                onEditingChanged: { editing in
                    draggingFocus = editing
                    camera.setLensPosition(lens)
                }
            )
            .tint(.white)
            .onChange(of: lens) { _, position in
                guard draggingFocus else { return }
                camera.setLensPosition(position)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(!camera.isRunning)
    }

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !isMosaicMode {
                    toolButton(livePositive ? "Positivo ✓" : "Positivo") {
                        livePositive.toggle()
                        camera.live.setEnabled(livePositive)
                    }
                }
                toolButton(camera.whiteBalanceLocked ? "Branco ✓" : "Branco") {
                    camera.lockWhiteBalance()
                }
                toolButton(roll.hasFlatField ? "Luz ✓" : "Luz") {
                    guard camera.rollLocked else {
                        camera.showLockedRequirement()
                        return
                    }
                    shoot(kind: .flatField, delayed: false)
                }
                toolButton(useTimer ? "2 s ✓" : "2 s") {
                    useTimer.toggle()
                }
                toolButton((pickingBase || roll.needsClearBase) ? "Base…" : (roll.clearBase == nil ? "Base" : "Base ✓")) {
                    if roll.needsClearBase {
                        pickingBase = true
                    } else {
                        pickingBase.toggle()
                    }
                }
                if camera.rollLocked {
                    toolButton("Remedir") {
                        camera.remeasure()
                    }
                    if let headroom = roll.exposureHeadroomEV {
                        if headroom < -0.1 {
                            // Brightest raw value already clips: step down.
                            toolButton("Satura −1 EV") {
                                camera.adjustLockedExposure(by: -1) { roll.exposureChanged(by: $0) }
                            }
                        } else if headroom >= 0.5 {
                            // Expose to the right: more signal in the dense negative highlights, less noise.
                            let step = min((headroom * 2).rounded(.down) / 2, 3)
                            toolButton(String(format: "ETTR +%.1f EV", step)) {
                                camera.adjustLockedExposure(by: step) { roll.exposureChanged(by: $0) }
                            }
                        }
                    }
                }
                Menu {
                    ForEach(CameraLens.allCases) { lens in
                        Button {
                            camera.selectLens(lens)
                        } label: {
                            if lens == camera.cameraLens {
                                Label(lens.title, systemImage: "checkmark")
                            } else {
                                Text(lens.title)
                            }
                        }
                    }
                } label: {
                    Text(camera.cameraLens.shortTitle)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.white.opacity(0.16), in: Capsule())
                Menu {
                    ForEach(FilmType.allCases) { type in
                        Button(type.title) {
                            roll.setFilmType(type)
                        }
                    }
                } label: {
                    Text(roll.filmType.title)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.white.opacity(0.16), in: Capsule())
            }
            .padding(.horizontal, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func toolButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.white.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var focusCaption: String {
        let distance = camera.cameraLens.usesAddOnLens
            ? nil
            : camera.minimumFocusCentimeters.map { "mín. \($0) cm" }
        switch (camera.lensLabel, distance) {
        case let (label, distance?) where !label.isEmpty:
            return "\(label) · \(distance)"
        case let (label, nil) where !label.isEmpty:
            return label
        case let ("", distance?):
            return distance
        default:
            return ""
        }
    }

    private func controls(layout: FilmLayout, viewSize: CGSize) -> some View {
        HStack {
            lastPhotoButton
            Spacer()
            shutterButton(layout: layout, viewSize: viewSize)
            Spacer()
            rollButton
        }
    }

    private func shutterButton(layout: FilmLayout, viewSize: CGSize) -> some View {
        Button {
            let now = Date()
            guard now.timeIntervalSince(lastShutter) > 0.45 else { return }
            lastShutter = now
            frameSnapshot.store(format: format, viewSize: viewSize, layout: layout)
            if isMosaicMode {
                if let reason = Self.tileBlocker(camera: camera, level: level) {
                    mosaic.refuse(reason)
                    return
                }
                if level.isAvailable, level.parallelDegrees > 1.8 {
                    mosaic.refuse(String(format: "Aviso: iPhone %.1f° fora do paralelo. Peça tirada na mesma.", level.parallelDegrees))
                }
                shoot(kind: .tile(mosaic.target), delayed: useTimer)
            } else {
                shoot(kind: .frame, delayed: useTimer)
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(.white)
                    .frame(width: 64, height: 64)
            }
        }
        .buttonStyle(.plain)
        .disabled(!camera.isRunning || camera.captureModeLabel.isEmpty || (isMosaicMode && (mosaic.isStitching || mosaic.finished)))
        .opacity(camera.isRunning && !camera.captureModeLabel.isEmpty ? 1 : 0.45)
        .accessibilityLabel("Tirar foto")
    }

    private var lastPhotoButton: some View {
        Button {
            showsRoll = true
        } label: {
            if let image = roll.frames.last?.preview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white, lineWidth: 1.5)
                    }
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                    .overlay {
                        if roll.frames.last?.isProcessing == true {
                            ProgressView()
                                .tint(.white)
                        }
                    }
            }
        }
        .disabled(roll.frames.isEmpty)
        .accessibilityLabel("Ver rolo")
    }

    private var rollButton: some View {
        Button {
            showsRoll = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                Text(roll.frames.isEmpty ? "Rolo" : "\(roll.frames.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel("Abrir o rolo")
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
            Text("Sem acesso à câmara")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("O scan-analog precisa da câmara traseira para tirar fotografias.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Button("Abrir Definições") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(.headline)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.white, in: Capsule())
            .foregroundStyle(.black)
        }
        .padding(32)
    }

    @ViewBuilder
    private var startingView: some View {
        if let statusMessage = camera.statusMessage {
            Text(statusMessage)
                .font(.body)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(32)
        } else {
            ProgressView()
                .tint(.white)
        }
    }

    private func statusBanner(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
    }

    private func shoot(kind: CaptureKind, delayed: Bool) {
        guard let geometry = frameSnapshot.geometry else { return }
        guard delayed else {
            camera.capture(geometry, kind: kind)
            return
        }
        countdown = 2
        Task {
            try? await Task.sleep(for: .seconds(1))
            countdown = 1
            try? await Task.sleep(for: .seconds(1))
            countdown = nil
            guard let geometry = frameSnapshot.geometry else { return }
            camera.capture(geometry, kind: kind)
        }
    }

    /// 6×6 through the clip-on macro cannot fit one shot: capture a 2×2 mosaic.
    /// 35 mm is always one shot; 6×6 on the built-in ultra wide fits one shot too.
    private var isMosaicMode: Bool {
        format == .square6 && camera.cameraLens == .clipOnMacro
    }

    /// Upright tile aspect (width / height) from a captured proxy, else the 4:3 sensor in portrait.
    private var tileAspect: CGFloat {
        if let proxy = mosaic.tiles.values.compactMap(\.proxy).first, proxy.size.height > 0 {
            return proxy.size.width / proxy.size.height
        }
        return 3.0 / 4.0
    }

    /// Why a tile may not be shot now, or nil.
    static func tileBlocker(camera: CameraController, level: LevelMonitor) -> String? {
        if !camera.whiteBalanceLocked {
            return "Antes da 1.ª peça: bloqueia o Branco no backlight sem filme."
        }
        if !camera.rollLocked {
            return "Toca na margem laranja do filme para bloquear exposição e foco. Sem margem à vista, toca num meio-tom — nunca na luz nua."
        }
        if level.isAvailable, level.parallelDegrees > 3 {
            return String(format: "iPhone %.1f° fora do paralelo. Endireita o suporte antes de tirar a peça.", level.parallelDegrees)
        }
        return nil
    }

    private func stitchMosaic() {
        let geometry = frameSnapshot.geometry
        Task {
            guard let record = try? await mosaic.stitch(flatFieldURL: roll.currentFlatFieldURL),
                  let geometry else { return }
            roll.ingestMosaic(record, geometry: geometry)
        }
    }

    private func guideRect(in size: CGSize) -> CGRect {
        let top = safeInsets.top + 96
        let bottom = safeInsets.bottom + 228
        let side = max(safeInsets.left, safeInsets.right, 20)
        return CGRect(
            x: side,
            y: top,
            width: max(size.width - side * 2, 1),
            height: max(size.height - top - bottom, 1)
        )
    }
}

private final class FrameSnapshot {
    var geometry: CaptureGeometry?
    var mosaicMode = false

    func store(format: FilmFormat, viewSize: CGSize, layout: FilmLayout) {
        geometry = CaptureGeometry(
            format: format,
            viewSize: viewSize,
            outer: layout.outer,
            inner: layout.inner,
            angle: 0
        )
    }
}

private struct SafeAreaProbe: UIViewRepresentable {
    var onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.publish()
    }

    final class ProbeView: UIView {
        var onChange: ((UIEdgeInsets) -> Void)?
        private var last = UIEdgeInsets(top: -1, left: -1, bottom: -1, right: -1)

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publish()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publish()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            publish()
        }

        func publish() {
            let insets = window?.safeAreaInsets ?? safeAreaInsets
            guard insets.top > 1 || insets.bottom > 1, insets != last else { return }
            last = insets
            onChange?(insets)
        }
    }
}

private struct LockReticle: View {
    var locked: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(locked ? Color.yellow : Color.white, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
}
