import Foundation

/// Строки экрана — внутренняя спецификация UI, §8.
/// Выбор языка — по правилу §3 строка 58: `en*` системы → en, ИНАЧЕ ru.
/// Стандартный фолбэк `Bundle.module` тут не годится: он отдал бы ru только для
/// development region, а нужен ru для любого не-английского.
enum L10n {

    enum Key: String, CaseIterable {
        case title = "rb_title"
        case placeholder = "rb_placeholder"
        case send = "rb_send"
        case close = "rb_close"
        case failed = "rb_failed"
        case notConfigured = "rb_not_configured"
        case attachment = "rb_attachment"
        case deleted = "rb_deleted"
        case attach = "rb_attach"
        case attachRemove = "rb_attach_remove"
        /// Меню скрепки (ui-спека §5 п. 6): «Фото и видео» и «Файл» — привычные пользователю мессенджеров подписи.
        case attachMedia = "rb_attach_media"
        case attachFile = "rb_attach_file"
        /// §8 перечисляет строку, но §5 п. 8 запрещает её показывать: ссылка на файл
        /// подписана именем файла. Держим ради полноты каталога.
        case download = "rb_download"
        case attachTooBig = "rb_attach_too_big"
        case attachFailed = "rb_attach_failed"
        case attachLimit = "rb_attach_limit"
        case emptyHint = "rb_empty_hint"
        /// Вне §8: ярлык действия «отменить отправку» у недоставленного пузыря (§12 пп. 40/42).
        case cancelSending = "rb_cancel_sending"
        case offline = "rb_offline"
        case online = "rb_online"
        case refresh = "rb_refresh"
        /// Вне §8: сообщение пришло в форме, которой эта версия SDK не знает.
        case unreadable = "rb_unreadable"
        /// Вне §8: вложение, которое не разобралось.
        case attachmentUnsupported = "rb_attachment_unsupported"
        /// Вне §8: объявление VoiceOver после прокрутки ленты тремя пальцами — формулировка
        /// как у системной («Страница N из M» / «Page N of M»).
        case pageOf = "rb_page_of"
        /// Вне §8: ярлык доступности плитки и обложки видео — «Видео, <длительность>, <имя>».
        case video = "rb_video"
        /// Вне §8: хвост ярлыка доступности плашки, пока файл грузится («IMG_0001.jpg, загружается»).
        case uploading = "rb_uploading"
    }

    static func languageCode(preferred: [String]) -> String {
        guard let first = preferred.first else { return "ru" }
        return first.lowercased().hasPrefix("en") ? "en" : "ru"
    }

    private static let currentLanguage: String = languageCode(preferred: Locale.preferredLanguages)

    /// Неизменяемый `let`: словарь собирается один раз лениво (гарантия рантайма Swift для
    /// глобальных `let`), дальше только читается. `static var` с дозаписью из разных потоков
    /// (вьюхи + колбэки ядра) был бы гонкой.
    private static let bundles: [String: Bundle] = {
        var map: [String: Bundle] = [:]
        for language in ["ru", "en"] {
            map[language] = Bundle.module.path(forResource: language, ofType: "lproj")
                .flatMap(Bundle.init(path:)) ?? Bundle.module
        }
        return map
    }()

    private static func bundle(for language: String) -> Bundle {
        bundles[language] ?? Bundle.module
    }

    static func string(_ key: Key, language: String) -> String {
        bundle(for: language).localizedString(forKey: key.rawValue, value: key.rawValue, table: nil)
    }

    static func t(_ key: Key) -> String { string(key, language: currentLanguage) }

    /// «Страница N из M» для `UIAccessibility.post(.pageScrolled, …)`.
    static func pageAnnouncement(page: Int, of count: Int, language: String = currentLanguage) -> String {
        String(format: string(.pageOf, language: language), page, count)
    }

    /// Полный снимок строк — передаётся в чистый маппер `ChatUiState.make(_:)`.
    static func strings(language: String = currentLanguage) -> Strings {
        Strings(
            title: string(.title, language: language),
            placeholder: string(.placeholder, language: language),
            send: string(.send, language: language),
            close: string(.close, language: language),
            failed: string(.failed, language: language),
            notConfigured: string(.notConfigured, language: language),
            attachment: string(.attachment, language: language),
            deleted: string(.deleted, language: language),
            attach: string(.attach, language: language),
            attachRemove: string(.attachRemove, language: language),
            attachMedia: string(.attachMedia, language: language),
            attachFile: string(.attachFile, language: language),
            attachTooBig: string(.attachTooBig, language: language),
            attachFailed: string(.attachFailed, language: language),
            attachLimit: string(.attachLimit, language: language),
            emptyHint: string(.emptyHint, language: language),
            cancelSending: string(.cancelSending, language: language),
            offline: string(.offline, language: language),
            online: string(.online, language: language),
            refresh: string(.refresh, language: language),
            unreadable: string(.unreadable, language: language),
            attachmentUnsupported: string(.attachmentUnsupported, language: language),
            video: string(.video, language: language),
            uploading: string(.uploading, language: language)
        )
    }
}

/// Снимок строк для чистой функции маппинга.
struct Strings: Equatable {
    var title: String
    var placeholder: String
    var send: String
    var close: String
    var failed: String
    var notConfigured: String
    var attachment: String
    var deleted: String
    var attach: String
    var attachRemove: String
    /// Пункты меню скрепки (§5 п. 6).
    var attachMedia: String
    var attachFile: String
    var attachTooBig: String
    var attachFailed: String
    var attachLimit: String
    var emptyHint: String
    var cancelSending: String
    var offline: String
    var online: String
    var refresh: String
    /// Подпись нечитаемого сообщения.
    var unreadable: String
    /// Подпись вложения-заглушки.
    var attachmentUnsupported: String
    /// Ярлык доступности видео.
    var video: String
    /// Хвост ярлыка доступности плашки, пока файл грузится.
    var uploading: String = ""
}
