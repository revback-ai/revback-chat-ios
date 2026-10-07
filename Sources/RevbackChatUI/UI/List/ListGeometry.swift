import CoreGraphics

/// Ориентация таблицы ленты. От неё зависят только трансформ, отображение
/// индексов и формулы этого файла.
enum ListOrientation: Equatable {
    /// Основной ход: `UITableView` с `transform = mirrorY`, строка 0 — новейшая, визуально внизу.
    case inverted
    /// Запасной ход: обычная таблица, строка 0 — самая старая (приветствие), визуально вверху.
    case normal
}

/// Геометрия ленты — чистые формулы от чисел таблицы, без UIKit.
///
/// Всё в координатах ТАБЛИЦЫ (не визуальных): `offsetY = contentOffset.y`, `boundsHeight = bounds.height`,
/// `contentHeight = contentSize.height`. `insetEnd` — отступ со стороны КОНЦА ленты (у `.inverted` —
/// `adjustedContentInset.top`, визуальный низ; у `.normal` — `.bottom`), `insetStart` — со стороны начала.
/// `oldestRowFrame` — `rectForRow` строки, которая визуально вверху ленты (приветствие или самое старое сообщение;
/// у `.inverted` — наибольший индекс, у `.normal` — индекс 0); `nil` — строк нет.
struct ListGeometry: Equatable {

    /// Допуск на дробные точки раскладки — как Android `EDGE_SLACK_PX`.
    static let slack: CGFloat = 4

    var orientation: ListOrientation
    var offsetY: CGFloat
    var boundsHeight: CGFloat
    var contentHeight: CGFloat
    var insetEnd: CGFloat
    var insetStart: CGFloat
    var oldestRowFrame: CGRect?

    init(orientation: ListOrientation = .inverted, offsetY: CGFloat, boundsHeight: CGFloat, contentHeight: CGFloat,
         insetEnd: CGFloat, insetStart: CGFloat, oldestRowFrame: CGRect? = nil) {
        self.orientation = orientation
        self.offsetY = offsetY
        self.boundsHeight = boundsHeight
        self.contentHeight = contentHeight
        self.insetEnd = insetEnd
        self.insetStart = insetStart
        self.oldestRowFrame = oldestRowFrame
    }

    /// Смещение «лента у самого конца»: низ последней строки над композером на паддинг ленты.
    /// `.inverted`: `−iE` (строка 0 у визуального низа при любой длине ленты).
    var endOffset: CGFloat {
        switch orientation {
        case .inverted: return -insetEnd
        case .normal: return max(-insetStart, contentHeight + insetEnd - boundsHeight)
        }
    }

    /// Смещение «лента у самого начала» (у `.inverted` это наибольшее смещение, у `.normal` —
    /// наименьшее, поэтому имя по смыслу, а не по знаку).
    var startOffset: CGFloat {
        switch orientation {
        case .inverted: return max(-insetEnd, contentHeight + insetStart - boundsHeight)
        case .normal: return -insetStart
        }
    }

    /// Сколько pt до конца ленты (0 — у конца; отрицательное — отскок за конец).
    var fromEnd: CGFloat {
        switch orientation {
        case .inverted: return offsetY + insetEnd
        case .normal: return endOffset - offsetY
        }
    }

    /// «У конца» = низ последней строки на экране с допуском (§12 пп. 59, 62, 65, 67; Android `isBottomVisible`).
    var atEnd: Bool { fromEnd <= Self.slack }

    /// Верх ленты (строка, визуально верхняя) хотя бы частью на экране (§12 п. 56; Android `isTopVisible`). Видимое окно
    /// `[o, o + H]` в координатах таблицы — одинаково для обеих ориентаций.
    var topVisible: Bool {
        guard let r = oldestRowFrame else { return false }
        return r.minY < offsetY + boundsHeight - Self.slack && r.maxY > offsetY + Self.slack
    }

