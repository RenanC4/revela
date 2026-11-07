//
//  MosaicModel.swift
//  scan-analog
//
//  2×2 ProRAW mosaic for a 6×6 frame shot through a clip-on macro lens.
//  The phone stays still on the copy stand; the film holder slides in X/Y between tiles.
//

import Combine
import CoreGraphics
import Foundation
import os
import UIKit

nonisolated private let mosaicLog = Logger(subsystem: "scan-analog", category: "mosaic")

/// Corner of the film frame a tile covers. Leading/trailing are the left/right of the camera
/// image as shown on screen (the rear camera is never mirrored), so the grid is always laid out
/// left-to-right to match the film physically.
nonisolated enum MosaicCorner: Int, CaseIterable, Codable, Sendable, Identifiable, Comparable {
    case topLeading = 0
    case topTrailing = 1
    case bottomLeading = 2
    case bottomTrailing = 3

    var id: Int { rawValue }
    /// 0 leading, 1 trailing.
    var column: Int { rawValue % 2 }
    /// 0 top, 1 bottom.
    var row: Int { rawValue / 2 }

    var title: String {
        switch self {
        case .topLeading: return "Canto superior esquerdo"
        case .topTrailing: return "Canto superior direito"
        case .bottomLeading: return "Canto inferior esquerdo"
        case .bottomTrailing: return "Canto inferior direito"
        }
    }

    var symbol: String {
        switch self {
        case .topLeading: return "arrow.up.left"
        case .topTrailing: return "arrow.up.right"
        case .bottomLeading: return "arrow.down.left"
        case .bottomTrailing: return "arrow.down.right"
        }
    }

    static func < (lhs: MosaicCorner, rhs: MosaicCorner) -> Bool { lhs.rawValue < rhs.rawValue }

    static func at(column: Int, row: Int) -> MosaicCorner {
        MosaicCorner(rawValue: row * 2 + column) ?? .topLeading
    }
}

/// Exposure state read from the device at the moment a tile is shot.
nonisolated struct CaptureLock: Codable, Sendable, Equatable {
    var iso: Float
    var exposureSeconds: Double
    var whiteBalanceGains: [Float]
    var lensPosition: Float
    var exposureLocked: Bool
    var focusLocked: Bool
    var whiteBalanceLocked: Bool
    var lens: String
    /// AVCaptureDevice.minimumFocusDistance at capture time, millimetres (−1 if unknown).
    var minimumFocusDistanceMM: Int

    var allLocked: Bool { exposureLocked && focusLocked && whiteBalanceLocked }

    /// Same ISO, shutter, focus and white balance (small float tolerance).
    func matches(_ other: CaptureLock) -> Bool {
        guard lens == other.lens, allLocked, other.allLocked else { return false }
        func close(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
            abs(a - b) <= tolerance * max(abs(a), abs(b), 1e-9)
        }
        guard close(Double(iso), Double(other.iso), 0.01),
              close(exposureSeconds, other.exposureSeconds, 0.01),
              abs(lensPosition - other.lensPosition) <= 0.005,
              whiteBalanceGains.count == other.whiteBalanceGains.count else { return false }
        for (a, b) in zip(whiteBalanceGains, other.whiteBalanceGains) where !close(Double(a), Double(b), 0.01) {
            return false
        }
        return true
    }
}

nonisolated struct MosaicTile: Codable, Sendable, Equatable {
    var corner: MosaicCorner
    var fileName: String
    var lock: CaptureLock
    /// UI rotation angle used to put the RAW upright.
    var angle: Double
    var timestamp: Date
}

