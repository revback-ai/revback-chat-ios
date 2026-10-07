import CoreGraphics

/// §4 строка 70: форма пузыря — радиус 12, у своего правый нижний угол 4, у чужого левый нижний 4.
/// Геометрия 1:1 с SwiftUI-формой пузыря (эталон формы — `MessageCellTests.legacyBubbleShapePath`), вынесена в
/// функцию для UIKit-пузыря (`BubbleView`). В RTL путь НЕ зеркалится — как у SwiftUI `Shape` (сам не
/// переворачивается): «хвост» своего всегда справа внизу.
enum BubblePath {

    static func make(rect: CGRect, isMine: Bool) -> CGPath {
        let r = Theme.bubbleRadius
        let tail = Theme.bubbleTailRadius
        let bottomLeft = isMine ? r : tail
        let bottomRight = isMine ? tail : r

        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        p.addArc(center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight),
                 radius: bottomRight, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft),
                 radius: bottomLeft, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .pi, endAngle: .pi * 3 / 2, clockwise: false)
        p.closeSubpath()
        return p
    }
}
