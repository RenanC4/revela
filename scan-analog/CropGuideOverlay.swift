//
//  CropGuideOverlay.swift
//  scan-analog
//

import SwiftUI

struct CropGuideOverlay: View {
    let layout: FilmLayout

    var body: some View {
        Canvas { context, size in
            var dimmed = Path()
            dimmed.addRect(CGRect(origin: .zero, size: size))
            dimmed.addRect(layout.outer)
            context.fill(dimmed, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))

            context.stroke(
                Path(layout.outer),
                with: .color(.white.opacity(0.9)),
                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
            )
            context.stroke(Path(layout.inner), with: .color(.white), lineWidth: 1.5)
            strokeCorners(in: &context, around: layout.inner)

            let band = layout.inner.minY - layout.outer.minY
            if band > 18 {
                let label = Text("rebate")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                context.draw(
                    label,
                    at: CGPoint(x: layout.outer.midX, y: layout.outer.minY + band / 2),
                    anchor: .center
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func strokeCorners(in context: inout GraphicsContext, around rect: CGRect) {
        let length: CGFloat = 16
        var path = Path()
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY + length), CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + length, y: rect.minY)),
            (CGPoint(x: rect.maxX - length, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + length)),
            (CGPoint(x: rect.minX, y: rect.maxY - length), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX + length, y: rect.maxY)),
            (CGPoint(x: rect.maxX - length, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY - length)),
        ]
        for (start, corner, end) in corners {
            path.move(to: start)
            path.addLine(to: corner)
            path.addLine(to: end)
        }
        context.stroke(path, with: .color(.white), lineWidth: 2)
    }
}
