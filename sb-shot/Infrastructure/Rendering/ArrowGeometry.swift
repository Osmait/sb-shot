import CoreGraphics

struct ArrowHead {
    let tip: CGPoint
    let left: CGPoint
    let right: CGPoint

    init(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(lineWidth * 4.5, 12)
        let spread = CGFloat.pi / 7

        tip = end
        left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
    }
}
