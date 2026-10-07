import UIKit

/// Состояние картинки-вложения строки — часть ключа кэша высот.
/// Начальное координатор берёт из синхронного кэша модели, дальше — по `imageSettled` ячейки.
enum ImageSlotState: Hashable {
    /// Серая плашка 200×150 (§5 п. 7), байт ещё нет.
    case placeholder
    /// Картинка показана во вписанном размере `Theme.photoFittedSize`.
    case fitted(CGSize)
    /// Отказ загрузки — вместо картинки ссылка с именем файла.
    case failed

    // `CGSize` не во всех SDK `Hashable` — сравнение и хеш по числам явно.
    static func == (a: ImageSlotState, b: ImageSlotState) -> Bool {
        switch (a, b) {
        case (.placeholder, .placeholder), (.failed, .failed): return true
        case let (.fitted(x), .fitted(y)): return x.width == y.width && x.height == y.height
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .placeholder: hasher.combine(0)
        case .failed: hasher.combine(1)
        case .fitted(let s):
            hasher.combine(2)
            hasher.combine(s.width)
            hasher.combine(s.height)
        }
    }
}

/// Всё, от чего зависит высота строки при данной ширине. Точное значение, а не число-хеш:
/// коллизия дала бы чужую высоту в оценке.
struct RowContentKey: Hashable {

    struct Attachment: Hashable {
        let kind: AttachmentDisplayKind
        let fileName: String?
        let unsupported: Bool
        /// Место фото и обложки видео до загрузки считается по размерам медиа.
        let width: Int?
        let height: Int?
    }

    let text: String?
    let deleted: Bool
    let unreadable: Bool
    let senderName: String?
    let hasTime: Bool
    let hasTicks: Bool
    let failed: Bool
    let attachments: [Attachment]
    /// Состояние картинок по ПОЗИЦИИ во `row.attachments` (у ссылок всегда `.placeholder` — на высоту не влияет).
    let imageStates: [ImageSlotState]
    /// «Жирный шрифт» (`UITraitCollection.legibilityWeight == .bold`) меняет метрики системного шрифта.
    let boldText: Bool
}

/// Кэш настоящих высот строк. Пишется в `willDisplay` и после
/// перемера строки, читается ТОЛЬКО в `estimatedHeightForRowAt`; настоящая высота — самоизмерение таблицы.
///
/// Ключ — id строки; запись годится только при той же ширине и том же `RowContentKey` (поворот, правка текста,
/// картинка, «Жирный шрифт» — промах сам). `width` — одна и та же величина у записи и чтения (ширина ленты, которую
/// координатор передаёт и в оценку).
final class RowHeightCache {

    private struct Entry {
        let width: CGFloat
        let key: RowContentKey
        let height: CGFloat
    }

    private var entries: [String: Entry] = [:]
    let estimator = RowHeightEstimator()

    /// Чистая функция ключа. `imageStates` — по позиции во `row.attachments`; нет записи — `.placeholder`.
    static func contentKey(row: BubbleRow, imageStates: [ImageSlotState],
                           legibilityWeight: UILegibilityWeight) -> RowContentKey {
        let attachments = row.attachments.map {
            RowContentKey.Attachment(kind: $0.kind, fileName: $0.fileName, unsupported: $0.unsupported,
                                     width: $0.width, height: $0.height)
        }
        let states: [ImageSlotState] = row.attachments.indices.map { i in
            let a = row.attachments[i]
            guard a.kind != .file, !a.unsupported, i < imageStates.count else { return .placeholder }
            return imageStates[i]
        }
        return RowContentKey(text: row.text, deleted: row.deleted, unreadable: row.unreadable,
                             senderName: row.senderName, hasTime: row.time != nil, hasTicks: row.ticks != .none,
                             failed: row.failed, attachments: attachments, imageStates: states,
                             boldText: legibilityWeight == .bold)
    }

    /// Настоящая высота строки, если она измерена при той же ширине и том же содержимом.
    func height(id: String, width: CGFloat, key: RowContentKey) -> CGFloat? {
        guard let e = entries[id], abs(e.width - width) < 0.01, e.key == key else { return nil }
        return e.height
    }

    func store(id: String, width: CGFloat, key: RowContentKey, height: CGFloat) {
        entries[id] = Entry(width: width, key: key, height: height)
    }

    func removeAll() {
        entries.removeAll()
        estimator.reset()
    }

    /// Смена `UIContentSizeCategory` — сброс (шрифты §4 фиксированные, но сброс дёшев и страхует).
    func contentSizeCategoryDidChange() { removeAll() }

    /// Для `estimatedHeightForRowAt`: измеренная высота из кэша, иначе оценка.
    func estimatedHeight(row: BubbleRow, width: CGFloat, imageStates: [ImageSlotState],
                         legibilityWeight: UILegibilityWeight) -> CGFloat {
        let key = Self.contentKey(row: row, imageStates: imageStates, legibilityWeight: legibilityWeight)
        if let h = height(id: row.id, width: width, key: key) { return h }
        return estimator.estimate(row: row, listWidth: width, key: key)
    }
}

/// Дешёвая оценка высоты строки (ячейка целиком: пузырь + по 4 pt сверху и снизу) по
/// `boundingRect` с теми же шрифтами, что у ячейки (`BubbleStyle.font`). `estimatedHeightForRowAt` таблица
/// зовёт для ВСЕХ строк при `apply` — отсюда мемоизация по `(id, ширина, ключ)`.
///
/// `listWidth` — ширина ленты без боковых safe area; пузырь не шире `(listWidth − 2·12) · 0,8`.
final class RowHeightEstimator {

