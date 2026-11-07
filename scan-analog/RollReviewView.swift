//
//  RollReviewView.swift
//  scan-analog
//

import SwiftUI

struct RollReviewView: View {
    @ObservedObject var roll: RollSession
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFrameID: UUID?

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                if roll.frames.isEmpty {
                    Text("Ainda não há fotogramas.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 48)
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(roll.frames) { frame in
                            Button {
                                selectedFrameID = frame.id
                            } label: {
                                FrameThumbnail(frame: frame)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
            }
            .background(Color.black)
            .navigationTitle("Rolo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if roll.staleCount > 0 {
                        Button("Atualizar \(roll.staleCount)") { roll.exportStale() }
                            .accessibilityLabel("Atualizar \(roll.staleCount) fotos na Fototeca")
                    }
                    Button("Novo rolo") { roll.beginNewRoll() }
                }
            }
            .navigationDestination(item: $selectedFrameID) { id in
                FrameDetailView(roll: roll, frameID: id)
            }
            .overlay(alignment: .bottom) {
                if let message = roll.message {
                    Text(message)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct FrameThumbnail: View {
    let frame: RollFrame

    var body: some View {
        Color.black
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let preview = frame.enhance.doesAnything ? (frame.enhancedPreview ?? frame.preview) : frame.preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                } else if frame.isProcessing {
                    ProgressView()
                        .tint(.white)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if frame.savedToLibrary {
                    Image(systemName: frame.libraryStale ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .clipped()
    }
}

private struct FrameDetailView: View {
    @ObservedObject var roll: RollSession
    let frameID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showsInfo = false
    @State private var showsMask = false
    @State private var showsCrop = false

    private var frame: RollFrame? {
        roll.frames.first { $0.id == frameID }
    }

    private var adjustments: Adjustments {
        frame?.adjustments ?? .neutral
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                if let frame, let preview = frame.preview {
                    if frame.enhance.doesAnything, let enhanced = frame.enhancedPreview {
                        BeforeAfterView(before: preview, after: enhanced, mask: showsMask ? frame.maskPreview : nil)
                    } else {
                        // The faithful positive, exactly as rendered.
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .overlay(alignment: .topTrailing) {
                if frame?.isProcessing == true, frame?.preview != nil {
                    ProgressView()
                        .tint(.white)
                        .padding(8)
                }
            }
            .frame(maxHeight: .infinity)
            controls
        }
        .background(Color.black)
        .navigationTitle("Positivo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsCrop = true
                } label: {
                    Image(systemName: "crop")
                }
                .accessibilityLabel("Ajustar recorte")
                Button {
                    roll.rotate(frameID: frameID)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .accessibilityLabel("Rodar 90°")
                Menu {
                    Button("Aplicar ao rolo todo") {
                        roll.applyToRoll(from: frameID)
                    }
                    Button("Repor ajustes", role: .destructive) {
                        roll.resetAdjustments(frameID: frameID)
                    }
                    Button(showsInfo ? "Esconder medições" : "Mostrar medições") {
                        showsInfo.toggle()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onChange(of: roll.frames.isEmpty) { _, empty in
            if empty { dismiss() }
        }
        .sheet(isPresented: $showsCrop) {
            CropEditorView(roll: roll, frameID: frameID)
        }
    }

    private var enhance: EnhanceSettings {
        frame?.enhance ?? EnhanceSettings()
    }

    private func enhanceBinding<Value>(_ keyPath: WritableKeyPath<EnhanceSettings, Value>) -> Binding<Value> {
        Binding(
            get: { enhance[keyPath: keyPath] },
            set: { value in
                var next = enhance
                next[keyPath: keyPath] = value
                roll.setEnhance(next, for: frameID)
            }
        )
    }

    /// Optional layer: off shows and saves the faithful inversion only.
    private var enhanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Melhorar · pó e look", isOn: enhanceBinding(\.enabled))
                .font(.subheadline)
                .foregroundStyle(.white)
                .tint(.white)
            if enhance.enabled {
                Picker("Pó e riscos", selection: enhanceBinding(\.dust)) {
                    ForEach(DustStrength.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Look", selection: enhanceBinding(\.look)) {
                    ForEach(FilmLook.available(for: roll.filmType)) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Mostrar máscara do pó · \(frame?.defects ?? 0) defeitos", isOn: $showsMask)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .tint(.red)
                    .disabled(enhance.dust == .off)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsInfo, let message = roll.message {
                Text(message)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if let mask = roll.mask {
                    Circle()
                        .fill(displayColor(mask))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                }
                Text(frame?.mosaic == nil ? roll.filmType.title : "\(roll.filmType.title) · mosaico 2×2")
                    .font(.footnote)
                    .foregroundStyle(.white)
                Spacer()
                Menu {
                    ForEach(AutoLevels.allCases) { mode in
                        Button {
                            var next = adjustments
                            next.autoLevels = mode
                            roll.setAdjustments(next, for: frameID)
                        } label: {
                            if mode == adjustments.autoLevels {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    Text("Auto: \(adjustments.autoLevels.title)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(adjustments.autoLevels == .off ? Color.white.opacity(0.16) : Color.white, in: Capsule())
                        .foregroundStyle(adjustments.autoLevels == .off ? Color.white : Color.black)
                }
                toggleChip(frame?.cropDetected == true || !adjustments.autoCrop ? "Recorte" : "Recorte ?", isOn: adjustments.autoCrop) { value in
                    var next = adjustments
                    next.autoCrop = value
                    roll.setAdjustments(next, for: frameID)
                }
            }

            ScrollView {
                VStack(spacing: 10) {
                    enhanceSection
                    Divider().overlay(.white.opacity(0.2))
                    slider("Exposição", \.exposure, -2...2, format: "%+.1f EV")
                    slider("Contraste", \.contrast, 0.5...1.8, format: "%.2f")
                    slider("Altas luzes", \.highlights, -1...1, format: "%+.2f")
                    slider("Sombras", \.shadows, -1...1, format: "%+.2f")
                    slider("Temperatura", \.temperature, -1...1, format: "%+.2f")
                    slider("Tint", \.tint, -1...1, format: "%+.2f")
                    slider("Saturação", \.saturation, 0...2, format: "%.2f")
                    // Manual square crop when frame detection is off or fails; negative keeps a thin rebate.
                    slider("Margem do recorte", \.cropInset, -0.04...0.08, format: "%+.3f")
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)

            Button {
                roll.export(frameID: frameID)
            } label: {
                Group {
                    if roll.isExporting(frameID) {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Text(frame?.savedToLibrary == true
                             ? (frame?.libraryStale == true ? "Atualizar na Fototeca ↻" : "Atualizar na Fototeca")
                             : "Guardar na Fototeca")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
            }
            .disabled(frame?.preview == nil || roll.isExporting(frameID))
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
    }

    private func slider(
        _ title: String,
        _ keyPath: WritableKeyPath<Adjustments, Double>,
        _ range: ClosedRange<Double>,
        format: String
    ) -> some View {
        let value = Binding<Double>(
            get: { adjustments[keyPath: keyPath] },
            set: { newValue in
                var next = adjustments
                next[keyPath: keyPath] = newValue
                roll.setAdjustments(next, for: frameID)
            }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                value.wrappedValue = Adjustments.neutral[keyPath: keyPath]
            }
            Slider(value: value, in: range)
                .tint(.white)
        }
    }

    private func toggleChip(_ title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> some View {
        Button {
            action(!isOn)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isOn ? Color.white : Color.white.opacity(0.16), in: Capsule())
                .foregroundStyle(isOn ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }

    private func displayColor(_ mask: RGBColor) -> Color {
        Color(
            red: Double(pow(mask.r, 1 / 2.2)),
            green: Double(pow(mask.g, 1 / 2.2)),
            blue: Double(pow(mask.b, 1 / 2.2))
        )
    }
}