/// Affine map from a tile's upright full-resolution pixels (Core Image, y up) into the canvas.
nonisolated struct MosaicPlacement: Codable, Sendable, Equatable {
    var corner: MosaicCorner
    var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    /// Normalised cross-correlation of the overlap that placed this tile (1 for the anchor).
    var confidence: Double

    init(corner: MosaicCorner, transform t: CGAffineTransform, confidence: Double) {
        self.corner = corner
        a = Double(t.a); b = Double(t.b); c = Double(t.c); d = Double(t.d)
        tx = Double(t.tx); ty = Double(t.ty)
        self.confidence = confidence
    }

    var transform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

/// Everything needed to rebuild the stitched linear negative, saved next to the DNGs.
nonisolated struct MosaicRecord: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var directory: URL
    var tiles: [MosaicTile]
    var placements: [MosaicPlacement]
    /// Upright full-resolution size of one tile.
    var tileWidth: Double
    var tileHeight: Double
    var canvasWidth: Double
    var canvasHeight: Double
    var method: String

    var canvasSize: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }

    func url(for tile: MosaicTile) -> URL { directory.appendingPathComponent(tile.fileName) }

    /// A 6×6 guide fitted to the canvas, so rebate sampling, Dmin and frame detection
    /// run on the assembled negative exactly as they do on a single frame.
    func geometry(for size: CGSize) -> CaptureGeometry {
        let rect = CGRect(origin: .zero, size: size)
            .insetBy(dx: size.width * 0.005, dy: size.height * 0.005)
        let layout = FilmFormat.square6.layout(filling: rect)
        return CaptureGeometry(format: .square6, viewSize: size, outer: layout.outer, inner: layout.inner, angle: 0)
    }

    static let fileName = "mosaic.json"

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Coverage model for copy text and the onion-skin guide only. Registration never assumes it.
nonisolated enum MosaicPlan {
    /// Moment 75 mm T-Series on the 1× camera at ~10 cm: about 48 × 36 mm (4:3).
    static let tileLongMM: CGFloat = 48
    static let tileShortMM: CGFloat = 36
    /// 120 film is ~61.5 mm wide; aim to cover the whole width so the rebate reaches every outer tile.
    static let coverMM: CGFloat = 62

    /// Fraction of a tile the film must slide along an axis (tile side in mm).
    static func shift(axisMM: CGFloat) -> CGFloat {
        max(coverMM - axisMM, 0) / axisMM
    }

    /// (horizontal, vertical) shift fractions for an upright tile of this aspect (width / height).
    static func shifts(imageAspect: CGFloat) -> (x: CGFloat, y: CGFloat) {
        let wide = imageAspect >= 1
        let widthMM = wide ? tileLongMM : tileShortMM
        let heightMM = wide ? tileShortMM : tileLongMM
        return (shift(axisMM: widthMM), shift(axisMM: heightMM))
    }

    static let order: [MosaicCorner] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]

    /// Plain-language direction to slide the plate from one tile to the next.
    /// The camera looks down at the film, so to see the frame's trailing side the picture must move leading-ward.
    static func instruction(from previous: MosaicCorner?, to next: MosaicCorner) -> String {
        guard let previous, previous != next else {
            return "Põe o \(next.title.lowercased()) do fotograma no ecrã, com a margem laranja à vista."
        }
        var moves: [String] = []
        let dx = next.column - previous.column
        let dy = next.row - previous.row
        if dx > 0 { moves.append("para a esquerda") }
        if dx < 0 { moves.append("para a direita") }
        if dy > 0 { moves.append("para cima") }
        if dy < 0 { moves.append("para baixo") }
        return "Desliza a placa até a imagem andar \(moves.joined(separator: " e ")) no ecrã e coincidir com a sombra. Não mexas na altura."
    }
}

/// State of the 2×2 capture on the camera screen.
@MainActor
final class MosaicSession: ObservableObject {
    struct TileState {
        var tile: MosaicTile
        var url: URL
        var proxy: UIImage?
    }

    @Published private(set) var tiles: [MosaicCorner: TileState] = [:]
    @Published var target: MosaicCorner = .topLeading
    @Published private(set) var message: String?
    @Published private(set) var isStitching = false
    @Published private(set) var failedCorners: Set<MosaicCorner> = []
    /// The stitched mosaic is now a roll frame; the tiles belong to it.
    @Published private(set) var finished = false

    private(set) var directory: URL?
    private var lastCaptured: MosaicCorner?

    var isComplete: Bool { tiles.count == 4 }
    var isEmpty: Bool { tiles.isEmpty }
    var referenceLock: CaptureLock? { MosaicPlan.order.compactMap { tiles[$0]?.tile.lock }.first }

    var instruction: String {
        if finished { return "Mosaico juntado e guardado no rolo." }
        if isStitching { return "A juntar as quatro peças…" }
        if isComplete && failedCorners.isEmpty { return "Quatro peças. Toca em Juntar." }
        if tiles.isEmpty {
            return "1.ª peça: \(target.title.lowercased()) com margem laranja. Bloqueia branco e exposição antes."
        }
        return MosaicPlan.instruction(from: lastCaptured, to: target)
    }

    /// Captured neighbours that share an edge with the target, for the onion skin.
    func onionNeighbours() -> [(corner: MosaicCorner, image: UIImage)] {
        MosaicCorner.allCases.compactMap { corner in
            guard corner != target,
                  abs(corner.column - target.column) + abs(corner.row - target.row) == 1,
                  let image = tiles[corner]?.proxy else { return nil }
            return (corner, image)
        }
    }

