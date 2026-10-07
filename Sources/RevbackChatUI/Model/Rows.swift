import Foundation

/// Плоские снимки данных ядра. Маппер `ChatUiState.make(_:)` работает только с ними —
/// поэтому правила §4/§6 тестируются без xcframework.

/// Вид вложения в терминах экрана (§4 строка 78: `Photo` — картинка, всё остальное — ссылка; видео — обложка,
/// если она есть, иначе та же ссылка).
enum AttachmentDisplayKind: Equatable {
    case photo
    /// Правило веб-виджета: вид `video` ИЛИ MIME `video/*` (`MediaRules.isVideo`).
    case video
    case file
}

struct AttachmentRow: Equatable {
    /// Порядковый номер внутри сообщения — параметр `attachmentBytes(messageId:index:)`.
    var index: Int32
    var kind: AttachmentDisplayKind
    var fileName: String?
    /// Для своих вложений — локальный файл (§4 строка 78).
    var localUri: String?
    /// Вложение, которое не разобралось: подпись «Данный тип файла не поддерживается», открывать нечего.
    var unsupported: Bool = false
    /// MIME из `Attachment` ядра — из него выводится расширение временного файла для QuickLook, когда
    /// в имени его нет (ui-спека §12 п. 50, `PreviewFileName`). Android отдаёт тот же `mime` просмотрщику
    /// напрямую (`setDataAndType`). Дефолт `nil` нужен литералам строк в тестах маппера.
    var mime: String? = nil
    /// У вложения есть обложка на сервере (`Attachment.thumbnailBlobRef`) — `attachmentThumbnail` её отдаст.
    var hasThumbnail: Bool = false
    /// Длительность медиа в мс (`Attachment.durationMs`).
    var durationMs: Int64? = nil
    /// Размеры медиа в ориентации показа — место в ленте занимается по ним ДО загрузки. Всегда парой.
    var width: Int? = nil
    var height: Int? = nil
    /// Сервер знает сообщение, и вложение можно скачать: чужое — всегда, своё — со статуса `Sent`/`ReadByOperator` (id
    /// строки на сервере ядро получает вместе со статусом: квитанция `202`, эхо, история). Своё `Sending`/`Failed` с сервера
    /// не скачать — только из копии. Входит в равенство: подтверждение своего меняет строку, и ячейка перезапускает
    /// загрузку картинки и обложки (паритет Android `AttachmentUi.onServer`).
    var onServer: Bool = true
}

enum Ticks: Equatable {
    /// §4 строка 73: `Failed` и все чужие — галочек нет.
    case none
    /// §4 строка 73: `Sending` / `Sent` → «✓».
    case one
    /// §4 строка 73: `ReadByOperator` → «✓✓» цветом #bfe3ff, opacity 1.
    case double
}

/// Подпись отправителя нужна только для `Agent` / `Assistant` (§4 строка 71).
/// Отправитель вида, которого SDK не знает (`Sender.Other`), приезжает сюда как `.agent` — с именем, но без ярлыка роли.
enum SenderRow: Equatable {
    case mine
    case agent(name: String?)
    case assistant(name: String?)
    case system
    case unknown
}

struct MessageRow: Equatable {
    var id: String
    var isMine: Bool
    var text: String?
    var attachments: [AttachmentRow]
    var sentAt: Date
    var ticks: Ticks
    var failed: Bool
    var deleted: Bool
    var sender: SenderRow
    /// Сообщение пришло в форме, которой эта версия SDK не знает: подпись «Не удалось отобразить сообщение».
    var unreadable: Bool = false
    /// §12 п. 71: своя строка из очереди ЭТОГО устройства — статус ядра `Sending` (оптимистичная, `Outbox.send`) или
    /// `Failed` (локальный отказ/сбой отправки). Своё с сервера — эхо отправленного с другого устройства (веб) — ядро
    /// отдаёт `Sent`/`ReadByOperator`: не «здесь». По признаку лента докручивает своё всегда, а эхо — как входящее.
    var sentHere: Bool = false
}

struct BrandingRow: Equatable {
    var title: String?
    var primaryColor: String?
    var logoUrl: String?
    var welcomeText: String?
    var attachmentsEnabled: Bool
    var maxFileSize: Int64
}

