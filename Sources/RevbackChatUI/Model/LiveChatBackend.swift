import Foundation
import RevbackChatCore

/// Узкий вид ядра для ПОДПИСКИ экрана: гейт `configure`, делегат и открытие/закрытие беседы.
/// Отдельный протокол — ровно по той же причине, что `ChatSource` на Android («подменяется
/// фейком в тестах»): живое ядро из тестов не поднять — `RevbackChat.install/uninstall`
/// в Kotlin `internal` и в Swift не экспортируются, а `configure` подняла бы рантайм с сетью.
/// Правило подписки (кто держит делегата и кто закрывает беседу) — самое хрупкое место экрана
/// (§12 п. 46), и проверяется оно на дублёре (`LiveChatBackendTests`).
/// Всё остальное (отправка, загрузки, байты вложений) идёт к ядру напрямую: там подменять нечего.
protocol CoreSubscription: AnyObject {
    var isConfigured: Bool { get }
    /// `nil` — снять делегата.
    func setDelegate(_ delegate: RevbackChatDelegate?)
    func openConversation()
    func closeConversation()
}

/// Настоящее ядро: фасад и беседа — ПОСТОЯННЫЕ объекты (`RevbackChat.kt`),
/// поэтому берутся по месту вызова, а не запоминаются ссылкой.
/// Метки аргументов перечислены явно: значения по умолчанию Kotlin в Swift не экспортируются
/// (README «Быстрый старт: iOS», core-spec §18 п. 130).
final class LiveCoreSubscription: CoreSubscription {
    var isConfigured: Bool { RevbackChat.shared.isConfigured }
    func setDelegate(_ delegate: RevbackChatDelegate?) { RevbackChat.shared.setDelegate(delegate: delegate) }
    func openConversation() { RevbackChat.shared.conversation.open() }
    func closeConversation() { RevbackChat.shared.conversation.close() }
}

/// Живая реализация `ChatBackend` поверх `RevbackChat.shared`.
///
/// `RevbackChatDelegate` — `@objc`-протокол, поэтому класс наследует `NSObject`
/// и реализует ВСЕ шесть методов: дефолты Kotlin в Swift не видны
/// (README «Быстрый старт: iOS», core-spec §18 п. 130).
/// Колбэки приходят НЕ с главного потока — каждый диспетчеризуется на main.
///
/// КОНТРАКТ ЕДИНСТВЕННОГО ДЕЛЕГАТА: у ядра делегат один
/// (`setDelegate` заменяет предыдущего), поэтому готовый экран занимает его на время показа
/// и обнуляет при закрытии. Хост, использующий готовый экран, СВОЙ `RevbackChatDelegate`
/// не ставит: для бейджа непрочитанного есть `RevbackChat.shared.setUnreadListener`,
/// для токена пушей — `setTokenSyncListener`. Геттера делегата у ядра нет, узнать о чужой
/// подписке нельзя — поэтому при `open()` просто пишем предупреждение в лог, а правило
/// закреплено в README («Известные ограничения») и в §12 спеки UI.
final class LiveChatBackend: NSObject, ChatBackend, RevbackChatDelegate {

    weak var observer: ChatBackendObserver?

    /// Кто из экранов сейчас держит делегата ядра. Ссылка слабая и статическая: экземпляр
    /// бэкенда живёт столько же, сколько экран, а вытеснить делегата может ВТОРОЙ экран
    /// (например, `RevbackChatViewController` поверх встроенного `RevbackChatView`).
    /// Без этого закрытие первого экрана снимало бы делегата, уже принадлежащего второму,
    /// и оставшийся экран замирал бы навсегда.
    private static weak var delegateOwner: LiveChatBackend?