    func select(_ corner: MosaicCorner) {
        guard !isStitching, !finished else { return }
        target = corner
        message = tiles[corner] == nil ? nil : "Repetir \(corner.title.lowercased()). As outras peças ficam."
    }

    func clearMessage() { message = nil }

    func refuse(_ text: String) { message = text }

    /// Stores one tile, or restarts the mosaic if the exposure lock moved since the first tile.
    func store(data: Data, geometry: CaptureGeometry, lock: CaptureLock, corner: MosaicCorner, rollDirectory: URL) {
        // Never overwrite a tile while registration is reading it.
        guard !finished, !isStitching else { return }
        guard lock.allLocked else {
            message = "Exposição, foco ou branco não estavam bloqueados. Peça não guardada."
            return
        }
        if let reference = MosaicPlan.order.filter({ $0 != corner }).compactMap({ tiles[$0]?.tile.lock }).first,
           !reference.matches(lock) {
            mosaicLog.error("lock changed between tiles")
            discard()
            message = "O bloqueio de exposição, foco ou branco mudou entre peças. Mosaico recomeçado: volta a bloquear e repete a 1.ª peça."
            return
        }
        let folder: URL
        if let directory {
            folder = directory
        } else {
            folder = rollDirectory.appendingPathComponent("mosaic-\(UUID().uuidString)", isDirectory: true)
        }
        let fileName = "tile-\(corner.rawValue).dng"
        let url = folder.appendingPathComponent(fileName)
        let tile = MosaicTile(corner: corner, fileName: fileName, lock: lock, angle: Double(geometry.angle), timestamp: Date())
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(tile).write(to: folder.appendingPathComponent("tile-\(corner.rawValue).json"), options: .atomic)
        } catch {
            message = "Não foi possível guardar a peça."
            return
        }
        directory = folder
        tiles[corner] = TileState(tile: tile, url: url, proxy: nil)
        failedCorners.remove(corner)
        lastCaptured = corner
        message = nil
        if let next = MosaicPlan.order.first(where: { tiles[$0] == nil }) {
            target = next
        }
        Task {
            let proxy = try? await NegativeProcessor.shared.tileProxy(url: url, angle: geometry.angle)
            guard tiles[corner]?.url == url, let proxy else { return }
            tiles[corner]?.proxy = UIImage(cgImage: proxy.image)
            if proxy.edgeSharpness < 0.35 {
                message = "\(corner.title): nítido no centro e suave nas bordas. Mantém a altura do suporte na faixa de foco da lente (cerca de 7–10 cm da lente ao filme) e só desliza X/Y."
            }
        }
    }

    /// Registers and records the mosaic. Throws `MosaicError` with the corners to recapture.
    func stitch(flatFieldURL: URL?) async throws -> MosaicRecord {
        guard isComplete, let directory else { throw MosaicError.incomplete }
        isStitching = true
        failedCorners = []
        message = nil
        defer { isStitching = false }
        let tileList = MosaicPlan.order.compactMap { tiles[$0]?.tile }
        do {
            let record = try await NegativeProcessor.shared.registerMosaic(
                directory: directory,
                tiles: tileList,
                flatFieldURL: flatFieldURL
            )
            try record.save()
            finished = true
            return record
        } catch let error as MosaicError {
            if case .registration(let corners, _) = error {
                failedCorners = corners
            }
            message = error.errorDescription
            throw error
        }
    }

    /// Deletes the tiles of an unfinished mosaic.
    func discard() {
        if !finished, let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        reset()
    }

    /// Starts a new mosaic. A finished mosaic keeps its files: they are the roll frame's RAWs.
    func reset() {
        tiles = [:]
        directory = nil
        target = .topLeading
        lastCaptured = nil
        failedCorners = []
        finished = false
        isStitching = false
        message = nil
    }
}

nonisolated enum MosaicError: LocalizedError {
    case incomplete
    case unreadableTile(MosaicCorner)
    case registration(Set<MosaicCorner>, String)

    var errorDescription: String? {
        switch self {
        case .incomplete:
            return "Faltam peças do mosaico."
        case .unreadableTile(let corner):
            return "Não foi possível ler a peça \(corner.title.lowercased())."
        case .registration(let corners, let detail):
            let names = corners.sorted().map { $0.title.lowercased() }.joined(separator: ", ")
            return "As peças não sobrepõem o suficiente para alinhar (\(detail)). Repete: \(names)."
        }
    }
}
