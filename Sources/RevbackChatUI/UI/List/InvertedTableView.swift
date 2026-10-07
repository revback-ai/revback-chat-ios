import UIKit

/// Что таблица ленты сообщает координатору.
/// Реализует `MessageTableCoordinator`; таблица держит его слабой ссылкой `host`.
protocol InvertedTableHost: AnyObject {
    /// Размер `bounds`/`frame` таблицы СЕЙЧАС сменится (ещё старый): снимок видимого по старому вьюпорту —
    /// в `layoutSubviews` `bounds` уже новый, и видимые строки там — строки нового вьюпорта. Внешняя смена, вложенные
    /// (`frame` → `bounds`) не шлются.
    func tableSizeWillChange(to new: CGSize)
    /// Из `layoutSubviews` таблицы ДО `super`: высота или ширина вьюпорта сменилась (клавиатура, поворот).
    func tableViewportWillChange(from old: CGSize, to new: CGSize)
    /// После `super`, в том же проходе раскладки.
    func tableViewportDidChange(from old: CGSize, to new: CGSize)
    /// Конец каждого прохода `layoutSubviews` (счётчик сторожа зависания).
    func tableLayoutPassFinished()
    /// Свой `accessibilityScroll` поставил смещение (после объявления страницы).
    func tableAccessibilityScrolled()
    /// Тап по статус-бару — пришёл в прокси (`ScrollToTopProxyView`); прокси сам не двигается.
    func statusBarTapped()
    /// Свой `accessibilityScroll` сейчас поставит смещение (ДО него — чтобы `scrollViewDidScroll` уже видел
    /// флаг «доступность», `ListScrollState.beginAccessibilityScroll()`). С пустой реализацией по
    /// умолчанию; то же видно и по `InvertedTableView.isAccessibilityScrolling`.
    func tableAccessibilityScrollWillBegin()
}

extension InvertedTableHost {
    func tableAccessibilityScrollWillBegin() {}
    func tableSizeWillChange(to new: CGSize) {}
}

/// Таблица ленты. У `.inverted` — `transform = mirrorY` (отражение по вертикали, а не поворот):
/// строка 0 — новейшая, визуально внизу; полоса прокрутки остаётся справа. Содержимое ячеек переворачивает обратно
/// координатор (`contentView.transform`).
///
/// Таблица о строках и решениях ленты не знает: данные, делегат и все решения — у координатора. Её дело —
/// настройки ниже, сообщения о смене вьюпорта из `layoutSubviews`, порядок элементов доступности сверху
/// вниз и своя прокрутка тремя пальцами.
final class InvertedTableView: UITableView {

    static let mirrorY = CGAffineTransform(scaleX: 1, y: -1)
    /// §4 строка 68: ячейка несёт по 4 pt вокруг пузыря (`MessageCell.verticalInset`), таблица — 8 с каждой стороны:
    /// 8 + 4 = 12 (паддинг ленты) у краёв, 4 + 4 = 8 (зазор) между пузырями.
    static let contentInsetEdge: CGFloat = Theme.listPadding - MessageCell.verticalInset

    let orientation: ListOrientation
    weak var host: InvertedTableHost?

    /// Число проходов `layoutSubviews` — только для сторожа зависания.
    private(set) var layoutPassCount = 0
    /// Идёт `super.layoutSubviews()`: смещения, которые таблица делает сама в проходе раскладки, — «программно».
    /// Координатор читает флаг в `scrollViewDidScroll`.
    var isInLayoutPass: Bool { layoutPassDepth > 0 }
    private var layoutPassDepth = 0
    /// Идёт смена размера `bounds`/`frame`: `UIScrollView` сам поджимает смещение к новому краю ВНЕ
    /// `layoutSubviews` (вьюпорт вырос у верха истории — клавиатура скрылась). Такое смещение — тоже «программно»:
    /// не «чужое» и не касание верха (§12 п. 57).
    var isResizing: Bool { resizeDepth > 0 }
    private var resizeDepth = 0
    /// Смещение ставит свой `accessibilityScroll` (флаг «доступность» для классификатора смещений).
    private(set) var isAccessibilityScrolling = false
    /// Размер `bounds` прошлого прохода раскладки. Читает хост: снимок до смены размера годен, только
    /// если снят при этом размере.
    private(set) var lastLayoutSize: CGSize = .zero

    /// Подмена признака «жест жив» для тестов (они проигрывают жест вызовами делегата — `isTracking`/
    /// `isDragging`/`isDecelerating` при этом `false`).
    var gestureLiveOverride: (() -> Bool)?
    /// Жест пальцем (с торможением) ещё идёт — страховка залипания `interacting`: палец касается, тянет или
    /// лента тормозит (`ListScrollState.gestureLive`).
    var gestureLive: Bool {
        gestureLiveOverride?()
            ?? ListScrollState.gestureLive(isTracking: isTracking, isDragging: isDragging, isDecelerating: isDecelerating)
    }

