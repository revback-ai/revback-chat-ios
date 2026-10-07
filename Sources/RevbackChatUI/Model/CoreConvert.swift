import Foundation
import RevbackChatCore

/// Граница между ядром и UI: модели Kotlin/Native → плоские `Rows`.
/// Всё остальное в UI-слое типов ядра не видит.
enum CoreConvert {

    // MARK: сообщения

    static func rows(_ messages: [Message]) -> [MessageRow] {
        messages.map(row(_:))
    }

    static func row(_ m: Message) -> MessageRow {
        MessageRow(
            id: m.id,
            isMine: m.isMine,
            // Единое правило с Android (`text?.takeIf { it.isNotBlank() }`): пустая и пробельная
            // строка — не текст, иначе пузырь рисовался бы пустым. Непустое отдаётся дословно.
            text: notBlank(m.text),
            attachments: m.attachments.enumerated().map { idx, a in
                AttachmentRow(
                    index: Int32(idx),
                    // §4 строка 78: картинкой показывается только Photo, остальное — ссылка.
                    // `AttachmentKind` — не enum, а класс ядра с сырой строкой сервера (спека §18 п. 246):
                    // известные виды лежат в companion (`AttachmentKind.companion.Photo`), а сравнение по
                    // `wire` не зависит от того, знает ядро этот вид или нет.
                    // Видео — правило веб-виджета `isVideoAttachment`: вид `video` ИЛИ MIME `video/*`.
                    kind: a.kind.wire == "photo" ? .photo
                        : MediaRules.isVideo(kindWire: a.kind.wire, mime: a.mime) ? .video : .file,
                    // Единое правило с Android (`fileName?.takeIf { it.isNotBlank() }`):
                    // имя из пробелов — это «имени нет», подпись даст строка «Вложение».
                    fileName: notBlank(a.fileName),
                    localUri: a.localUri,
                    unsupported: Self.isUnsupportedStub(a),
                    // ui-спека §12 п. 50: без `mime` безымянное вложение оператора легло бы во временный
                    // файл без расширения, и QuickLook его не открыл бы. Пробелы здесь не чистим —
                    // пустой/нераспознанный MIME отсеет `PreviewFileName` (у `UTType` его просто нет).
                    mime: a.mime,
                    // Превью — правда сервера (ядро уже отбросило значения вне границ и размеры без пары).
                    hasThumbnail: a.thumbnailBlobRef != nil,
                    durationMs: a.durationMs?.int64Value,
                    width: a.width?.intValue,
                    height: a.height?.intValue,
                    // Единое правило с Android: своё скачивается с сервера только подтверждённым
                    onServer: !m.isMine || m.status is MessageStatus.Sent || m.status is MessageStatus.ReadByOperator
                )
            },
            sentAt: date(m.sentAt),
            ticks: ticks(m),
            // Единое правило с Android (`failedOwn = isMine && status is Failed`):
            // «не доставлено» — свойство СВОЕГО сообщения; чужой `Failed` пузырь не метит.
            failed: m.isMine && m.status is MessageStatus.Failed,
            deleted: m.deleted,
            sender: senderRow(m),
            // Нечитаемое сообщение: ни текста, ни вложений, и не тумбстон.
            // Считается по модели ЯДРА, ДО `notBlank`. `!m.isMine` обязателен: своё отклонённое «empty»
            // из `Outbox` лежит в ленте ровно в такой же форме, а нечитаемая строка страницы всегда «чужая»
            // (`direction` из сырого JSON не читается). Единое правило с Android.
            unreadable: !m.deleted && !m.isMine && m.text == nil && m.attachments.isEmpty,
            // §12 п. 71: «отправлено с этого устройства» — своё из очереди этого устройства: `Sending` (оптимистичная
            // строка `Outbox.send`) или `Failed` (локальный отказ/сбой). Своё с сервера (эхо отправленного с другого
            // устройства) ядро маппит в `Sent`/`ReadByOperator` (`MessageDto.toMessage`). Единое правило с Android.
            sentHere: m.isMine && (m.status is MessageStatus.Sending || m.status is MessageStatus.Failed)
        )
    }

    /// §4 строка 73: галочки только у своих. `Sending`/`Sent` → «✓», `ReadByOperator` → «✓✓»,
    /// `Failed` → нет.
    private static func ticks(_ m: Message) -> Ticks {
        guard m.isMine else { return .none }
        if m.status is MessageStatus.ReadByOperator { return .double }
        if m.status is MessageStatus.Sending || m.status is MessageStatus.Sent { return .one }
        return .none
    }

