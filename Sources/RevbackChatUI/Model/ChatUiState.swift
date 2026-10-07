import Foundation

/// Вход чистой функции маппинга: снимок всего, что влияет на экран.
/// Времязависимые факты (`connectingOverdue`, `showBackOnline`) вычисляет `ChatModel` —
/// маппер остаётся чистым и тестируемым.
struct ChatUiInput: Equatable {
    var messages: [MessageRow]
    var state: ConversationStateRow
    var connection: ConnectionRow
    var branding: BrandingRow?
    var hasMore: Bool
    var draft: String
    var chips: [ChipRow]
    var transientError: TransientError?
    /// §6 строка 124: `Connecting` держится дольше 3 с при открытом экране.
    var connectingOverdue: Bool
    /// §6 строка 124: окно «Снова в сети» на 3 с.
    var showBackOnline: Bool
    var timeZone: TimeZone
    var strings: Strings
    /// §12 п. 73: id строк, отправленных (или повторённых) с этого экрана (`ChatModel.sentHereIds`).
    var sentHereIds: Set<String> = []
}

/// Строка ленты — пузырь сообщения или локальное приветствие.
struct BubbleRow: Equatable, Identifiable {
    var id: String
    var isMine: Bool
    /// Текст к показу; у удалённого уже подменён на «Сообщение удалено» (§4 строка 75).
    var text: String?
    var deleted: Bool
    /// §4 строка 71: только у чужих с `Agent`/`Assistant`, только непустое имя.
    var senderName: String?
    /// §4 строка 72: `HH:mm`; nil у приветствия (§4 строка 77).
    var time: String?
    var ticks: Ticks
    /// §4 строка 74: пунктирная рамка, opacity .55, тап = retry, долгое = cancel.
    var failed: Bool
    var attachments: [AttachmentRow]
    var isWelcome: Bool
    /// Сообщение неизвестной формы: текст уже подменён на «Не удалось отобразить сообщение»,
    /// рисуется курсивом и приглушённо, как «Сообщение удалено».
    var unreadable: Bool = false
    /// Своя, отправленная с этого устройства: id из возврата `send()`/`retry` этого экрана (§12 п. 73) или статус
    /// очереди этого устройства (`MessageRow.sentHere`, §12 п. 71).
    var sentHere: Bool = false
}

/// Готовый снимок экрана. Вьюхи не знают ни про ядро, ни про правила — только про это.
struct ChatUiState: Equatable {

    enum Mode: Equatable {
        /// §4 строка 68: лента пузырей.
        case list
        /// §4 строка 69: пустая беседа с подсказкой.
        case empty
        /// §4 строка 81: «Чат временно недоступен» с кнопкой «Обновить».
        case unavailable
    }

    var headerColorHex: String
    var headerTitle: String
    var logoUrl: String?
    /// §6: одна строка или ничего.
    var errorBar: String?
    /// §12 п. 78: полоса нажимаема — «Не доставлено — нажмите, чтобы повторить»; нажатие повторяет все свои
    /// `failed` (`ChatModel.retryAllFailed()`). У прочих строк полосы — `false`.
    var errorBarRetriesAll: Bool = false
    var mode: Mode
    var rows: [BubbleRow]
    /// Подсказка пустого состояния; nil, когда её показывать нельзя (§4 строка 81).
    var emptyHint: String?
    var composerVisible: Bool
    var attachVisible: Bool
    var sendEnabled: Bool
    var refreshVisible: Bool
    var refreshColorHex: String
    var chips: [ChipRow]
    var hasMore: Bool
    var strings: Strings

    /// §5 п. 6 и §4 строка 103: `MAX_MESSAGE_ATTACHMENTS = 10` (`widget.js:72`).
    static let maxAttachmentsPerMessage = 10

    /// §6 строка 123 + §12 п. 41: терминальные причины беседы — общий с Android набор
    /// (`TERMINAL_REASONS` в `ui-android/.../ChatUiState.kt`). `not_configured` ядро ставит
    /// на беседе-заглушке ДО `RevbackChat.init` (`ConversationImpl.kt`): чинить это состояние
    /// экрану нечем, а композер на нём «отправлял» бы в никуда — поэтому оно наравне
    /// с `widget_not_found` даёт экран §4 «недоступен» с кнопкой «Обновить».
    static let terminalReasons: Set<String> = ["widget_not_found", "not_configured"]

    /// Идентификатор локального пузыря приветствия — он не сообщение (§4 строка 77).
    static let welcomeRowId = "__revback_welcome__"