    /// Объявитель «Страница N из M». Тесты подменяют (в тестовом процессе VoiceOver нет).
    var announce: (String) -> Void = { UIAccessibility.post(notification: .pageScrolled, argument: $0) }

    init(orientation: ListOrientation = .inverted) {
        self.orientation = orientation
        super.init(frame: .zero, style: .plain)
        // У вью с не-единичным `transform` `frame` не определён — только констрейнты (Auto Layout работает с
        // `bounds`/`center`), а не `autoresizingMask`.
        translatesAutoresizingMaskIntoConstraints = false
        transform = orientation == .inverted ? Self.mirrorY : .identity
        separatorStyle = .none
        allowsSelection = false
        // Фон ленты — у контейнера.
        backgroundColor = .clear
        rowHeight = UITableView.automaticDimension
        // `estimatedRowHeight` — у делегата (`RowHeightCache`).
        sectionHeaderHeight = 0
        sectionFooterHeight = 0
        estimatedSectionHeaderHeight = 0
        estimatedSectionFooterHeight = 0
        sectionHeaderTopPadding = 0
        tableHeaderView = nil
        tableFooterView = nil
        // Отступы и safe area — наши: боковые берёт контейнер, вертикальные — `contentInset`.
        contentInsetAdjustmentBehavior = .never
        insetsContentViewsToSafeArea = false
        cellLayoutMarginsFollowReadableWidth = false
        automaticallyAdjustsScrollIndicatorInsets = false
        // Полоса прокрутки на всю высоту.
        verticalScrollIndicatorInsets = .zero
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = false
        // Жест по короткой ленте — касание (§12 пп. 56, 58).
        alwaysBounceVertical = true
        keyboardDismissMode = .none
        contentInset = UIEdgeInsets(top: Self.contentInsetEdge, left: 0, bottom: Self.contentInsetEdge, right: 0)
        // «Top» перевёрнутой таблицы — визуальный низ, а у конца UIKit делегата не зовёт вовсе. Тап по
        // статус-бару принимает прокси контейнера — единственный вид со `scrollsToTop` в окне.
        scrollsToTop = false
        register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseIdentifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    /// Геометрия таблицы сейчас. Рамку верхней строки ленты добавляет координатор — он знает число строк.
    var geometry: ListGeometry {
        let inset = adjustedContentInset
        return ListGeometry(orientation: orientation, offsetY: contentOffset.y, boundsHeight: bounds.height,
                            contentHeight: contentSize.height,
                            insetEnd: orientation == .inverted ? inset.top : inset.bottom,
                            insetStart: orientation == .inverted ? inset.bottom : inset.top)
    }

    // MARK: - Раскладка

    override var bounds: CGRect {
        get { super.bounds }
        set {
            guard newValue.size != super.bounds.size else {
                super.bounds = newValue
                return
            }
            resizeDepth += 1
            if resizeDepth == 1 { host?.tableSizeWillChange(to: newValue.size) }
            super.bounds = newValue
            resizeDepth -= 1
        }
    }

    override var frame: CGRect {
        get { super.frame }
        set {
            resizeDepth += 1
            if resizeDepth == 1, newValue.size != super.frame.size { host?.tableSizeWillChange(to: newValue.size) }
            super.frame = newValue
            resizeDepth -= 1
        }
    }

    override func layoutSubviews() {
        let new = bounds.size
        let old = lastLayoutSize
        let changed = new != old
        // Запоминаем сразу: хост может вызвать `layoutIfNeeded()` из своих обработчиков, и вложенный проход не должен
        // увидеть ту же смену второй раз.
        if changed {
            lastLayoutSize = new
            host?.tableViewportWillChange(from: old, to: new)
        }
        layoutPassDepth += 1
        super.layoutSubviews()
        layoutPassDepth -= 1
        if changed { host?.tableViewportDidChange(from: old, to: new) }
        layoutPassCount += 1
        host?.tableLayoutPassFinished()
    }

    // MARK: - Доступность

    /// Порядок сверху вниз по экрану. У перевёрнутой таблицы штатный порядок обратный (свайп вправо — к
    /// элементу выше; Apple рекомендует `accessibilityElements`). Ячейки — контейнеры (`isAccessibilityElement =
    /// false`), внутри — элементы пузыря.
    override var accessibilityElements: [Any]? {
        get {
            guard orientation == .inverted else { return super.accessibilityElements }
            return visibleCells.sorted { Self.screenMinY($0) < Self.screenMinY($1) }
        }
        set { super.accessibilityElements = newValue }
    }

    private static func screenMinY(_ view: UIView) -> CGFloat {
        view.convert(view.bounds, to: nil).minY
    }

    /// Прокрутка тремя пальцами ЦЕЛИКОМ своя, без `super` (в тестовом процессе `super` ничего не делает,
    /// а на перевёрнутом виде его направление — внутренность UIKit). `.up` — к началу ленты (у `.inverted` смещение
    /// растёт), `.down` — к концу; шаг — видимая высота; уже у края — `false` (звук границы даёт VoiceOver).
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard orientation == .inverted else { return super.accessibilityScroll(direction) }
        let towardStart: Bool
        switch direction {
        case .up: towardStart = true
        case .down: towardStart = false
        default: return false
        }
        let geometry = self.geometry
        let step = pageStep
        let current = contentOffset.y
        let target = geometry.clamped(towardStart ? current + step : current - step)
        guard abs(target - current) > 0.5 else { return false }
        host?.tableAccessibilityScrollWillBegin()
        isAccessibilityScrolling = true
        contentOffset = CGPoint(x: contentOffset.x, y: target)
        // Ячейки нового положения — сейчас, под тем же флагом: объявление и решения хоста — по видимым строкам.
        layoutIfNeeded()
        isAccessibilityScrolling = false
        let page = Self.page(offset: contentOffset.y, geometry: self.geometry, step: step)
        announce(L10n.pageAnnouncement(page: page.number, of: page.count))
        host?.tableAccessibilityScrolled()
        return true
    }