    private struct MemoKey: Hashable {
        let id: String
        let width: CGFloat
        let key: RowContentKey
    }

    private var memo: [MemoKey: CGFloat] = [:]
    /// Потолок памяти оценок: лента в сотни строк × несколько ширин — с запасом.
    private static let memoLimit = 4000

    /// Для тестов мемоизации.
    var memoCount: Int { memo.count }

    func reset() { memo.removeAll() }

    func estimate(row: BubbleRow, listWidth: CGFloat, imageStates: [ImageSlotState],
                  legibilityWeight: UILegibilityWeight) -> CGFloat {
        let key = RowHeightCache.contentKey(row: row, imageStates: imageStates, legibilityWeight: legibilityWeight)
        return estimate(row: row, listWidth: listWidth, key: key)
    }

    func estimate(row: BubbleRow, listWidth: CGFloat, key: RowContentKey) -> CGFloat {
        let m = MemoKey(id: row.id, width: listWidth, key: key)
        if let h = memo[m] { return h }
        if memo.count >= Self.memoLimit { memo.removeAll() }
        let h = Self.compute(row: row, listWidth: listWidth, imageStates: key.imageStates, bold: key.boldText)
        memo[m] = h
        return h
    }

    /// Чистый расчёт без памяти.
    static func compute(row: BubbleRow, listWidth: CGFloat, imageStates: [ImageSlotState],
                        legibilityWeight: UILegibilityWeight) -> CGFloat {
        compute(row: row, listWidth: listWidth, imageStates: imageStates, bold: legibilityWeight == .bold)
    }

    private static func compute(row: BubbleRow, listWidth: CGFloat, imageStates: [ImageSlotState],
                                bold: Bool) -> CGFloat {
        let bubbleMax = max(0, (listWidth - 2 * Theme.listPadding) * Theme.bubbleMaxWidthFraction)
        let inner = max(1, bubbleMax - 2 * Theme.bubblePaddingHorizontal)

        // Ячейка: пузырь + по bubbleGap/2 сверху и снизу.
        var h = 2 * Theme.bubblePaddingVertical + Theme.bubbleGap

        if let name = row.senderName {
            h += textHeight(name, font: font(.sender, bold: bold), width: inner, lineSpacing: 0)
            h += Theme.senderBottomGap
        }
        if let text = row.text, !text.isEmpty {
            h += textHeight(text, font: font(.text(dim: row.deleted || row.unreadable), bold: bold), width: inner,
                            lineSpacing: Theme.bubbleLineSpacing)
        }
        if !row.attachments.isEmpty {
            let linkLine = font(.link, bold: bold).lineHeight
            var parts: [CGFloat] = []
            for (i, a) in row.attachments.enumerated() {
                if a.unsupported {
                    // «Не поддерживается» переносится (без `lineLimit`). Строк локали у оценки нет — берётся подпись
                    // ru (en короче), для оценки хватает.
                    parts.append(textHeight("Данный тип файла не поддерживается",
                                            font: font(.link, bold: bold), width: inner,
                                            lineSpacing: 0))
                    continue
                }
                switch a.kind {
                case .file:
                    parts.append(linkLine)          // одна строка, обрезка в середине
                case .photo:
                    let state = i < imageStates.count ? imageStates[i] : .placeholder
                    switch state {
                    case .placeholder: parts.append(Theme.photoReservedSize(width: a.width, height: a.height).height)
                    case .fitted(let size): parts.append(size.height)
                    case .failed: parts.append(linkLine)
                    }
                case .video:
                    // Обложка одной высоты до и после загрузки; нет обложки или отказ — ссылка.
                    let state = i < imageStates.count ? imageStates[i] : .placeholder
                    switch state {
                    case .placeholder, .fitted: parts.append(Theme.videoCoverSize(width: a.width, height: a.height).height)
                    case .failed: parts.append(linkLine)
                    }
                }
            }
            h += Theme.attachmentTopGap + parts.reduce(0, +)
                + Theme.attachmentGap * CGFloat(max(0, parts.count - 1))
        }
        if row.time != nil {
            h += Theme.timeTopGap + font(.time, bold: bold).lineHeight
        }
        if row.ticks != .none {
            h += font(.ticks, bold: bold).lineHeight
        }
        return h
    }

    /// Высота текста: число строк по `boundingRect`, межстрочный `lineSpacing` — только МЕЖДУ строками (так рисует
    /// SwiftUI `Text.lineSpacing`; хвост после последней строки у `boundingRect` непостоянен).
    private static func textHeight(_ text: String, font: UIFont, width: CGFloat, lineSpacing: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let line = font.lineHeight
        let lines = max(1, (rect.height / line).rounded())
        return lines * line + (lines - 1) * lineSpacing
    }

    /// Шрифт — ровно тот, что у ячейки: та же роль `BubbleStyle.Role` через `BubbleStyle.font(_:legibilityWeight:)`.
    /// Своего веса оценщик не выбирает: явный `.semibold` при глобальном «Жирном шрифте»
    /// рисуется как Heavy (`BubbleStyle.font(base:…)`), и оценка разошлась бы с самоизмерением ячейки. Internal —
    /// для теста «оценщик и ячейка берут один шрифт».
    static func font(_ role: BubbleStyle.Role, bold: Bool) -> UIFont {
        BubbleStyle.font(role, legibilityWeight: bold ? .bold : .regular)
    }
}