    static func make(_ input: ChatUiInput) -> ChatUiState {
        let s = input.strings

        // --- брендинг (§4 строка 66, §7) ---
        // `primaryColor` сервер отдаёт и с решёткой, и без — принимаются обе формы, а наружу
        // состояние несёт каноничное `#rrggbb` в нижнем регистре.
        let primaryHex: String? = input.branding
            .flatMap { $0.primaryColor }
            .flatMap { Theme.normalizedHex($0) }
        let headerColorHex = primaryHex ?? Theme.neutralHeaderHex
        let brandTitle = input.branding?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerTitle = (brandTitle?.isEmpty == false) ? brandTitle! : s.title

        // --- §6 строка 123: терминальные отказы ---
        let terminalReason: Bool = {
            if case .failed(let reason) = input.state { return terminalReasons.contains(reason) }
            return false
        }()
        let connectionTerminal: Bool = {
            if case .failed = input.connection { return true }
            return false
        }()
        let unavailable = terminalReason || connectionTerminal

        // --- лента (§4 строки 68/77) ---
        var rows: [BubbleRow] = []
        if !unavailable {
            let welcome = input.branding?.welcomeText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !welcome.isEmpty {
                rows.append(BubbleRow(
                    id: welcomeRowId, isMine: false, text: welcome, deleted: false,
                    senderName: nil, time: nil, ticks: .none, failed: false,
                    attachments: [], isWelcome: true
                ))
            }
            let formatter = timeFormatter(input.timeZone)
            rows.append(contentsOf: input.messages.map { m in
                BubbleRow(
                    id: m.id,
                    isMine: m.isMine,
                    // Нечитаемое сообщение — служебная подпись вместо текста, как у удалённого:
                    // своего текста у него нет.
                    text: m.deleted ? s.deleted : (m.unreadable ? s.unreadable : m.text),
                    deleted: m.deleted,
                    senderName: senderCaption(m.sender),
                    // Свой неотправленный (как `.msg.mine.failed` у веб-виджета) — голый пузырь, без времени и
                    // без галочек (§4 строки 72/73 читаются вместе со строкой 74)
                    time: (m.isMine && m.failed) ? nil : formatter.string(from: m.sentAt),
                    ticks: (m.isMine && !m.failed) ? m.ticks : .none,
                    failed: m.failed,
                    // §4 строка 75: у удалённого вложений нет
                    attachments: m.deleted ? [] : m.attachments,
                    isWelcome: false,
                    unreadable: m.unreadable,
                    // §12 п. 73: своё и (id отправки с этого экрана ИЛИ статус очереди этого устройства)
                    sentHere: m.isMine && (input.sentHereIds.contains(m.id) || m.sentHere)
                )
            })
        }

        // --- режим (§6 строка 129) ---
        let mode: Mode = unavailable ? .unavailable : (rows.isEmpty ? .empty : .list)

        // --- §6 строка 127: прочий Failed при пустой ленте ---
        let otherFailureOnEmptyFeed: Bool = {
            guard !unavailable, case .failed = input.state else { return false }
            return input.messages.isEmpty
        }()

        // --- полоса ошибки: приоритет §6 сверху вниз ---
        var errorBar: String?
        var errorBarRetriesAll = false
        if unavailable {
            errorBar = s.notConfigured
        } else if input.connection == .offline || (input.connection == .connecting && input.connectingOverdue) {
            errorBar = s.offline
        } else if input.showBackOnline {
            errorBar = s.online
        } else if input.messages.contains(where: { $0.isMine && $0.failed }) {
            errorBar = s.failed
            errorBarRetriesAll = true   // §12 п. 78: текст зовёт нажать на полосу
        } else if let t = input.transientError {
            switch t {
            case .tooBig: errorBar = s.attachTooBig
            case .attachFailed: errorBar = s.attachFailed
            case .limit: errorBar = s.attachLimit
            }
        } else if otherFailureOnEmptyFeed {
            errorBar = s.notConfigured
        }

        // --- композер (§4 строки 79/81, §5 пп. 5/6) ---
        let composerVisible = !unavailable
        let attachmentsEnabled = input.branding?.attachmentsEnabled ?? true
        let anyUploading = input.chips.contains { $0.uploading }
        let readyChips = input.chips.contains { $0.uploaded != nil }
        let hasText = !input.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sendEnabled = composerVisible && !anyUploading && (hasText || readyChips)

        return ChatUiState(
            headerColorHex: headerColorHex,
            headerTitle: headerTitle,
            logoUrl: input.branding?.logoUrl,
            errorBar: errorBar,
            errorBarRetriesAll: errorBarRetriesAll,
            mode: mode,
            rows: rows,
            // §4 строка 81: на экране «недоступен» подсказки нет; §12 п. 30/44: при «мягком» отказе на пустой
            // ленте — тоже (иначе рядом с полосой «Чат временно недоступен» звало бы «Напишите нам»), как на Android
            emptyHint: mode == .empty && !otherFailureOnEmptyFeed ? s.emptyHint : nil,
            composerVisible: composerVisible,
            attachVisible: composerVisible && attachmentsEnabled,
            sendEnabled: sendEnabled,
            refreshVisible: unavailable,
            refreshColorHex: headerColorHex,
            chips: input.chips,
            hasMore: input.hasMore && !unavailable,
            strings: s
        )
    }

    /// §4 строка 71: подпись только у чужих `Agent`/`Assistant` и только непустая.
    /// Отправитель вида, которого SDK не знает (`Sender.Other`), доходит сюда уже как `.agent`, поэтому подпись у него есть.
    private static func senderCaption(_ sender: SenderRow) -> String? {
        switch sender {
        case .agent(let name), .assistant(let name):
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        case .mine, .system, .unknown:
            return nil
        }
    }

    /// §4 строка 72: `HH:mm` локальное. Фиксированная локаль убирает 12-часовой формат.
    ///
    /// Форматтер кэшируется по часовому поясу: `DateFormatter()` — дорогой объект (разбор
    /// шаблона, ICU), а `make(_:)` зовётся на КАЖДОЕ изменение состояния, вплоть до каждой
    /// буквы черновика. Кэш статический и потому общий; пользоваться им можно только с
    /// главного потока — это и есть контракт `ChatModel` (все методы зовутся оттуда).
    private static var formatters: [String: DateFormatter] = [:]

    private static func timeFormatter(_ tz: TimeZone) -> DateFormatter {
        if let cached = formatters[tz.identifier] { return cached }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        formatters[tz.identifier] = f
        return f
    }
}
