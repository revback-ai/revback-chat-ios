import SwiftUI

/// SVG-пути иконок — ДОСЛОВНО как у веб-виджета, `viewBox 0 0 24 24`.
enum Icons {

    /// `ICON_CHAT` — обводка, stroke-width 1.7, round cap/join.
    static let chat = "M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"

    /// `ICON_SEND` — заливка.
    static let send = "M3.4 20.4l17.45-7.48a1 1 0 0 0 0-1.84L3.4 3.6a.993.993 0 0 0-1.39.91L2 9.12c0 .5.37.93.87.99L17 12 2.87 13.88c-.5.07-.87.5-.87 1l.01 4.61c0 .71.73 1.2 1.39.91z"

    /// `ICON_ATTACH` — обводка, stroke-width 1.7, round cap/join.
    static let attach = "M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"

    /// Толщина обводки иконок в единицах viewBox.
    static let strokeInViewBox: CGFloat = 1.7
}

/// Рисует путь иконки в квадрате `size × size`.
/// `strokeWidthInViewBox == nil` — заливка (ICON_SEND); иначе обводка, толщина масштабируется
/// вместе с viewBox.
struct SvgIcon: View {
    let d: String
    let size: CGFloat
    let color: Color
    var strokeWidthInViewBox: CGFloat? = Icons.strokeInViewBox

    var body: some View {
        let path = Path(SvgPath.cgPath(d: d, box: 24, size: size))
        Group {
            if let w = strokeWidthInViewBox {
                path.stroke(
                    color,
                    style: StrokeStyle(lineWidth: w * size / 24, lineCap: .round, lineJoin: .round)
                )
            } else {
                path.fill(color)
            }
        }
        .frame(width: size, height: size)
    }
}
