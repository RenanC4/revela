//
//  EnhanceViews.swift
//  scan-analog
//

import SwiftUI
import UIKit

/// Faithful (left of the divider) against enhanced (right). Drag anywhere to move the divider.
struct BeforeAfterView: View {
    let before: UIImage
    let after: UIImage
    var mask: UIImage?
    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            let rect = fitRect(for: before.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: mask ?? after)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                Image(uiImage: before)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: rect.width * split)
                    }
                    .offset(x: rect.minX, y: rect.minY)
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: rect.height)
                    .offset(x: rect.minX + rect.width * split - 1, y: rect.minY)
                    .shadow(radius: 2)
                HStack {
                    label("Fiel")
                    Spacer()
                    label(mask == nil ? "Melhorado" : "Máscara")
                }
                .frame(width: rect.width)
                .offset(x: rect.minX, y: rect.minY + 6)
                .padding(.horizontal, 0)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard rect.width > 0 else { return }
                    split = min(max((value.location.x - rect.minX) / rect.width, 0), 1)
                }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Comparação entre o positivo fiel e o melhorado")
        .accessibilityValue("\(Int(split * 100)) % fiel")
        .accessibilityAdjustableAction { direction in
            split = min(max(split + (direction == .increment ? 0.1 : -0.1), 0), 1)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.horizontal, 6)
    }
}

func fitRect(for size: CGSize, in container: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return .zero }
    let scale = min(container.width / size.width, container.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
}

/// Normalised (top-left origin) rect through `turns` clockwise quarter turns, and back.
enum CropRotation {
    static func rotate(_ r: CGRect, turns: Int) -> CGRect {
        var rect = r
        for _ in 0..<(((turns % 4) + 4) % 4) {
            rect = CGRect(x: 1 - (rect.minY + rect.height), y: rect.minX, width: rect.height, height: rect.width)
        }
        return rect
    }

    static func unrotate(_ r: CGRect, turns: Int) -> CGRect {
        var rect = r
        for _ in 0..<(((turns % 4) + 4) % 4) {
            rect = CGRect(x: rect.minY, y: 1 - (rect.minX + rect.width), width: rect.height, height: rect.width)
        }
        return rect
    }

    static func orientation(turns: Int) -> UIImage.Orientation {
        switch ((turns % 4) + 4) % 4 {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }
}

/// Drag the crop on the whole capture. Corners resize, the inside moves it.
struct CropEditorView: View {
    @ObservedObject var roll: RollSession
    let frameID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    /// Crop in the displayed (rotated) image, normalised, top-left origin.
    @State private var crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var dragStart: CGRect?

    private var turns: Int { roll.frames.first { $0.id == frameID }?.quarterTurns ?? 0 }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let image {
                        let rect = fitRect(for: image.size, in: geo.size)
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                        cropOverlay(in: rect)
                    } else {
                        ProgressView().tint(.white)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .background(Color.black)
            .navigationTitle("Recorte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Automático") {
                        roll.setManualCrop(nil, for: frameID)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") {
                        roll.setManualCrop(CropRotation.unrotate(crop, turns: turns), for: frameID)
                        dismiss()
                    }
                    .disabled(image == nil)
                }
            }
            .task {
                guard let result = await roll.cropEditorPreview(for: frameID), let cg = result.image.cgImage else { return }
                image = UIImage(cgImage: cg, scale: 1, orientation: CropRotation.orientation(turns: turns))
                crop = CropRotation.rotate(result.crop, turns: turns)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func cropOverlay(in rect: CGRect) -> some View {
        let box = CGRect(
            x: rect.minX + crop.minX * rect.width,
            y: rect.minY + crop.minY * rect.height,
            width: crop.width * rect.width,
            height: crop.height * rect.height
        )
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(rect)
                path.addRect(box)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: box.width, height: box.height)
                .contentShape(Rectangle())
                .offset(x: box.minX, y: box.minY)
                .gesture(drag(in: rect) { start, dx, dy in
                    var moved = start.offsetBy(dx: dx, dy: dy)
                    moved.origin.x = min(max(moved.minX, 0), 1 - moved.width)
                    moved.origin.y = min(max(moved.minY, 0), 1 - moved.height)
                    return moved
                })
            ForEach(0..<4, id: \.self) { corner in
                let x = corner % 2 == 0 ? box.minX : box.maxX
                let y = corner < 2 ? box.minY : box.maxY
                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle().inset(by: -12))
                    .position(x: x, y: y)
                    .gesture(drag(in: rect) { start, dx, dy in
                        resize(start, corner: corner, dx: dx, dy: dy)
                    })
            }
        }
    }

    private func drag(in rect: CGRect, _ change: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                crop = change(start, value.translation.width / rect.width, value.translation.height / rect.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resize(_ start: CGRect, corner: Int, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minimum: CGFloat = 0.1
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if corner % 2 == 0 { minX = min(max(minX + dx, 0), maxX - minimum) } else { maxX = max(min(maxX + dx, 1), minX + minimum) }
        if corner < 2 { minY = min(max(minY + dy, 0), maxY - minimum) } else { maxY = max(min(maxY + dy, 1), minY + minimum) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
