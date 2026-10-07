import SwiftUI

/// §4 строка 79: белый, линия сверху 1 #e3e5e8, паддинг 10/12, зазор 8.
struct Composer: View {
    let state: ChatUiState
    @ObservedObject var model: ChatModel
    /// Пункты меню скрепки (§5 п. 6, §12 п. 51): «Фото и видео» → `PhotoPicker`, «Файл» → `DocumentPicker`.
    let onAttachMedia: () -> Void
    let onAttachFile: () -> Void

    @State private var fieldHeight = Theme.fieldMinHeight
    /// Меню живёт в композере и висит на самой кнопке: в regular size class (iPad) система рисует
    /// `confirmationDialog` popover'ом от вьюхи с модификатором — на всей строке композера стрелка
    /// уходила бы к её центру, а не к скрепке.
    @State private var showAttachMenu = false

    private var primary: Color {
        Theme.color(hex: state.headerColorHex) ?? Theme.color(hex: Theme.neutralHeaderHex)!
    }

    /// §4 строка 79: при выбранном файле рамка и глиф скрепки — цветом primary.
    private var attachTint: Color { state.chips.isEmpty ? Theme.controlGlyph : primary }
    private var attachBorder: Color { state.chips.isEmpty ? Theme.controlBorder : primary }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: Theme.composerBorderWidth)

            if !state.chips.isEmpty {
                AttachChips(chips: state.chips, strings: state.strings) { model.removeChip(id: $0) }
            }

            HStack(alignment: .bottom, spacing: Theme.composerGap) {
                if state.attachVisible { attachButton }
                field
                sendButton
            }
            // Круги 34 стоят в зонах касания 44 (§9), поэтому строка меряется в 44: вычитаем
            // перехлёст, чтобы от края композера до круга остались §4-шные 10, а высота — 54.
            // По ГОРИЗОНТАЛИ перехлёст вычитают сами кнопки (`touchTargetHorizontalOverhang`),
            // а не строка: иначе при выключенных вложениях (§4 строка 79 — скрепки нет)
            // на 5 левее уезжало бы поле, которому никакой зоны касания компенсировать не надо.
            .padding(.vertical, Theme.composerPaddingVertical - Theme.touchOverhang)
            .padding(.horizontal, Theme.composerPaddingHorizontal)
        }
        .background(Theme.surface)
    }

    /// §4 строка 79: скрепка 34 круг, рамка 1, глиф 16. §9: зона касания 44 — это сама кнопка.
    private var attachButton: some View {
        Button { showAttachMenu = true } label: {
            ZStack {
                Circle()
                    .strokeBorder(attachBorder, lineWidth: 1)
                    .background(Circle().fill(Theme.surface))
                SvgIcon(d: Icons.attach, size: Theme.attachGlyphSize, color: attachTint)
            }
            .frame(width: Theme.composerControlSize, height: Theme.composerControlSize)
            .touchTarget()
        }
        .accessibilityLabel(state.strings.attach)
        // §5 п. 6: системное меню из двух пунктов; «Отмена» iPhone добавляет сам, на iPad её нет — закрытие тапом мимо.
        .confirmationDialog("", isPresented: $showAttachMenu, titleVisibility: .hidden) {
            Button(state.strings.attachMedia, action: onAttachMedia)
            Button(state.strings.attachFile, action: onAttachFile)
        }
        .touchTargetHorizontalOverhang()
    }

    /// §4 строка 79: рамка 1 #d4d7dc, радиус 10, паддинг 7/12, 14, высота 34, до 4 строк.
    /// Вертикальный паддинг в `touchOverhang` — снаружи рамки: он уравнивает поле (34)
    /// с кнопками (44), поэтому в строке они стоят на одной линии, а видимая рамка
    /// остаётся §4-шной высоты.
    private var field: some View {
        GrowingTextView(
            text: $model.draft,
            height: $fieldHeight,
            placeholder: state.strings.placeholder,
            fontSize: Theme.fieldFontSize,
            minHeight: Theme.fieldMinHeight,
            maxLines: Theme.fieldMaxLines,
            paddingVertical: Theme.fieldPaddingVertical,
            paddingHorizontal: Theme.fieldPaddingHorizontal
        )
        .frame(height: fieldHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.fieldRadius)
                .strokeBorder(Theme.controlBorder, lineWidth: 1)
        )
        .padding(.vertical, Theme.touchOverhang)
    }

    /// §4 строка 79: кнопка отправки 34 круг primary, глиф 18 белый. §9: зона касания 44
    /// тем же приёмом, что у скрепки.
    /// Неактивная кнопка НЕ приглушается: на сайте и на Android `disabled` меняет только
    /// поведение, а §4 никакой прозрачности не задаёт.
    private var sendButton: some View {
        Button { model.send() } label: {
            ZStack {
                Circle().fill(primary)
                SvgIcon(d: Icons.send, size: Theme.sendGlyphSize, color: .white,
                        strokeWidthInViewBox: nil)   // ICON_SEND — заливка
            }
            .frame(width: Theme.composerControlSize, height: Theme.composerControlSize)
            .touchTarget()
        }
        .disabled(!state.sendEnabled)
        .accessibilityLabel(state.strings.send)
        .touchTargetHorizontalOverhang()
    }
}