    /// «ЭТА вьюха открывала беседу у ядра». Признак отдельный от владения делегатом, потому
    /// что одно без другого бывает: делегата может забрать ВТОРОЙ экран (§12 п. 46), и тогда
    /// беседу открывал один, а владеет подпиской другой. Состояния «экран подписки не получил
    /// вовсе» нет — гейта `configure` нет, показ подписывает экран всегда (§12 п. 47),
    /// а открытие беседы до `configure` запоминает фасад ядра (core-спека §18 п. 250).
    /// Закрывать беседу обязан тот, кто её открывал: ничья ОТКРЫТАЯ беседа гасит баннеры пушей
    /// по `isOpen` (`PushAction.Suppress`, `Runtime.kt`) — человек молча переставал бы получать
    /// уведомления о новых сообщениях.
    ///
    /// `deinit { close() }` здесь НАМЕРЕННО нет (и добавлять не нужно): ядро держит делегата
    /// СИЛЬНО (`RevbackChat.delegateRef`), поэтому владелец подписки до уничтожения не доживает —
    /// пока он владеет, его держит ядро, а отпускает подписку только `close()` по уходу с экрана.
    /// Экран-НЕвладелец уничтожиться может, но ему и закрывать нечего: беседа либо чужая живая
    /// (её гасить нельзя), либо уже закрыта. Плюс `deinit` приходит на произвольном потоке.
    private var didOpen = false

    private let core: CoreSubscription
    /// Повтор одной строки у ядра. Подменяет только тест порядка `retryAll` (§12 п. 79): ядро из тестов не поднять.
    private let retryOne: (String) async -> Void

    init(core: CoreSubscription = LiveCoreSubscription(), retryOne: ((String) async -> Void)? = nil) {
        self.core = core
        self.retryOne = retryOne ?? { id in _ = try? await RevbackChat.shared.conversation.retry(messageId: id) }
        super.init()
    }

    private var conversation: Conversation { RevbackChat.shared.conversation }

    /// Непрозрачный id → реальное вложение ядра.
    private var uploaded: [String: Attachment] = [:]
    private var uploads: [String: any Upload] = [:]
    /// Отмена, пришедшая раньше ручки загрузки: `upload(file:)` зовётся вне главного потока
    /// после побайтового перевода `Data → KotlinByteArray`, и тап по крестику чипа
    /// вполне успевает случиться до того, как ручка доедет в `uploads`.
    private var cancelledUploads: Set<String> = []

    var isConfigured: Bool { core.isConfigured }

    var persistHistory: Bool? { RevbackChat.shared.config?.persistHistory }

    // MARK: подписка

    func open() {
        if !isConfigured {
            NSLog("[RevbackChatUI] open() до RevbackChat.configure — делегат буферизуется ядром, "
                + "беседа откроется сразу после configure")
        }
        // Делегат у ядра один, и экран забирает его себе на время показа.
        // Узнать, стоял ли до нас чужой, нельзя (геттера нет) — поэтому предупреждаем всегда.
        NSLog("[RevbackChatUI] готовый экран занимает RevbackChat.setDelegate на время показа; "
            + "хосту свой RevbackChatDelegate не ставить — для бейджа setUnreadListener, "
            + "для токена setTokenSyncListener (README «Известные ограничения»)")
        core.setDelegate(self)
        Self.delegateOwner = self
        core.openConversation()
        didOpen = true
        pushSnapshots()
    }

