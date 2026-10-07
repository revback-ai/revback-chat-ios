import SwiftUI

/// Встраиваемый экран чата. `onClose == nil` → крестика в шапке нет (спека §3, строка 53).
public struct RevbackChatView: View {

    private let onClose: (() -> Void)?
    @StateObject private var model: ChatModel
    /// Какой пикер открыт листом (§5 п. 6): `nil` — ни один. Один `@State` на оба — два листа
    /// одновременно SwiftUI всё равно не показал бы.
    @State private var picker: PickerKind?
    @State private var preview: FilePreviewItem?

    /// Пункты меню скрепки (§12 п. 51).
    enum PickerKind: Identifiable {
        case media, file
        var id: Self { self }
    }

    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        _model = StateObject(wrappedValue: ChatModel(backend: LiveChatBackend()))
    }

    /// Точка входа для тестов и превью с подменённым бэкендом.
    init(onClose: (() -> Void)?, model: ChatModel) {
        self.onClose = onClose
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        let state = model.ui

        VStack(spacing: 0) {
            ChatHeader(state: state, onClose: onClose)
                // §4 строка 65: шапка тянется на верхнюю safe-area
                .background(
                    (Theme.color(hex: state.headerColorHex) ?? Theme.color(hex: Theme.neutralHeaderHex)!)
                        .ignoresSafeArea(edges: .top)
                )

            // §6: под шапкой одна строка
            if let error = state.errorBar {
                ErrorBar(text: error, onTap: state.errorBarRetriesAll ? { model.retryAllFailed() } : nil)
            }

            content(state)
        }
        .background(Theme.surface)
        // §4 строка 65: композер над нижней safe-area; §5 п. 11 — клавиатура штатная
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if state.composerVisible {
                Composer(state: state, model: model,
                         onAttachMedia: { picker = .media },
                         onAttachFile: { picker = .file })
                    .background(Theme.surface.ignoresSafeArea(edges: .bottom))
            }
        }
        .onAppear { model.screenAppeared() }
        .onDisappear { model.screenDisappeared() }
        .sheet(item: $picker) { kind in
            // Лист закрывает ВЬЮХА (`onFinish` → `picker = nil`). Если `dismiss` зовёт
            // координатор, `picker` остаётся взведённым и второй тап по скрепке ничего не открывает.
            let begin: () -> PickSink = { model.beginPick() }
            let remaining = ChatUiState.maxAttachmentsPerMessage - state.chips.count
            switch kind {
            case .media:
                PhotoPicker(begin: begin, onFinish: { picker = nil },
                            remaining: remaining, maxFileSize: model.maxFileSize)
            case .file:
                DocumentPicker(begin: begin, onFinish: { picker = nil },
                               remaining: remaining, maxFileSize: model.maxFileSize)
            }
        }
        .sheet(item: $preview) { item in
            FilePreview(item: item)
        }
    }

    @ViewBuilder
    private func content(_ state: ChatUiState) -> some View {
        switch state.mode {
        case .unavailable:
            UnavailableScreen(state: state) { model.refresh() }
        case .empty:
            // Подсказку решает маппер (§12 п. 44): nil — пустая лента без текста, фолбэка на строку нет
            Group {
                if let hint = state.emptyHint {
                    EmptyState(hint: hint)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.listBackground)
        case .list:
            MessageList(state: state, model: model, preview: $preview)
        }
    }
}