    /// Шаг прокрутки тремя пальцами — видимая высота ленты без отступов.
    var pageStep: CGFloat {
        max(1, bounds.height - adjustedContentInset.top - adjustedContentInset.bottom)
    }

    /// «Страница N из M»: страницы считаются от начала ленты (1 — у начала, M — у конца), шаг — `step`.
    static func page(offset: CGFloat, geometry: ListGeometry, step: CGFloat) -> (number: Int, count: Int) {
        let range = abs(geometry.startOffset - geometry.endOffset)
        let count = Int((range / step - 0.001).rounded(.up)) + 1
        let fromStart = min(range, abs(geometry.startOffset - offset))
        let number = Int((fromStart / step - 0.001).rounded(.up)) + 1
        return (min(max(number, 1), max(count, 1)), max(count, 1))
    }
}

/// Контейнер ленты без трансформа — `UIViewRepresentable` ставит ему `frame` (у вью с
/// трансформом `frame` не определён). Фон ленты #f5f6f8, таблица — на всю площадь констрейнтами, прокси статус-бара.
final class MessageListContainerView: UIView {

    let table: InvertedTableView
    let scrollToTopProxy: ScrollToTopProxyView

    /// Боковые safe area — у КОНТЕЙНЕРА (у перевёрнутой таблицы с `insetsContentViewsToSafeArea = false` свои не
    /// используем). Координатор прибавляет их к паддингу 12 (альбомная с вырезом).
    var sideSafeInsets: UIEdgeInsets {
        UIEdgeInsets(top: 0, left: safeAreaInsets.left, bottom: 0, right: safeAreaInsets.right)
    }

    init(orientation: ListOrientation = .inverted) {
        table = InvertedTableView(orientation: orientation)
        scrollToTopProxy = ScrollToTopProxyView()
        super.init(frame: .zero)
        backgroundColor = UIColor(Theme.listBackground)
        // Прокси — под таблицей: тапов он не перехватывает, а `scrollsToTop` перекрытие не мешает.
        addSubview(scrollToTopProxy)
        addSubview(table)
        scrollToTopProxy.table = table
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: topAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollToTopProxy.topAnchor.constraint(equalTo: topAnchor),
            // На всю ширину — UIKit выбирает вид для тапа по статус-бару и по x (тап посреди статус-бара
            // до прокси 1×1 в углу мог бы не дойти); высота 1 pt.
            scrollToTopProxy.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollToTopProxy.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollToTopProxy.heightAnchor.constraint(equalToConstant: ScrollToTopProxyView.side),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }
}

/// Приёмник тапа по статус-бару. UIKit зовёт `scrollsToTop` только если такой вид в
/// окне ОДИН, и только у вида «не наверху» — поэтому прокси всегда со смещением 1 из 2 возможных, а у таблицы и поля
/// композера `scrollsToTop = false`. Сам прокси не двигается (`false`), прокрутку ленты к началу делает хост. Ширина —
/// контейнера (констрейнты), высота `side`.
final class ScrollToTopProxyView: UIScrollView, UIScrollViewDelegate {

    static let side: CGFloat = 1
    /// Смещение прокси: ненулевое — у вида «уже наверху» UIKit делегата не зовёт.
    static let restingOffset: CGFloat = 1

    weak var table: InvertedTableView?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentSize = CGSize(width: Self.side, height: Self.side * 3)
        contentOffset = CGPoint(x: 0, y: Self.restingOffset)
        scrollsToTop = true
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Страховка: смещение прокси никто не должен трогать, но у «наверху» тап терялся бы.
        if contentOffset.y != Self.restingOffset { contentOffset = CGPoint(x: 0, y: Self.restingOffset) }
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        table?.host?.statusBarTapped()
        return false
    }
}