    /// Гейта `isConfigured` здесь нет ПАРНО с `open()`: экран, подписавшийся до `configure`, обязан
    /// уметь отписаться — ядро держит делегата СИЛЬНО (`RevbackChat.delegateRef`), и без этого
    /// мёртвый экран остался бы у ядра до конца жизни процесса.
    func close() {
        let owner = Self.delegateOwner
        // Беседу закрывает тот, кто её ОТКРЫВАЛ, — но только если ядро не держит её ради
        // ДРУГОГО экрана. Если поверх открылся второй экран, он уже поставил своего делегата
        // и заново открыл беседу: `conversation` у ядра одна, и закрытие первого экрана гасило
        // бы живую беседу второго (сокет порван, `isOpen == false`, а его `close()` уже прошёл).
        //
        // Ветка «владельца делегата нет» по нынешнему коду срабатывает ВХОЛОСТУЮ: `didOpen`
        // ставится только там же, где экран становится владельцем, а владелец в `close()`
        // закрывает беседу ДО того, как обнулит владение, — состояния «беседа открыта,
        // владельца нет» не возникает, и здесь мы закрываем уже закрытую беседу (A открыл →
        // B открыл → B ушёл и закрыл → уходит A). Оставлена СТРАХОВКОЙ на случай, если
        // появится ещё один путь открытия беседы: цена — идемпотентный no-op у ядра
        // (CAS по `openFlag`, `ConversationEngine.kt`, плюс возврат окна ленты к 200
        // с публикацией), а пропущенная ничья ОТКРЫТАЯ беседа — это снова пропавшие пуши
        // (§12 п. 46). Фильтровать вызов по флагу открытости незачем: протокол подписки его
        // не экспортирует, расширять протокол ради экономии одного no-op не стоит — и после
        // сказанного выше фильтровать тут попросту нечего.
        if didOpen, owner == nil || owner === self {
            core.closeConversation()
        }
        didOpen = false
        // Делегата снимает только ВЛАДЕЛЕЦ подписки — по той же причине: чужого снимать нельзя.
        guard owner === self else { return }
        Self.delegateOwner = nil
        core.setDelegate(nil)
    }

    /// §6 строка 123: «Обновить». У ПОДПИСАННОГО экрана делегат не трогается — экран остаётся
    /// подписанным, иначе снимок после `open()` пришёл бы в никуда.
    ///
    /// Единственный случай «экрана без подписки» — тот, у кого делегата забрал
    /// ВТОРОЙ экран (§12 п. 46): своего слушателя у него больше нет, и слепые `close(); open()`
    /// ему не помогли бы — пришёл бы один снимок, а дальше лента стояла бы мёртвой. Поэтому
    /// такой случай сводится к обычному «экран появился». Показ до `configure` сюда
    /// не относится: `open()` подписывает экран сразу (§12 п. 47).
    ///
    /// Следствие, зафиксированное правилом «кто последний тапнул, тот и владелец» (§5 п. 1,
    /// §12 п. 46): если подписку держит ЖИВОЙ второй экран (оба видимы сразу — iPad, режим
    /// разделённого окна), «Обновить» заберёт её себе, и второй экран перестанет обновляться.
    /// Делегат у ядра один, выбора нет; беседу мы при этом не закрываем — она остаётся живой
    /// для обоих, а уход второго экрана её корректно закроет по его `didOpen`.
    func refresh() {
        guard Self.delegateOwner === self else {
            open()
            return
        }
        core.closeConversation()
        core.openConversation()
        didOpen = true
        pushSnapshots()
    }

    /// Снимок текущих значений: делегат присылает только ИЗМЕНЕНИЯ, а экран
    /// открывается на уже прогретом ядре (README: `.value` без подписки синхронизацию не поднимает,
    /// поэтому снимок берётся ПОСЛЕ open()).
    /// `as?` для потоков не нужен (компилятор предупредил бы «conditional cast always
    /// succeeds»): apinotes SKIE типизируют потоки (`RCCSkieKotlinStateFlow<NSArray<RCCMessage *> *>`
    /// и т. д.), поэтому `value` приезжает в Swift уже как `[Message]` / `ConversationState` /
    /// `ConnectionState` / `Branding?`. Единственное НАСТОЯЩЕЕ приведение — `hasMore`:
    /// `KotlinBoolean` остаётся `Any`, и `as? Bool` там работает по делу.
    private func pushSnapshots() {
        let hasMore = (conversation.hasMore.value as? Bool) ?? false
        let rows = CoreConvert.rows(conversation.messages.value)
        onMain { [weak self] in self?.observer?.backendDidUpdateMessages(rows, hasMore: hasMore) }

        let state = CoreConvert.row(conversation.state.value)
        onMain { [weak self] in self?.observer?.backendDidUpdateState(state) }

        let connection = CoreConvert.row(RevbackChat.shared.connection.value)
        onMain { [weak self] in self?.observer?.backendDidUpdateConnection(connection) }

        let branding = CoreConvert.row(RevbackChat.shared.branding.value)
        onMain { [weak self] in self?.observer?.backendDidUpdateBranding(branding) }
    }

