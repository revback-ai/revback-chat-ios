import Combine
import Foundation
import UIKit

/// Состояние экрана: получает снимки от `ChatBackend`, держит локальное (черновик, чипы,
/// транзиентные ошибки, таймеры) и на каждом изменении пересобирает `ChatUiState`
/// чистой функцией `ChatUiState.make(_:)`.
///
/// КОНТРАКТ: все методы зовутся с главного потока. `LiveChatBackend` диспетчеризует туда
/// колбэки ядра сам (README «Известные ограничения»: делегат приходит НЕ с main).
/// `@MainActor` намеренно не ставим — язык Swift 5 mode без strict concurrency
/// (спека §2, строка 24), а изоляция протоколов и замыканий-колбэков этого не переживает.
final class ChatModel: ObservableObject, ChatBackendObserver {

    // MARK: константы поведения (§5, §6)

    /// §6 строка 124: `Connecting` дольше 3 с — «Нет соединения».
    static let connectingGrace: TimeInterval = 3
    /// §6 строка 124: «Снова в сети» держится 3 с.
    static let backOnlineDuration: TimeInterval = 3
    /// §6 строка 126: полоса отказа вложения снимается через 4 с.
    static let transientErrorDuration: TimeInterval = 4
    /// §5 п. 4: дебаунс прочтения 500 мс.
    static let markReadDebounce: TimeInterval = 0.5

    // MARK: публичное

    @Published private(set) var ui: ChatUiState
    /// Счётчик завершённых подгрузок истории (успешных и нет). Лента по его смене заново проверяет повод для
    /// `loadMore` (§12 п. 56): отброшенный из-за незавершённого запроса повод иначе не вернулся бы.
    @Published private(set) var loadMoreFinished = 0
    /// Счётчик возвратов связи (паритет Android `ChatViewModel.reconnects`, §12 пп. 58, 63, 66): `Connected` после иного
    /// состояния, когда прежде уже был `Connected` или обрыв (`Offline`/`Failed`). Первое подключение после одних
    /// `Idle`/`Connecting` и повтор того же `Connected` (снимок при открытии) не считаются. Лента по его смене разрешает
    /// ещё одну страницу истории при том же первом сообщении — без цикла.
    @Published private(set) var reconnects = 0
    /// §6 строка 126 «или следующее действие»: набор текста — тоже действие, полоса отказа
    /// вложения снимается им же (единое правило с Android: `copy(draft = value, attachNotice = null)`).
    @Published var draft: String = "" {
        didSet {
            guard draft != oldValue else { return }
            clearTransient()
            rebuild()
        }
    }

    /// §5 п. 8: каталог временных файлов просмотрщика — свой у каждого экрана. Экранов
    /// бывает два сразу, и уборка при закрытии первого не должна трогать файлы второго.
    let previewSession = UUID().uuidString

    // MARK: зависимости

