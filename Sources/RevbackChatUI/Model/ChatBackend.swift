import Foundation

/// Отказ загрузки вложения. Отдельный тип нужен потому, что `Result` требует
/// `Failure: Error`, а `Void` этому не удовлетворяет.
enum UploadFailure: Error {
    /// Загрузка сорвалась — §6 строка 126: полоса «Не удалось прикрепить файл», чип снимается.
    case failed
    /// Загрузку отменили (крестик чипа или `UploadResult.Cancelled` у ядра): чип снимается
    /// МОЛЧА, полосы отказа быть не должно — пользователь сам это и сделал
    /// (единое правило с Android: `is UploadResult.Cancelled -> dropChip(chip.id)`).
    case cancelled
}

/// Всё, что `ChatModel` просит у ядра. Типов Kotlin здесь нет — поэтому в тестах
/// подставляется фейк, а живая реализация (`LiveChatBackend`) линкует ядро.
protocol ChatBackend: AnyObject {

    /// §3: `false` до `configure`. Экран при этом работает, но пишет строку в лог: подписку
    /// ядро буферизует, а открытие беседы запоминает фасад и применяет сразу после `configure`
    /// (core-спека §18 п. 250).
    var isConfigured: Bool { get }

    /// Хранит ли модуль историю на диске (`RevbackChatConfig.persistHistory`); `nil` — модуль ещё не настроен.
    /// Читается в момент каждого выбора файла: от неё зависит, пишет ли экран свою копию вложения на диск.
    var persistHistory: Bool? { get }

    /// Наблюдатель получает колбэки УЖЕ на главном потоке.
    var observer: ChatBackendObserver? { get set }

    /// §5 п. 1. `open()` занимает делегата ядра на время показа, `close()` его отпускает
    /// и закрывает беседу, если открывал её этот же экран (§12 п. 46).
    func open()
    func close()

    /// §6 строка 123: «Обновить» — `conversation.close(); open()` и свежий снимок,
    /// но БЕЗ смены делегата: подписанный экран с себя подписку не снимает и заново не ставит.
    /// Экран, у которого делегата забрал второй экран, «Обновить» ПОДПИСЫВАЕТ заново:
    /// иначе беседа у ядра открывалась бы без единого слушателя (§12 п. 46).
    func refresh()

    /// §5 п. 5. `attachments` — только то, что вернул `upload` (§5 п. 6).
    /// `sent` — id строки ленты, которую родила отправка (возврат `conversation.send()`: тот же id, что у оптимистичной
    /// строки и у её подтверждения). Зовётся на главном потоке; при отказе до ядра не зовётся (§12 п. 73).
    func send(text: String, attachments: [UploadedAttachment], sent: @escaping (String) -> Void)

    /// §5 п. 9.
    func retry(messageId: String)
    /// §12 п. 79: повтор нескольких строк СТРОГО по порядку `messageIds` — следующий `retry` ядра
    /// начинается только после завершения предыдущего. Порядок постановки в очередь ядра (`Outbox.retry`, `seq` под
    /// `rowMutex`) — порядок, в котором оператор получит сообщения; отдельные параллельные задачи его не гарантируют.
    func retryAll(messageIds: [String])
    func cancel(messageId: String)

    /// §5 п. 3. `completion` зовётся на главном потоке ПО ЗАВЕРШЕНИЮ подгрузки — в том числе
    /// при отказе. Именно он снимает «идёт подгрузка»: по обновлению ленты этого делать нельзя
    /// (отказ не обновляет её вовсе и флаг залипал бы навсегда).
    func loadMore(completion: @escaping () -> Void)

    /// §5 п. 4. Прочитано всё до сейчас.
    func markRead()

    /// §5 п. 6. `completion` зовётся на главном потоке.
    /// `uploadId` задаёт ЭКРАН — он же id чипа: имя файла ключом быть не может
    /// (два одинаковых имени из пикера — обычное дело), а ждать возврата из `upload`
    /// нельзя, чип появляется раньше.
    /// `localUri` — файл-копия выбранного вложения (§5 п. 7: свой пузырь рисует картинку из него).
    /// `preview` — превью, снятое экраном при выборе файла: уходит в `FileSource.withPreview`; `nil` — без превью.
    func upload(uploadId: String, fileName: String, mime: String, data: Data, localUri: String?,
                preview: UploadPreview?,
                completion: @escaping (Result<UploadedAttachment, UploadFailure>) -> Void)

    func cancelUpload(uploadId: String)

    /// §5 п. 7. `completion` зовётся на главном потоке; nil — байты недоступны.
    /// Ядро отдаёт и свои вложения (по id строки на сервере) — для своего без локального файла.
    func attachmentBytes(messageId: String, index: Int32, completion: @escaping (Data?) -> Void)

    /// Обложка вложения (кадр видео), `Conversation.attachmentThumbnail`. `completion` — на главном потоке;
    /// nil — обложки нет (404, сеть, нет `thumbnailBlobRef`), экран рисует ссылку на файл.
    func attachmentThumbnail(messageId: String, index: Int32, completion: @escaping (Data?) -> Void)
}

/// Снимки ядра, уже переведённые в `Rows` и уже на главном потоке.
protocol ChatBackendObserver: AnyObject {
    func backendDidUpdateMessages(_ rows: [MessageRow], hasMore: Bool)
    func backendDidUpdateState(_ state: ConversationStateRow)
    func backendDidUpdateConnection(_ connection: ConnectionRow)
    func backendDidUpdateBranding(_ branding: BrandingRow?)
    /// §5 п. 2: `ChatEvent.Reset` — очистить локальное (черновик, чипы, ошибку).
    func backendDidReset()
    /// §5 п. 4: пришло НОВОЕ чужое сообщение — `ChatEvent.Added` с `isMine == false`.
    /// Триггер прочтения — именно событие, а не рост `messages.count`: подгрузка истории
    /// (`loadMore`) ленту тоже растит, но прочтением не является (единое
    /// правило с Android).
    func backendDidAddIncomingMessage()

    /// §12 п. 24: соответствие «чип → вложение ядра» потеряно, и отправка отменена целиком.
    /// Экран очистил поле и чипы ещё до вызова (§5 п. 5, оптимистично), поэтому об отмене
    /// нужно сказать полосой — иначе сообщение пропадает молча.
    func backendDidDropSendWithoutAttachments()
}