enum ConversationStateRow: Equatable {
    case empty
    case loading
    case ready
    case failed(reason: String)
}

enum ConnectionRow: Equatable {
    case idle
    case connecting
    case connected
    case offline
    /// Терминальный отказ соединения.
    case failed(reason: String)
}

/// §6 строка 126: транзиентная полоса отказа вложения, снимается через 4 с или следующим действием.
enum TransientError: Equatable {
    case tooBig
    case attachFailed
    case limit
}

/// Чип выбранного файла над композером (§4 строка 80).
struct ChipRow: Equatable, Identifiable {
    var id: String
    var fileName: String
    /// Загрузка ещё идёт — кнопка отправки неактивна (§5 п. 6).
    var uploading: Bool
    /// Готовое вложение ядра; nil, пока грузится.
    var uploaded: UploadedAttachment?
    /// Плашка вложения: вид, миниатюра, размер файла, длительность. По умолчанию — карточка документа.
    var media: ChipMedia = .file(byteCount: 0)
}

/// §5 п. 3, §12 пп. 22, 56: когда верх ленты на экране — повод догрузить историю.
///
/// Верх виден — по ГЕОМЕТРИИ таблицы (`ListGeometry.topVisible`), а не по появлению верхней
/// строки: ленивый контейнер создаёт строки с запасом, и в короткой ленте верхняя строка «появляется» раньше касания
/// и больше не появляется.
///
/// Два повода:
/// - реальная прокрутка пользователя (единое правило с Android, где то же делает
///   `listState.isScrollInProgress`). Повод расходуется подгрузкой: после вставки страницы сверху верх
///   ленты остаётся на экране (`UIScrollView` держит смещение от начала), и без расхода запросы шли бы
///   каскадом, вычерпывая историю без единого движения пальцем;
/// - вся лента на экране (верх и конец видны сразу) — экран не заполнен: догружаем без касания, но не чаще
///   раза на страницу (ключ — id первого сообщения, он меняется, когда страница пришла) и на смену
///   `hasMore`. Так маленькая страница хоста (`historyPageSize`) дозаполняет экран, как у мессенджеров, и
///   останавливается, когда лента стала длиннее экрана или истории больше нет. Отказ подгрузки ключ не
///   меняет — повтор только по касанию, цикла нет.
///
/// Касание — это жест пальцем (один повод на жест: `gestureChanged`/`gestureEnded`) ЛИБО прокрутка без жеста,
/// распознанная по геометрии (`topObserved`): VoiceOver (три пальца, фокус) `DragGesture` не даёт,
/// и верх, ставший видимым при том же первом сообщении, — это пользователь дошёл до начала. Вставка страницы
/// сверху меняет первое сообщение и поводом не считается — каскада нет.
///
/// Запрос, который `ChatModel.loadMore()` отбросил (прежний ещё не завершён), повод не тратит:
/// `requestDropped()` откатывает состояние к тому, что было до `shouldLoad`, а завершение прежнего запроса
/// лента превращает в новую проверку.
struct LoadMoreGate {

    private var scrolled = false
    /// Пользователь хоть раз тянул ленту с момента показа. В отличие от `scrolled` НЕ расходуется
    /// подгрузкой: «тянул ли вообще» и «есть ли неизрасходованный повод для `loadMore`» — разные
    /// вопросы (иначе флик к началу в окне досадки съедал бы `scrolled`, и досадка возвращала бы
    /// пользователя вниз).
    private(set) var userTouched = false
    /// Первое сообщение, при котором уже попросили страницу. `nil` — не просили; `.some(nil)` — просили
    /// при ленте без сообщений.
    private var requestedAt: String?? = nil
    /// Текущий жест уже дал повод (один повод на жест: повод на каждый кадр жеста вычерпывал бы
    /// несколько страниц за один свайп — страница приходит, пока палец ещё тянет ленту у верха).
    private var gestureCounted = false
    /// Верх ленты при прошлой проверке: виден ли и при каком первом сообщении. `nil` — ещё не смотрели.
    private var lastTop: (visible: Bool, firstMessageId: String?)?
    /// Состояние до последнего разрешения `shouldLoad` — для `requestDropped()`.
    private var beforeLastLoad: (scrolled: Bool, requestedAt: String??)?

