// Adapted from AimMac / Orbit Pointer, copyright (c) 2026 Bart.
// MIT license: see THIRD_PARTY_NOTICES/AimMac-LICENSE.txt.
import Foundation

enum MouseButton: UInt8, Sendable { case left=0, right=1 }
enum ScrollSignal: UInt8, Sendable { case fingersBegan=1, fingersEnded, momentumBegan, momentumEnded }
enum SensitivityPreset: Double, CaseIterable {
    case low=0.7, medium=1.0, high=1.5
    var title: String { switch self { case .low: return "低"; case .medium: return "中"; case .high: return "高" } }
    static func nearest(_ speed: Double)->Self { allCases.min { abs($0.rawValue-speed)<abs($1.rawValue-speed) } ?? .medium }
}