    private static func senderRow(_ m: Message) -> SenderRow {
        if m.isMine { return .mine }
        if let a = m.sender as? Sender.Agent { return .agent(name: a.name) }
        if let a = m.sender as? Sender.Assistant { return .assistant(name: a.name) }
        // Отправитель вида, которого SDK не знает, рисуется как оператор: имя из него, отдельного ярлыка нет.
        if let a = m.sender as? Sender.Other { return .agent(name: a.name) }
        if m.sender is Sender.System { return .system }
        return .unknown
    }

    // MARK: брендинг и состояния

    static func row(_ b: Branding?) -> BrandingRow? {
        guard let b else { return nil }
        return BrandingRow(
            title: b.title,
            primaryColor: b.primaryColor,
            // Единое правило с Android (`logoUrl?.takeIf { it.isNotBlank() }`): пустая строка —
            // это «логотипа нет», иначе шапка пошла бы качать пустой адрес.
            logoUrl: notBlank(b.logoUrl),
            welcomeText: b.welcomeText,
            attachmentsEnabled: b.features.attachments,
            maxFileSize: b.maxFileSize
        )
    }

    /// Потолок размера вложения, когда брендинга ещё нет (первый запуск без сети, ключ неизвестен).
    /// Берём его из ЯДРА, а не константой в UI: `Branding.DEFAULT_MAX_FILE_SIZE` — жёсткий серверный потолок
    /// (§9 core-спеки), его же берёт Android (`ChatViewModel.onFilePicked`), и он описан в README как поведение
    /// SDK. Так у платформ остаётся одно число, и экран поедет за ядром сам, если оно изменится.
    /// Здесь, а не в `ChatModel`: типы ядра в UI-слое видит только `CoreConvert`.
    static var defaultMaxFileSize: Int64 { Branding.companion.DEFAULT_MAX_FILE_SIZE }

    static func row(_ s: ConversationState) -> ConversationStateRow {
        if let f = s as? ConversationState.Failed { return .failed(reason: f.reason) }
        if s is ConversationState.Loading { return .loading }
        if s is ConversationState.Ready { return .ready }
        return .empty
    }

    static func row(_ c: ConnectionState) -> ConnectionRow {
        if let f = c as? ConnectionState.Failed { return .failed(reason: f.reason) }
        if c is ConnectionState.Offline { return .offline }
        if c is ConnectionState.Connecting { return .connecting }
        if c is ConnectionState.Connected { return .connected }
        return .idle
    }

    // MARK: время и байты

    static func date(_ instant: KotlinInstant) -> Date {
        Date(timeIntervalSince1970: Double(instant.toEpochMilliseconds()) / 1000.0)
    }

    /// Публичный заголовок ядра доступа к памяти массива не даёт — только `get(index:)`,
    /// поэтому побайтово. Звать вне главного потока.
    static func data(_ arr: KotlinByteArray) -> Data {
        let n = Int(arr.size)
        var bytes = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            bytes[i] = UInt8(bitPattern: arr.get(index: Int32(i)))
        }
        return Data(bytes)
    }

    /// Обратный перевод для `FileSource(fileName:mime:bytes:)`. Тоже побайтово и тоже вне главного потока.
    static func byteArray(_ data: Data) -> KotlinByteArray {
        let bytes = [UInt8](data)
        return KotlinByteArray(size: Int32(bytes.count)) { index in
            KotlinByte(char: Int8(bitPattern: bytes[Int(truncating: index)]))
        }
    }

    /// Превью экрана → `MediaPreview` ядра: пустое превью и цепочка `with…`. Тип обложки уходит только вместе
    /// с самой обложкой, ширина — только вместе с высотой. Побайтовый перевод кадра — звать вне главного потока.
    static func mediaPreview(_ p: UploadPreview) -> MediaPreview {
        var preview = MediaPreview()
        if let thumbnail = p.thumbnail, let mime = p.thumbnailMime {
            preview = preview.withThumbnail(bytes: byteArray(thumbnail), mime: mime)
        }
        if let durationMs = p.durationMs {
            preview = preview.withDurationMs(ms: durationMs)
        }
        if let width = p.width, let height = p.height {
            preview = preview.withSize(width: Int32(clamping: width), height: Int32(clamping: height))
        }
        return preview
    }

    // MARK: строки

    /// Аналог котлинового `takeIf { it.isNotBlank() }`: строка из одних пробелов — не значение.
    private static func notBlank(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// Заглушка битого вложения: вид неизвестен и показывать нечего —
    /// ни MIME, ни имени, ни единой ссылки. Признака в публичной модели нет, поэтому считаем по составу
    /// на границе с ядром — единое правило с Android (`Attachment.isUnsupportedStub` в `ChatUiState.kt`).
    private static func isUnsupportedStub(_ a: Attachment) -> Bool {
        a.kind.wire == "other" && a.mime == nil && a.fileName == nil && a.blobRef == nil
            && a.externalUrl == nil && a.localUri == nil
    }
}
