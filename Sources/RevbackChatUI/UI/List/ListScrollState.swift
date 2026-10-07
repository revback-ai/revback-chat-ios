import Foundation

/// Что сделать с положением ленты после обновления.
enum UpdatePlan: Equatable {
    /// Смещение не трогаем (вставка только истории выше видимых сообщений).
    case keep
    /// Восстановить якорь читателя — присвоением `contentOffset`, не `setContentOffset(animated: false)` (не рвёт
    /// торможение).
    case anchor
    /// Сразу в конец, без анимации.
    case end
    /// Сначала якорь (новая строка под краем), затем прокрутка в конец (`animated` — анимированная).
    case anchorThenEnd(animated: Bool)
}

/// Кто двигал ленту в `scrollViewDidScroll`.
enum ScrollKind: Equatable {
    /// Своё смещение ленты (`apply`, якорь, конец, смена вьюпорта, проход раскладки таблицы, анимация к концу).
    case programmatic
    /// Идёт жест пальцем (с торможением) — решит конец жеста.
    case gesture
    /// Прокрутка без жеста: VoiceOver, статус-бар, фокус, прочие системные — `followsEnd` по геометрии уже обновлён,
    /// для `LoadMoreGate.topObserved` это `byScroll: true`.
    case withoutGesture
}

/// Поводы для `LoadMoreGate`, которые координатор применяет по порядку.
enum GateEvent: Equatable {
    /// `gate.gestureChanged()`; `true` — проверить повод (`checkLoadMore()`).
    case gestureChanged
    /// `gate.gestureEnded()`.
    case gestureEnded
    /// `checkLoadMore()`.
    case checkLoadMore
}

/// Решение по новому снимку строк.
struct RowsDecision: Equatable {
    var plan: UpdatePlan
    /// Оборвать торможение флинга (`setContentOffset(contentOffset, animated: false)` под «программно») ДО плана.
    var abortDeceleration: Bool
    /// `NewRowScroll` решил крутить к концу — крючок `onScrollToEndDecided`.
    var decidedScroll: Bool
    /// Поводы гейта (закрытие жеста при обрыве торможения).
    var gate: [GateEvent]
}

/// Итог конца жеста / страховки.
struct DragEndAction: Equatable {
    var gate: [GateEvent]
    /// `pendingEnd` исполняется — план докрутки своего.
    var plan: UpdatePlan?
    /// Оборвать начинающееся торможение перед планом.
    var abortDeceleration: Bool
}

/// Автомат ленты без UIKit.
///
/// «У конца» — СОСТОЯНИЕ `followsEnd`, а не вывод из последнего кадра раскладки: его меняют только решение «в конец»,
/// конец пользовательского движения (по геометрии) и не программное смещение вне жеста (по геометрии). Кто двигал
/// ленту — из событий `UIScrollViewDelegate`, которые координатор переводит в вызовы этого типа; так тест может
/// проиграть жест вызовами.
///
/// `NewRowScroll`/`RowsTail`/`AutoScrollRule` (`Rows.swift`) зовутся, а не копируются.
struct ListScrollState {

    /// «Пользователь у конца» для всех решений (`wasAtBottom` в `NewRowScroll`/`AutoScrollRule`). На показе `true`.
    private(set) var followsEnd = true
    /// От `WillBeginDragging` до конца торможения (`DidEndDragging(false)` / `DidEndDecelerating` / обрыв / страховка).
    private(set) var interacting = false
    /// Палец на экране: от `WillBeginDragging` до `DidEndDragging` (или закрытия жеста). Автомат ведёт сам — план
    /// строк не спрашивает `table.isDragging` (своё под пальцем ждёт отпускания).
    private(set) var fingerDown = false
    /// `DidEndDragging(willDecelerate: true)` пришёл, `WillBeginDecelerating` ещё нет: `isDecelerating` таблицы ещё
    /// `false`, и страховка приняла бы начинающееся торможение за потерянный жест.
    private(set) var awaitingDeceleration = false
    /// Своё пришло, пока палец на экране — «к концу» исполняется в `DidEndDragging`.
    private(set) var pendingEnd = false
    private var pendingEndAnimated = true
    /// При ждущей докрутке своего флинг отпускания погашен в `WillEndDragging` (цель торможения = текущее
    /// смещение). Торможение UIKit начинается ПОСЛЕ `DidEndDragging` — обрыв там его не отменил бы и порвал анимацию к
    /// концу; поэтому докрутка ждёт конца этого (нулевого) торможения.
    private(set) var flingStopped = false
    /// Глубина синхронных «своих» смещений (`beginProgrammatic`/`endProgrammatic`).
    private(set) var programmaticDepth = 0
    /// Идёт анимированная прокрутка к концу (`setContentOffset(animated: true)`) — «программно» до
    /// `scrollViewDidEndScrollingAnimation` или до жеста, который её обрывает.
    private(set) var animatingToEnd = false
    /// Анимированная прокрутка к началу по тапу статус-бара.
    private(set) var statusBarScrolling = false
    /// Свой `accessibilityScroll` ставит смещение.
    private(set) var accessibilityScrolling = false
    /// Прокрутка к строке по фокусу элемента VoiceOver.
    private(set) var focusScrolling = false
    /// Смещения не от ленты (`programmatic == 0`, без жеста, без флагов доступности/статус-бара/фокуса). После смены
    /// высоты вьюпорта расти не должен — рост значит, что `UIScrollView` двигает смещение сам.
    private(set) var unownedOffsetCount = 0

