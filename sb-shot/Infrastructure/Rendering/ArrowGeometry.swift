import CoreGraphics

nonisolated struct ArrowHead {
    let tip: CGPoint
    let left: CGPoint
    let right: CGPoint
    /// Punto donde termina el cuerpo de la flecha (base de la punta).
    let base: CGPoint

    init(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = hypot(end.x - start.x, end.y - start.y)
        let headLength = min(max(lineWidth * 4, 14), length * 0.6)
        let spread = CGFloat.pi / 6.5

        tip = end
        left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        base = CGPoint(
            x: end.x - headLength * 0.8 * cos(angle),
            y: end.y - headLength * 0.8 * sin(angle)
        )
    }
}
