import SwiftUI
import UIKit

/// §4 строка 68: фон #f5f6f8, паддинг 12, зазор 8. §5 п. 3: лента открывается у конца, дальше автопрокрутка — только
/// если пользователь был у конца; `loadMore` — когда верх ленты на экране после реальной прокрутки, либо без неё, пока
/// лента не длиннее экрана (§12 п. 56).
///
/// Лента — перевёрнутая `UITableView` (`InvertedTableView`) в `UIViewRepresentable`, решения —
/// у `MessageTableCoordinator` по событиям `UIScrollViewDelegate`. Здесь только граница SwiftUI ↔ UIKit: тело
/// читает состояние и отдаёт его ЗНАЧЕНИЯМИ, `updateUIView` получает свежий `self` на каждой отрисовке — устаревших
/// замыканий (§12 п. 53) нет по построению.
struct MessageList: View {
    let state: ChatUiState
    @ObservedObject var model: ChatModel
    @Binding var preview: FilePreviewItem?
    /// Анимированная прокрутка к новой строке (`.anchorThenEnd`). Выключают только тесты ленты — кроме сторожа
    /// анимации.
    var animatesScrollToEnd: Bool = true
    /// Лента решила докрутить к концу (`NewRowScroll`). Подставляет только тест: у конца смещение по вставке само не
    /// отличает «правило крутило» от «не крутило».
    var onScrollToEndDecided: (() -> Void)? = nil
    /// Лента засчитала прокрутку к началу без жеста касанием (`LoadMoreGate.topObserved`). Подставляет только тест.
    var onTopTouch: (() -> Void)? = nil

    /// Ссылка на координатор этой ленты — для `onAppear` (новый показ). Класс в `@State`: живёт, пока живёт вью.
    @State private var link = MessageListLink()

    var body: some View {
        let binding = $preview
        MessageTableRepresentable(
            input: MessageListInput(
                rows: state.rows,
                headerColorHex: state.headerColorHex,
                strings: state.strings,
                hasMore: state.hasMore,
                loadMoreFinished: model.loadMoreFinished,
                reconnects: model.reconnects,
                model: model,
                // Смена `@Published`/привязки — не посреди отрисовки SwiftUI.
                openPreview: { item in DispatchQueue.main.async { binding.wrappedValue = item } },
                animatesScrollToEnd: animatesScrollToEnd,
                onScrollToEndDecided: onScrollToEndDecided,
                onTopTouch: onTopTouch
            ),
            link: link
        )
        // §4 строка 68: фон ленты и под safe area по бокам (альбомная с вырезом).
        .background(Theme.listBackground)
        // §12 п. 52: новый показ (и повторный `onAppear` того же вью во вкладке хоста) — гейт заново, лента у конца.
        .onAppear { link.coordinator?.screenShown() }
    }
}

/// Слабая ссылка `MessageList` → координатор его таблицы (координатор создаёт `makeUIView`).
final class MessageListLink {
    weak var coordinator: MessageTableCoordinator?
}

/// Обёртка таблицы. Контейнер без трансформа (ему `UIViewRepresentable` ставит `frame`), таблица и
/// прокси статус-бара — внутри (`MessageListContainerView`).
struct MessageTableRepresentable: UIViewRepresentable {
    let input: MessageListInput
    let link: MessageListLink

    func makeUIView(context: Context) -> MessageListContainerView {
        let container = MessageListContainerView(orientation: .inverted)
        let coordinator = MessageTableCoordinator(table: container.table)
        container.table.host = coordinator
        context.coordinator.list = coordinator
        link.coordinator = coordinator
        return container
    }

    /// Обновление таблицы — синхронно (только UIKit); всё, что меняет `@Published` модели, координатор откладывает
    /// на `main.async`.
    func updateUIView(_ container: MessageListContainerView, context: Context) {
        link.coordinator = context.coordinator.list
        context.coordinator.list?.update(input: input)
    }

    func makeCoordinator() -> Holder { Holder() }

    /// Держит координатор ленты: `delegate`/`host` таблицы — слабые ссылки.
    final class Holder {
        var list: MessageTableCoordinator?
    }
}