    /// Лента не длиннее экрана: и конец, и верх видны (§12 п. 56).
    var wholeListVisible: Bool { atEnd && topVisible }

    /// Смещение в пределах `[конец, начало]` (порядок краёв зависит от ориентации).
    func clamped(_ y: CGFloat) -> CGFloat {
        Self.clamp(y, endOffset, startOffset)
    }

    /// Восстановление якоря читателя по геометрии ПОСЛЕ обновления (`self`): рамка той же строки после обновления и
    /// её расстояние `d` от визуального верха вьюпорта до обновления (`AnchorSnapshot`).
    func restoredOffset(anchorFrame: CGRect, distance: CGFloat) -> CGFloat {
        Self.restoreAnchor(orientation: orientation, anchorFrameAfter: anchorFrame, distance: distance,
                           boundsHeightAfter: boundsHeight, endOffsetAfter: endOffset, startOffsetAfter: startOffset)
    }

    /// `.inverted` — `o' = clamp(A'.maxY + d − H')` (визуальный верх строки — её `maxY`, верх вьюпорта —
    /// `o + H`); `.normal` — `o' = clamp(A'.minY − d)`. Якорь по визуальному ВЕРХУ — как Android.
    static func restoreAnchor(orientation: ListOrientation, anchorFrameAfter a: CGRect, distance d: CGFloat,
                              boundsHeightAfter h: CGFloat, endOffsetAfter end: CGFloat,
                              startOffsetAfter start: CGFloat) -> CGFloat {
        let raw: CGFloat
        switch orientation {
        case .inverted: raw = a.maxY + d - h
        case .normal: raw = a.minY - d
        }
        return clamp(raw, end, start)
    }

    private static func clamp(_ y: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        min(max(y, min(a, b)), max(a, b))
    }
}

/// Снимок видимых строк ДО обновления — для якоря читателя.
struct AnchorSnapshot: Equatable {

    /// Видимая строка: расстояние `distance` от визуального верха вьюпорта до визуального верха строки
    /// (положительное — верх строки ниже верха экрана).
    struct Entry: Equatable {
        let id: String
        let isWelcome: Bool
        let distance: CGFloat
    }

    /// Рамка строки в координатах таблицы (`rectForRow`).
    struct RowFrame: Equatable {
        let id: String
        let isWelcome: Bool
        let frame: CGRect
    }

    /// Видимые строки сверху вниз (визуально).
    let entries: [Entry]

    init(entries: [Entry]) { self.entries = entries }

    /// Из рамок строк: видимые — пересекающие `[o, o + H]`, упорядочены сверху вниз.
    init(orientation: ListOrientation, offsetY o: CGFloat, boundsHeight h: CGFloat, rows: [RowFrame]) {
        let visible = rows.filter { $0.frame.maxY > o && $0.frame.minY < o + h }
        switch orientation {
        case .inverted:
            entries = visible.sorted { $0.frame.maxY > $1.frame.maxY }
                .map { Entry(id: $0.id, isWelcome: $0.isWelcome, distance: (o + h) - $0.frame.maxY) }
        case .normal:
            entries = visible.sorted { $0.frame.minY < $1.frame.minY }
                .map { Entry(id: $0.id, isWelcome: $0.isWelcome, distance: $0.frame.minY - o) }
        }
    }

    /// Якорь: первая видимая строка, КРОМЕ приветствия (приветствие якорем — только если других строк на экране
    /// нет), уцелевшая в новом наборе; удалена — следующая по списку. Все видимые сообщения удалены — уцелевшее
    /// приветствие (лучше, чем ничего). `nil` — не уцелело ничего видимого.
    func pickAnchor(surviving: Set<String>) -> (id: String, distance: CGFloat)? {
        let pick = entries.first { !$0.isWelcome && surviving.contains($0.id) }
            ?? entries.first { $0.isWelcome && surviving.contains($0.id) }
        return pick.map { ($0.id, $0.distance) }
    }
}