    private let backend: ChatBackend
    private let strings: Strings
    private let timeZone: TimeZone
    private let images = ImageCache()
    /// Сырые байты вложений (§5 п. 8). Держим отдельно от `images`: перевод
    /// `KotlinByteArray → Data` побайтовый и дорогой (§12 п. 3 спеки),
    /// повторять его на каждый тап по ссылке нельзя. Это не второй LRU
    /// поверх кэша картинок, а ОДИН последний файл (§12 п. 45, `AttachmentMemoryBudget`).
    private let bytesCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = AttachmentMemoryBudget.viewerFiles
        cache.totalCostLimit = AttachmentMemoryBudget.viewerBytes
        return cache
    }()

    // MARK: снимки ядра

    private var messages: [MessageRow] = []
    private var state: ConversationStateRow = .loading
    private var connection: ConnectionRow = .idle
    private var branding: BrandingRow?
    private var hasMore = false

    // MARK: локальное

    private var chips: [ChipRow] = []
    /// Поколение экрана: растёт на `Reset`. Подготовка выбранного файла идёт вне главного потока и может закончиться
    /// уже после смены хозяина переписки — её результат сверяется с поколением, взятым в момент выбора
    /// (`beginPick`), и при расхождении отбрасывается вместе с записанной копией: плашка и файл прежнего
    /// пользователя не достаются новому.
    private var pickGeneration = 0
    /// §12 п. 73: id строк, которые родила отправка (возврат `send()`) или повтор (`retry`) С ЭТОГО экрана. Живёт с
    /// экраном. По нему своё — «отправлено здесь», даже если экран впервые увидел строку уже `Sent`: статус становится
    /// `Sent` по 202 за одно RTT, и при занятом главном потоке снимок `Sending` мог не дойти до отрисовки. Эхо с
    /// другого устройства сюда не попадает; свои из очереди прошлой сессии покрывает статус (`Sending`/`Failed`).
    private var sentHereIds: Set<String> = []
    private var transientError: TransientError?
    private var connectingOverdue = false
    private var showBackOnline = false
    private var wasDisconnected = false
    /// Связь уже бывала (`Connected`) или рвалась (`Offline`/`Failed`) — следующий `Connected` будет возвратом.
    private var hadLink = false
    private var screenVisible = false
    private var loadingMore = false
    /// Экран закрыт не уходом с него, а сворачиванием приложения (§5 п. 1): по возврату
    /// его нужно открыть обратно, а вот «холодный» `willEnterForeground` без своего
    /// `didEnterBackground` (например, экран показали уже в фоне) открывать ничего не должен.
    private var suspended = false

    private var connectingTimer: DispatchWorkItem?
    private var backOnlineTimer: DispatchWorkItem?
    private var transientTimer: DispatchWorkItem?
    private var markReadTimer: DispatchWorkItem?

    private var inflightImages: [String: Task<UIImage?, Never>] = [:]
    /// Отказы загрузки картинок ленты по `id#index`. Ведётся с главного потока.
    private var failedImages: Set<String> = []
    /// Обложки видео с сервера — свои запросы в полёте и своя память отказов, ключ `thumb#id#index`.
    private var inflightThumbnails: [String: Task<UIImage?, Never>] = [:]
    private var failedThumbnails: Set<String> = []
    /// Поколение памяти отказов: растёт при каждом сбросе (`forgetImageFailures`, возврат связи). Отказ обложки
    /// запоминается, только если поколение не сменилось за время запроса (паритет Android `coverEpoch`).
    private var failureGeneration = 0
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Отложенная работа модели (выдержка `Connecting`, «Снова в сети», полоса отказа, прочтение): через столько
    /// секунд выполнить на главном потоке. Подменяют только тесты (§12 п. 79) — ручными часами вместо реальных.
    typealias Scheduler = (TimeInterval, DispatchWorkItem) -> Void
    static let mainScheduler: Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private let schedule: Scheduler

    init(backend: ChatBackend,
         language: String = L10n.languageCode(preferred: Locale.preferredLanguages),
         timeZone: TimeZone = .current,
         scheduler: @escaping Scheduler = ChatModel.mainScheduler) {
        self.backend = backend
        self.schedule = scheduler
        self.strings = L10n.strings(language: language)
        self.timeZone = timeZone
        self.ui = ChatUiState.make(ChatUiInput(
            messages: [], state: .loading, connection: .idle, branding: nil, hasMore: false,
            draft: "", chips: [], transientError: nil, connectingOverdue: false,
            showBackOnline: false, timeZone: timeZone, strings: strings
        ))
        backend.observer = self
        observeAppLifecycle()
    }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        // §5 п. 8: временные файлы просмотрщика живут ровно столько, сколько экран.
        // Чистится только СВОЙ каталог: общий корень принадлежит и другим экранам.
        FilePreviewItem.cleanup(session: previewSession)
    }

    // MARK: фон и возврат приложения (§5 п. 1)

    /// Сворачивание приложения не даёт ни `onDisappear`, ни `viewDidDisappear` — экран
    /// остаётся «показанным», а у ядра `conversation.isOpen == true` (`Runtime.kt:332–335`):
    /// пуши глушатся, счётчик непрочитанного стоит, `markRead` уходит из фона. Поэтому
    /// беседу закрывает и открывает сама модель по уведомлениям `UIApplication`.
    ///
    /// `queue: nil` — блок выполняется синхронно на потоке отправителя, а UIKit шлёт оба
    /// уведомления с главного (и тест шлёт их оттуда же): лишнего перескока нет.
    private func observeAppLifecycle(center: NotificationCenter = .default) {
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self, self.screenVisible else { return }
            self.closeScreen()
            self.suspended = true
        }
        let foreground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self, self.suspended else { return }
            self.suspended = false
            self.screenAppeared()
        }
        lifecycleObservers = [background, foreground]
    }

    // MARK: жизненный цикл (§5 п. 1)

    func screenAppeared() {
        if !backend.isConfigured {
            // Экран встроили ДО `RevbackChat.configure`: подписку ядро буферизует (`RevbackChat.setDelegate`),
            // а открытие беседы запоминает фасад (§18 п. 250 core-спеки) — экран оживёт сам.
            NSLog("[RevbackChatUI] экран показан до RevbackChat.configure — подписка и беседа встанут сразу после него")
        }
        screenVisible = true
        backend.open()
        markReadSoon()
    }

    /// Уход С ЭКРАНА. Отменяет и «вернуть беседу по возврату приложения»: экран могли убрать,
    /// пока приложение было свёрнуто (`viewDidDisappear` в фоне приходит), и тогда открывать
    /// беседу на возврате было бы не за чем — а закрыть её потом стало бы некому.
    func screenDisappeared() {
        suspended = false
        closeScreen()
    }

    /// Гейта `isConfigured` здесь нет ПАРНО с `screenAppeared()`: экран, подписавшийся до
    /// `configure`, обязан уметь отписаться — ядро держит делегата СИЛЬНО
    /// (`RevbackChat.delegateRef`), и мёртвый экран жил бы у него до конца процесса.
    private func closeScreen() {
        screenVisible = false
        cancelTimers()
        backend.close()
        rebuild()
    }

    /// Гасятся ВСЕ отложенные работы: `markRead`, «Нет соединения», «Снова в сети» и полоса
    /// отказа вложения. Иначе таймер сработал бы на закрытом экране, а `showBackOnline`/`transientError`
    /// остались бы взведёнными и всплыли полосой при следующем показе.
    private func cancelTimers() {
        markReadTimer?.cancel(); markReadTimer = nil
        connectingTimer?.cancel(); connectingTimer = nil
        backOnlineTimer?.cancel(); backOnlineTimer = nil
        showBackOnline = false
        clearTransient()
    }

    // MARK: ChatBackendObserver

    func backendDidUpdateMessages(_ rows: [MessageRow], hasMore: Bool) {
        messages = rows
        self.hasMore = hasMore
        // §5 п. 4: прочтение отмечается по СОБЫТИЮ `Added` (`backendDidAddIncomingMessage`),
        // а не по росту ленты: `loadMore` растит её так же, но прочтением не является.
        rebuild()
    }

    /// §5 п. 4: `ChatEvent.Added` с чужим сообщением — отметить прочтение с дебаунсом 500 мс.
    /// На скрытом экране `markReadSoon()` сам ничего не делает (единое правило с Android).
    func backendDidAddIncomingMessage() {
        markReadSoon()
    }

    /// §12 п. 24: отправку отменили — вложение потеряло соответствие в ядре. Показываем
    /// ту же полосу, что и у сорвавшейся загрузки («Не удалось прикрепить файл», §6 строка 126):
    /// причина для пользователя одна и та же — файл до сообщения не доехал.
    /// Текст в поле НЕ восстанавливаем: §5 п. 5 чистит поле оптимистично, и возврат уже
    /// стёртого черновика поверх того, что пользователь успел набрать заново, — хуже отказа.
    func backendDidDropSendWithoutAttachments() {
        showTransient(.attachFailed)
    }

    func backendDidUpdateState(_ state: ConversationStateRow) {
        self.state = state
        rebuild()
    }

    func backendDidUpdateConnection(_ connection: ConnectionRow) {
        let before = self.connection
        self.connection = connection
        switch connection {
        case .connected:
            if hadLink && before != .connected { reconnects &+= 1 }
            hadLink = true
        case .offline, .failed:
            hadLink = true
        case .idle, .connecting:
            break
        }
        connectingTimer?.cancel(); connectingTimer = nil

        switch connection {
        case .connecting:
            // «Снова в сети» от прошлого возврата гасим: связь снова щупается
            showBackOnline = false
            backOnlineTimer?.cancel(); backOnlineTimer = nil
            // §12 п. 78 (паритет Android): возврат сети — `Offline → Connecting → Connected`. После
            // `Offline` «Нет соединения» уже на экране — держим её сразу, без выдержки, иначе на время переподключения
            // полоса пропадала бы до «Снова в сети» (мигание, а при своём `failed` мелькала бы «Не доставлено»). Выдержка 3 с —
            // только для обрыва, которого пользователь не видел (`Connected`/`Idle`/`Failed` → `Connecting`).
            // `wasDisconnected` уже взвёл `Offline`.
            if before == .offline {
                connectingOverdue = true
                break
            }
            connectingOverdue = false
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.connection == .connecting else { return }
                self.connectingOverdue = true
                // Полоса «Нет соединения» реально показана — значит «Снова в сети» потом уместна
                self.wasDisconnected = true
                self.rebuild()
            }
            connectingTimer = work
            schedule(Self.connectingGrace, work)

        case .offline, .failed:
            connectingOverdue = false
            wasDisconnected = true
            showBackOnline = false
            backOnlineTimer?.cancel(); backOnlineTimer = nil

        case .connected:
            connectingOverdue = false
            // §6 строка 124: «Снова в сети» — ТОЛЬКО если полоса «Нет соединения»
            // была реально показана, то есть после `.offline`/`.failed` или после сработавшего
            // 3-секундного таймера `Connecting`. Штатный старт `Idle → Connecting → Connected`
            // укладывается в 3 с, полосы не было — вспышки быть не должно.
            // Единое правило с Android (`barWasShown`).
            let hadProblem = wasDisconnected
            if hadProblem {
                wasDisconnected = false
                showBackOnline = true
                backOnlineTimer?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.showBackOnline = false
                    self?.rebuild()
                }
                backOnlineTimer = work
                schedule(Self.backOnlineDuration, work)
            }

        case .idle:
            connectingOverdue = false
        }
        rebuild()
    }

    func backendDidUpdateBranding(_ branding: BrandingRow?) {
        self.branding = branding
        rebuild()
    }

    /// §5 п. 2: `ChatEvent.Reset` — очистить локальное.
    func backendDidReset() {
        draft = ""
        chips.forEach { backend.cancelUpload(uploadId: $0.id) }
        chips = []
        // Файлы, выбранные до сброса и ещё не готовые, плашками уже не станут.
        pickGeneration &+= 1
        // §12 п. 75 (паритет Android п. 74): id отправленного с этого экрана относятся к прежней беседе.
        sentHereIds = []
        clearTransient()
        rebuild()
    }

    // MARK: действия

    /// §5 п. 5. Поле и чипы очищаются сразу (оптимистично, как на сайте).
    func send() {
        guard ui.sendEnabled else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = chips.compactMap(\.uploaded)
        chips = []
        draft = ""
        clearTransient()
        backend.send(text: text, attachments: attachments, sent: { [weak self] id in
            guard let self else { return }
            self.sentHereIds.insert(id)
            self.rebuild()
        })
        rebuild()
    }

    func retry(id: String) {
        clearTransient()
        sentHereIds.insert(id)
        backend.retry(messageId: id)
        rebuild()
    }

    /// §12 п. 78 (паритет Android `onRetryAll`): нажатие на полосу «Не доставлено — нажмите, чтобы повторить» —
    /// повтор каждого СВОЕГО `failed` в порядке ленты. Чужое и своё в иных статусах не трогаем. id — в «отправлено
    /// здесь» (§12 п. 73) ДО вызова, как у тапа по пузырю. §12 п. 79: одним вызовом `retryAll` — бэкенд
    /// повторяет строки последовательно, и ядро ставит их в очередь в порядке ленты.
    func retryAllFailed() {
        let ids = messages.filter { $0.isMine && $0.failed }.map(\.id)
        guard !ids.isEmpty else { return }
        clearTransient()
        sentHereIds.formUnion(ids)
        backend.retryAll(messageIds: ids)
        rebuild()
    }

    func cancel(id: String) {
        clearTransient()
        backend.cancel(messageId: id)
    }

    /// §5 п. 3: один запрос за раз. Флаг снимает ЗАВЕРШЕНИЕ подгрузки, а не обновление ленты:
    /// отказ (`loadMore` бросил или страница пустая) ленту не трогает вовсе, и при снятии по обновлению
    /// экран залипал бы — история больше никогда не догружалась.
    ///
    /// §12 п. 56: `false` — запрос не ушёл (истории нет или прежний не завершён). Строки страницы
    /// приходят коллектором ядра РАНЬШЕ, чем завершение снимет `loadingMore`, и лента успевает решить «пора» на
    /// новой странице — такой отказ гейт ленты откатывает, а `loadMoreFinished` даёт ей новый повод проверки.
    @discardableResult
    func loadMore() -> Bool {
        guard hasMore, !loadingMore else { return false }
        loadingMore = true
        backend.loadMore { [weak self] in
            guard let self else { return }
            self.loadingMore = false
            self.loadMoreFinished &+= 1
        }
        return true
    }

    /// §5 п. 4: дебаунс 500 мс, в фоне не зовём.
    func markReadSoon() {
        guard screenVisible else { return }
        markReadTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.screenVisible else { return }
            self.backend.markRead()
        }
        markReadTimer = work
        schedule(Self.markReadDebounce, work)
    }

    /// §6 строка 123: «Обновить» → `conversation.close(); open()` и свежий снимок.
    /// Делегата ядра при этом не трогаем: экран с себя подписку не снимает (иначе между
    /// `close()` и `open()` колбэки ушли бы в никуда), её снимает только уход с экрана.
    ///
    /// Гейта `isConfigured` здесь нет: показ до `configure` тоже подписывает экран и
    /// взводит `screenVisible` (§12 п. 47), поэтому «первым показом» «Обновить» оборачивается
    /// только для экрана, который `screenAppeared()` ещё не звал вовсе (или у которого его
    /// отменил уход в фон). Ветка оставлена страховкой: без неё такой тап не дал бы ни ленты,
    /// ни отметки прочтения, ни `screenVisible` — а значит, и уход с экрана не закрыл бы
    /// беседу, и ядро молча погасило бы баннеры пушей (§12 п. 46).
    ///
    /// `markReadSoon()` — на ОБЕИХ ветках: «Обновить» у видимого экрана
    /// тоже может обернуться полноценным открытием подписки (её мог забрать второй экран),
    /// и без отметки счётчик непрочитанного у ядра стоял бы до следующего чужого сообщения
    /// или до следующего показа экрана — человек в это время читает ленту. Лишней отметки
    /// нет: `markReadSoon()` дебаунсится 500 мс и молчит на скрытом экране (§5 п. 4),
    /// а у ядра `markRead` троттлится 2 с.
    func refresh() {
        guard screenVisible else {
            screenAppeared()
            return
        }
        backend.refresh()
        markReadSoon()
    }

    // MARK: вложения (§5 п. 6)

    /// §5 п. 6: лимит размера из брендинга; без брендинга — жёсткий потолок ядра (10 МБ), а не «сколько угодно».
    /// Публичный, потому что `PhotoPicker` отбрасывает слишком большое видео ДО чтения байтов в память: без потолка
    /// видео на сотни мегабайт поднималось бы в память приложения-хоста.
    var maxFileSize: Int64 { branding?.maxFileSize ?? CoreConvert.defaultMaxFileSize }

    /// §5 п. 6. Порядок проверок — СНАЧАЛА лимит 10 чипов, ПОТОМ размер файла
    /// (единое правило с Android).
    /// `localUri` — копия выбранного файла в кэше (§5 п. 7): свой пузырь рисует картинку
    /// из неё, не дожидаясь ни загрузки, ни обратного скачивания.
    /// `media` — плашка (вид, миниатюра, размер, длительность), `preview` — превью для ядра; оба снимает
    /// пикер вне главного потока. Без `media` — плашка по MIME без миниатюры (плитка-заглушка или карточка).
    func attach(fileName: String, mime: String, data: Data, localUri: String? = nil,
                media: ChipMedia? = nil, preview: UploadPreview? = nil) {
        guard chips.count < ChatUiState.maxAttachmentsPerMessage else {
            showTransient(.limit)
            return
        }
        guard Int64(data.count) <= maxFileSize else {
            showTransient(.tooBig)
            return
        }
        clearTransient()
        // id загрузки задаёт экран: чип и его загрузка связываются по нему, а не по имени файла —
        // два «IMG_0001.HEIC» из пикера соответствие по имени ломают напрочь.
        let uploadId = UUID().uuidString
        let chipMedia = media ?? ChipMedia(kind: ChipKind.of(mime: mime), tile: nil,
                                           byteCount: Int64(data.count), durationMs: nil)
        chips.append(ChipRow(id: uploadId, fileName: fileName, uploading: true, uploaded: nil, media: chipMedia))
        backend.upload(uploadId: uploadId, fileName: fileName, mime: mime,
                       data: data, localUri: localUri, preview: preview) { [weak self] result in
            guard let self, let idx = self.chips.firstIndex(where: { $0.id == uploadId }) else { return }
            switch result {
            case .success(let attachment):
                self.chips[idx].uploading = false
                self.chips[idx].uploaded = attachment
            case .failure(.failed):
                self.chips.remove(at: idx)
                self.showTransient(.attachFailed)
            case .failure(.cancelled):
                // Отмену сделал сам пользователь — полосы отказа быть не должно (§6 строка 126)
                self.chips.remove(at: idx)
            }
            self.rebuild()
        }
        rebuild()
    }

    /// Выбранный файл из пикера целиком.
    func attach(_ file: PickedFile) {
        attach(fileName: file.name, mime: file.mime, data: file.data, localUri: file.localUri,
               media: file.media, preview: file.preview)
    }

    /// Начало выбора файлов — пикер зовёт в момент, когда файлы выбраны. Настройка хранения читается здесь, на каждом
    /// выборе, а не при создании экрана: модуль мог быть настроен позже или заново. Без хранения истории на диске
    /// своей копии нет; модуль ещё не настроен — тоже нет: настройка неизвестна, а копия, записанная вопреки ей,
    /// осталась бы на диске.
    ///
    /// Плашки и отказ сверяются с поколением экрана на момент выбора: пришедшее после `Reset` плашкой не становится,
    /// полосы не поднимает, а его копия с обложкой удаляется. Модель держится слабо: экрана нет — копия тоже не нужна.
    func beginPick() -> PickSink {
        let generation = pickGeneration
        return PickSink(
            writeCopy: backend.persistHistory == true,
            picked: { [weak self] file in
                guard let self, generation == self.pickGeneration else {
                    if let localUri = file.localUri { CacheUri.deleteCopy(localUri) }
                    return
                }
                self.attach(file)
            },
            rejected: { [weak self] error in
                guard let self, generation == self.pickGeneration else { return }
                self.showTransient(error)
            }
        )
    }

    func removeChip(id: String) {
        backend.cancelUpload(uploadId: id)
        chips.removeAll { $0.id == id }
        clearTransient()
        rebuild()
    }

    // MARK: картинки (§5 п. 7)

    /// Метод изолирован главным потоком НАМЕРЕННО: словарь `inflightImages` — обычный
    /// `Dictionary`, а зовут метод из `.task` каждого пузыря, то есть с пула потоков.
    /// Два фото в одном сообщении появляются одновременно, и две записи в словарь
    /// сошлись бы на его переаллокации — и гонка, и лишний запрос к ядру.
    /// Поэтому бухгалтерия словаря идёт на main, а дорогое (перевод `KotlinByteArray → Data`
    /// и декодирование `UIImage`) — в `Task.detached`.
    @MainActor
    func image(messageId: String, index: Int32) async -> UIImage? {
        if let cached = images.image(messageId: messageId, index: index) { return cached }
        let key = "\(messageId)#\(index)"
        if let running = inflightImages[key] { return await running.value }

        // `Task` заводится в изоляции main и её наследует, поэтому запись в кэш — тоже на main.
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            let backend = self.backend
            let loaded: (image: UIImage, cost: Int)? = await Task.detached(priority: .userInitiated) {
                let data: Data? = await withCheckedContinuation { cont in
                    backend.attachmentBytes(messageId: messageId, index: index) { cont.resume(returning: $0) }
                }
                // Подвыборка + стоимость по распакованным байтам (§12 п. 45, паритет с decodeSampled на Android)
                guard let data else { return nil }
                return ImageCache.decodeSampled(data)
            }.value
            guard let loaded else { return nil }
            self.images.store(loaded.image, messageId: messageId, index: index, cost: loaded.cost)
            self.failedImages.remove(key)   // доехала позже — прежний отказ больше не действует
            return loaded.image
        }
        inflightImages[key] = task
        let result = await task.value
        inflightImages.removeValue(forKey: key)
        return result
    }

    /// Синхронное чтение уже декодированной картинки: ячейка UIKit-ленты при `configure`
    /// ставит её сразу — переиспользование, повторный показ и `reconfigureItems` идут без плашки и без смены
    /// высоты. Нет в кэше — `nil`, дальше асинхронный `image(messageId:index:)`. Ядро не дёргает.
    @MainActor
    func cachedImage(messageId: String, index: Int32) -> UIImage? {
        images.image(messageId: messageId, index: index)
    }

    /// Память отказов: картинку, которую не удалось загрузить, ячейка UIKit-ленты при повторном
    /// показе строки рисует ссылкой СРАЗУ — без плашки 150 и новой загрузки (иначе высота прыгает 150 ↔ строка
    /// ссылки). Пишет ячейка по исходу загрузки (и своё фото из `localUri`, и чужое у ядра) — ключ `id#index`
    /// строки. Живёт, пока жив экран (модель); удачная загрузка той же картинки отказ снимает.
    @MainActor
    func rememberImageFailure(messageId: String, index: Int32) {
        failedImages.insert(ImageCache.key(messageId: messageId, index: index) as String)
    }

    @MainActor
    func imageFailed(messageId: String, index: Int32) -> Bool {
        failedImages.contains(ImageCache.key(messageId: messageId, index: index) as String)
    }

    /// Связь вернулась (`reconnects`) — память отказов сбрасывается, лента перезагружает видимые строки с отказом.
    /// Иначе после разового сбоя сети картинка не грузилась бы до закрытия экрана. Память отказов обложек видео —
    /// тоже (отказ мог быть сбоем сети при открытии чата без связи; паритет Android `missingCovers`).
    @MainActor
    func forgetImageFailures() {
        failedImages.removeAll()
        failedThumbnails.removeAll()
        failureGeneration += 1
    }

    /// То же для своих из `localUri`: `localImage(uri:)` кладёт декодированную картинку в общий кэш (`local#uri`).
    func cachedLocalImage(uri: String) -> UIImage? {
        images.localImage(uri: uri)
    }

    // MARK: обложки видео

    /// Синхронное чтение уже декодированной обложки с сервера (ключ `thumb#id#index`) — как `cachedImage`.
    @MainActor
    func cachedThumbnail(messageId: String, index: Int32) -> UIImage? {
        images.thumbnail(messageId: messageId, index: index)
    }

    /// Обложка видео с сервера (`attachmentThumbnail`). Один запрос на пару (`id`, `index`) за раз, как у `image`.
    /// Отказ (404 — обложки нет, или сеть) запоминается: строка в новой ячейке сразу рисует ссылку и ядро больше
    /// не спрашивает. Ключ отдельный от отказов картинок; сбрасывает память возврат связи (`forgetImageFailures`)
    /// — 404 от сбоя сети не отличить, а повтор раз на возврат связи дёшев.
    @MainActor
    func thumbnail(messageId: String, index: Int32) async -> UIImage? {
        if let cached = images.thumbnail(messageId: messageId, index: index) { return cached }
        let key = ImageCache.thumbnailKey(messageId: messageId, index: index) as String
        if failedThumbnails.contains(key) { return nil }
        if let running = inflightThumbnails[key] { return await running.value }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            let backend = self.backend
            let fetch = { () async -> (image: UIImage, cost: Int)? in
                await Task.detached(priority: .userInitiated) {
                    let data: Data? = await withCheckedContinuation { cont in
                        backend.attachmentThumbnail(messageId: messageId, index: index) { cont.resume(returning: $0) }
                    }
                    guard let data else { return nil }
                    return ImageCache.decodeSampled(data)
                }.value
            }
            // Отказ запроса, начатого ДО возврата связи, но пришедший ПОСЛЕ сброса памяти отказов,
            // не запоминаем (строка осталась бы ссылкой до следующего реконнекта) — один повтор; отказ повтора без
            // новой смены поколения запоминается как обычно.
            var generation = self.failureGeneration
            var loaded = await fetch()
            if loaded == nil, generation != self.failureGeneration {
                generation = self.failureGeneration
                loaded = await fetch()
            }
            guard let loaded else {
                if generation == self.failureGeneration { self.failedThumbnails.insert(key) }
                return nil
            }
            self.images.storeThumbnail(loaded.image, messageId: messageId, index: index, cost: loaded.cost)
            return loaded.image
        }
        inflightThumbnails[key] = task
        let result = await task.value
        inflightThumbnails.removeValue(forKey: key)
        return result
    }

    /// Известный отказ обложки с сервера.
    @MainActor
    func thumbnailFailed(messageId: String, index: Int32) -> Bool {
        failedThumbnails.contains(ImageCache.thumbnailKey(messageId: messageId, index: index) as String)
    }

    /// Свои вложения — из `localUri` (§5 п. 7). Адрес относительный (`revback-cache://…`,
    /// §12 п. 27), в файл его разворачивает `CacheUri`: он же поднимает старые записи с
    /// абсолютным `file://`, переехавшие вместе с контейнером данных приложения.
    /// Чтение файла и декодирование — ВНЕ главного потока: `Data(contentsOf:)` на main
    /// подвешивает прокрутку ленты.
    /// Декодированное своё фото ложится в общий кэш картинок (ключ `local#uri`, тот же бюджет
    /// §12 п. 43) — повторный показ строки берёт его синхронно (`cachedLocalImage`) и файл не перечитывает.
    func localImage(uri: String) async -> UIImage? {
        if let cached = images.localImage(uri: uri) { return cached }
        guard let url = CacheUri.resolve(uri) else { return nil }
        let images = self.images
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url),
                  let decoded = ImageCache.decodeSampled(data)   // своё фото — тоже с подвыборкой (§12 п. 45)
            else { return nil }
            images.storeLocal(decoded.image, uri: uri, cost: decoded.cost)   // `NSCache` потокобезопасен
            return decoded.image
        }.value
    }

    /// §5 п. 8: байты вложения как есть (для системного просмотрщика).
    /// Перевод `KotlinByteArray → Data` побайтовый и дорогой (§12 спеки),
    /// поэтому результат кэшируется по (`messageId`, `index`) на время жизни экрана:
    /// повторный тап по той же ссылке ядро уже не дёргает.
    /// Изоляция main — та же причина, что у `image(messageId:index:)`: метод зовут тапы по
    /// вложениям, то есть с пула потоков, а сам запрос уходит в `Task.detached`.
    @MainActor
    func bytes(messageId: String, index: Int32) async -> Data? {
        let key = ImageCache.key(messageId: messageId, index: index)
        if let cached = bytesCache.object(forKey: key) { return cached as Data }
        let backend = self.backend
        let data: Data? = await Task.detached(priority: .userInitiated) {
            await withCheckedContinuation { cont in
                backend.attachmentBytes(messageId: messageId, index: index) { cont.resume(returning: $0) }
            }
        }.value
        if let data { bytesCache.setObject(data as NSData, forKey: key, cost: data.count) }
        return data
    }

    // MARK: транзиентные полосы (§6 строка 126)

    private func showTransient(_ error: TransientError) {
        transientError = error
        transientTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.transientError = nil
            self?.rebuild()
        }
        transientTimer = work
        schedule(Self.transientErrorDuration, work)
        rebuild()
    }

    private func clearTransient() {
        transientTimer?.cancel(); transientTimer = nil
        transientError = nil
    }

    // MARK: пересборка

    private func rebuild() {
        ui = ChatUiState.make(ChatUiInput(
            messages: messages,
            state: state,
            connection: connection,
            branding: branding,
            hasMore: hasMore,
            draft: draft,
            chips: chips,
            transientError: transientError,
            connectingOverdue: connectingOverdue,
            showBackOnline: showBackOnline,
            timeZone: timeZone,
            strings: strings,
            sentHereIds: sentHereIds
        ))
    }
}