    /// Смещение сейчас — своё.
    var isProgrammatic: Bool { programmaticDepth > 0 || animatingToEnd }

    // MARK: - Показ

    /// Новый показ (и повторный `onAppear` того же вью): у конца, без жеста и флагов. Гейт сбрасывает координатор.
    mutating func shown() {
        self = ListScrollState()
    }

    // MARK: - Свои смещения

    mutating func beginProgrammatic() { programmaticDepth += 1 }

    mutating func endProgrammatic() { programmaticDepth = max(0, programmaticDepth - 1) }

    /// Допуск «цель анимации = текущее смещение»: UIKit в этом случае `scrollViewDidEndScrollingAnimation` НЕ шлёт.
    static let animationTargetSlack: CGFloat = 0.5

    /// Сдвинет ли анимированная прокрутка ленту (`|цель − текущее| > 0,5`). Нет — флаг анимации ставить нельзя:
    /// завершения не будет, и флаг залип бы.
    static func animationMoves(from current: CGFloat, to target: CGFloat) -> Bool {
        abs(target - current) > animationTargetSlack
    }

    /// Анимированная прокрутка к концу начинается (`.anchorThenEnd(animated: true)`); `geometry` — ПОСЛЕ якоря, перед
    /// `setContentOffset(endOffset, animated: true)`. `false` — лента уже у `endOffset` (короткая лента, якорь совпал
    /// с концом): флаг не ставится, анимацию координатор не запускает (завершения от UIKit не будет).
    @discardableResult
    mutating func beginAnimatedScrollToEnd(geometry: ListGeometry) -> Bool {
        statusBarScrolling = false
        animatingToEnd = Self.animationMoves(from: geometry.offsetY, to: geometry.endOffset)
        return animatingToEnd
    }

    /// Анимированная прокрутка к началу по статус-бару начинается (цель — `startOffset`). `false` — лента уже у
    /// начала: флаг не ставится.
    @discardableResult
    mutating func beginStatusBarScroll(geometry: ListGeometry) -> Bool {
        animatingToEnd = false
        statusBarScrolling = Self.animationMoves(from: geometry.offsetY, to: geometry.startOffset)
        return statusBarScrolling
    }

    /// Анимации прокрутки больше нет без `scrollViewDidEndScrollingAnimation` (смещение присвоено поверх неё,
    /// `setContentOffset(animated: false)`): снять оба флага, иначе чужие смещения шли бы как `.programmatic`, а
    /// `unownedOffsetCount` ослеп бы.
    mutating func cancelScrollAnimations() {
        animatingToEnd = false
        statusBarScrolling = false
    }

    /// `scrollViewDidEndScrollingAnimation`. Статус-бар — «прокрутка без жеста» (`followsEnd` по геометрии, повод
    /// `topObserved(byScroll: true)`); прокрутка к концу — своя. `nil` — анимации не было.
    mutating func scrollAnimationEnded(geometry: ListGeometry) -> ScrollKind? {
        if statusBarScrolling {
            statusBarScrolling = false
            followsEnd = geometry.atEnd
            return .withoutGesture
        }
        if animatingToEnd {
            animatingToEnd = false
            return .programmatic
        }
        return nil
    }