    /// Пользователь тянет ленту.
    mutating func userDidScroll() { scrolled = true; userTouched = true }

    /// Кадр жеста пальцем. `true` — жест только что дал повод (первый кадр жеста), лента проверяет края.
    mutating func gestureChanged() -> Bool {
        guard !gestureCounted else { return false }
        gestureCounted = true
        userDidScroll()
        return true
    }

    /// Жест кончился или отменён — следующий жест снова даст повод.
    mutating func gestureEnded() { gestureCounted = false }

    /// Края ленты сменились. `true` — верх стал виден (был не виден) при том же первом сообщении
    /// и ПРОКРУТКОЙ без жеста (`byScroll`: координатор передаёт `ScrollKind.withoutGesture` из `scrollViewDidScroll`
    /// перевёрнутой таблицы или конец такой анимации — VoiceOver, тап по статус-бару, фокус). Это касание — повод для
    /// `loadMore`; «у конца» (`followsEnd`) ведёт `ListScrollState`, не гейт. Верх, ставший видимым от своих смещений
    /// ленты (якорь, конец, смена вьюпорта — клавиатура, поворот), от прохода раскладки таблицы (перемер строки,
    /// оценка высоты сменилась настоящей) — `byScroll: false`, не касание. Первая проверка после показа только
    /// запоминает; смена первого сообщения (вставка страницы) — не повод.
    mutating func topObserved(visible: Bool, firstMessageId: String?, byScroll: Bool) -> Bool {
        defer { lastTop = (visible, firstMessageId) }
        guard let last = lastTop, visible, !last.visible, last.firstMessageId == firstMessageId, byScroll else {
            return false
        }
        userDidScroll()
        return true
    }

    /// Лента опустела (сообщений не осталось; приветствие не в счёт) — смена визитёра при открытом экране
    /// (логаут/identify). Следующая непустая лента — снова первый показ: неизрасходованный повод и касание прежней
    /// ленты на новую не переносятся (паритет Android, §12 п. 61). Текущий жест остаётся
    /// засчитанным (`gestureCounted`): один повод на жест.
    mutating func listEmptied() {
        let counted = gestureCounted
        self = LoadMoreGate()
        gestureCounted = counted
    }

    /// `hasMore` сменился — новый повод дозаполнить экран при том же первом сообщении.
    mutating func hasMoreChanged() { requestedAt = nil }

    /// Связь вернулась (`ChatModel.reconnects`, паритет Android `reconnects`, §12 п. 66): страница, не пришедшая из-за
    /// сети, повторяется раз на возврат связи при том же первом сообщении. Сам отказ повтора не даёт — цикла нет.
    mutating func connectionReturned() { requestedAt = nil }

    /// `loadMore()` отбросил разрешённый запрос (прежний ещё идёт) — повод и ключ страницы не потрачены.
    mutating func requestDropped() {
        guard let before = beforeLastLoad else { return }
        scrolled = before.scrolled
        requestedAt = before.requestedAt
        beforeLastLoad = nil
    }

    /// Звать ли `loadMore()`. `topVisible` — верх ленты на экране; `wholeListVisible` — на экране и верх,
    /// и конец (лента не длиннее экрана); `firstMessageId` — id первого сообщения сейчас.
    mutating func shouldLoad(topVisible: Bool, wholeListVisible: Bool, hasMore: Bool,
                             firstMessageId: String?) -> Bool {
        guard hasMore, topVisible else { return false }
        let before = (scrolled, requestedAt)
        if scrolled {
            scrolled = false
            requestedAt = .some(firstMessageId)
            beforeLastLoad = before
            return true
        }
        guard wholeListVisible, requestedAt != .some(firstMessageId) else { return false }
        requestedAt = .some(firstMessageId)
        beforeLastLoad = before
        return true
    }
}

