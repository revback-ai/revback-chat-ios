import UIKit

/// Журнал ленты для отладки — `NSLog` под флагом. Включается аргументом запуска sample
/// `-RevbackListTrace 1` и только в отладочной сборке: в боевой флаг — константа `false`, аргументы процесса не
/// читаются. Sample — не публичный API.
enum ListTrace {
    #if DEBUG
    static let enabled = isRequested(arguments: ProcessInfo.processInfo.arguments)

    /// `-RevbackListTrace 1` (или `YES`/`true`) среди аргументов запуска.
    static func isRequested(arguments: [String]) -> Bool {
        guard let i = arguments.firstIndex(of: "-RevbackListTrace"), i + 1 < arguments.count else { return false }
        return ["1", "yes", "true"].contains(arguments[i + 1].lowercased())
    }
    #else
    static let enabled = false
    #endif

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("[RevbackList] %@", message())
    }
}

/// Всё, что `MessageList` отдаёт таблице на каждой отрисовке, — ЗНАЧЕНИЯМИ (без устаревших
/// замыканий, §12 п. 53), плюс тестовые крючки.
struct MessageListInput {
    var rows: [BubbleRow]
    var headerColorHex: String
    var strings: Strings
    var hasMore: Bool
    /// `ChatModel.loadMoreFinished` — смена значения = повод проверки.
    var loadMoreFinished: Int
    /// `ChatModel.reconnects` — связь вернулась (§12 п. 66).
    var reconnects: Int
    var model: ChatModel
    /// Открыть просмотрщик (привязка `preview`; `MessageList` сам откладывает на `main.async`).
    var openPreview: (FilePreviewItem) -> Void
    /// Анимированная прокрутка к новой строке (`.anchorThenEnd`). Выключают тесты ленты.
    var animatesScrollToEnd: Bool = true
    /// Тест: лента решила докрутить к концу (`NewRowScroll`).
    var onScrollToEndDecided: (() -> Void)? = nil
    /// Тест: прокрутка к началу без жеста засчитана касанием (`LoadMoreGate.topObserved`).
    var onTopTouch: (() -> Void)? = nil
}

/// Координатор ленты — данные таблицы (diffable), делегат таблицы и
/// прокрутки, применение снимков строк по планам автомата `ListScrollState`, кэш высот, состояние картинок строк,
/// поводы подгрузки истории (`LoadMoreGate`).
///
/// Решения — в `ListScrollState`/`ListGeometry`/`Rows.swift`; здесь только перевод событий UIKit в их вызовы и
/// исполнение планов. «Кто двигал ленту» — из событий делегата, «у конца» — состояние `followsEnd`.
final class MessageTableCoordinator: NSObject, UITableViewDelegate, InvertedTableHost {

    let table: InvertedTableView
    private var dataSource: UITableViewDiffableDataSource<Int, String>!

    /// Автомат ленты. Internal — для тестов (`ListProbe`).
    private(set) var scrollState = ListScrollState()
    /// Поводы подгрузки истории.
    private(set) var gate = LoadMoreGate()
    let heights = RowHeightCache()

    // MARK: входные значения

    private weak var model: ChatModel?
    private var openPreview: (FilePreviewItem) -> Void = { _ in }
    private var animatesScrollToEnd = true
    private var onScrollToEndDecided: (() -> Void)?
    private var onTopTouch: (() -> Void)?

    /// Строки ленты сверху вниз (без повторов id) и по id.
    private(set) var rows: [BubbleRow] = []
    private var rowsById: [String: BubbleRow] = [:]
    private var tail = RowsTail([])
    /// Обработанный хвост (`RowsTail.remembered(after:)`), `nil` — снимка ещё не было.
    private var seenTail: RowsTail?
    private var primaryHex = Theme.neutralHeaderHex
    private var strings: Strings?
    private var hasMore = false
    private var lastLoadMoreFinished: Int?
    private var lastReconnects: Int?
    private var appliedOnce = false
    /// Был `screenShown`: до показа повод подгрузки не проверяется — иначе запрос до показа, сброс гейта
    /// показом и отказ первой страницы дали бы повтор запроса.
    private var shownOnce = false
    /// Текущий тап по статус-бару уже дал касание верха. Один тап — один повод, как один жест: страница,
    /// пришедшая до конца анимации к началу, и досылка верха в её конце — тот же тап, а не новое касание.
    private var statusBarTouchCounted = false
    /// Первое сообщение на момент тапа по статус-бару. Сменилось к концу анимации
    /// (страница истории пришла посреди неё) — верх не досылается: лента остаётся на верхе загруженного при тапе.
    private var statusBarTapFirstId: String?
    /// Идёт запуск анимированной прокрутки (`startScrollAnimation`). Новая `setContentOffset(animated: true)` обрывает
    /// идущую, и UIKit синхронно зовёт `scrollViewDidEndScrollingAnimation` СТАРОЙ — уже после флага новой; такой конец
    /// флаг новой не снимает.
    private var startingScrollAnimation = false

    /// Состояние картинок строки по позиции в `row.attachments` — часть ключа кэша высот.
    private var imageStates: [String: [ImageSlotState]] = [:]
    private var actions: CellActions?
    private var actionsModel: ObjectIdentifier?

