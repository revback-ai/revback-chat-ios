import SwiftUI

/// §4 строка 66. Фон тянется на верхнюю safe-area (§4 строка 65) — это делает родитель
/// (`RevbackChatView`), здесь только содержимое строки.
struct ChatHeader: View {
    let state: ChatUiState
    let onClose: (() -> Void)?

    private var background: Color {
        Theme.color(hex: state.headerColorHex) ?? Theme.color(hex: Theme.neutralHeaderHex)!
    }

    var body: some View {
        HStack(spacing: Theme.headerGap) {
            avatar
            Text(state.headerTitle)
                .font(.system(size: Theme.headerTitleSize, weight: Theme.headerTitleWeight))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    // §4 строка 66: текстовый глиф «✕» 20, белый, opacity .85
                    Text("✕")
                        .font(.system(size: Theme.closeGlyphSize))
                        .foregroundColor(.white)
                        .opacity(Theme.closeGlyphOpacity)
                        // §9: зона касания 44×44 — это САМА кнопка, глиф лежит внутри неё
                        .touchTarget()
                }
                .accessibilityLabel(state.strings.close)   // §9
                // Зона касания 44 (§9) шире глифа 20, и по ГОРИЗОНТАЛИ её перехлёст тоже
                // нужно вычесть: иначе от края панели до глифа выходило 26 вместо §4-шных
                // 14 (у сайта `.close{padding:2px 4px}` — правый край глифа ~18 от края).
                // Отрицательный отступ уводит кнопку в паддинг шапки: глиф встаёт на 14,
                // а касание остаётся 44×44 и целиком внутри шапки.
                .padding(.trailing, -Theme.closeTouchOverhang)
            }
        }
        // Строка шапки меряется в 44 (кнопка = зона касания), поэтому паддинг вычитает
        // перехлёст: от края до глифа — §4-шные 12, высота шапки — те же 58 (12 + 34 + 12).
        .padding(.vertical, Theme.headerPaddingVertical - Theme.touchOverhang)
        .padding(.horizontal, Theme.headerPaddingHorizontal)
        .frame(minHeight: Theme.headerHeight)
        .background(background)
    }

    /// §4 строка 66: круг 34 rgba(255,255,255,.22), внутри логотип (object-fit cover)
    /// или иконка чата 20 stroke 1.7.
    private var avatar: some View {
        ZStack {
            Circle().fill(Color.white.opacity(Theme.avatarFillOpacity))
            if let logo = state.logoUrl, let url = URL(string: logo) {
                RemoteLogo(url: url)
                    .frame(width: Theme.avatarSize, height: Theme.avatarSize)
                    .clipShape(Circle())
            } else {
                SvgIcon(d: Icons.chat, size: Theme.headerIconSize, color: .white)
            }
        }
        .frame(width: Theme.avatarSize, height: Theme.avatarSize)
    }
}

/// Логотип канала. `AsyncImage` — iOS 15, но `.aspectRatio(.fill)` для `object-fit: cover`
/// задаётся явно.
private struct RemoteLogo: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                SvgIcon(d: Icons.chat, size: Theme.headerIconSize, color: .white)
            }
        }
    }
}