/// §5 п. 3/п. 11: правило автопрокрутки ленты к концу — чистая функция без UIKit, покрыта юнит-тестами. Зовут
/// `NewRowScroll` (новая строка) и `ListScrollState.planResize` (смена вьюпорта); `wasAtBottom` — состояние
/// `ListScrollState.followsEnd` перевёрнутой таблицы, а не вывод из последнего кадра раскладки.
///
/// Поводы прокрутить к концу:
/// - новая строка (`countIncreased`) — но только если пользователь и так был у конца
///   (`wasAtBottom`), либо если добавленная строка своя и отправлена С ЭТОГО устройства (`lastRowSentHere`, п. 3:
///   своё отправленное сообщение — действие пользователя, уводить от него нельзя, даже если конец ленты уже успел уйти
///   из вида из-за подросшей клавиатуры). Своё, пришедшее с другого устройства (эхо с веба), — как входящее (§12 п. 71);
/// - клавиатура сжала вьюпорт (`viewportShrank`) — конец ленты уходит из вида сам по себе, но пользователя это не
///   должно сдвигать с места, где он был (п. 11): был у конца — остаётся у конца, иначе якорь;
/// - клавиатура скрылась, вьюпорт вырос (`viewportGrew`, §12 п. 77): `UIScrollView` держит прежнее смещение, и
///   без прокрутки под последней строкой остаётся пустота на высоту клавиатуры до первого касания. Был у конца — к концу.
enum AutoScrollRule {

    static func shouldScrollToBottom(
        wasAtBottom: Bool,
        lastRowSentHere: Bool,
        countIncreased: Bool,
        viewportShrank: Bool,
        viewportGrew: Bool = false
    ) -> Bool {
        if viewportShrank || viewportGrew { return wasAtBottom }
        if countIncreased { return wasAtBottom || lastRowSentHere }
        return false
    }
}

/// §12 п. 53: «хвост» ленты — всё, что нужно `MessageList` для решения «новая последняя строка →
/// прокрутить ли к концу». `onChange` следит именно за этим значением и получает его параметром: читать
/// `state` в теле `onChange` нельзя — замыкание захвачено прошлой отрисовкой и видит ленту на одно
/// изменение раньше.
///
/// §12 п. 54: `firstMessageId` — id первой строки-СООБЩЕНИЯ (приветствие не в счёт: оно стоит первым
/// всегда, и подгрузка истории вставляет строки ПОСЛЕ него). По нему рост числа строк делится на «вставка
/// сверху» (`loadMore`, первый id сменился) и «вставка в середину/перед последней» (догон, первый id тот же).
struct RowsTail: Equatable {
    let count: Int
    let firstMessageId: String?
    let lastId: String?
    /// Последняя строка — своя, отправленная с этого устройства (`BubbleRow.sentHere`, §12 п. 71). В равенство НЕ
    /// входит: статус своей последней строки меняется на месте (`Sending` → `Sent`), хвост при этом тот же — раскладки
    /// не отбрасываются как раскладки «другого хвоста». `onChange` ленты следит за `watched` (с признаком): поздний id
    /// из `send()` делает ту же последнюю строку «отправленной здесь» — это новое своё (§12 п. 75).
    private(set) var lastSentHere: Bool
    /// §12 п. 73: id всех строк хвоста — чтобы отличить новую последнюю строку от перестановки (старая своя
    /// `Failed` оказалась последней, когда подтверждённая строка уехала выше неё). В равенство НЕ входит.
    let ids: Set<String>

    init(_ rows: [BubbleRow]) {
        count = rows.count
        firstMessageId = rows.first(where: { !$0.isWelcome })?.id
        lastId = rows.last?.id
        lastSentHere = rows.last.map { $0.isMine && $0.sentHere } ?? false
        ids = Set(rows.map(\.id))
    }

    static func == (a: RowsTail, b: RowsTail) -> Bool {
        a.count == b.count && a.firstMessageId == b.firstMessageId && a.lastId == b.lastId
    }

    /// §12 п. 75: значение, за которым следит `onChange` ленты, — хвост плюс признак «последняя — своя отсюда». Равенство
    /// самого хвоста признак не включает (раскладки того же хвоста); смена признака у той же последней строки — повод
    /// для решения (`NewRowScroll`).
    struct Watched: Equatable {
        let tail: RowsTail
        static func == (a: Watched, b: Watched) -> Bool {
            a.tail == b.tail && a.tail.lastSentHere == b.tail.lastSentHere
        }
    }

