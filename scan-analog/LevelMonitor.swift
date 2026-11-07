//
//  LevelMonitor.swift
//  scan-analog
//

import Combine
import CoreMotion
import SwiftUI

@MainActor
final class LevelMonitor: ObservableObject {
    @Published private(set) var rollDegrees: Double = 0
    @Published private(set) var parallelDegrees: Double = 90
    @Published private(set) var isLevel = false
    @Published private(set) var isAvailable = false

    private let motion = CMMotionManager()
    private var smoothedRoll = 0.0
    private var smoothedParallel = 90.0

    func start() {
        guard motion.isDeviceMotionAvailable else {
            isAvailable = false
            return
        }
        isAvailable = true
        motion.deviceMotionUpdateInterval = 1.0 / 8.0
        guard !motion.isDeviceMotionActive else { return }
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let data else { return }
            let gravity = data.gravity
            Task { @MainActor in
                self?.apply(gravity)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    private func apply(_ gravity: CMAcceleration) {
        let inPlane = hypot(gravity.x, gravity.y)
        let angle = atan2(gravity.x, gravity.y)
        let quarter = (angle / (.pi / 2)).rounded()
        let roll = (angle - quarter * .pi / 2) * 180 / .pi
        let displayRoll = inPlane < 0.15 ? 0 : roll

        let flatError = acos(min(1, abs(gravity.z))) * 180 / .pi
        let uprightError = abs(asin(min(1, max(-1, gravity.z)))) * 180 / .pi
        let parallel = min(flatError, uprightError)

        smoothedRoll += (displayRoll - smoothedRoll) * 0.35
        smoothedParallel += (parallel - smoothedParallel) * 0.35
        let level = abs(smoothedRoll) < 1.2 && smoothedParallel < 1.8
        guard abs(smoothedRoll - rollDegrees) > 0.4
                || abs(smoothedParallel - parallelDegrees) > 0.4
                || level != isLevel else { return }
        rollDegrees = smoothedRoll
        parallelDegrees = smoothedParallel
        isLevel = level
    }
}

struct LevelBadge: View {
    @ObservedObject var level: LevelMonitor

    var body: some View {
        if level.isAvailable {
            HStack(spacing: 8) {
                Capsule()
                    .fill(level.isLevel ? Color.green : Color.white)
                    .frame(width: 28, height: 2)
                    .rotationEffect(.degrees(-level.rollDegrees))
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(level.isLevel ? Color.green : Color.white)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .accessibilityLabel(level.isLevel ? "iPhone nivelado" : "iPhone inclinado")
        }
    }

    private var label: String {
        if level.isLevel {
            return "Nivelado"
        }
        let shown = max(abs(level.rollDegrees), level.parallelDegrees)
        return String(format: "%.1f°", shown)
    }
}
