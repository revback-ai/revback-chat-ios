import SwiftUI

/// §4 строка 81: лента пустая без подсказки, кнопка «Обновить» 34, радиус 10,
/// фон #6b7280 либо primary из кэша, текст белый 14. Композера нет.
///
/// Макет экрана: `.retry{align-self:center; height:34; padding:0 18px}` внутри `.list{padding:12}` —
/// кнопка стоит СРАЗУ ПОД полосой ошибки и центрирована только по горизонтали,
/// по вертикали её не центрируют.
struct UnavailableScreen: View {
    let state: ChatUiState
    let onRefresh: () -> Void

    private var buttonColor: Color {
        Theme.color(hex: state.refreshColorHex) ?? Theme.color(hex: Theme.neutralHeaderHex)!
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onRefresh) {
                Text(state.strings.refresh)
                    .font(.system(size: Theme.refreshButtonFontSize))
                    .foregroundColor(.white)
                    .padding(.horizontal, Theme.refreshButtonPaddingHorizontal)
                    .frame(height: Theme.refreshButtonHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.refreshButtonRadius).fill(buttonColor)
                    )
            }
            .accessibilityLabel(state.strings.refresh)
            // остаток ленты пустой — подсказки на этом экране нет (§4 строка 81)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.listPadding)
        .background(Theme.listBackground)
    }
}