    // MARK: RevbackChatDelegate (колбэки НЕ с главного потока)

    func onMessagesChanged(messages: [Message]) {
        let rows = CoreConvert.rows(messages)
        let hasMore = (conversation.hasMore.value as? Bool) ?? false
        onMain { [weak self] in self?.observer?.backendDidUpdateMessages(rows, hasMore: hasMore) }
    }

    func onConversationStateChanged(state: ConversationState) {
        let row = CoreConvert.row(state)
        onMain { [weak self] in self?.observer?.backendDidUpdateState(row) }
    }

    func onConnectionChanged(state: ConnectionState) {
        let row = CoreConvert.row(state)
        onMain { [weak self] in self?.observer?.backendDidUpdateConnection(row) }
    }

    func onBrandingChanged(branding: Branding?) {
        let row = CoreConvert.row(branding)
        onMain { [weak self] in self?.observer?.backendDidUpdateBranding(row) }
    }

    func onEvent(event: ChatEvent) {
        if event is ChatEvent.Reset {
            onMain { [weak self] in self?.observer?.backendDidReset() }
            return
        }
        // §5 п. 4: прочтение отмечает СОБЫТИЕ прихода чужого сообщения,
        // а не рост ленты — иначе `loadMore` отмечал бы историю прочитанной.
        if let added = event as? ChatEvent.Added, !added.message.isMine {
            onMain { [weak self] in self?.observer?.backendDidAddIncomingMessage() }
        }
    }

    /// Счётчик непрочитанного экрану не нужен (§11), но метод протокола обязателен.
    func onUnreadChanged(unread: UnreadCount) {}

    // MARK: действия

    /// `self` во всех действиях захватывается СИЛЬНО (паритет с Android, где они уходят
    /// в `work`-scope, переживающий модель): `[weak self]` терял бы действие, если экран
    /// уничтожен сразу после тапа — задача просыпалась бы уже с `nil` и до ядра не дошли бы
    /// ни отправка, ни `markRead`. Цикла удержания нет: задача короткая и `self` отпускает.
    func send(text: String, attachments: [UploadedAttachment], sent: @escaping (String) -> Void) {
        let core = attachments.compactMap { uploaded[$0.id] }
        // Соответствие id → вложение ядра пропало (отмена, `reset`, гонка) — отправлять
        // сообщение БЕЗ вложения нельзя: пользователь его прикрепил и увидел бы текст без файла.
        guard core.count == attachments.count else {
            NSLog("[RevbackChatUI] send: вложений %d из %d — соответствие потеряно, сообщение не отправлено",
                  core.count, attachments.count)
            // §12 п. 24: молча ронять отправку нельзя — поле уже очищено, и без полосы
            // пользователь видел бы, что сообщение просто исчезло (§6 строка 126).
            onMain { [weak self] in self?.observer?.backendDidDropSendWithoutAttachments() }
            return
        }
        let ids = attachments.map(\.id)
        // §12 п. 73: `Outbox.send` возвращает строку сразу после записи оптимистичной строки (до сети) — id тот же, что
        // в ленте и у подтверждения (`confirmOwn` по id). Возврат доезжает до главной очереди раньше снимка со `Sent`:
        // тот ставится в неё только после ответа сервера (одно RTT), а очередь идёт по порядку.
        Task { [self] in
            let message = try? await conversation.send(text: text, attachments: core)
            await MainActor.run {
                ids.forEach { uploaded.removeValue(forKey: $0) }
                if let message { sent(message.id) }
            }
        }
    }