    // MARK: - Доступность

    /// Свой `accessibilityScroll` ставит смещение под этим флагом.
    mutating func beginAccessibilityScroll() { accessibilityScrolling = true }

    /// Завершение `accessibilityScroll` — «прокрутка без жеста»: `followsEnd` по геометрии.
    mutating func accessibilityScrolled(geometry: ListGeometry) {
        accessibilityScrolling = false
        followsEnd = geometry.atEnd
    }

    /// Прокрутка к строке по фокусу элемента VoiceOver.
    mutating func beginFocusScroll() { focusScrolling = true }

    mutating func focusScrolled(geometry: ListGeometry) {
        focusScrolling = false
        followsEnd = geometry.atEnd
    }

    // MARK: - Жест

    /// `WillBeginDragging`: сначала закрыть прежний незакрытый жест (его `gestureEnded`), потом новый жест — свой повод.
    /// Жест обрывает анимацию к концу/к началу: дальше решает он. Ждавшая докрутка своего (`DidEndDragging` прежнего
    /// жеста потерян) в новый жест не переносится: пользователь снова держит ленту, отпускание нового жеста её не
    /// исполнит.
    mutating func dragBegan(geometry: ListGeometry) -> [GateEvent] {
        var events = closeGesture(geometry: geometry)
        pendingEnd = false
        flingStopped = false
        cancelScrollAnimations()
        interacting = true
        fingerDown = true
        awaitingDeceleration = false
        events.append(.gestureChanged)
        return events
    }

    /// `WillEndDragging`. `true` — ждёт докрутка своего: координатор гасит флинг отпускания
    /// (`targetContentOffset` = текущее смещение), докрутка — по концу торможения (`decelerationEnded`).
    mutating func dragWillEnd() -> Bool {
        flingStopped = pendingEnd
        return pendingEnd
    }

    /// `DidEndDragging(willDecelerate:)`. Ждущая докрутка своего: флинг погашен (`dragWillEnd`) и торможение
    /// ещё будет — ждёт его конца; иначе исполняется здесь (жест закрыт, план `.anchorThenEnd`; торможение без
    /// `WillEndDragging` — обрыв). Без неё: торможение — тот же жест (решит его конец), без торможения — жест закрыт.
    mutating func dragEnded(willDecelerate: Bool, geometry: ListGeometry) -> DragEndAction {
        fingerDown = false
        if pendingEnd {
            if willDecelerate, flingStopped {
                awaitingDeceleration = interacting
                return DragEndAction(gate: [], plan: nil, abortDeceleration: false)
            }
            return runPendingEnd(abort: willDecelerate, geometry: geometry)
        }
        guard !willDecelerate else {
            awaitingDeceleration = interacting
            return DragEndAction(gate: [], plan: nil, abortDeceleration: false)
        }
        return DragEndAction(gate: closeGesture(geometry: geometry), plan: nil, abortDeceleration: false)
    }

    /// `WillBeginDecelerating`: торможение пошло, `isDecelerating` таблицы — `true`; страховка снова в силе.
    mutating func decelerationBegan() { awaitingDeceleration = false }

    /// `DidEndDecelerating`: жест закрыт; ждала докрутка своего (флинг погашен) — исполнить.
    mutating func decelerationEnded(geometry: ListGeometry) -> DragEndAction {
        if pendingEnd { return runPendingEnd(abort: false, geometry: geometry) }
        return DragEndAction(gate: closeGesture(geometry: geometry), plan: nil, abortDeceleration: false)
    }

    /// Закрытие жеста: `followsEnd` по геометрии, `gestureEnded`, проверка повода. Повторный вызов — ничего.
    mutating func closeGesture(geometry: ListGeometry) -> [GateEvent] {
        guard interacting else { return [] }
        interacting = false
        fingerDown = false
        awaitingDeceleration = false
        flingStopped = false
        followsEnd = geometry.atEnd
        return [.gestureEnded, .checkLoadMore]
    }

    /// Жест живой — для страховки: палец касается (`isTracking`), тянет (`isDragging`) или лента тормозит
    /// (`isDecelerating`).
    static func gestureLive(isTracking: Bool, isDragging: Bool, isDecelerating: Bool) -> Bool {
        isTracking || isDragging || isDecelerating
    }