    /// Идёт своё обновление (`update`, перемер) — проверки повода из прохода раскладки ждут его конца (§12 п. 56).
    private var updating = 0
    /// Смена вьюпорта между `tableViewportWillChange` и `…DidChange`: якорь до смены.
    private var viewportChange: AnchorSnapshot?
    /// Якорь, снятый ДО смены размера `bounds` (`tableSizeWillChange`), и размер, при котором снят. Годен для
    /// `tableViewportWillChange`, только если этот размер — прежний размер раскладки.
    private var preResize: (size: CGSize, anchor: AnchorSnapshot)?
    private var lastContentHeight: CGFloat?
    private var lastLegibility: UILegibilityWeight?
    private var lastSizeCategory: UIContentSizeCategory?
    private var rowResizeScheduled = false
    private var traitsCheckScheduled = false

    /// Тест: сколько раз лента оборвала торможение. В процессе тестов пакета настоящего торможения нет — обрыв
    /// иначе не наблюдаем.
    private(set) var abortedDecelerations = 0

    /// Тест-сторож зависания: строка, реально попавшая на экран (`willDisplay`).
    var onWillDisplayRow: ((IndexPath) -> Void)?

    var orientation: ListOrientation { table.orientation }

    /// Смещения не от ленты (см. `ListScrollState.unownedOffsetCount`).
    var unownedOffsetCount: Int { scrollState.unownedOffsetCount }

