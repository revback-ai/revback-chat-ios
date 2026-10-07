import UIKit

/// Всё, что ячейке ленты нужно снаружи. Ячейка не знает ни `ChatModel`, ни
/// координатора — только эти действия; в тестах они подменяются фейком.
struct CellActions {
    /// §5 п. 9: тап по недоставленному.
    var retry: (String) -> Void
    /// §5 п. 9: долгое нажатие / действие доступности «Отменить отправку».
    var cancel: (String) -> Void
    /// Синхронный кэш картинок модели: `ChatModel.cachedImage(messageId:index:)`.
    var cachedImage: (String, Int32) -> UIImage?
    /// `ChatModel.cachedLocalImage(uri:)`.
    var cachedLocalImage: (String) -> UIImage?
    /// `ChatModel.image(messageId:index:)`.
    var image: (String, Int32) async -> UIImage?
    /// `ChatModel.localImage(uri:)`.
    var localImage: (String) async -> UIImage?
    /// `ChatModel.bytes(messageId:index:)` — оригинальные байты для просмотрщика.
    var bytes: (String, Int32) async -> Data?
    /// `ChatModel.previewSession` — каталог временных файлов просмотрщика этого экрана.
    var previewSession: String
    /// Открыть системный просмотрщик (`preview` привязки `MessageList`).
    var openPreview: (FilePreviewItem) -> Void
    /// Исход АСИНХРОННОЙ загрузки картинки: id строки, `AttachmentRow.index`, состояние. Картинка из синхронного
    /// кэша при `configure` сообщения не шлёт — её состояние даёт `MessageCell.initialImageStates`.
    var imageSettled: (String, Int32, ImageSlotState) -> Void
    /// Фокус VoiceOver на элементе пузыря строки.
    var accessibilityFocused: (String) -> Void
    // Три поля ниже — с умолчаниями, чтобы вызовы из тестов (замер оценщика в `RowHeightCacheTests`) собирались;
    // координатор обязан передать настоящие.
    /// Память отказов загрузки картинок: `ChatModel.imageFailed(messageId:index:)`. Известный
    /// отказ — ссылка СРАЗУ, без плашки и повторной загрузки (иначе высота прыгает 150 ↔ строка ссылки).
    var imageFailed: (String, Int32) -> Bool = { _, _ in false }
    /// `ChatModel.rememberImageFailure(messageId:index:)` — ячейка зовёт при отказе асинхронной загрузки.
    var rememberImageFailure: (String, Int32) -> Void = { _, _ in }
    /// Высота пузыря строки изменилась по трейту («Жирный шрифт», `legibilityWeight`) — не через `configure` и не
    /// картинкой (`imageSettled`). Координатор перемеряет строку, как по `imageSettled`, ключ кэша высот
    /// промахивается сам (`legibilityWeight` в `contentKey`).
    var contentHeightChanged: (String) -> Void = { _ in }
    // Обложки видео. Умолчания — «обложек нет»: вызовы из тестов собираются, координатор передаёт настоящие.
    /// Синхронный кэш обложек с сервера: `ChatModel.cachedThumbnail(messageId:index:)`.
    var cachedThumbnail: (String, Int32) -> UIImage? = { _, _ in nil }
    /// `ChatModel.thumbnail(messageId:index:)` — обложка с сервера.
    var thumbnail: (String, Int32) async -> UIImage? = { _, _ in nil }
    /// `ChatModel.thumbnailFailed(messageId:index:)` — известный отказ обложки: сервер больше не спрашиваем.
    var thumbnailFailed: (String, Int32) -> Bool = { _, _ in false }
    /// Есть ли файл по локальному адресу (`revback-cache://…`) — обложка своего видео рядом с копией.
    var localFileExists: (String) -> Bool = CellActions.fileExists