    /// Страховка залипания: координатор зовёт в начале `update`, в `scrollViewDidScroll`, в `WillBeginDragging`
    /// с `live` = `gestureLive(...)` таблицы. Жест живой или торможение вот-вот начнётся (между
    /// `DidEndDragging(willDecelerate: true)` и `WillBeginDecelerating`) — ничего. Иначе жест помечен идущим —
    /// закрыть; ждала докрутка своего — исполнить.
    mutating func gestureLost(live: Bool, geometry: ListGeometry) -> DragEndAction {
        guard !live, !awaitingDeceleration else { return DragEndAction(gate: [], plan: nil, abortDeceleration: false) }
        if pendingEnd { return runPendingEnd(abort: false, geometry: geometry) }
        return DragEndAction(gate: closeGesture(geometry: geometry), plan: nil, abortDeceleration: false)
    }

    private mutating func runPendingEnd(abort: Bool, geometry: ListGeometry) -> DragEndAction {
        pendingEnd = false
        flingStopped = false
        let events = closeGesture(geometry: geometry)
        followsEnd = true
        return DragEndAction(gate: events, plan: .anchorThenEnd(animated: pendingEndAnimated), abortDeceleration: abort)
    }

    // MARK: - Классификатор смещений

    /// `scrollViewDidScroll` (после страховки): своё → ничего; жест → ничего (решит конец жеста); иначе — прокрутка без
    /// жеста, `followsEnd` по геометрии; смещение без флагов доступности/статус-бара/фокуса — «чужое».
    mutating func scrolled(geometry: ListGeometry) -> ScrollKind {
        if programmaticDepth > 0 { return .programmatic }
        if accessibilityScrolling || focusScrolling {
            followsEnd = geometry.atEnd
            return .withoutGesture
        }
        if animatingToEnd { return .programmatic }
        if interacting { return .gesture }
        followsEnd = geometry.atEnd
        if !statusBarScrolling { unownedOffsetCount += 1 }
        return .withoutGesture
    }

    // MARK: - План обновления строк

    /// Решение по новому снимку строк — синхронно, по состоянию ДО обновления.
    /// - `seen` — обработанный хвост (`RowsTail.remembered(after:)` прошлого решения), `nil` — первый снимок;
    /// - `whole` — `ListGeometry.wholeListVisible` до обновления;
    /// - `onlyPrepended` — `ListScrollState.onlyPrepended(old:new:)`.
    /// Палец на экране — `fingerDown` самого автомата. План, двигающий смещение (всё, кроме `.keep`), обрывает
    /// анимацию прокрутки — флаги анимаций снимаются (`cancelScrollAnimations`). Кроме `.anchor` посреди анимации к
    /// началу по статус-бару: её координатор не обрывает — лента доезжает, конец анимации досылает верх.
    mutating func planRows(seen: RowsTail?, tail: RowsTail, whole: Bool, onlyPrepended: Bool,
                           animates: Bool) -> RowsDecision {
        let d = decideRows(seen: seen, tail: tail, whole: whole, onlyPrepended: onlyPrepended, animates: animates)
        if d.plan != .keep, !(d.plan == .anchor && statusBarScrolling) { cancelScrollAnimations() }
        return d
    }

    /// После `.anchor`/`.keep` вне жеста и анимаций лента оказалась у конца (строки ниже читающего
    /// удалены, перемер укоротил строку) — «у конца» снова состояние, следующее входящее докручивается.
    mutating func contentSettled(geometry: ListGeometry) {
        guard !interacting, !animatingToEnd, !statusBarScrolling, geometry.atEnd else { return }
        followsEnd = true
    }