    init(table: InvertedTableView) {
        self.table = table
        super.init()
        table.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseIdentifier)
        dataSource = UITableViewDiffableDataSource<Int, String>(tableView: table) { [weak self] table, indexPath, id in
            let cell = table.dequeueReusableCell(withIdentifier: MessageCell.reuseIdentifier, for: indexPath)
            if let self, let cell = cell as? MessageCell, let row = self.rowsById[id] {
                self.configure(cell, row: row)
            }
            return cell
        }
        dataSource.defaultRowAnimation = .none
        table.delegate = self
        table.host = self
    }

    // MARK: - Обновление

    /// Порядок фиксирован — (1) страховка жеста; (2) цвет/локаль; (3) строки (план, `apply`, восстановление);
    /// (4) `hasMore`, `loadMoreFinished`, `reconnects` и проверка повода. Иначе завершение страницы, пришедшее вместе
    /// со строками, проверило бы повод по геометрии ДО вставки (§12 п. 56, «перелёт»).
    func update(input: MessageListInput) {
        updating += 1
        defer { updating -= 1 }
        if actionsModel != ObjectIdentifier(input.model) { actions = nil }
        model = input.model
        actionsModel = ObjectIdentifier(input.model)
        openPreview = input.openPreview
        animatesScrollToEnd = input.animatesScrollToEnd
        onScrollToEndDecided = input.onScrollToEndDecided
        onTopTouch = input.onTopTouch

        // (1)
        runGestureLost()

        // (2) Цвет канала высоты не меняет; локаль — меняет («Не поддерживается», «Вложение»): кэш заново.
        var reconfigureVisible = false
        if input.headerColorHex != primaryHex {
            primaryHex = input.headerColorHex
            reconfigureVisible = appliedOnce
        }
        if input.strings != strings {
            if strings != nil { heights.removeAll() }
            strings = input.strings
            reconfigureVisible = appliedOnce
        }

        // (3)
        let newRows = Self.deduplicated(input.rows)
        if !appliedOnce || newRows != rows {
            applyRows(newRows, reconfigureVisible: reconfigureVisible)
        } else if reconfigureVisible {
            reconfigureRows(ids: visibleIds())
        }

        // (4)
        var check = false
        if input.hasMore != hasMore {
            hasMore = input.hasMore
            gate.hasMoreChanged()
            check = true
        }
        if let last = lastLoadMoreFinished, last != input.loadMoreFinished { check = true }
        lastLoadMoreFinished = input.loadMoreFinished
        if let last = lastReconnects, last != input.reconnects {
            gate.connectionReturned()
            reloadFailedImages()
            check = true
        }
        lastReconnects = input.reconnects
        if check { checkLoadMore() }
    }

    /// §12 п. 52: новый показ (и повторный `onAppear` того же вью) — гейт заново, `followsEnd`, лента в конец без
    /// анимации.
    func screenShown() {
        gate = LoadMoreGate()
        statusBarTouchCounted = false
        shownOnce = true
        scrollState.shown()
        if !rows.isEmpty { seenTail = RowsTail(rows) }
        updating += 1
        table.layoutIfNeeded()
        settleAtEnd()
        updating -= 1
        let g = geometry()
        observeTop(g, byScroll: false)
        checkLoadMore(g)
    }

    // MARK: - Строки

    /// Повтор id в одном снимке (ядро не должно, но diffable на нём падает) — первое вхождение, `NSLog`.
    static func deduplicated(_ rows: [BubbleRow]) -> [BubbleRow] {
        var seen = Set<String>()
        var out: [BubbleRow] = []
        out.reserveCapacity(rows.count)
        var dropped = 0
        for r in rows {
            if seen.insert(r.id).inserted { out.append(r) } else { dropped += 1 }
        }
        if dropped > 0 { NSLog("[RevbackChatUI] лента: повтор id в снимке строк — отброшено %d", dropped) }
        return out
    }

    /// Идентификаторы в порядке таблицы: `.inverted` — индекс 0 = новейшая (визуально внизу).
    private func tableIds(_ rows: [BubbleRow]) -> [String] {
        orientation == .inverted ? rows.reversed().map(\.id) : rows.map(\.id)
    }

    private func applyRows(_ newRows: [BubbleRow], reconfigureVisible: Bool) {
        let oldRows = rows
        let oldById = rowsById
        let newTail = RowsTail(newRows)
        let before = geometry()
        let anchor = anchorSnapshot()
        let onlyPrepended = ListScrollState.onlyPrepended(old: oldRows, new: newRows)
        let decision = scrollState.planRows(seen: seenTail, tail: newTail, whole: before.wholeListVisible,
                                            onlyPrepended: onlyPrepended, animates: animatesScrollToEnd)
        // §12 п. 62: лента опустела (приветствие не в счёт) — сброс гейта один раз на переходе; §12 п. 63:
        // следующая непустая лента — первый показ (`.end` без анимации), а не решение по хвосту прежнего визитёра.
        if newTail.firstMessageId == nil, tail.firstMessageId != nil {
            gate.listEmptied()
            seenTail = nil
        } else if !(seenTail == nil && newRows.isEmpty) {
            // Пустой первый снимок первым не считается: первые строки после него — тоже показ (`.end` без анимации).
            seenTail = newTail.remembered(after: seenTail)
        }
        if decision.decidedScroll { onScrollToEndDecided?() }
        if decision.abortDeceleration { abortDeceleration() }

        var byId: [String: BubbleRow] = [:]
        byId.reserveCapacity(newRows.count)
        for r in newRows { byId[r.id] = r }
        rows = newRows
        rowsById = byId
        tail = newTail
        imageStates = Self.keptImageStates(imageStates, old: oldById, new: byId)

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(tableIds(newRows), toSection: 0)
        var reconfigure = Set(newRows.compactMap { r -> String? in
            guard let old = oldById[r.id], old != r else { return nil }
            return r.id
        })
        if reconfigureVisible { reconfigure.formUnion(visibleIds().filter { byId[$0] != nil }) }
        if !reconfigure.isEmpty { snapshot.reconfigureItems(Array(reconfigure)) }

        scrollState.beginProgrammatic()
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            // Перенастроенная строка могла сменить высоту — перемер без перезагрузки.
            if !reconfigure.isEmpty { table.performBatchUpdates(nil) }
        }
        table.layoutIfNeeded()
        scrollState.endProgrammatic()
        appliedOnce = true
        ListTrace.log("rows \(oldRows.count)→\(newRows.count) plan=\(decision.plan) follows=\(scrollState.followsEnd)")

        execute(decision.plan, anchor: anchor)
        storeVisibleHeights()
        handle(decision.gate)
        let g = geometry()
        observeTop(g, byScroll: false)
        checkLoadMore(g)
    }

    /// Перенастроить строки на месте (цвет, локаль, картинки после возврата связи) и перемерить.
    private func reconfigureRows(ids: [String]) {
        let present = ids.filter { rowsById[$0] != nil }
        guard !present.isEmpty else { return }
        updating += 1
        defer { updating -= 1 }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(present)
        let anchor = anchorSnapshot()
        let plan = scrollState.planRowResize()
        scrollState.beginProgrammatic()
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            table.performBatchUpdates(nil)
        }
        table.layoutIfNeeded()
        scrollState.endProgrammatic()
        execute(plan, anchor: anchor)
        storeVisibleHeights()
        let g = geometry()
        observeTop(g, byScroll: false)
        checkLoadMore(g)
    }

    // MARK: - Исполнение планов

    private func execute(_ plan: UpdatePlan, anchor: AnchorSnapshot?) {
        switch plan {
        case .keep:
            // У `.inverted` старшие строки встают выше видимых — смещение не трогаем. Запасной ход `.normal`:
            // вставка сверху сдвигает видимое — восстановление якоря.
            if orientation == .normal { restoreAnchor(anchor, assign: scrollState.interacting) }
            scrollState.contentSettled(geometry: geometry())
        case .anchor:
            // Анимацию к началу по статус-бару не обрываем — она доедет, её конец досылает верх.
            // Под пальцем/флингом — присвоением (не рвёт торможение); иначе `setContentOffset(animated: false)` —
            // он же останавливает анимацию прокрутки, если она ещё идёт.
            if !scrollState.statusBarScrolling { restoreAnchor(anchor, assign: scrollState.interacting) }
            scrollState.contentSettled(geometry: geometry())
        case .end:
            settleAtEnd()
        case .anchorThenEnd(let animated):
            restoreAnchor(anchor, assign: false)
            scrollToEnd(animated: animated)
        }
    }

    /// Якорь читателя — первая видимая строка без приветствия, уцелевшая в новом наборе (удалена — соседняя).
    /// Две итерации: после первой раскладки нового положения строки ниже якоря могли смениться с оценки на настоящую
    /// высоту.
    private func restoreAnchor(_ anchor: AnchorSnapshot?, assign: Bool) {
        guard let anchor, let pick = anchor.pickAnchor(surviving: Set(rowsById.keys)),
              let indexPath = dataSource.indexPath(for: pick.id) else {
            // Ничего видимого не уцелело — в пределы ленты.
            let g = geometry()
            let clamped = g.clamped(g.offsetY)
            if abs(clamped - g.offsetY) > 0.5 { setOffset(clamped, assign: assign) }
            return
        }
        for _ in 0..<2 {
            let g = geometry()
            let target = g.restoredOffset(anchorFrame: table.rectForRow(at: indexPath), distance: pick.distance)
            guard abs(target - g.offsetY) > 0.5 else { break }
            setOffset(target, assign: assign)
            scrollState.beginProgrammatic()
            table.layoutIfNeeded()
            scrollState.endProgrammatic()
        }
    }

    /// Своё смещение: под «программно». `assign` — присвоением `contentOffset` (не рвёт торможение), иначе
    /// `setContentOffset(animated: false)` (останавливает анимацию прокрутки UIKit).
    private func setOffset(_ y: CGFloat, assign: Bool) {
        scrollState.beginProgrammatic()
        let point = CGPoint(x: table.contentOffset.x, y: y)
        if assign {
            table.contentOffset = point
        } else {
            table.setContentOffset(point, animated: false)
        }
        scrollState.endProgrammatic()
    }

    /// В конец без анимации. Две итерации: строки, вставшие на экран, перемеряются с оценки на настоящую высоту, и
    /// таблица в том же проходе раскладки поправляет смещение (на доли пункта) — конец ставится ещё раз.
    private func settleAtEnd() {
        for _ in 0..<2 {
            let end = geometry().endOffset
            guard abs(table.contentOffset.y - end) > 0.01 else { break }
            setOffset(end, assign: false)
            scrollState.beginProgrammatic()
            table.layoutIfNeeded()
            scrollState.endProgrammatic()
        }
    }

    /// Прокрутка в конец. Анимированная — `setContentOffset(animated: true)`, флаг автомата до
    /// `scrollViewDidEndScrollingAnimation`; цель совпала с текущим (±0,5) — флага и анимации нет.
    private func scrollToEnd(animated: Bool) {
        let g = geometry()
        guard animated else {
            settleAtEnd()
            return
        }
        if scrollState.beginAnimatedScrollToEnd(geometry: g) {
            startScrollAnimation(to: g.endOffset)
        }
    }

    /// Анимированная прокрутка к `y` под флагом автомата, уже поставленным вызывающим (к концу / к началу).
    private func startScrollAnimation(to y: CGFloat) {
        startingScrollAnimation = true
        table.setContentOffset(CGPoint(x: table.contentOffset.x, y: y), animated: true)
        startingScrollAnimation = false
    }

    /// Оборвать торможение флинга. Жест закрывает автомат (`DidEndDecelerating` не придёт).
    private func abortDeceleration() {
        abortedDecelerations += 1
        setOffset(table.contentOffset.y, assign: false)
    }

    // MARK: - Геометрия

    /// Геометрия таблицы с рамкой визуально верхней строки ленты.
    func geometry() -> ListGeometry {
        var g = table.geometry
        let count = table.numberOfSections > 0 ? table.numberOfRows(inSection: 0) : 0
        if count > 0 {
            let oldest = orientation == .inverted ? count - 1 : 0
            g.oldestRowFrame = table.rectForRow(at: IndexPath(row: oldest, section: 0))
        }
        return g
    }

    /// Снимок видимых строк для якоря. `boundsHeight` — высота вьюпорта ДО смены (клавиатура).
    private func anchorSnapshot(boundsHeight: CGFloat? = nil) -> AnchorSnapshot {
        let frames: [AnchorSnapshot.RowFrame] = (table.indexPathsForVisibleRows ?? []).compactMap { ip in
            guard let id = dataSource.itemIdentifier(for: ip), let row = rowsById[id] else { return nil }
            return AnchorSnapshot.RowFrame(id: id, isWelcome: row.isWelcome || id == ChatUiState.welcomeRowId,
                                           frame: table.rectForRow(at: ip))
        }
        return AnchorSnapshot(orientation: orientation, offsetY: table.contentOffset.y,
                              boundsHeight: boundsHeight ?? table.bounds.height, rows: frames)
    }

    private func visibleIds() -> [String] {
        (table.indexPathsForVisibleRows ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
    }

    // MARK: - Подгрузка истории

    /// Верх ленты стал виден прокруткой без жеста (VoiceOver, статус-бар, фокус) — касание (§12 п. 57); иначе только
    /// запоминается. `statusBar` — прокрутка к началу по тапу статус-бара: касание засчитывается раз на тап;
    /// повторное появление верха в том же тапе (страница пришла посреди анимации, конец анимации дослал верх новой
    /// страницы) гейт только запоминает.
    private func observeTop(_ g: ListGeometry, byScroll: Bool, statusBar: Bool = false) {
        let spent = byScroll && statusBar && statusBarTouchCounted
        if spent {
            // Журнал отладки: гейт засчитал бы это касанием.
            var probe = gate
            if probe.topObserved(visible: g.topVisible, firstMessageId: tail.firstMessageId, byScroll: true) {
                ListTrace.log("top by status bar again — tap already counted, first=\(tail.firstMessageId ?? "nil")")
            }
        }
        if gate.topObserved(visible: g.topVisible, firstMessageId: tail.firstMessageId, byScroll: byScroll && !spent) {
            if statusBar { statusBarTouchCounted = true }
            onTopTouch?()
        }
    }

    /// Повод для `loadMore` по геометрии сейчас. Сам вызов модели — `main.async`: публикация посреди
    /// отрисовки SwiftUI недопустима.
    func checkLoadMore(_ geometry: ListGeometry? = nil) {
        guard shownOnce else { return }
        let g = geometry ?? self.geometry()
        guard gate.shouldLoad(topVisible: g.topVisible, wholeListVisible: g.wholeListVisible, hasMore: hasMore,
                              firstMessageId: tail.firstMessageId) else { return }
        ListTrace.log("loadMore first=\(tail.firstMessageId ?? "nil")")
        DispatchQueue.main.async { [weak self] in
            guard let self, let model = self.model else { return }
            // Запрос не ушёл (прежний ещё идёт) — повод не потрачен, вернётся по `loadMoreFinished`.
            if !model.loadMore() { self.gate.requestDropped() }
        }
    }

    private func handle(_ events: [GateEvent]) {
        for event in events {
            switch event {
            case .gestureChanged:
                if gate.gestureChanged() { checkLoadMore() }
            case .gestureEnded:
                gate.gestureEnded()
            case .checkLoadMore:
                checkLoadMore()
            }
        }
    }

    // MARK: - Жест и страховка

    /// Страховка залипания: `interacting`, а жеста нет — закрыть; ждала докрутка своего — исполнить.
    private func runGestureLost() {
        guard scrollState.interacting else { return }
        perform(scrollState.gestureLost(live: table.gestureLive, geometry: geometry()))
    }

    private func perform(_ action: DragEndAction) {
        if action.abortDeceleration { abortDeceleration() }
        if let plan = action.plan { execute(plan, anchor: anchorSnapshot()) }
        handle(action.gate)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === table else { return }
        handle(scrollState.dragBegan(geometry: geometry()))
    }

    /// Ждёт докрутка своего — флинг отпускания гасится (цель торможения = текущее смещение в пределах
    /// ленты): торможение UIKit начнётся ПОСЛЕ `DidEndDragging` и оборвало бы анимацию к концу.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === table else { return }
        if scrollState.dragWillEnd() {
            targetContentOffset.pointee.y = geometry().clamped(table.contentOffset.y)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === table else { return }
        perform(scrollState.dragEnded(willDecelerate: decelerate, geometry: geometry()))
    }

    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === table else { return }
        scrollState.decelerationBegan()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === table else { return }
        perform(scrollState.decelerationEnded(geometry: geometry()))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === table else { return }
        runGestureLost()
        let g = geometry()
        let unownedBefore = scrollState.unownedOffsetCount
        // Смещения, которые таблица делает сама в проходе раскладки или при смене рамки (поджим к краю при росте
        // вьюпорта), — «программно».
        let kind: ScrollKind = table.isInLayoutPass || table.isResizing
            ? .programmatic : scrollState.scrolled(geometry: g)
        if scrollState.unownedOffsetCount != unownedBefore {
            ListTrace.log("unowned offset #\(scrollState.unownedOffsetCount) y=\(g.offsetY) h=\(g.boundsHeight)")
        }
        observeTop(g, byScroll: kind == .withoutGesture,
                   statusBar: kind == .withoutGesture && scrollState.statusBarScrolling)
        guard updating == 0 else { return }
        checkLoadMore(g)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === table else { return }
        // Конец прежней анимации, оборванной запуском новой: флаги уже новой — не трогать.
        guard !startingScrollAnimation else {
            ListTrace.log("scroll animation interrupted by a new one — flags kept")
            return
        }
        // К началу по оценкам высот верх мог не встать — одна досылка, пока флаг «статус-бар» ещё стоит
        // (прокрутка без жеста, касание засчитывается). Страница пришла посреди анимации (первое сообщение
        // сменилось с тапа) — досылки нет: верх новой страницы — скачок на страницу вверх; лента остаётся на верхе
        // загруженного при тапе, старшие сообщения выше, дальше — пальцем.
        if scrollState.statusBarScrolling {
            let g = geometry()
            if tail.firstMessageId != statusBarTapFirstId {
                if !g.topVisible { ListTrace.log("status bar: page arrived mid-animation — top not re-sent") }
            } else if !g.topVisible, abs(g.startOffset - g.offsetY) > 0.5 {
                table.setContentOffset(CGPoint(x: table.contentOffset.x, y: g.startOffset), animated: false)
            }
        }
        let g = geometry()
        let ended = scrollState.scrollAnimationEnded(geometry: g)
        ListTrace.log("scroll animation ended kind=\(String(describing: ended)) y=\(g.offsetY) top=\(g.topVisible)")
        if ended == .withoutGesture {
            observeTop(g, byScroll: true, statusBar: true)
        }
        checkLoadMore(g)
    }

    /// Таблица сама к «top» UIKit не прокручивается (`scrollsToTop = false`): тап принимает прокси
    /// (`ScrollToTopProxyView` — сам себе делегат, зовёт `statusBarTapped`). Здесь — страховка на случай, если
    /// `scrollsToTop` таблицы кто-то включит.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool { false }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rowsById[id] else {
            return Theme.photoPlaceholderHeight
        }
        return heights.estimatedHeight(row: row, width: contentWidth, imageStates: states(for: row),
                                       legibilityWeight: legibility)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        onWillDisplayRow?(indexPath)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rowsById[id] else { return }
        store(height: cell.bounds.height, row: row)
    }

    // MARK: - InvertedTableHost

    /// Снимок видимого по СТАРОМУ вьюпорту — `bounds` ещё прежний. Несколько смен до раскладки — годен первый
    /// (снят при размере прошлой раскладки); устаревший (раскладки со сменой не было) — заменяется.
    func tableSizeWillChange(to new: CGSize) {
        if let pending = preResize, pending.size == table.lastLayoutSize { return }
        let size = table.bounds.size
        guard size == table.lastLayoutSize else {
            preResize = nil
            return
        }
        preResize = (size, anchorSnapshot())
    }

    func tableViewportWillChange(from old: CGSize, to new: CGSize) {
        // Якорь — по вьюпорту ДО смены: снятый до смены `bounds` (здесь `bounds` уже новый, и видимые
        // строки — строки нового вьюпорта); нет его — по видимым сейчас с прежней высотой (клавиатура: ширина та же).
        // Смещения прохода раскладки — «программно» по `isInLayoutPass`, свои установки в `…DidChange` — под
        // `setOffset`; открывать «программно» здесь не нужно (вложенная смена размера затёрла бы непарный счётчик).
        // Перенастройка ячеек под новую ширину — в `…DidChange` (`cellForRow` здесь сдвигал бы смещение
        // вне прохода раскладки — «чужое»).
        if let pending = preResize, pending.size == old {
            viewportChange = pending.anchor
        } else {
            viewportChange = anchorSnapshot(boundsHeight: old.height)
        }
        preResize = nil
    }

    func tableViewportDidChange(from old: CGSize, to new: CGSize) {
        guard let anchor = viewportChange else { return }
        viewportChange = nil
        updating += 1
        defer { updating -= 1 }
        guard appliedOnce else { return }
        let hadAnimation = scrollState.animatingToEnd || scrollState.statusBarScrolling
        let fresh = old.height <= 0 || old.width <= 0
        if old.width != new.width { remeasureForWidth() }
        let plan = scrollState.planResize(viewportShrank: !fresh && new.height < old.height,
                                          viewportGrew: !fresh && new.height > old.height)
        ListTrace.log("viewport \(old)→\(new) plan=\(plan) follows=\(scrollState.followsEnd) "
                      + "unowned=\(scrollState.unownedOffsetCount)")
        switch plan {
        case .end:
            setOffset(geometry().endOffset, assign: !hadAnimation)
        case .anchor:
            restoreAnchor(anchor, assign: scrollState.interacting || !hadAnimation)
            scrollState.contentSettled(geometry: geometry())
        case .keep, .anchorThenEnd:
            execute(plan, anchor: anchor)
        }
        storeVisibleHeights()
        let g = geometry()
        observeTop(g, byScroll: false)
        checkLoadMore(g)
    }

    func tableLayoutPassFinished() {
        let h = table.contentSize.height
        // `contentSize` сменился (оценки заменились настоящими высотами) — повод проверки. Посреди своего
        // обновления — нет: проверит его конец (§12 п. 56).
        if lastContentHeight != h {
            lastContentHeight = h
            if updating == 0, viewportChange == nil, !scrollState.isProgrammatic, appliedOnce { checkLoadMore() }
        }
        scheduleTraitsCheckIfNeeded()
    }

    func tableAccessibilityScrollWillBegin() {
        scrollState.beginAccessibilityScroll()
    }

    func tableAccessibilityScrolled() {
        let g = geometry()
        scrollState.accessibilityScrolled(geometry: g)
        observeTop(g, byScroll: true)
        checkLoadMore(g)
    }

    /// Тап по статус-бару — анимированно к началу ленты; флаг «статус-бар» до конца анимации.
    func statusBarTapped() {
        let g = geometry()
        ListTrace.log("status bar tap y=\(g.offsetY) start=\(g.startOffset) animating=\(scrollState.statusBarScrolling)")
        if scrollState.beginStatusBarScroll(geometry: g) {
            // Новый тап — новый повод.
            statusBarTouchCounted = false
            statusBarTapFirstId = tail.firstMessageId
            startScrollAnimation(to: g.startOffset)
        }
    }

    // MARK: - Доступность: фокус элемента

    /// Фокус VoiceOver на элементе пузыря строки: строка — крайняя загруженная сверху или снизу, и за ней есть строки →
    /// прокрутка к ней (соседние загрузятся, следующий свайп их найдёт). Прокрутка без жеста.
    func accessibilityFocused(rowId: String) {
        guard let ip = dataSource.indexPath(for: rowId) else { return }
        let visible = (table.indexPathsForVisibleRows ?? []).map(\.row)
        guard let lo = visible.min(), let hi = visible.max() else { return }
        let count = table.numberOfSections > 0 ? table.numberOfRows(inSection: 0) : 0
        guard (ip.row == lo && lo > 0) || (ip.row == hi && hi < count - 1) else { return }
        scrollState.cancelScrollAnimations()
        scrollState.beginFocusScroll()
        table.scrollToRow(at: ip, at: .middle, animated: false)
        table.layoutIfNeeded()
        let g = geometry()
        scrollState.focusScrolled(geometry: g)
        observeTop(g, byScroll: true)
        checkLoadMore(g)
    }

    // MARK: - Ячейки, картинки, кэш высот

    /// Ширина ленты без боковых safe area — ОДНА для оценки и кэша; ячейка получает ширину таблицы и отступы
    /// 12 + safe area своей стороны, итог тот же: потолок пузыря `(ширина − 2·12 − safe area) · 0,8`.
    private var sideInsets: UIEdgeInsets {
        (table.superview as? MessageListContainerView)?.sideSafeInsets ?? .zero
    }

    var contentWidth: CGFloat {
        let s = sideInsets
        return max(0, table.bounds.width - s.left - s.right)
    }

    private var legibility: UILegibilityWeight { BubbleStyle.legibility(table.traitCollection) }

    private func states(for row: BubbleRow) -> [ImageSlotState] {
        if let s = imageStates[row.id] { return s }
        // Фото и видео — у обоих есть состояние картинки; у одних ссылок его нет.
        guard row.attachments.contains(where: { $0.kind != .file }) else { return [] }
        return MessageCell.initialImageStates(row: row, actions: cellActions)
    }

    private func store(height: CGFloat, row: BubbleRow) {
        guard height > 0, contentWidth > 0 else { return }
        let key = RowHeightCache.contentKey(row: row, imageStates: states(for: row), legibilityWeight: legibility)
        heights.store(id: row.id, width: contentWidth, key: key, height: height)
    }

    private func storeVisibleHeights() {
        for ip in table.indexPathsForVisibleRows ?? [] {
            guard let cell = table.cellForRow(at: ip), let id = dataSource.itemIdentifier(for: ip),
                  let row = rowsById[id] else { continue }
            store(height: cell.bounds.height, row: row)
        }
    }

    private func configure(_ cell: MessageCell, row: BubbleRow) {
        // Переворот содержимого — по ориентации (ячейка о нём не знает).
        cell.contentView.transform = orientation == .inverted ? InvertedTableView.mirrorY : .identity
        let actions = cellActions
        let states = MessageCell.initialImageStates(row: row, actions: actions)
        let s = sideInsets
        let rtl = table.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let leading = Theme.listPadding + (rtl ? s.right : s.left)
        let trailing = Theme.listPadding + (rtl ? s.left : s.right)
        // Отказ картинки забыт (возврат связи): та же ячейка той же строки держит ссылку и сама не перезапускает
        // загрузку («показанное не трогаем») — сначала сбросить её вложения. Сверка — с тем, что показывает САМА
        // ячейка: кэш состояний строки возврат связи уже сбросил (`reloadFailedImages`).
        if cell.bubble.row?.id == row.id,
           Self.failureForgotten(previous: cell.bubble.attachmentsView.slots.map(\.state), now: states) {
            var blank = row
            blank.attachments = []
            cell.configure(row: blank, primaryHex: primaryHex, strings: strings ?? L10n.strings(language: "ru"),
                           listWidth: table.bounds.width, leadingInset: leading, trailingInset: trailing,
                           actions: actions)
        }
        imageStates[row.id] = states
        cell.configure(row: row, primaryHex: primaryHex, strings: strings ?? L10n.strings(language: "ru"),
                       listWidth: table.bounds.width, leadingInset: leading, trailingInset: trailing,
                       actions: actions)
    }

    /// Состояние картинок строк нового снимка: ушедших строк — долой; строки, у которой сменились вложения
    /// (подтверждение своего меняет `onServer`), — тоже: дальше оно заново по новой строке. Загруженную ячейку
    /// перенастроит `reconfigureItems`, а незагруженную он не трогает — её оценка высоты считала бы прежнее состояние
    /// (ссылку), хотя ячейка при показе нарисует картинку.
    static func keptImageStates(_ states: [String: [ImageSlotState]], old: [String: BubbleRow],
                                new: [String: BubbleRow]) -> [String: [ImageSlotState]] {
        states.filter { id, _ in
            guard let row = new[id] else { return false }
            return old[id]?.attachments == row.attachments
        }
    }

    /// Было `.failed`, стало не `.failed` на той же позиции — память отказа сброшена.
    static func failureForgotten(previous: [ImageSlotState], now: [ImageSlotState]) -> Bool {
        zip(previous, now).contains { $0 == .failed && $1 != .failed }
    }

    /// Ширина сменилась — ячейки заново под новую ширину и перемер высот строк
    /// (`performBatchUpdates(nil)` без анимации, как при росте строки: без перенастройки таблица высоты загруженных
    /// строк не пересчитывает; на новых iOS перемеряет уже `apply` с `reconfigureItems`). Перенастройка —
    /// `reconfigureItems` снимка, а не обход `visibleCells`: он достаёт и ЗАГОТОВЛЕННЫЕ за краем ячейки (префетч, iOS
    /// 15+), они выходят на экран без `cellForRow` и остались бы под старую ширину. Незагруженные строки он не трогает.
    /// Смещения, которые при этом ставит таблица, — «программно». До решения о смене вьюпорта: якорь и конец — по новым
    /// высотам.
    private func remeasureForWidth() {
        var snapshot = dataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        scrollState.beginProgrammatic()
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            table.performBatchUpdates(nil)
        }
        table.layoutIfNeeded()
        scrollState.endProgrammatic()
    }

    /// Связь вернулась — память отказов картинок и обложек видео сбрасывается, строки с отказом перенастраиваются (загрузка заново). Кэш состояний этих
    /// строк сбрасывается тоже: иначе ключ кэша высот у невидимой строки остался бы «ссылкой», и при прокрутке к ней
    /// оценка разошлась бы с ячейкой. `reconfigureItems` трогает только загруженные ячейки (видимые и заготовленные),
    /// прочие перезагрузятся при показе (`configure`); перемер — с якорем, как любой рост строки.
    private func reloadFailedImages() {
        model?.forgetImageFailures()
        let failed = imageStates.filter { $0.value.contains(.failed) }.map(\.key)
        guard !failed.isEmpty else { return }
        for id in failed { imageStates[id] = nil }
        reconfigureRows(ids: failed)
    }

    /// Исход асинхронной загрузки картинки: состояние строки (ключ кэша высот) и перемер.
    private func imageSettled(rowId: String, index: Int32, state: ImageSlotState) {
        guard let row = rowsById[rowId] else { return }
        let old = states(for: row)
        let new = MessageCell.settling(old, row: row, index: index, state: state)
        imageStates[rowId] = new
        guard new != old else { return }
        resizeRows()
    }

    /// Рост/перемер строки — `performBatchUpdates(nil)` без анимации, план автомата.
    func resizeRows() {
        updating += 1
        let anchor = anchorSnapshot()
        let plan = scrollState.planRowResize()
        scrollState.beginProgrammatic()
        UIView.performWithoutAnimation { table.performBatchUpdates(nil) }
        table.layoutIfNeeded()
        scrollState.endProgrammatic()
        execute(plan, anchor: anchor)
        storeVisibleHeights()
        updating -= 1
        let g = geometry()
        observeTop(g, byScroll: false)
        checkLoadMore(g)
    }

    /// Высота строки сменилась по трейту ячейки («Жирный шрифт») — сигнал приходит посреди раскладки, перемер —
    /// следующим оборотом, один на все ячейки.
    private func scheduleRowResize() {
        guard !rowResizeScheduled else { return }
        rowResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rowResizeScheduled = false
            self.resizeRows()
        }
    }

    /// «Жирный шрифт» (`legibilityWeight`) и категория размера шрифта — пересчёт видимых строк; категория —
    /// ещё и сброс кэша высот. Смена видна в проходе раскладки, действие — следующим оборотом.
    private func scheduleTraitsCheckIfNeeded() {
        let weight = legibility
        let category = table.traitCollection.preferredContentSizeCategory
        guard lastLegibility != nil else {
            lastLegibility = weight
            lastSizeCategory = category
            return
        }
        guard weight != lastLegibility || category != lastSizeCategory, !traitsCheckScheduled else { return }
        traitsCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.traitsCheckScheduled = false
            let weight = self.legibility
            let category = self.table.traitCollection.preferredContentSizeCategory
            if category != self.lastSizeCategory { self.heights.contentSizeCategoryDidChange() }
            self.lastLegibility = weight
            self.lastSizeCategory = category
            self.reconfigureRows(ids: self.visibleIds())
        }
    }

    private var cellActions: CellActions {
        if let actions { return actions }
        let made = makeActions()
        actions = made
        return made
    }

    /// Модель — слабо: действия живут в ячейках и координаторе дольше экрана.
    private func makeActions() -> CellActions {
        // Локальная ссылка живёт только в этом вызове; замыкания держат модель слабо (`[weak model]`).
        let model = self.model
        var a = CellActions(
            retry: { [weak model] id in DispatchQueue.main.async { model?.retry(id: id) } },
            cancel: { [weak model] id in DispatchQueue.main.async { model?.cancel(id: id) } },
            cachedImage: { [weak model] id, index in model?.cachedImage(messageId: id, index: index) },
            cachedLocalImage: { [weak model] uri in model?.cachedLocalImage(uri: uri) },
            image: { [weak model] id, index in await model?.image(messageId: id, index: index) },
            localImage: { [weak model] uri in await model?.localImage(uri: uri) },
            bytes: { [weak model] id, index in await model?.bytes(messageId: id, index: index) },
            previewSession: model?.previewSession ?? "",
            openPreview: { [weak self] item in self?.openPreview(item) },
            imageSettled: { [weak self] id, index, state in self?.imageSettled(rowId: id, index: index, state: state) },
            accessibilityFocused: { [weak self] id in self?.accessibilityFocused(rowId: id) })
        a.imageFailed = { [weak model] id, index in model?.imageFailed(messageId: id, index: index) ?? false }
        a.rememberImageFailure = { [weak model] id, index in
            model?.rememberImageFailure(messageId: id, index: index)
        }
        a.contentHeightChanged = { [weak self] _ in self?.scheduleRowResize() }
        // Обложки видео — свой кэш и своя память отказов модели.
        a.cachedThumbnail = { [weak model] id, index in model?.cachedThumbnail(messageId: id, index: index) }
        a.thumbnail = { [weak model] id, index in await model?.thumbnail(messageId: id, index: index) }
        a.thumbnailFailed = { [weak model] id, index in model?.thumbnailFailed(messageId: id, index: index) ?? false }
        return a
    }
}