    static let fileExists: (String) -> Bool = { uri in
        guard let url = CacheUri.resolve(uri) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

/// Ячейка ленты: пузырь на UIKit, прижатый к TRAILING (своё) или LEADING (чужое) — как
/// `HStack` + `Spacer`, который в RTL зеркалится сам. По 4 pt сверху и снизу вокруг пузыря: с
/// `contentInset` таблицы 8 это даёт паддинг ленты 12 у краёв и зазор 8 между пузырями (§4 строка 68).
/// Переворот `contentView` ставит координатор по ориентации ленты — ячейка о нём не знает.
final class MessageCell: UITableViewCell {

    static let reuseIdentifier = "RevbackMessageCell"
    /// Половина зазора между пузырями: 4 сверху + 4 снизу.
    static let verticalInset: CGFloat = Theme.bubbleGap / 2

    let bubble = BubbleView()

    private var leadingEqual: NSLayoutConstraint!
    private var trailingEqual: NSLayoutConstraint!
    private var leadingAtLeast: NSLayoutConstraint!
    private var trailingAtMost: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        // Контейнер: VoiceOver идёт в элементы пузыря, а не читает ячейку целиком.
        isAccessibilityElement = false

        bubble.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)
        let bottom = contentView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: Self.verticalInset)
        // Ниже обязательного: при оценочной высоте строки таблица временно ставит свою высоту ячейки.
        bottom.priority = UILayoutPriority(999)
        leadingEqual = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        trailingEqual = contentView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor)
        leadingAtLeast = bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor)
        trailingAtMost = contentView.trailingAnchor.constraint(greaterThanOrEqualTo: bubble.trailingAnchor)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalInset),
            bottom,
        ])
        accessibilityElements = [bubble]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// - Parameters:
    ///   - listWidth: ширина ленты (таблицы).
    ///   - leadingInset: отступ со стороны LEADING — паддинг ленты 12 + safe area контейнера с этой стороны
    ///     (в LTR левая, в RTL правая).
    ///   - trailingInset: то же со стороны TRAILING. Стороны раздельно: safe area бывает несимметричной
    ///     (альбомная с вырезом, Stage Manager, Slide Over).
    func configure(row: BubbleRow, primaryHex: String, strings: Strings, listWidth: CGFloat, leadingInset: CGFloat,
                   trailingInset: CGFloat, actions: CellActions) {
        // §4 строка 69: потолок пузыря — 80 % ширины ленты за вычетом паддингов, ширина — по содержимому.
        let maxBubble = max(0, (listWidth - leadingInset - trailingInset) * Theme.bubbleMaxWidthFraction)
        bubble.configure(row: row, primaryHex: primaryHex, strings: strings, maxBubbleWidth: maxBubble,
                         actions: actions)

        NSLayoutConstraint.deactivate([leadingEqual, trailingEqual, leadingAtLeast, trailingAtMost])
        leadingEqual.constant = leadingInset
        trailingEqual.constant = trailingInset
        leadingAtLeast.constant = leadingInset
        trailingAtMost.constant = trailingInset
        NSLayoutConstraint.activate(row.isMine ? [trailingEqual, leadingAtLeast] : [leadingEqual, trailingAtMost])
    }

    /// Симметричный отступ (обе стороны одинаково) — для замеров без safe area; лента зовёт раздельный вариант.
    func configure(row: BubbleRow, primaryHex: String, strings: Strings, listWidth: CGFloat, sideInset: CGFloat,
                   actions: CellActions) {
        configure(row: row, primaryHex: primaryHex, strings: strings, listWidth: listWidth, leadingInset: sideInset,
                  trailingInset: sideInset, actions: actions)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        bubble.prepareForReuse()
    }

    /// Состояние картинок строки из синхронного кэша модели — начальное значение для ключа кэша высот.
    /// Массив по позиции в `row.attachments` (как `RowHeightCache.contentKey`).
    static func initialImageStates(row: BubbleRow, actions: CellActions) -> [ImageSlotState] {
        AttachmentStackView.initialImageStates(row: row, actions: actions)
    }

    /// Применить `imageSettled(rowId, index, state)` к массиву состояний строки: `index` — `AttachmentRow.index`,
    /// позиция в массиве — по `row.attachments`. Короткий массив дополняется `.placeholder`; чужой индекс — без изменений.
    static func settling(_ states: [ImageSlotState], row: BubbleRow, index: Int32,
                         state: ImageSlotState) -> [ImageSlotState] {
        guard let position = row.attachments.firstIndex(where: { $0.index == index }) else { return states }
        var result = states
        if result.count < row.attachments.count {
            result += Array(repeating: .placeholder, count: row.attachments.count - result.count)
        }
        result[position] = state
        return result
    }
}