    private mutating func decideRows(seen: RowsTail?, tail: RowsTail, whole: Bool, onlyPrepended: Bool,
                                     animates: Bool) -> RowsDecision {
        guard let seen else {
            followsEnd = true
            return RowsDecision(plan: .end, abortDeceleration: false, decidedScroll: false, gate: [])
        }
        let scroll = NewRowScroll.shouldScroll(seen: seen, tail: tail, wasAtBottom: followsEnd,
                                               wasWholeListVisible: whole)
        // Сменилась последняя строка ИЛИ та же последняя стала «своей отсюда» (§12 п. 75).
        let lastIsNew = tail.lastId != seen.lastId || (tail.lastSentHere && !seen.lastSentHere)
        // Своё отсюда НОВОЕ: последней стала строка, которой в прошлом хвосте не было (перестановка — не новое своё,
        // §12 п. 73), или та же последняя стала «своей отсюда» (поздний id, §12 п. 75).
        let ownNew: Bool = {
            guard tail.lastSentHere, let last = tail.lastId else { return false }
            if last != seen.lastId { return !seen.ids.contains(last) }
            return !seen.lastSentHere
        }()

        if ownNew {
            if fingerDown {
                // Под пальцем ленту не рвём — докрутка при отпускании.
                pendingEnd = true
                pendingEndAnimated = animates
                return RowsDecision(plan: .anchor, abortDeceleration: false, decidedScroll: true, gate: [])
            }
            // Идёт торможение — оборвать его и закрыть жест самим (`DidEndDecelerating` не придёт). Ждавшая
            // докрутка прежнего своего (погашенный флинг) исполняется этим же планом.
            let abort = interacting
            pendingEnd = false
            flingStopped = false
            var events: [GateEvent] = []
            if interacting {
                interacting = false
                events = [.gestureEnded, .checkLoadMore]
            }
            followsEnd = true
            return RowsDecision(plan: .anchorThenEnd(animated: animates), abortDeceleration: abort,
                                decidedScroll: true, gate: events)
        }
        if interacting {
            // Под пальцем/флингом ленту не двигаем — и «крутить» не решали.
            return RowsDecision(plan: onlyPrepended ? .keep : .anchor, abortDeceleration: false,
                                decidedScroll: false, gate: [])
        }
        if scroll && lastIsNew {
            followsEnd = true
            return RowsDecision(plan: .anchorThenEnd(animated: animates), abortDeceleration: false,
                                decidedScroll: true, gate: [])
        }
        if scroll || followsEnd {
            followsEnd = true
            return RowsDecision(plan: .end, abortDeceleration: false, decidedScroll: scroll, gate: [])
        }
        if onlyPrepended {
            return RowsDecision(plan: .keep, abortDeceleration: false, decidedScroll: false, gate: [])
        }
        return RowsDecision(plan: .anchor, abortDeceleration: false, decidedScroll: false, gate: [])
    }

    /// Смена высоты вьюпорта (клавиатура) — по `AutoScrollRule`; `followsEnd` не меняется. Смена только ширины
    /// (поворот) — `followsEnd ? .end : .anchor`. Под пальцем — якорь: ленту из-под пальца к концу не дёргаем.
    /// Любой из этих планов двигает смещение — флаги анимаций снимаются.
    mutating func planResize(viewportShrank: Bool, viewportGrew: Bool) -> UpdatePlan {
        cancelScrollAnimations()
        if interacting { return .anchor }
        guard viewportShrank || viewportGrew else { return followsEnd ? .end : .anchor }
        let toEnd = AutoScrollRule.shouldScrollToBottom(wasAtBottom: followsEnd, lastRowSentHere: false,
                                                        countIncreased: false, viewportShrank: viewportShrank,
                                                        viewportGrew: viewportGrew)
        return toEnd ? .end : .anchor
    }

    /// Рост/перемер строки (картинка, правка, тумбстон) — под пальцем якорь, у конца конец, иначе якорь.
    mutating func planRowResize() -> UpdatePlan {
        cancelScrollAnimations()
        if interacting { return .anchor }
        return followsEnd ? .end : .anchor
    }

    // MARK: - Только история сверху

    /// Добавлены только старшие сообщения: прежние строки-сообщения — хвост новых ПО ЗНАЧЕНИЮ (не только по id: правка
    /// видимой строки в том же снимке, что и история, сдвигает строки под ней — это `.anchor`, а не `.keep`), первое
    /// сообщение сменилось, последнее то же. Приветствие не считается. Порядок — как в ленте (сверху вниз).
    static func onlyPrepended(old: [BubbleRow], new: [BubbleRow]) -> Bool {
        let o = old.filter { !isWelcome($0) }
        let n = new.filter { !isWelcome($0) }
        guard !o.isEmpty, n.count > o.count else { return false }
        return Array(n.suffix(o.count)) == o
    }

    private static func isWelcome(_ row: BubbleRow) -> Bool {
        row.isWelcome || row.id == ChatUiState.welcomeRowId
    }
}
