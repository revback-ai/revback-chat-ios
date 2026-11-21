# RevBack Chat SDK для iOS

[Documentation in English](./README_en.md)

**RevBack Chat SDK** встраивает чат поддержки RevBack в мобильное приложение: переписка с оператором
и AI-ассистентом, история, вложения, счётчик непрочитанного и push-уведомления. Два продукта Swift-пакета —
ядро без единого экрана (`RevbackChatCore`) и готовый экран чата на SwiftUI поверх него (`RevbackChatUI`):
берите готовый экран, если не хотите рисовать чат сами, или только ядро, если интерфейс у вас свой.

Ядро написано на Kotlin Multiplatform и приезжает бинарным статическим XCFramework; в Swift его API
выглядит как обычный: `async`-функции и потоки данных как `AsyncSequence`. Канал распространения iOS-части —
Swift Package Manager, этот репозиторий; парная версия для Android — Maven Central, репозиторий
[revback-chat-android](https://github.com/revback-ai/revback-chat-android).

## Возможности

- Переписка визитёра с оператором и AI-ассистентом, системные сообщения.
- История переписки с подгрузкой вверх; кэш беседы ускоряет холодный старт.
- Вложения в обе стороны: загрузка и отправка своих файлов, скачивание файлов оператора и своих;
  у видео — обложка, длительность и размеры.
- Статусы своих сообщений: отправляется, отправлено (сервер принял), прочитано оператором,
  не отправлено (с повтором).
- Очередь отправки на диске: неотправленное переживает перезапуск процесса (пока история хранится на
  диске — так по умолчанию).
- Счётчик непрочитанного вне экрана чата — для бейджа на кнопке «Поддержка».
- Push-уведомления через Firebase Cloud Messaging: решение о показе, когда приложение на экране,
  переход к беседе по тапу.
- Связывание визитёра с пользователем приложения (`identify`) по токену, который выпускает ваш бэкенд.
- Атрибуты пользователя, которые видит оператор (`setAttributes`).
- Готовый экран чата на SwiftUI — отдельным продуктом; ядро работает и без него.
- Телеметрия SDK для диагностики интеграции (без идентификаторов визитёра и токенов).

## Требования

| Что | Значение |
|---|---|
| Минимальная версия iOS | 15.0 |
| Swift Package Manager | `swift-tools-version` 5.9 |
| Swift | проверено на Xcode 26.3 (Swift 6.2.4). Ядро собрано в режиме языка Swift 5 (`-swift-version 5` в `.swiftinterface` модуля). Пакет и все примеры этого руководства собираются в режиме языка Swift 5, в том числе с изоляцией `MainActor` по умолчанию (`SWIFT_DEFAULT_ACTOR_ISOLATION`) — тогда пример из «Вложения и превью» выдаёт предупреждения об изоляции. В режиме языка Swift 6 часть примеров не собирается: строгая проверка гонок данных требует их доработки. Более старые версии Xcode не проверялись |
| Firebase Cloud Messaging | подключает само приложение — пакет SDK Firebase за собой не тянет |
| Разрешения | готовому экрану строки `NS…UsageDescription` не нужны; разрешение на уведомления запрашивает приложение |
| Keychain | SDK хранит идентификаторы в Keychain, поэтому сборка должна быть подписана — в том числе под симулятор (достаточно ad hoc). Без подписи Keychain отвечает `errSecMissingEntitlement`, и беседа не открывается |

## Зависимости и совместимость

SDK не требует переделывать сетевой слой приложения и не добавляет в проект ни одного стороннего пакета:
у Swift-пакета внешних зависимостей нет. Ядро — статический `RevbackChatCore.xcframework`, сторонние
библиотеки скомпилированы внутрь него; снаружи нужна только системная `libsqlite3`, и её пакет линкует сам
(см. «Подключение»).

| Что внутри `RevbackChatCore.xcframework` | Версия | Что это значит для приложения |
|---|---|---|
| Kotlin/Native (рантайм и стандартная библиотека) | 2.2.21 | Kotlin в приложении не нужен |
| Ktor, движок Darwin (`NSURLSession`) | 3.3.3 | сеть SDK; сетевой слой и `URLSession` приложения SDK не настраивает |
| kotlinx.coroutines | 1.10.2 | `suspend`-функции видны в Swift как `async throws` |
| kotlinx.serialization | 1.9.0 | — |
| SQLDelight / SQLiter | 2.2.1 / 1.3.3 | кэш беседы на системной `libsqlite3` |
| SKIE (рантайм) | 0.10.14 | мост в Swift: `async`-функции, потоки как `AsyncSequence` |
| kotlinx-atomicfu, kotlinx-io, Stately | 0.29.0 / 0.8.0 / 2.1.0 | — |

Полный список сторонних компонентов с лицензиями — в `THIRD-PARTY-NOTICES`. Если ваше приложение само
написано на Kotlin Multiplatform — см. раздел «Приложение на Kotlin Multiplatform».

## Подключение

В Xcode: **File → Add Package Dependencies…** → адрес этого репозитория
(`https://github.com/revback-ai/revback-chat-ios`) → выбрать продукт `RevbackChatUI`.

Ядро (`RevbackChatCore`) подключается вместе с `RevbackChatUI` автоматически — отдельно
добавлять его не нужно. Кто рисует экран чата сам, выбирает продукт `RevbackChatCore`
(только ядро, без готового экрана). Системную `libsqlite3` (её требует кэш беседы внутри
ядра) пакет линкует сам — **с любым из двух продуктов**; вручную добавлять `libsqlite3.tbd`
в проект хоста не требуется.

В своём `Package.swift` — то же самое. Пока версия `0.x`, ломающие изменения возможны в минорной версии
(см. «Совместимость и версии»), поэтому берите обновления только в пределах минорной:

```swift
dependencies: [
    .package(url: "https://github.com/revback-ai/revback-chat-ios", .upToNextMinor(from: "0.1.1"))
],
targets: [
    .target(
        name: "App",
        dependencies: [
            // готовый экран чата; ядро приезжает вместе с ним
            .product(name: "RevbackChatUI", package: "revback-chat-ios")
            // или только ядро — если экран рисуете сами:
            // .product(name: "RevbackChatCore", package: "revback-chat-ios")
        ]
    )
]
```

```swift
import RevbackChatCore
import RevbackChatUI
```

Если имя типа SDK совпадает с типом вашего приложения или другой библиотеки (`Message`, `Attachment`,
`Conversation` и т. п.), укажите модуль явно: `RevbackChatCore.Message`.

Третий модуль в списке таргетов пакета — `RevbackChatCoreLink` — служебный: кода в нём нет,
он только сообщает линковщику про `libsqlite3` для продукта «только ядро». Импортировать его
не нужно.

**Если линковка приложения всё же падает** на `Undefined symbols: _sqlite3_…` — добавьте
`libsqlite3.tbd` к цели приложения (Build Phases → Link Binary With Libraries → `libsqlite3.tbd`)
и напишите нам. Это страховка на случай нестандартной конфигурации проекта: со штатным
подключением через Swift Package Manager шаг не нужен ни с одним из продуктов.

Ключ канала (`widgetKey`) берётся в кабинете RevBack, канал «Чат в приложении». Ключ публичен
по дизайну — он извлекается из сборки приложения и секретом не является; секрет канала, которым ваш бэкенд
подписывает токен личности пользователя, в приложение не кладётся и живёт на вашем бэкенде.

## Быстрый старт

Настройка — один раз при старте процесса: в `application(_:didFinishLaunchingWithOptions:)` или в `init()`
вашего `App`. Если в приложении есть Firebase — после `FirebaseApp.configure()`.

```swift
import RevbackChatCore
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // телеметрию — до configure: SDK запомнит слушателя; события приходят с любого потока
        RevbackChat.shared.setTelemetryListener { event in
            NSLog("RevBack: %@", String(describing: event))
        }
        // в инициализаторе только ключ канала; необязательное — цепочкой with…
        RevbackChat.shared.configure(config: RevbackChatConfig(widgetKey: "wk_…"))
        return true
    }
}
```

- Повторный `configure` с тем же ключом — no-op: настройка остаётся той, с которой модуль собран (в том числе
  `persistHistory`). С другим ключом SDK пересобирает модуль под новый канал и новую настройку.
  Некорректный конфиг (пустой ключ) — запись в лог и отказ, без исключения.
- Любой вызов до `configure` безопасен: no-op с записью в лог. Часть вызовов при этом не теряется: SDK
  запоминает `setPushToken`, `conversation.open()` и `close()`, а также слушателей (`setTelemetryListener`,
  `setUnreadListener`, `setTokenSyncListener`, `setDelegate`) и применяет их сразу после `configure`.
  `markRead()` до `configure` SDK тоже запоминает, но досылает после `configure`, только если экран в этот
  момент открыт (`conversation.open()` позван и не закрыт `close()`); иначе отметка снимается.
  `identify` до `configure` не запоминается — зовите его после.
- `suspend`-функции ядра в Swift — `async throws`. Бизнес-ошибок они не бросают (отказы приходят состояниями
  и событиями), `try?` достаточно.
- Значения параметров по умолчанию Kotlin в Swift не видны: передавайте все параметры
  (`setPushToken(token:provider:)`, `markRead(upTo: nil)`, все пять параметров `MediaPreview`).
- `RevbackChat.shared.isConfigured` — настроен ли модуль; `RevbackChat.shared.config` — настройка, с которой
  он работает (`nil` до `configure`).

## Готовый экран

Продукт `RevbackChatUI`. Открыть поверх приложения — одним вызовом:

```swift
import RevbackChatUI
import UIKit

final class SupportEntryController: UIViewController {

    // например, по тапу на «Поддержка»
    @objc func supportTapped() {
        RevbackChatUI.present(over: self)
    }

    // закрыть из кода — например, при выходе пользователя; экран не показан — ничего не делает
    func closeSupportChat() {
        RevbackChatUI.dismiss()
    }
}
```

Или собрать показ самому — SwiftUI-вью `RevbackChatView` или UIKit-контейнер `RevbackChatViewController`:

```swift
import RevbackChatUI
import SwiftUI
import UIKit

struct SupportButton: View {
    @State private var chatOpen = false

    var body: some View {
        Button("Поддержка") { chatOpen = true }
            .fullScreenCover(isPresented: $chatOpen) {
                RevbackChatView(onClose: { chatOpen = false })
            }
    }
}

final class SupportHostController: UIViewController {
    func openSupportChat() {
        let chat = RevbackChatViewController(onClose: { [weak self] in
            self?.dismiss(animated: true)
        })
        present(chat, animated: true)
    }
}
```

- Экран повторяет вид виджета RevBack на сайте: шапка в цвете канала, входящие с подписью
  отправителя, свои сообщения со статусами, вложения, поле ввода.
- `RevbackChatUI.present(over:)` показывает экран модально во весь экран, крестик в шапке его закрывает.
  Повторный `present` при уже показанном экране — no-op. Звать можно с любого потока.
- `RevbackChatUI.dismiss()` закрывает экран вместе со всем, что открыто поверх него (меню скрепки, выбор файла,
  просмотр вложения): закрытие идёт через контроллер, который экран показал. `RevbackChatUI.isPresented` —
  показан ли экран; если экран убран не через `dismiss()` (например, вы закрыли контроллер, поверх которого он
  лежал), `isPresented` вернёт `false`, и следующий `present` откроет экран заново. Читайте `isPresented` на
  главном потоке: вне его свойство не сверяется с UIKit и отвечает `true`, пока фасад помнит экран, даже уже
  убранный мимо `dismiss()`, а `present` и `dismiss`, вызванные не с главного потока, исполняются на нём позже,
  асинхронно, — до этого `isPresented` их ещё не видит.
- `RevbackChatViewController` — модальный контейнер (`modalPresentationStyle = .fullScreen`, светлый
  статус-бар): он рассчитан на `present`, а не на `pushViewController`. `onClose: nil` — крестик закрывает
  контейнер сам. Если всё же кладёте его в стек навигации — прячьте навбар хоста сами, иначе над шапкой чата
  останется вторая шапка.
- `RevbackChatView(onClose: nil)` — крестика в шапке нет, экран закрывает хост.
- Экран сам открывает и закрывает беседу — по показу и скрытию, а также при уходе приложения в фон и
  возвращении: звать `conversation.open()` / `close()` рядом с ним не нужно.
- Экран, открытый до `RevbackChat.shared.configure`, показывает «Чат временно недоступен» с кнопкой
  «Обновить» и оживает сам, как только вы позовёте `configure`. Если `configure` не случится никогда,
  экран так и останется на этом состоянии.
- Вложения: скрепка открывает меню «Фото и видео» (`PHPickerViewController`) и «Файл»
  (`UIDocumentPickerViewController`). Оба пикера работают вне процесса приложения и отдают только выбранные
  файлы — разрешений и строк `NS…UsageDescription` не требуется. До 10 файлов в одном сообщении; потолок
  размера файла задаёт канал. Присланные файлы открываются системным `QLPreviewController`.
- Фото HEIC с iPhone и другие картинки в форматах, которые сервер не показывает как картинку, экран перед
  отправкой перекодирует в JPEG с правильным поворотом — они уходят фото, а не файлом. Картинка при этом
  ужимается до 4096 пикселей по большей стороне; с настоящей прозрачностью — PNG, а если PNG больше потолка
  размера файла — JPEG на белом фоне. Снимок уходит одинаково, выбран он в «Фото и видео» или в «Файл».
  Картинки в форматах, которые сервер показывает как картинку, уходят как есть, любого размера в пикселях, —
  если файл укладывается в потолок размера. Неподвижную картинку больше потолка (JPEG, PNG, HEIC и др.) экран
  ужимает до 4096 пикселей и отправляет, если ужатое в потолок влезло; анимированные и многокадровые больше
  потолка не отправляются.
  Кадр-обложку и длительность видео экран снимает сам.
- Своё вложение экран рисует из локальной копии выбранного файла в кэше приложения (копии занимают не больше
  50 МБ), а без копии — скачивает с сервера, как только сервер подтвердил отправку.
- Строки экрана — английские, если язык системы английский, иначе русские.
- На время показа экран занимает `RevbackChatDelegate` (делегат у ядра один): свой делегат рядом с готовым
  экраном не ставьте — следите за данными потоками (см. «Подписка на данные в Swift»).

## Свой экран поверх ядра

Всё, что нужно своему экрану, лежит в `RevbackChat.shared.conversation` — это постоянный объект: его можно
взять до `configure`, после смены ключа он продолжает работать. Модели и состояния — из `RevbackChatCore`.

### Лента и отправка

```swift
import Combine
import Foundation
import RevbackChatCore

/// Причины Failed беседы, на которых чат стоит: до configure и после терминального стопа.
/// Остальные Failed — сбой сети или сервера: следующий open() или возврат из фона загрузят ленту снова.
let supportChatStopReasons: Set<String> = ["not_configured", "widget_not_found", "sdk_outdated", "cache_unavailable"]

@MainActor
final class SupportChatModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var hasMore = false
    @Published private(set) var unavailable = false
    /// текст, который SDK не принял (см. send); верните его в поле ввода
    @Published private(set) var rejectedDraft: String?

    private var tasks: [Task<Void, Never>] = []

    /// экран показан
    func screenAppeared() {
        let conversation = RevbackChat.shared.conversation
        conversation.open()   // живёт chat-сокет, пуши о новых сообщениях баннером не показываются
        tasks.append(Task { [weak self] in
            // первым приходит текущая лента, дальше — каждое изменение
            for await messages in conversation.messages {
                guard let self else { return }
                self.messages = messages
                self.hasMore = (conversation.hasMore.value as? Bool) ?? false
                self.markRead()
            }
        })
        tasks.append(Task { [weak self] in
            for await state in conversation.state {
                // на причинах остановки — «чат недоступен» без поля ввода; на прочих Failed поле остаётся
                let reason = (state as? ConversationState.Failed)?.reason
                self?.unavailable = reason.map { supportChatStopReasons.contains($0) } ?? false
            }
        })
    }

    /// экран скрыт: парный close() обязателен, иначе пуши о новых сообщениях останутся заглушенными
    func screenDisappeared() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        RevbackChat.shared.conversation.close()
    }

    func send(_ text: String) {
        // оптимистично: сообщение сразу в ленте со статусом Sending
        Task { [weak self] in
            guard let message = try? await RevbackChat.shared.conversation.send(text: text, attachments: []) else { return }
            // до configure и при недоступном кэше отказанное сообщение в ленту не попадает:
            // отказ виден только здесь, в результате send
            if let failed = message.status as? MessageStatus.Failed,
               failed.reason == "not_configured" || failed.reason == "cache_unavailable" {
                self?.rejectedDraft = text
            }
        }
    }

    func retry(_ message: Message) {
        // повтор своего Failed
        Task { _ = try? await RevbackChat.shared.conversation.retry(messageId: message.id) }
    }

    func loadMore() {
        // страница истории вверх
        Task { _ = try? await RevbackChat.shared.conversation.loadMore() }
    }

    private func markRead() {
        // nil — прочитано всё до текущего момента; частоту ядро ограничивает само (не чаще раза в 2 с)
        Task { _ = try? await RevbackChat.shared.conversation.markRead(upTo: nil) }
    }
}

/// Причины Failed сообщения, при которых retry не поможет (см. «Отказы и повтор»).
let supportRetryUseless: Set<String> = ["empty", "bad_attachment", "sdk_outdated", "widget_not_found"]

/// Подпись статуса своего сообщения. Набор вариантов растёт — ветка «иначе» обязательна.
func statusLabel(_ message: Message) -> String {
    let status = message.status
    if status is MessageStatus.Sending { return "отправляется" }
    if status is MessageStatus.Sent { return "отправлено" }
    if status is MessageStatus.ReadByOperator { return "прочитано" }
    if let failed = status as? MessageStatus.Failed {
        return supportRetryUseless.contains(failed.reason) ? "не отправлено" : "не отправлено — нажмите, чтобы повторить"
    }
    return ""   // Received (чужие сообщения) и будущие варианты
}
```

- Лента — последние ≤ 200 сообщений, всё догруженное `loadMore()` и новые; свои `Sending`/`Failed` — в хвосте.
  Первая подписка на `messages` (или `open()`) запускает синхронизацию ленты; чтение `.value` без подписки её
  не поднимает.
- `deleted == true` — удалённое сообщение: оно остаётся в ленте, покажите его заглушкой.
- Отправитель чужого сообщения — `message.sender`: `Sender.Agent`, `Sender.Assistant`, `Sender.System`,
  `Sender.Other` (вид, которого эта версия SDK не знает) или `nil`; разбор через `as?`, ветка «иначе» обязательна.
- `conversation.cancel(messageId:)` убирает своё `Sending`/`Failed` из ленты; `conversation.events` — события
  ленты (`ChatEvent.Added`, `Updated`, `Deleted`, `ReadByOperator`, `OperatorTyping`, `Reset`).
- Набор текста: `conversation.setTyping(draft:)` — визитёр печатает (`nil` — перестал). Уходит на сервер только
  при включённом на канале `features.typing` и открытой беседе, не чаще раза в 3 с. Что печатает оператор —
  поток `conversation.operatorTyping` (`TypingState?`: `sender`, `until`; `nil` — не печатает).
- `conversation.unreadInConversation` — поток числа чужих непрочитанных сообщений внутри беседы.

### Отказы и повтор

Причина отказа — строка в `Failed(reason)`. Набор причин открыт: на незнакомой причине поступайте как с
временным сбоем.

**Сообщение** — `MessageStatus.Failed(reason)`; повтор — `conversation.retry(messageId:)`:

| Причина | Что значит | Поможет ли `retry` |
|---|---|---|
| `network` | сеть или сервер не ответили: SDK пробовал около минуты (сообщение, которое так и не ушло в сеть, — до 5 минут) | да |
| `rejected` | сервер принял запрос, но сообщение не сохранил (например, отправка на канале выключена). Если это была гонка двух одинаковых запросов, статус сам сменится на `Sent`, когда сообщение придёт с сервера | повтор отправит снова; если сервер не сохраняет такие сообщения, откажет так же |
| текст ответа сервера или `HTTP <код>` | сервер отклонил само сообщение (ответ 4xx) | обычно нет: то же сообщение будет отклонено снова |
| `empty` | нет ни текста, ни вложений | нет |
| `bad_attachment` | вложение не из результата `upload` (без ссылки на загруженный файл) | нет |
| `sdk_outdated`, `widget_not_found` | чат остановлен (см. ниже) | нет |
| `not_configured`, `cache_unavailable` | `send` до `configure` или при недоступном кэше беседы: сообщение в ленту не попадает, отказ виден только в результате `send` | нет — в ленте его нет; отправьте текст заново, когда чат заработает |
| `logout`, `identity_changed`, `identity_lost` | очередь сброшена выходом пользователя, сменой или потерей личности: неотправленное исчезает из ленты вместе с ней, о каждом сообщении приходит событие телеметрии `TelemetryEvent.SendFailed(messageId, reason)` | нет — сообщения в ленте уже нет |

**Загрузка вложения** — `UploadResult.Failed(reason)`; повтор — новый `upload` того же файла:

| Причина | Что значит | Поможет ли повтор |
|---|---|---|
| `too_large` | файл больше `branding.value?.maxFileSize`, отказ без сети | нет |
| `network` | нет сети | да |
| `session` | сессию визитёра получить не удалось, либо пользователь вышел или сменился, пока файл грузился | да, если пользователь тот же; файл прежнего пользователя после выхода не отправляйте |
| текст ответа сервера или `HTTP <код>` | сервер отклонил файл | при ответе 5xx — да, при 4xx — обычно нет |
| `not_configured`, `sdk_outdated`, `widget_not_found`, `cache_unavailable` | модуль не настроен или чат остановлен | нет |

`Upload.progress` — поток `0` до завершения и `1` при `Done`: промежуточных значений нет.

**Беседа** — `ConversationState.Failed(reason)`:

| Причина | Что значит | Что делать |
|---|---|---|
| `not_configured` | `configure` ещё не было | экран «чат недоступен» без поля ввода; после `configure` беседа оживёт сама |
| `widget_not_found`, `sdk_outdated`, `cache_unavailable` | чат остановлен | экран «чат недоступен» без поля ввода |
| `session`, `history HTTP <код>`, `changes HTTP <код>` | сбой сети или сервера при загрузке ленты | поле ввода оставьте: следующий `open()` или возврат приложения из фона загрузят ленту снова |

**Соединение** — `RevbackChat.shared.connection`: `Offline(since)` — связи нет, SDK переподключается сам;
`Failed(reason)` бывает только при остановке чата — `widget_not_found`, `sdk_outdated`, `cache_unavailable`.

**Остановка чата.** Сервер может объявить версию SDK устаревшей: тогда приходит событие телеметрии
`TelemetryEvent.SdkOutdated(minSdkVersion)`, беседа и соединение переходят в `Failed("sdk_outdated")`,
отправка и загрузки отказывают с той же причиной, и чат стоит, пока приложение не обновится на версию с более
новым SDK. `widget_not_found` — сервер не знает ключ канала (ключ с ошибкой или канал удалён): чат стоит до
`configure` с верным ключом. `cache_unavailable` — не открылся кэш беседы на устройстве: чат стоит до
перезапуска приложения. Готовый экран на всех трёх показывает «Чат временно недоступен». Следите за
`SdkOutdated` в телеметрии — это сигнал выпустить обновление приложения.

### Вложения и превью

Вложение сначала загружается, потом отправляется — `send` принимает только результат `upload`. Байты в API
ядра — `KotlinByteArray`, а не `Data`. Перевод идёт по одному байту (у массива ядра в Swift нет доступа к
памяти целиком): файл 10 МБ — около 10 млн вызовов в каждую сторону. Поэтому переводите вне главного потока —
в `Task.detached`, который не наследует актор вызывающего (например, `@MainActor` экрана):

```swift
import Foundation
import RevbackChatCore

/// Data → KotlinByteArray: по одному байту, только вне главного потока
func kotlinBytes(_ data: Data) -> KotlinByteArray {
    let bytes = [UInt8](data)
    return KotlinByteArray(size: Int32(bytes.count)) { index in
        KotlinByte(char: Int8(bitPattern: bytes[Int(truncating: index)]))
    }
}

/// KotlinByteArray → Data: по одному байту, только вне главного потока
func swiftData(_ array: KotlinByteArray) -> Data {
    var bytes = [UInt8](repeating: 0, count: Int(array.size))
    for i in bytes.indices {
        bytes[i] = UInt8(bitPattern: array.get(index: Int32(i)))
    }
    return Data(bytes)
}

/// Фото: localCopy — ваша копия файла, по ней экран покажет своё вложение без сети
func sendPhoto(jpeg: Data, localCopy: URL?) async {
    await Task.detached {
        let conversation = RevbackChat.shared.conversation
        let source = FileSource(fileName: "photo.jpg", mime: "image/jpeg", bytes: kotlinBytes(jpeg))
            .withLocalUri(localUri: localCopy?.absoluteString)
        guard let result = try? await conversation.upload(file: source).await() else { return }
        if let done = result as? UploadResult.Done {
            _ = try? await conversation.send(text: "", attachments: [done.attachment])
        } else if let failed = result as? UploadResult.Failed {
            NSLog("вложение не загрузилось: %@", failed.reason)   // причины — в «Отказы и повтор»
        }   // Cancelled и будущие варианты
    }.value
}

/// Видео с обложкой: кадр, длительность и размеры снимает ваш экран при выборе файла
func sendVideo(mp4: Data, coverJpeg: Data?, durationMs: Int64, width: Int32, height: Int32) async {
    await Task.detached {
        let conversation = RevbackChat.shared.conversation
        var preview = MediaPreview()
            .withDurationMs(ms: durationMs)
            .withSize(width: width, height: height)              // в ориентации показа
        if let coverJpeg {                                       // кадр из первой секунды; JPEG или WebP, до 640 px, до 200 КБ
            preview = preview.withThumbnail(bytes: kotlinBytes(coverJpeg), mime: "image/jpeg")
        }
        let source = FileSource(fileName: "clip.mp4", mime: "video/mp4", bytes: kotlinBytes(mp4))
            .withPreview(preview: preview)
        guard let result = try? await conversation.upload(file: source).await() else { return }
        if let done = result as? UploadResult.Done {
            _ = try? await conversation.send(text: "", attachments: [done.attachment])
        }
    }.value
}

/// Байты вложения — оператора и своего; nil — вложение недоступно
func attachmentData(message: Message, index: Int) async -> Data? {
    let messageId = message.id
    return await Task.detached { () -> Data? in
        guard let bytes = try? await RevbackChat.shared.conversation
            .attachmentBytes(messageId: messageId, index: Int32(index)) else { return nil }
        return swiftData(bytes)
    }.value
}

/// Обложка видео; nil — обложки нет: покажите ссылку на файл
func videoCover(message: Message, index: Int) async -> Data? {
    let attachment = message.attachments[index]
    // attachment.width, attachment.height, attachment.durationMs — nil, если неизвестны
    guard attachment.thumbnailBlobRef != nil else { return nil }
    let messageId = message.id
    return await Task.detached { () -> Data? in
        guard let bytes = try? await RevbackChat.shared.conversation
            .attachmentThumbnail(messageId: messageId, index: Int32(index)) else { return nil }
        return swiftData(bytes)
    }.value
}
```

- Своё вложение показывайте из своего файла (`Attachment.localUri` — то, что вы передали в
  `FileSource.withLocalUri`), а если его уже нет — через `attachmentBytes`, как вложение оператора: сервис
  отдаёт и свои файлы, например после переустановки или на другом устройстве. Исключение — своё сообщение,
  которое сервер ещё не подтвердил (`Sending`, `Failed`): для него `attachmentBytes` сразу вернёт `nil`, без
  запроса. Своему видео, которое сервер ещё не подтвердил, обложку с сервера тоже не получить — показывайте
  кадр, снятый при выборе файла.
- Обложка уходит отдельной загрузкой, и её сбой отправку не валит — видео уйдёт без обложки. У фото достаточно
  размеров. Превью собирается цепочкой: `MediaPreview()` и `withThumbnail(bytes:mime:)`, `withDurationMs(ms:)`,
  `withSize(width:height:)` — обложка задаётся вместе с типом, ширина вместе с высотой. Значения вне допустимых
  границ (длительность, размеры) ядро отбрасывает до сети.
- Как картинку сервер показывает только PNG, JPEG, GIF, WebP, AVIF и BMP; остальное (например, HEIC с iPhone)
  станет файлом. Готовый экран перекодирует такие картинки сам, своему экрану это нужно делать самому.
- Потолок размера файла — `RevbackChat.shared.branding.value?.maxFileSize` (по умолчанию 10 МБ); файл больше
  него `upload` отклонит без сети с причиной `too_large`. `upload` возвращает ход загрузки: `cancel()` — отмена.
- Вложение, которое эта версия SDK не разобрала, приходит видом `AttachmentKind.companion.Other` без имени,
  MIME-типа и ссылок — подпишите его «Данный тип файла не поддерживается» (см. «Совместимость и версии»).

### Непрочитанное вне экрана чата

```swift
import RevbackChatCore
import UIKit

final class SupportBadge {
    private weak var label: UILabel?

    init(label: UILabel) {
        self.label = label
        // новый слушатель сразу получает текущее число (если оно уже известно), дальше — каждое изменение;
        // колбэк приходит не с главного потока
        RevbackChat.shared.setUnreadListener { [weak self] unread in
            let count = unread.count
            DispatchQueue.main.async {
                // пусто при нуле, «99+» сверху — так же, как в примере с потоком ниже
                self?.label?.text = count > 99 ? "99+" : (count > 0 ? String(count) : nil)
            }
        }
    }
}
```

- Слушатель у SDK один: новый `setUnreadListener` заменяет прежнего, `nil` — отписка (снимайте его там, где
  бейдж больше не нужен, а не в `deinit` объекта: к этому моменту слушателем может быть уже чужой). SDK держит
  слушателя, пока его не заменят или не снимут; `[weak self]` в замыкании не даёт ему удерживать бейдж. Без
  слушателя — поток `RevbackChat.shared.unreadCount` (см. «Подписка на данные в Swift»).
- Число видно сразу после холодного старта (сохранённое с прошлого запуска), дальше его уточняют сервер, живая
  подписка и пуши. `RevbackChat.shared.refreshUnread()` — запросить заново.
- Иконку приложения (app badge) SDK не трогает.

## Подписка на данные в Swift

Потоки ядра — `conversation.messages`, `conversation.state`, `conversation.events`,
`RevbackChat.shared.unreadCount`, `connection`, `branding` — в Swift это `AsyncSequence`: подписка —
`for await`, первым приходит текущее значение (у `events` — только новые события), дальше каждое изменение.
Подписка живёт, пока жива задача; отмените задачу, когда данные больше не нужны. Текущее значение без
подписки — `.value` (`RevbackChat.shared.conversation.messages.value` — это `[Message]`).

```swift
import RevbackChatCore
import UIKit

@MainActor
final class SupportObservers {
    private var tasks: [Task<Void, Never>] = []

    func start(badge: UILabel, onReset: @escaping () -> Void) {
        tasks.append(Task {
            for await unread in RevbackChat.shared.unreadCount {
                let count = unread.count
                badge.text = count > 99 ? "99+" : (count > 0 ? String(count) : nil)
            }
        })
        tasks.append(Task {
            for await event in RevbackChat.shared.conversation.events {
                if event is ChatEvent.Reset { onReset() }   // выход или смена пользователя
            }
        })
    }

    // отписка
    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
```

Готовый экран на время показа занимает `RevbackChatDelegate` (делегат у ядра один), поэтому рядом с ним
следите за лентой, событиями и счётчиком потоками — подписок может быть сколько угодно, и экрану они не мешают.

Делегат — запасной путь для кода без `async`. `RevbackChatDelegate` — `@objc`-протокол: класс наследует
`NSObject` и реализует все шесть методов. Колбэки приходят не с главного потока; `setDelegate(delegate: nil)` —
отписка, новый делегат заменяет прежнего. Ядро держит делегата **сильной ссылкой**, пока его не снимут
`setDelegate(delegate: nil)` или не заменят: без `detach()` объект не освободится.

```swift
import Foundation
import RevbackChatCore

final class ChatDelegateBridge: NSObject, RevbackChatDelegate {
    var onMessages: (([Message]) -> Void)?

    // ядро держит делегата сильной ссылкой — парный detach() обязателен
    func attach() { RevbackChat.shared.setDelegate(delegate: self) }
    func detach() { RevbackChat.shared.setDelegate(delegate: nil) }

    func onMessagesChanged(messages: [Message]) {
        DispatchQueue.main.async { self.onMessages?(messages) }
    }
    func onConversationStateChanged(state: ConversationState) {}
    func onConnectionChanged(state: ConnectionState) {}
    func onEvent(event: ChatEvent) {}
    func onUnreadChanged(unread: UnreadCount) {}
    func onBrandingChanged(branding: Branding?) {}
}
```

## Пуши

Пуши приходят через Firebase Cloud Messaging (на iPhone — через APNs). FCM SDK подключает само приложение;
SDK RevBack получает токен, решает, показывать ли уведомление, когда приложение на экране, и находит беседу
по тапу. Пока экран чата открыт, уведомления о новых сообщениях не показываются.

```swift
import RevbackChatCore
import RevbackChatUI
import UIKit
import UserNotifications

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // FirebaseApp.configure() — до configure SDK
        RevbackChat.shared.configure(config: RevbackChatConfig(widgetKey: "wk_…"))
        // делегат уведомлений — до конца didFinishLaunching, иначе тап на холодном старте не дойдёт
        UNUserNotificationCenter.current().delegate = self
        // Messaging.messaging().delegate = self
        return true
    }

    /// FCM-токен: зовите из MessagingDelegate.messaging(_:didReceiveRegistrationToken:)
    /// и из Messaging.messaging().token { … } при каждом старте. Messaging.messaging().token запрашивайте
    /// после того, как приложение получило APNs-токен (didRegisterForRemoteNotificationsWithDeviceToken):
    /// без APNs-токена FCM-токена на iPhone нет
    func fcmTokenReceived(_ token: String) {
        // provider указывается всегда: значения по умолчанию Kotlin в Swift не видны
        RevbackChat.shared.setPushToken(token: token, provider: PushProvider.companion.Fcm)
    }

    // приложение на экране: показывать ли уведомление
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let data = Self.stringData(notification.request.content.userInfo)
        // для ShowMessage вызов не идемпотентен (SDK запоминает показ) — один вызов на уведомление
        let action = RevbackChat.shared.handlePush(data: data)
        if action is PushAction.ShowMessage || action is PushAction.TestPush {
            completionHandler([.banner, .list, .sound])
        } else if action is PushAction.NotOurs {
            completionHandler([.banner, .list, .sound])   // ваши собственные пуши — по-вашему
        } else {
            completionHandler([])   // Suppress (чат открыт), Ignore и будущие варианты
        }
    }

    // тап по уведомлению
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let data = Self.stringData(response.notification.request.content.userInfo)
        if RevbackChat.shared.conversationId(data: data) != nil {
            DispatchQueue.main.async { self.openSupportChat(attemptsLeft: 10) }
        }
        completionHandler()
    }

    /// На холодном старте тап приходит, пока окно ещё поднимается: ждём контроллер в окне (до ~3 с)
    private func openSupportChat(attemptsLeft: Int) {
        if let top = Self.topViewController(), top.view.window != nil {
            RevbackChatUI.present(over: top)   // экран уже показан — no-op
            return
        }
        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.openSupportChat(attemptsLeft: attemptsLeft - 1)
        }
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// наши data-ключи лежат строками на верхнем уровне userInfo; aps и не-строки отбрасываем
    static func stringData(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, let value = value as? String {
                out[key] = value
            }
        }
        return out
    }
}
```

- `PushAction` — решение по пушу: `ShowMessage` и `TestPush` — показать; `Suppress` — не показывать (чат
  открыт или дубль); `Ignore` — наш пуш, но показывать нечего (чужой ключ канала, неизвестный тип, пуш
  операторской части RevBack, модуль не настроен); `NotOurs` — пуш вашего приложения. Набор вариантов растёт —
  ветка «иначе» обязательна.
- `RevbackChat.shared.isRevbackPush(data:)` — пуш RevBack любого вида; удобно для ветвления в общем обработчике.
- `conversationId(data:)` отвечает и до `configure` — тап на холодном старте не теряется. `nil` — не пуш беседы
  RevBack (ваш, тестовый или чужого канала).
- Если экран чата у вас свой — откройте его по тапу сами; про открытый экран SDK узнаёт из
  `conversation.open()` / `close()`.
- Звать `setPushToken` можно до `configure`: SDK придержит токен и отправит его после настройки. Прежний токен
  после `reset()` SDK объявит заново сам.

Текста переписки в пуше нет: заголовок и текст уведомления iOS берёт по ключам из `Localizable.strings`
**главного бандла приложения** (ресурсы пакета для них не видны; отсутствующий ключ iOS показывает буквально).
Добавьте четыре ключа в каждый язык приложения:

```
/* en.lproj/Localizable.strings */
"revback.push.visitor.new_message.title_brand" = "%@";
"revback.push.visitor.new_message.body_contentless" = "New message from support";
"revback.push.visitor.test.title" = "Notification test";
"revback.push.visitor.test.body" = "Support chat notifications are working";
```

```
/* ru.lproj/Localizable.strings */
"revback.push.visitor.new_message.title_brand" = "%@";
"revback.push.visitor.new_message.body_contentless" = "Новое сообщение от поддержки";
"revback.push.visitor.test.title" = "Тест уведомлений";
"revback.push.visitor.test.body" = "Пуши из чата поддержки доходят";
```

Что нужно, чтобы пуши доходили:

- в консоли Firebase вашего проекта загружен **APNs Auth Key (`.p8`)** (Project settings → Cloud Messaging) —
  без него FCM отвечает `THIRD_PARTY_AUTH_ERROR`; в RevBack ключ `.p8` загружать не нужно;
- в кабинете RevBack на канале «Чат в приложении» загружен service-account вашего проекта Firebase с правом
  `cloudmessaging.messages.create` (строка «Ключ Firebase» в настройках канала).

Проверить доставку на конкретном устройстве помогает `try await RevbackChat.shared.sendTestPush()` — исход
приходит вариантом `TestPushResult` (`Accepted`, `Rejected` с причиной `TestPushRejection`, `TooManyRequests`,
`PushUnavailable`, `Failed`); тест можно повторять не чаще раза в минуту. Диагностику интеграции отдают
`RevbackChat.shared.debugInfo` (`nil` до `configure`) и `RevbackChat.shared.setTokenSyncListener { … }`.
Таблица исходов теста — на странице документации.

## Разрешение на уведомления

SDK разрешение на уведомления не запрашивает и `registerForRemoteNotifications()` не вызывает — это делает
приложение, как для своих пушей. Ответ поддержки приходит не сразу, и пуш — единственный способ о нём
узнать, поэтому удачный момент для запроса — сразу после того, как пользователь отправил первое сообщение
в чат:

- сначала отправьте сообщение, не задерживая его, потом покажите поверх чата короткий экран-объяснение
  (например, «Сообщим, когда ответит поддержка») с одной кнопкой, которая открывает системный запрос;
- показывайте его, только если разрешения ещё нет; если пользователь раньше отказал, системный запрос
  больше не появится — кнопка должна вести в Настройки;
- отказ не переспрашивайте при каждом сообщении.

Первое отправленное сообщение видно в потоке ленты (см. «Подписка на данные в Swift»): своё новое
сообщение появляется в `conversation.messages` сразу со статусом `MessageStatus.Sending`. Чтобы показать
экран-объяснение поверх готового экрана, откройте чат сами — `present(RevbackChatViewController(onClose: { … }), animated: true)`, —
а свой экран показывайте над ним стилем `.overFullScreen`. При полноэкранном показе экран чата получает
`viewDidDisappear`, считает себя закрытым и закрывает беседу. Чат, открытый так, `RevbackChatUI.isPresented`
и `RevbackChatUI.dismiss()` не видят — закрывайте его сами.

## Личность пользователя и выход

`identify` связывает визитёра с пользователем вашего приложения. Токен выпускает **ваш бэкенд**:
JWT HS256, ключ — секрет канала из кабинета как есть, срок — на ваше усмотрение (советуем 1–5 минут).
В токене — id пользователя (`sub`), остальное по желанию. Один токен — один вход: на каждый запрос
SDK выпускайте новый токен со случайным `jti`, не кэшируйте его (повтор токена из другой сессии —
`410`). Необязательные claims названы как в OpenID Connect (формат токена identify v2): `name`,
`email`, `phone_number` — E.164 (`+79001234567`; пробелы, дефисы и скобки сервер уберёт сам; прежний
`phone` сервер игнорирует — переименуйте его); `email_verified`, `phone_number_verified` — подтвердил
ли ваш бэкенд почту и телефон; `amr`, `idp`, `auth_time` — как и когда пользователь вошёл; `ids` —
ваши идентификаторы пользователя объектом «ключ → строка» (например `{"crm_id": "…"}`; их
получают инструменты ассистента, модели они не показываются); `attributes` — подписанные атрибуты.
Поле неверного вида вход не роняет: сервер его не сохраняет, `identify` проходит без ошибки — отказ
(`422`) бывает только по безопасности токена. SDK токен не разбирает, поэтому переход на v2 —
правка только вашего бэкенда. Точные правила, готовые сниппеты для Node, PHP, Python и Go и
тест-вектор — в описании операции identify в OpenAPI RevBack
(`https://api.revback.ai/v1/widget/openapi.json`). Приложение просит токен у своего бэкенда и отдаёт
его SDK как есть:

```swift
import Foundation
import RevbackChatCore

/// IdentityTokenProvider — @objc-протокол, а не замыкание: нужен класс-наследник NSObject
final class RevbackTokenProvider: NSObject, IdentityTokenProvider {
    private let fetchToken: (@escaping (String?) -> Void) -> Void

    /// fetchToken — запрос токена у вашего бэкенда; зовёт колбэк один раз, nil — токена нет
    init(fetchToken: @escaping (@escaping (String?) -> Void) -> Void) {
        self.fetchToken = fetchToken
    }

    // SDK зовёт это не с главного потока; onResult можно звать с любого потока, первый вызов побеждает
    func provideIdentityToken(onResult: @escaping (String?) -> Void) {
        fetchToken(onResult)
    }
}

// при каждом старте процесса, после configure (почему — ниже)
func identifySupportUser(fetchToken: @escaping (@escaping (String?) -> Void) -> Void) {
    RevbackChat.shared.identify(provider: RevbackTokenProvider(fetchToken: fetchToken))
}
```

Запрос токена к своему бэкенду делайте отдельным HTTP-клиентом — без общего обработчика ответа `401`,
который обновляет сессию, повторяет запрос или выводит пользователя из аккаунта:

- отказ этой ручки — просто «токена нет»: отдайте SDK `nil`, чат останется анонимным. Через общий
  обработчик ошибочный `401` вспомогательной ручки выкинул бы пользователя из аккаунта, а авто-обновление
  могло бы повторить запрос уже под другой (гостевой) сессией;
- повторы не нужны: истёкший токен SDK попросит сам, а ответа ждёт не дольше 10 секунд;
- пользователь не вошёл — ручку не зовите, сразу `onResult(nil)`;
- пользователь вышел или сменился, пока запрос летел, — пришедший токен не отдавайте, верните `nil`.

Подтверждение личности включается на канале отдельно (`RevbackChat.shared.branding.value?.features.identify`),
и токен проверяет сервис, а не SDK. Если возможность на канале выключена или токен не принят,
визитёр остаётся анонимным, а причина приходит событием `TelemetryEvent.IdentifyFailed(reason)`;
если сервис отклонил токен из-за его содержимого, причина называет поле, например `aud/mismatch`.
Поставьте `RevbackChat.shared.setTelemetryListener { … }` до первого `identify` и прогоните сценарий
со своим бэком, прежде чем полагаться на него в проде.

Звать `identify` нужно при **каждом** старте процесса. Подтверждённая личность живёт в сохранённой сессии
визитёра (срок задаёт сервер) и пропадает вместе с ней — когда сессия истекает или сервер её отзывает. Каждый удачный
`identify` выдаёт новую сессию, и вызов на старте не даёт ей дойти до истечения. Ответа провайдера SDK ждёт
не дольше 10 секунд, побеждает первый вызов `onResult`; `onResult(nil)` — отказ хоста, личность остаётся
прежней. Если срок токена успел истечь, SDK сам один раз попросит у провайдера новый.

Если у подтверждённого пользователя пропала сессия (например, истекла), анонимную сессию под его визитёром
сервер больше не выдаёт. Тогда SDK заводит нового анонимного визитёра — как при выходе: очередь отправки и
лента стираются, неотправленные сообщения исчезают из ленты, и о каждом приходит событие телеметрии
`TelemetryEvent.SendFailed(messageId, "identity_lost")`; в ленте приходит `ChatEvent.Reset`, затем —
`TelemetryEvent.IdentityLost`. Атрибуты пользователя SDK отправит новому визитёру сам. Если пользователь в
приложении всё ещё вошёл, позовите `identify` ещё раз. Слушатель телеметрии у SDK один — держите в нём и
логирование:

```swift
import Foundation
import RevbackChatCore

func installSupportTelemetry(isSignedIn: @escaping () -> Bool, makeProvider: @escaping () -> IdentityTokenProvider) {
    RevbackChat.shared.setTelemetryListener { event in
        NSLog("RevBack: %@", String(describing: event))
        if event is TelemetryEvent.IdentityLost {
            DispatchQueue.main.async {
                if isSignedIn() { RevbackChat.shared.identify(provider: makeProvider()) }
            }
        }
    }
}
```

При выходе пользователя из аккаунта зовите `RevbackChat.shared.reset()` (`async throws`): это новый
визитёр, снятая подписка на пуши и недоступная прежняя переписка. Если экран чата в этот момент
открыт, закрывает или перерисовывает его хост — по событию `ChatEvent.Reset`, которое приходит в
`conversation.events` (и в `RevbackChatDelegate.onEvent`). Готовый экран `RevbackChatUI` получает это
событие сам (он занимает делегата на время показа — свой `RevbackChatDelegate` рядом с ним не ставьте,
следите за событиями потоком `conversation.events`, см. «Подписка на данные в Swift») и чистит по нему
черновик и вложения; закрыть экран — `RevbackChatUI.dismiss()`. Выход доводится до конца, даже если задача,
из которой его позвали, отменена. Если приложение убили посреди выхода, SDK сам дочистит данные прежнего
пользователя на следующем старте — повторно звать `reset()` не нужно. Так же после переустановки приложения
подтверждённая личность не сохраняется: SDK сам сбрасывает её при первом запуске, а `identify` после входа
вернёт пользователю его переписку; анонимный гость продолжает беседу (см. «Хранение переписки на устройстве»).

Порядок при смене пользователя: `try await reset()`, и только **после** возврата — `identify()` и
`setAttributes()` нового пользователя, из той же задачи. Если вызвать их, не дождавшись выхода
(`Task { try await RevbackChat.shared.reset() }` и сразу `identify(…)`), SDK отнесёт их к **прежнему**
пользователю: выход их отбросит, новый визитёр останется анонимным и без атрибутов, а в телеметрии придут
`TelemetryEvent.IdentifyFailed(reason: "logging_out")` / `TelemetryEvent.AttributesFailed(reason: "logging_out")`.
Вызовы, пришедшие, пока `reset()` уже исполняется, ждут его конца и достаются новому визитёру.

```swift
import Foundation
import RevbackChatCore
import RevbackChatUI

func switchSupportUser(to provider: IdentityTokenProvider, name: String) {
    Task {
        // новый визитёр; отмена задачи выход не прерывает; прежний FCM-токен переобъявится сам
        _ = try? await RevbackChat.shared.reset()
        RevbackChat.shared.identify(provider: provider)            // новый пользователь
        RevbackChat.shared.setAttributes(attributes: ["name": name])
    }
}

func logOutOfSupport() {
    // готовый экран, открытый через present(over:), — вместе с открытыми поверх листами; не показан — no-op
    RevbackChatUI.dismiss()
    Task { _ = try? await RevbackChat.shared.reset() }
}
```

### Атрибуты пользователя

`RevbackChat.shared.setAttributes(attributes:)` передаёт оператору и ассистенту данные о пользователе. В Swift
параметр — `[String: Any]`, но значением может быть только `String` или `NSNull()`. Удалить ключ — значение
`NSNull()` (в ядре это `null`). **Любое другое значение — число, `Bool`, дата, вложенный словарь — SDK
отбрасывает вместе с ключом:** компилятор такой вызов пропустит, а SDK запишет в лог отброшенные ключи и пришлёт
`TelemetryEvent.AttributesTruncated` (отброшенные ключи входят в `droppedKeys`); строковые значения того же вызова
сохраняются. Числа и флаги переводите в строку сами (`String(age)`). Вызов сливается с прежним снимком:
ключи, которых нет в вызове, остаются.

```swift
import Foundation
import RevbackChatCore

func updateSupportAttributes(plan: String) {
    RevbackChat.shared.setAttributes(attributes: [
        "plan": plan,            // добавить или обновить
        "promo": NSNull(),       // удалить ключ
    ])
}
```

- Лимиты на весь снимок: не больше 32 ключей (остаются первые 32 по алфавиту имён), ключ — до 64 байт в UTF-8
  (длиннее — отбрасывается), значение — до 512 байт (длиннее — обрезается по границе символа). Что отброшено
  или обрезано, сообщает событие телеметрии `TelemetryEvent.AttributesTruncated(droppedKeys, truncatedValues)`.
- Если сервер атрибуты не принимает (`branding.value?.features.attributes == false`), SDK хранит снимок на
  устройстве, ничего не отправляет и присылает `TelemetryEvent.AttributesUnavailable`.
- Атрибуты принадлежат визитёру, текущему в момент вызова; при смене пользователя зовите `setAttributes` после
  `reset()` (см. выше).

## Хранение переписки на устройстве

По умолчанию SDK хранит ленту и очередь отправки в кэше на диске: на холодном старте лента видна сразу,
а неотправленное переживает перезапуск процесса. Кэш лежит в `Application Support` приложения и в резервную
копию не попадает — флаг ставит сам SDK.

Идентификаторы и сессия лежат не в кэше, а в Keychain, и удаление приложения их не стирает: после
переустановки анонимный гость продолжает беседу. Подтверждённая личность после переустановки сбрасывается: если
до удаления приложения пользователь прошёл `identify`, SDK на первом запуске сам сбрасывает его сессию и данные
на устройстве, как при `reset()` (событие `ChatEvent.Reset` при этом не приходит), — чат открывается новым
анонимным визитёром, и переписка клиента не достаётся следующему гостю. Она остаётся на сервере и вернётся после
`identify`. Приложению ничего делать не нужно. Отличить переустановку SDK может только в основном приложении (в
расширениях проверки нет) и только когда файлы приложения и Keychain уже читаются — с первой разблокировки
устройства после включения, в том числе при заблокированном экране. Если система запустила приложение раньше
(после перезагрузки, до первой разблокировки), решение откладывается до следующего запуска, и до тех пор SDK в
этом процессе не открывает сессию визитёра: чат и счётчик непрочитанного ждут. Если приложение не
переустанавливали, сессия откроется, как только устройство разблокируют; если переустанавливали — на следующем
запуске. В зашифрованную резервную копию устройства попадают идентификатор
визитёра и его сохранённые данные (счётчик непрочитанного, атрибуты, оформление канала) — на новом iPhone,
восстановленном из копии, визитёр тот же. Сессия визитёра (а с ней подтверждённая личность) и идентификатор
установки привязаны к устройству (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) и в копию не попадают:
на новом устройстве SDK заведёт новую сессию, а подтверждённого пользователя заново свяжет `identify`. Всё это
стирает `reset()`: новый визитёр, новый идентификатор установки, сессия удалена.

Если переписка не должна оставаться на устройстве (банк, медицина), выключите хранение:

```swift
import RevbackChatCore

func configureSupportWithoutHistoryOnDisk() {
    RevbackChat.shared.configure(
        config: RevbackChatConfig(widgetKey: "wk_…").withPersistHistory(persistHistory: false)
    )
}
```

- Лента и очередь отправки живут только в памяти процесса: история приходит с сервера при каждом
  старте, а неотправленное при перезапуске процесса пропадает.
- На устройстве остаются идентификатор визитёра и подтверждённая личность, счётчик непрочитанного, атрибуты
  пользователя и оформление канала — без них не продолжить ту же беседу.
- Готовый экран не сохраняет копии выбранных файлов: своё вложение он показывает, скачивая его с сервера
  (см. «Известные ограничения»).
- Свой экран сам решает, где держать файлы, которые передаёт в `FileSource.withLocalUri`: SDK их не
  удаляет.

При выходе пользователя (`reset()`) и при смене пользователя SDK удаляет каталоги `revback-chat` в `Caches` и
`tmp` приложения со всеми файлами, которые там сохранял готовый экран, — при любой настройке `persistHistory`.
С выключенным хранением эти каталоги очищаются ещё и при каждом запуске SDK.

Настройку `persistHistory` берёт тот `configure`, который собрал модуль: повторный `configure` с тем же
ключом — no-op и её не меняет. Новая настройка вступает в силу с `configure` под другим ключом или на
следующем запуске процесса. Текущую настройку можно прочитать: `RevbackChat.shared.config?.persistHistory`
(`config` — `nil` до `configure`).

## Приложение на Kotlin Multiplatform

SDK — тоже Kotlin Multiplatform, и на iOS он приезжает своим Kotlin-фреймворком `RevbackChatCore`. Если
у приложения уже есть свой Kotlin-фреймворк (общий модуль), в приложении их станет два. Они собираются и
работают вместе, но независимы друг от друга. Отсюда три правила:

- **На iOS зовите SDK только из Swift.** Не подключайте `ai.revback:revback-chat-core` к iOS-части
  общего модуля: ядро тогда войдёт в ваш фреймворк отдельной копией, а готовый экран `RevbackChatUI`
  работает с ядром из `RevbackChatCore`. Общему коду нужен чат — объявите в нём интерфейс, реализуйте его
  в Swift поверх SDK и передайте реализацию в общий модуль при старте. На Android ту же реализацию можно
  написать на Kotlin в модуле приложения.
- **Не импортируйте оба фреймворка в один Swift-файл.** У них одноимённые служебные типы (`KotlinInt`,
  `KotlinBoolean`, типы корутин и другие), и в файле с двумя импортами такие имена неоднозначны. Держите
  вызовы SDK в своих файлах, а между ними и кодом с вашим фреймворком передавайте только типы Swift —
  например, через Swift-протокол.
- **В интерфейсе для Swift избегайте типов, которые превращаются в обёртки Kotlin**: `Int?`, лямбды с
  `Int` в параметрах и т. п. В Swift это `KotlinInt`, а его имя есть в обоих фреймворках. Для колбэков
  берите `fun interface` с примитивными параметрами.

Ktor вашего фреймворка и Ktor внутри SDK не пересекаются: сеть SDK собрана внутри `RevbackChatCore`.
Совместная работа проверялась с фреймворком приложения на Kotlin 2.2.21 — той же версии, что у SDK.

## Privacy manifest

SDK приносит свой privacy manifest (`PrivacyInfo.xcprivacy`) — Xcode учитывает его в Privacy Report
приложения (Product → Archive → Generate Privacy Report). Что в нём объявлено:

- **Отслеживания нет** (`NSPrivacyTracking = false`, доменов трекинга нет).
- **Required-reason API SDK не использует** (`NSPrivacyAccessedAPITypes` пуст): идентификаторы визитёра,
  установки и сессии хранятся в Keychain, а не в `UserDefaults`; даты файлов SDK не читает и не пишет — потолок
  кэша копий вложений готового экрана считает возраст копии по её имени.
- **Собираемые данные** уходят только на сервер RevBack ради работы чата (`App Functionality`), не
  для трекинга, и связаны с пользователем (после `identify` — с вашим пользователем):
  - текст сообщений — `Customer Support`;
  - фото и видео во вложениях — `Photos or Videos`, прочие файлы — `Other User Content`;
  - идентификаторы визитёра и установки, которые назначает SDK, — `User ID`;
  - имя, email, телефон — `Name`, `Email Address`, `Phone Number`, ваши идентификаторы пользователя
    (claim `ids`) — `User ID`: они лежат в токене личности, который выпускает ваш бэкенд, а SDK
    передаёт этот токен на сервер как есть, не разбирая. Флаги подтверждения почты и телефона и
    сведения о входе (`amr`, `idp`, `auth_time`) — служебные данные той же личности, отдельного типа
    данных Apple для них нет;
  - push-токен FCM — `Device ID`.

**Что декларируете вы сами.** Атрибуты, которые приложение передаёт через `setAttributes`,
произвольны, и манифест SDK покрыть их не может: если среди них есть данные из списка Apple
(например, история покупок или местоположение) — объявите их в манифесте и анкете App Privacy
своего приложения.

Через Swift Package Manager ничего делать не нужно: манифест приезжает ресурсом пакета с любым из
двух продуктов. **При ручном подключении XCFramework** (без SPM) манифест лежит в каждом слайсе
(`RevbackChatCore.framework/PrivacyInfo.xcprivacy`) и попадает в приложение, только если фреймворк
встраивается (**Embed & Sign** или **Embed Without Signing**); при «Do Not Embed» перенесите `PrivacyInfo.xcprivacy` в
ресурсы приложения.

## Что включается на стороне канала

Часть возможностей зависит от настроек вашего канала и версии сервиса: подтверждение личности,
вложения, индикатор «печатает», счётчик непрочитанного, атрибуты, правка и удаление сообщений.
Актуальный набор приезжает потоком `RevbackChat.shared.branding`: читайте его подпиской (`for await`) или как
`RevbackChat.shared.branding.value?.features`. Событием телеметрии SDK сообщает о двух выключенных
возможностях: `identify` при выключенном подтверждении личности — `TelemetryEvent.IdentifyFailed("identify_disabled")`,
атрибуты, которые сервер не принимает, — `TelemetryEvent.AttributesUnavailable`. Об остальном (вложения,
«печатает», непрочитанное, правка и удаление) SDK отдельно не сообщает — сверяйтесь с `features` сами:
например, при `typing == false` вызов `setTyping` ничего не отправляет. Там же — оформление канала (`title`,
`primaryColor`, `logoUrl`, `welcomeText`) и потолок размера вложения (`maxFileSize`).

## Совместимость и версии

Версии — по SemVer. Пока версия `0.x`, ломающие изменения возможны в минорной версии (`0.1` → `0.2`)
и описываются в заметках к выпуску (`CHANGELOG.md` в этом репозитории и текст GitHub Release);
патч-версии (`0.1.0` → `0.1.1`) ничего не ломают. Правила ниже действуют начиная с `0.1.0`.

Как устроен API, чтобы обновления не ломали вашу сборку:

- **Модели SDK создаёт только SDK.** У `Message`, `Attachment`, `Branding`, `Features` и других
  моделей данных инициализатора в Swift нет — поэтому новые поля появляются без ломающих изменений.
  Новые поля добавляются только в конец, читайте свойства по имени.
- **Тесты и превью вашего экрана.** Модели для них собирают фикстуры ядра — в Swift это обычные
  классы: `let f = MessageFixture()`, задайте свойства и вызовите `f.build()`. Рядом
  `AttachmentFixture`, `SenderFixture`, `FeaturesFixture`, `BrandingFixture`, `TypingStateFixture`,
  `UnreadCountFixture`; состояния и события с данными — `StateFixtures.shared` (например
  `StateFixtures.shared.messageFailed(reason: "net")`). Исключение — `SenderFixture`: `build()` у неё
  нет, вариант отправителя выбирается методом `agent()`, `assistant()` или `other(kind:)`. В боевом
  коде фикстуры не используйте. Фикстуры (пакет ядра `ai.revback.chat.testing`) — не боевой API: правила
  этого раздела на них не распространяются, и они могут меняться в обычных версиях, не только в ломающих.
- **Настройки и файлы.** В инициализаторе `RevbackChatConfig`, `FileSource` —
  только обязательное, у `MediaPreview` обязательного нет (`MediaPreview()`); остальное задаётся цепочкой
  `with…`: `RevbackChatConfig(widgetKey: "wk_…").withPersistHistory(persistHistory: false)`,
  `FileSource(fileName: name, mime: mime, bytes: bytes).withLocalUri(localUri: uri)`,
  `MediaPreview().withSize(width: 1080, height: 1920)`. Новая настройка —
  это новый метод `with…`, существующий код не меняется. `bytes` здесь — `KotlinByteArray` ядра, а не
  `Data`: готовый экран переводит `Data` в него побайтово (`KotlinByteArray(size:)` с замыканием) и
  делает это вне главного потока — свой экран поступает так же.
- **Состояния и события** (`ConnectionState`, `ConversationState`, `MessageStatus`, `Sender`,
  `ChatEvent`, `UploadResult`, `PushAction`, `TelemetryEvent`, `TestPushResult`, `TestPushRejection`)
  намеренно НЕ `sealed`: набор вариантов растёт, и новый вариант не должен ломать вашу сборку.
  В Swift это обычные классы — Swift-enum'ов и `onEnum(of:)` по ним нет, разбор идёт через `is`/`as?`,
  и ветка «иначе» есть всегда. Вариант проверяйте по типу (`is ConnectionState.Connected`), а не по
  равенству: вариант без данных может в будущем получить данные. Варианты с данными создаёт только
  SDK, в тестах — `StateFixtures.shared`.
- **Незнакомые значения сервера не теряются.** `AttachmentKind` — не enum: у незнакомого вида
  `isKnown == false`, а `wire` хранит строку сервера; известные виды — свойства companion:
  `AttachmentKind.companion.Photo`. Сервер уже сегодня может прислать вид вложения вне восьми
  именованных (например `unknown`) — он придёт с `isKnown == false`. Отправитель незнакомого вида
  приходит как `Sender.Other` со свойствами `kind`, `name`, `avatarUrl`.
- **Сообщение неожиданной формы не ломает ленту.** Если содержимое сообщения пришло в форме, которой
  эта версия SDK не знает, сообщение всё равно попадает в ленту — чужим живым сообщением
  (`isMine == false`, `deleted == false`) без текста и без вложений: покажите ему заглушку вроде
  «Не удалось отобразить сообщение». Своё сообщение в такой же форме — это отклонённая отправка, у неё
  свой `MessageStatus.Failed`, и заглушка ей не нужна. Вложение, которое не разобралось, приезжает как
  `Attachment` вида `AttachmentKind.Other` без имени, MIME-типа и ссылок — его место в списке и индексы
  соседних вложений при этом сохраняются; подпишите его «Данный тип файла не поддерживается».
  Встроенный экран SDK делает и то, и другое сам.
- **Экран, встроенный до настройки, оживает сам.** `conversation.open()`, вызванный ДО `configure`
  (например, экран чата лежит во вкладке, а ключ канала приложение получает по сети), не теряется:
  SDK запомнит его и откроет беседу сразу, как только модуль соберётся, — и ровно так же переоткроет
  её на новом модуле при смене ключа на живом процессе. До настройки беседа отвечает
  `ConversationState.Failed("not_configured")` — покажите на этом состоянии экран «чат недоступен»
  без поля ввода. Парный `close()` при уходе экрана обязателен: пока беседа открыта, SDK не
  показывает баннеры пушей о новых сообщениях. Встроенный экран SDK делает всё это сам.
- **Перечисление** `UnreadSource`: в совместимых версиях значения в него не добавляются.
- **`PushProvider` — не enum**, а открытый набор, как `AttachmentKind`: известные провайдеры — свойства
  companion (`PushProvider.companion.Fcm`, `Apns`, `Rustore`, `Hms`), новые появляются новыми константами в
  совместимых версиях. Сравнивайте по равенству (`==`), а не исчерпывающим `switch`. Провайдер, которого
  ваша версия SDK ещё не знает, задаётся строкой сервера: `PushProvider.companion.fromWire(value: "…")`. Пустая
  строка даёт `Fcm` — не передавайте в `fromWire` непроверенное значение из своего конфига.
- **`RevbackChatDelegate`:** новые методы в него не добавляются — в Swift все методы протокола
  обязательны. Новые события приходят через `onEvent` либо отдельными слушателями.
- **`Conversation` и `Upload` реализует только SDK.** В них могут появляться новые методы; в тестах
  оборачивайте их своим протоколом, а не реализуйте напрямую.
- **Функции:** у существующих публичных функций не появляется новых параметров — значений по
  умолчанию в Swift нет вовсе. Новая возможность — новая функция или перегрузка.
- **Служебные типы кэша — не API.** В заголовке ядра видны типы базы кэша беседы (`ChatDatabase`,
  `ChatDatabaseQueries`, `Messages`, `Outbox`, `Meta`, `Attachments` и другие) и типы SQLDelight с
  префиксом `Runtime` (`RuntimeSqlDriver`, `RuntimeTransacter` и другие). Они служебные, не входят в API
  SDK и могут меняться в любой версии — не используйте их в своём коде.

## Известные ограничения

- **Готовый экран на время показа занимает единственный `RevbackChatDelegate`** и снимает его при закрытии:
  делегат, поставленный приложением рядом с экраном, будет вытеснен. Рядом с готовым экраном следите за
  данными потоками (`for await`) — их экран не занимает.
- **`RevbackChatUI.isPresented` и `RevbackChatUI.dismiss()` знают только экран, открытый через
  `RevbackChatUI.present(over:)`.** Экран, который вы показали сами (`RevbackChatViewController`,
  `RevbackChatView`), закрывайте сами — через контроллер, который его показал, чтобы вместе с ним закрылись
  и открытые поверх листы.
- **Минимальная версия — iOS 15**, но на iOS 15 и 16 готовый экран пока не проверялся: он проверен на
  актуальных версиях iOS.
- **Готовый экран проверен на iPhone в портретной ориентации**; на iPad и в альбомной ориентации он не
  проверялся.
- **Экран не учитывает системный размер шрифта** (Dynamic Type): размеры текста фиксированы.
- **Клавиатуру не убрать свайпом по ленте или тапом мимо поля**: она остаётся открытой до закрытия экрана.
- **Тёмной темы у экрана нет.** Палитра готового экрана фиксирована светлой — как у виджета RevBack на сайте;
  настройки темы в SDK тоже нет.
- **Своё вложение, ещё не подтверждённое сервером, без локальной копии не показывается.** Своё вложение
  экран рисует из копии файла в кэше приложения, а без неё (кэш почищен системой, приложение
  переустановлено, сообщение отправлено с другого устройства, `persistHistory = false`) — скачивает с сервера.
  Пока сервер не подтвердил отправку (статусы `Sending` и `Failed`), скачать нечего: у такого сообщения без
  копии видно только имя файла. Как только отправка подтверждена, картинка и обложка видео появляются сами.
- **Наборы вариантов пополняются** от версии к версии: публичные иерархии состояний и событий не
  `sealed`, поэтому разбор через `is`/`as?` всегда держит ветку «иначе» — полный перечень иерархий и
  правила см. в разделе «Совместимость и версии».
- Колбэки SDK (`RevbackChatDelegate`, слушатели) приходят из корутин ядра, **не с главного потока**:
  переход на главный поток — на вашей стороне.

## Документация и Android

- Документация интегратора: <https://revback.ai/docs/mobile-app>
- Версия для Android: [revback-ai/revback-chat-android](https://github.com/revback-ai/revback-chat-android)

## Как сообщить о проблеме

Заводите issue в этом репозитории. Помогает приложить:

- версию SDK (`RevbackChat.shared.debugInfo?.sdkVersion`), версию iOS и модель устройства;
- шаги воспроизведения и ожидаемое поведение;
- события `RevbackChat.shared.setTelemetryListener { … }` за время проблемы.

**Не публикуйте в issue** ключ канала, пуш-токен и идентификатор визитёра — они есть в
`RevbackChat.shared.debugInfo`; если они нужны для разбора, пришлите их через кабинет RevBack.

Вопросы по каналу, тарифу и учётной записи решаются в кабинете <https://revback.ai>, а не здесь.

## Об этом репозитории

Этот репозиторий — сборка для распространения через Swift Package Manager: `Package.swift`,
Swift-исходники готового экрана (`Sources/`) и документы. Ядро приезжает бинарным
`RevbackChatCore.xcframework` из GitHub Release соответствующей версии; его исходники (Kotlin) лежат в
репозитории Android-версии. Исходная разработка SDK ведётся в приватном монорепозитории; содержимое сюда
синхронизируется из него при выпуске каждой новой версии.

**Pull-запросы мы не вливаем**: ветка здесь перезаписывается синхронизацией, и любой коммит поверх
неё исчезнет со следующим выпуском. Если нашли ошибку или сделали патч — заводите issue и приложите
diff (или ссылку на свою ветку): правку перенесём во внутренний репозиторий, а в issue напишем,
в какой версии она приедет сюда.

## Лицензия

Apache License 2.0 — см. [LICENSE](./LICENSE).

Сторонние компоненты, вкомпилированные в `RevbackChatCore.xcframework`, и их лицензии
перечислены в [THIRD-PARTY-NOTICES](./THIRD-PARTY-NOTICES). Если вы публикуете приложение —
перенесите их содержимое (вместе со своими уведомлениями) на экран лицензий приложения:
наш код попадает к вашим пользователям внутри вашей сборки.

Лицензия распространяется на код SDK. Доступ к сервису RevBack (канал, операторы, история
переписки) остаётся по условиям вашего тарифа.
