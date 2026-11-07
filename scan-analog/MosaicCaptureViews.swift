//
//  MosaicCaptureViews.swift
//  scan-analog
//

import SwiftUI

/// Where the aspect-fit camera image sits inside the preview.
func mosaicImageRect(aspect: CGFloat, in size: CGSize) -> CGRect {
    guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
    let width = min(size.width, size.height * aspect)
    let height = width / aspect
    return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
}

/// Onion skin of the neighbouring tiles in the expected overlap, plus a marker for the target corner.
struct MosaicGuideOverlay: View {
    @ObservedObject var mosaic: MosaicSession
    let viewSize: CGSize
    let imageAspect: CGFloat

    var body: some View {
        let rect = mosaicImageRect(aspect: imageAspect, in: viewSize)
        let shift = MosaicPlan.shifts(imageAspect: imageAspect)
        ZStack(alignment: .topLeading) {
            ForEach(mosaic.isStitching || mosaic.finished ? [] : mosaic.onionNeighbours(), id: \.corner) { neighbour in
                let dx = -CGFloat(mosaic.target.column - neighbour.corner.column) * shift.x * rect.width
                let dy = -CGFloat(mosaic.target.row - neighbour.corner.row) * shift.y * rect.height
                // Clipping to the camera image leaves exactly the band both tiles should share.
                Image(uiImage: neighbour.image)
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: dx, y: dy)
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    .clipped()
                    .opacity(0.33)
                    .offset(x: rect.minX, y: rect.minY)
            }
            Path { path in
                path.addRect(rect)
            }
            .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            cornerMarker(in: rect)
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func cornerMarker(in rect: CGRect) -> some View {
        let corner = mosaic.target
        let inset = min(rect.width, rect.height) * 0.05
        let length = min(rect.width, rect.height) * 0.18
        let x = corner.column == 0 ? rect.minX + inset : rect.maxX - inset
        let y = corner.row == 0 ? rect.minY + inset : rect.maxY - inset
        let sx: CGFloat = corner.column == 0 ? 1 : -1
        let sy: CGFloat = corner.row == 0 ? 1 : -1
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: y + sy * length))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + sx * length, y: y))
            }
            .stroke(.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            Text("canto do fotograma\n+ margem laranja")
                .font(.caption2.weight(.semibold))
                .multilineTextAlignment(corner.column == 0 ? .leading : .trailing)
                .foregroundStyle(.yellow)
                .padding(4)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
                .position(x: x + sx * length * 0.9, y: y + sy * length * 0.55)
        }
    }
}

/// 2×2 grid of the film frame's corners with stitch / discard actions.
struct MosaicPanel: View {
    @ObservedObject var mosaic: MosaicSession
    var onStitch: () -> Void
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                grid
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mosaico 6×6 · 2×2")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    if mosaic.finished {
                        actionButton("Novo mosaico", filled: true) { mosaic.reset() }
                    } else {
                        actionButton(mosaic.isStitching ? "A juntar…" : "Juntar", filled: mosaic.isComplete) {
                            onStitch()
                        }
                        .disabled(!mosaic.isComplete || mosaic.isStitching)
                        actionButton("Descartar", filled: false) { confirmDiscard = true }
                            .disabled(mosaic.isEmpty || mosaic.isStitching)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(mosaic.message ?? mosaic.instruction)
                .font(.caption)
                .foregroundStyle(mosaic.failedCorners.isEmpty ? .white : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .confirmationDialog("Apagar as peças deste mosaico?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Apagar peças", role: .destructive) { mosaic.discard() }
        }
    }

    // Always left-to-right: the cells mirror the camera image, which is never flipped.
    private var grid: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                cell(.topLeading)
                cell(.topTrailing)
            }
            GridRow {
                cell(.bottomLeading)
                cell(.bottomTrailing)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func cell(_ corner: MosaicCorner) -> some View {
        let state = mosaic.tiles[corner]
        let failed = mosaic.failedCorners.contains(corner)
        let isTarget = mosaic.target == corner && !mosaic.finished
        return Button {
            mosaic.select(corner)
        } label: {
            ZStack {
                Color.white.opacity(0.12)
                if let proxy = state?.proxy {
                    Image(uiImage: proxy)
                        .resizable()
                        .scaledToFill()
                }
                Image(systemName: state == nil ? corner.symbol : "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(failed ? Color.red : (isTarget ? Color.yellow : Color.white.opacity(0.4)), lineWidth: isTarget || failed ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(corner.title)\(state == nil ? "" : ", capturado")")
    }

    private func actionButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(filled ? Color.white : Color.white.opacity(0.16), in: Capsule())
                .foregroundStyle(filled ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}
