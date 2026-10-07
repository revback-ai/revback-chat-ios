import SwiftUI

/// §4 строка 67: под шапкой, фон #fdecea, текст #b3261e 13, паддинг 8/12.
/// `onTap` — только у «Не доставлено — нажмите, чтобы повторить» (§12 п. 78): текст зовёт нажать на полосу, значит
/// полоса — кнопка (роль и действие для VoiceOver, подпись — тот же текст, новых строк нет). Прочие полосы — просто текст.
struct ErrorBar: View {
    let text: String
    var onTap: (() -> Void)? = nil

    var body: some View {
        if let onTap {
            Button(action: onTap) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(text)
                .accessibilityAddTraits(.isButton)
        } else {
            label
        }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: Theme.errorBarFontSize))
            .foregroundColor(Theme.errorText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.errorBarPaddingVertical)
            .padding(.horizontal, Theme.errorBarPaddingHorizontal)
            .background(Theme.errorBackground)
            .contentShape(Rectangle())
    }
}