    func retry(messageId: String) {
        Task { [self] in await retryOne(messageId) }
    }

    /// §12 п. 79: ОДНА задача, id обходятся последовательно через `await` — следующий повтор
    /// ставится в очередь ядра только после того, как предыдущий туда встал. Задача на каждый id (как у `retry`) порядок
    /// в очереди не гарантирует, и оператор получил бы сообщения не в порядке ленты.
    func retryAll(messageIds: [String]) {
        guard !messageIds.isEmpty else { return }
        Task { [self] in
            for id in messageIds { await retryOne(id) }
        }
    }

    func cancel(messageId: String) {
        Task { [self] in try? await conversation.cancel(messageId: messageId) }
    }

    func loadMore(completion: @escaping () -> Void) {
        Task { [self] in
            _ = try? await conversation.loadMore()
            await MainActor.run { completion() }
        }
    }

    func markRead() {
        // nil = прочитано всё до сейчас (§5 п. 4); троттл 2 с у ядра
        Task { [self] in try? await conversation.markRead(upTo: nil) }
    }

    func upload(uploadId: String, fileName: String, mime: String, data: Data, localUri: String?,
                preview: UploadPreview?,
                completion: @escaping (Result<UploadedAttachment, UploadFailure>) -> Void) {
        Task.detached { [weak self] in
            guard let self else { return }
            // §5 п. 7: `localUri` доезжает до `Attachment.localUri` своего сообщения
            // (`Uploader.kt:47`) — свой пузырь рисует картинку из файла, не качая её обратно.
            // Превью — кадр второй загрузкой, длительность и размеры в `send` (ядро проверяет границы само).
            let source = FileSource(fileName: fileName, mime: mime, bytes: CoreConvert.byteArray(data))
                .withLocalUri(localUri: localUri)
                .withPreview(preview: preview.map(CoreConvert.mediaPreview(_:)))
            let handle = self.conversation.upload(file: source)
            let cancelledEarly = await MainActor.run { () -> Bool in
                if self.cancelledUploads.remove(uploadId) != nil { return true }
                self.uploads[uploadId] = handle
                return false
            }
            if cancelledEarly { handle.cancel() }
            let result = try? await handle.await()
            await MainActor.run {
                self.uploads.removeValue(forKey: uploadId)
                self.cancelledUploads.remove(uploadId)
                if let done = result as? UploadResult.Done, !cancelledEarly {
                    self.uploaded[uploadId] = done.attachment
                    completion(.success(UploadedAttachment(id: uploadId)))
                } else if cancelledEarly || result is UploadResult.Cancelled {
                    // Отмену сделал пользователь — чип снимается молча, без полосы отказа
                    // (§6 строка 126, единое правило с Android)
                    completion(.failure(.cancelled))
                } else {
                    completion(.failure(.failed))
                }
            }
        }
    }

    func cancelUpload(uploadId: String) {
        if let handle = uploads.removeValue(forKey: uploadId) {
            handle.cancel()
        } else {
            // Ручки ещё нет — пометим, и она отменится сразу, как только появится.
            cancelledUploads.insert(uploadId)
        }
        uploaded.removeValue(forKey: uploadId)
    }

    func attachmentBytes(messageId: String, index: Int32, completion: @escaping (Data?) -> Void) {
        Task.detached { [weak self] in
            guard let self else { return }
            let arr = try? await self.conversation.attachmentBytes(messageId: messageId, index: index)
            let data = arr.map(CoreConvert.data(_:))
            await MainActor.run { completion(data) }
        }
    }

    func attachmentThumbnail(messageId: String, index: Int32, completion: @escaping (Data?) -> Void) {
        Task.detached { [weak self] in
            guard let self else { return }
            let arr = try? await self.conversation.attachmentThumbnail(messageId: messageId, index: index)
            let data = arr.map(CoreConvert.data(_:))
            await MainActor.run { completion(data) }
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
