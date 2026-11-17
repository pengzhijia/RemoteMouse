import CoreGraphics

@main
struct DisplayMapCheck {
    static func main() {
        let displays = DisplayMap(rects: [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 130, y: 30, width: 100, height: 100)
        ])
        let gap = displays.clampToSpan(CGPoint(x: 110, y: 50))
        precondition(gap.x == 110)
        precondition(displays.clamp(gap).x == 99)
        let second = displays.clampToSpan(CGPoint(x: 135, y: 50))
        precondition(displays.clamp(second) == second)
        let edge = displays.clampToSpan(CGPoint(x: 999, y: 50))
        precondition(edge.x == 229)
    }
}
