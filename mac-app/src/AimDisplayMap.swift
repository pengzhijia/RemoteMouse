// Adapted from AimMac / Orbit Pointer, copyright (c) 2026 Bart.
// MIT license: see THIRD_PARTY_NOTICES/AimMac-LICENSE.txt.
import CoreGraphics

/// A snapshot of the display layout. A value type, so the input queue and the
/// main thread never share mutable geometry.
struct DisplayMap: Sendable, Equatable {
    var rects: [CGRect]

    var spanningBounds: CGRect { rects.reduce(.null) { $0.union($1) } }

    func clampToSpan(_ p: CGPoint) -> CGPoint {
        let bounds = spanningBounds
        guard !bounds.isNull else { return p }
        return CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(p.y, bounds.minY), bounds.maxY - 1))
    }

    static func current() -> DisplayMap {
        var count: UInt32 = 0
        var rects: [CGRect] = []
        if CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetActiveDisplayList(count, &ids, &count) == .success {
                rects = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
            }
        }
        return DisplayMap(rects: rects.isEmpty ? [CGDisplayBounds(CGMainDisplayID())] : rects)
    }

    /// The nearest point that is actually on a display.
    func clamp(_ p: CGPoint) -> CGPoint {
        if rects.contains(where: { $0.contains(p) }) { return p }
        var best = p
        var bestDist = CGFloat.greatestFiniteMagnitude
        for r in rects {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let dist = hypot(q.x - p.x, q.y - p.y)
            if dist < bestDist { bestDist = dist; best = q }
        }
        return best
    }
}