    var watched: Watched { Watched(tail: self) }

    /// §12 п. 75: хвост, который лента запоминает как обработанный. Признак «своя отсюда» у той же последней строки не
    /// снимается: `Sending` (докручено) → снимок `Sent` раньше id (признак пропал) → id (вернулся) — это та же строка,
    /// вторую прокрутку по ней не выдаём. Другая последняя строка признак не наследует.
    func remembered(after seen: RowsTail?) -> RowsTail {
        guard !lastSentHere, let seen, seen.lastId == lastId, seen.lastSentHere else { return self }
        var kept = self
        kept.lastSentHere = true
        return kept
    }
}

/// §5 п. 3, §12 пп. 53–54: прокрутка ленты по изменению хвоста. `seen` — хвост, который лента уже
/// обработала (после показа — настоящий).
///
/// - Сменилась последняя строка — правило `AutoScrollRule` для новой строки: своя, отправленная с этого
///   устройства, и которой не было в прошлом хвосте (не перестановка, §12 п. 73), — всегда; чужая и своя с другого устройства (эхо, §12 п. 71) — только если пользователь был у
///   конца. Смена id без роста числа (отмена неотправленного последнего, удаление, подрезка окна с новой строкой в
///   конце) — тоже «новая последняя строка».
/// - Последняя та же, но стала своей, отправленной с этого устройства (поздний id из `send()`, §12 п. 75), — всегда.
/// - Последняя та же, но строк стало больше и первое сообщение то же — строка встала в середину или
///   перед последней (догон принёс входящее со временем раньше своего только что отправленного). Если
///   пользователь был у конца, конец ленты уехал вниз на высоту вставки — крутим обратно.
/// - Сменилось первое сообщение при той же последней строке — это подгрузка истории сверху (`loadMore`):
///   позицию не трогаем. Кроме ленты, которая целиком была на экране (`wasWholeListVisible`, §12 п. 56):
///   дозаполнение экрана без касания; `UIScrollView` держит смещение от начала, и без прокрутки новые строки
///   сверху вытолкнули бы вниз за экран последние сообщения, а верх так и остался бы на виду.
enum NewRowScroll {

    static func shouldScroll(seen: RowsTail?, tail: RowsTail, wasAtBottom: Bool,
                             wasWholeListVisible: Bool = false) -> Bool {
        if tail.lastId != seen?.lastId {
            // §12 п. 73: «своё — всегда» только для НОВОЙ последней строки. Последней стала строка, уже
            // бывшая в прошлом хвосте, — перестановка (свои неподтверждённые стоят в хвосте, подтверждённая уезжает
            // выше висящей `Failed`): только «был у конца».
            let lastIsNew = tail.lastId.map { !(seen?.ids.contains($0) ?? false) } ?? false
            return AutoScrollRule.shouldScrollToBottom(
                wasAtBottom: wasAtBottom,
                lastRowSentHere: tail.lastSentHere && lastIsNew,
                countIncreased: true,
                viewportShrank: false
            )
        }
        // §12 п. 75: та же последняя строка стала «своей отсюда» (id из `send()` пришёл позже снимка `Sent`, первое
        // решение по ней было как по эху) — новое своё: докручиваем при любом положении. `Sending` → `Sent` признак не
        // меняет (id уже в множестве, или признак запомнен `remembered`) — прокрутка не перезапускается.
        if let seen, tail.lastSentHere, !seen.lastSentHere { return true }
        guard let seen, tail.count > seen.count else { return false }
        guard tail.firstMessageId == seen.firstMessageId else { return wasWholeListVisible }
        // Вставленная строка — не последняя, «своя последняя» тут не повод: только «был у конца».
        return AutoScrollRule.shouldScrollToBottom(
            wasAtBottom: wasAtBottom,
            lastRowSentHere: false,
            countIncreased: true,
            viewportShrank: false
        )
    }
}

/// Непрозрачная ссылка на загруженное вложение ядра:
/// соответствие `id → Attachment` держит `LiveChatBackend`, фейк в тестах типов ядра не знает.
struct UploadedAttachment: Equatable, Hashable {
    var id: String
}
