import CoreGraphics
import Foundation

/// Превью вложений: чистые правила без UIKit и без ядра — формат длительности,
/// «это видео», размеры кадра и места в ленте, источники обложки. Единые правила с Android и веб-виджетом
/// (`widget.js`: `formatDuration`, `isVideoAttachment`, `videoPreview`).
enum MediaRules {

    // MARK: длительность

    /// Правило виджета дословно (`widget.js` `formatDuration`): `round(ms / 1000)` секунд, «м:сс», с часа — «ч:мм:сс».
    /// Нет длительности, ноль или меньше — `nil` (плашки длительности нет). Округление — половина вверх, как
    /// `Math.round` у положительных.
    static func formatDuration(ms: Int64?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let total = (ms + 500) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))"
        }
        return "\(minutes):\(twoDigits(seconds))"
    }

    private static func twoDigits(_ n: Int64) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }

    /// Ярлык доступности видео: «Видео, <длительность>, <имя>»; нет длительности или имени — без них.
    static func videoAccessibilityLabel(video: String, durationMs: Int64?, name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [video, formatDuration(ms: durationMs), trimmed?.isEmpty == false ? trimmed : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// Размер файла в подписи карточки документа — системный формат (`ByteCountFormatter`, стиль файлов), как
    /// `Formatter.formatShortFileSize` на Android.
    static func fileSizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    // MARK: «видео»

    /// Правило виджета (`widget.js` `isVideoAttachment`): вид `video` ИЛИ MIME `video/*`.
    static func isVideo(kindWire: String, mime: String?) -> Bool {
        if kindWire == "video" { return true }
        return mime?.lowercased().hasPrefix("video/") ?? false
    }

    // MARK: кадр видео при выборе файла

    /// Рекомендации сервера к обложке: до 640 px по длинной стороне, до 200 КБ, JPEG.
    static let frameMaxSide: CGFloat = 640
    static let frameMaxBytes = 200 * 1024
    static let frameMime = "image/jpeg"
    /// Миниатюра плитки над композером: 72 pt × 3 (самый плотный экран) — больше декодировать незачем.
    static let tileMaxPixels = 216

    /// Момент кадра — как у виджета (`seekToFrame`): `min(1 с, половина длительности)`, то есть всегда в первой
    /// секунде и не за концом короткого ролика. Длительность неизвестна (≤ 0, не число) — начало.
    static func frameTime(durationSeconds: Double) -> Double {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        return min(1, durationSeconds / 2)
    }

    /// Размер, вписанный по длинной стороне в `maxSide`, без увеличения; стороны — целые пиксели, не меньше 1
    /// (как `canvas` виджета: `Math.max(1, Math.round(w * scale))`). Пустой размер — `nil`.
    static func scaledToMaxSide(_ size: CGSize, maxSide: CGFloat) -> CGSize? {
        guard size.width > 0, size.height > 0, maxSide > 0 else { return nil }
        let k = min(1, maxSide / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * k).rounded()), height: max(1, (size.height * k).rounded()))
    }

    /// Размеры медиа в ориентации показа: `naturalSize` дорожки через её `preferredTransform` (поворот на 90° меняет
    /// стороны местами), по модулю. Пустое — `nil`.
    static func displaySize(natural: CGSize, transform: CGAffineTransform) -> (width: Int, height: Int)? {
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        let w = Int(abs(r.width).rounded())
        let h = Int(abs(r.height).rounded())
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// Ступени качества JPEG: первая — как у виджета (`toBlob(…, 0.8)`), дальше — пока не влезет в потолок.
    static let jpegQualities: [CGFloat] = [0.8, 0.7, 0.6, 0.5, 0.4]
    /// Не влезло ни на одной ступени — сторона кадра уменьшается в столько раз и попытка повторяется, но не ниже
    /// `frameMinSide` (дальше обложка бесполезна — вложение уходит без неё).
    static let frameShrinkFactor: CGFloat = 0.75
    static let frameMinSide: CGFloat = 160

    // MARK: место в ленте

    /// Обложка видео в ленте: ширина ВСЕГДА потолок картинки (`Theme.photoMaxWidth`), высота — по пропорциям
    /// `width`/`height` вложения (нет их — 16:9) в рамках обложки виджета (`.att-video`:
    /// `min-height 60`, `max-height 240`); что не влезло — срезается по центру (`scaleAspectFill`).
    /// Вертикальное видео не сужается — как Android, виджет и спека. Размер известен ДО загрузки кадра, поэтому
    /// строка ленты не прыгает.
    static func videoCoverSize(width: Int?, height: Int?, maxWidth: CGFloat, minHeight: CGFloat,
                               maxHeight: CGFloat) -> CGSize {
        let aspect: CGFloat
        if let width, let height, width > 0, height > 0 {
            aspect = CGFloat(width) / CGFloat(height)
        } else {
            aspect = 16.0 / 9.0
        }
        return CGSize(width: maxWidth, height: min(maxHeight, max(minHeight, maxWidth / aspect)))
    }

    // MARK: обложка своего видео

    /// Обложка своего видео лежит файлом рядом с локальной копией: тот же адрес плюс суффикс. Отдельного
    /// хранилища не нужно — адрес выводится из `localUri` вложения, которое ядро хранит в кэше беседы.
    static let localCoverSuffix = ".cover.jpg"

    static func localCoverUri(forLocalUri uri: String) -> String {
        uri + localCoverSuffix
    }

    /// Откуда брать обложку видео в ленте, по порядку: своя — файл рядом с локальной копией, если он есть;
    /// затем сервер, если у вложения есть `thumbnailBlobRef`. Пусто — обложки нет, рисуется прежняя ссылка.
    static func coverSources(localUri: String?, hasThumbnail: Bool,
                             localFileExists: (String) -> Bool) -> [CoverSource] {
        var sources: [CoverSource] = []
        if let localUri {
            let cover = localCoverUri(forLocalUri: localUri)
            if localFileExists(cover) { sources.append(.local(cover)) }
        }
        if hasThumbnail { sources.append(.server) }
        return sources
    }
}

/// Источник обложки видео в ленте.
enum CoverSource: Equatable {
    /// Файл обложки своего видео рядом с локальной копией (`revback-cache://…`).
    case local(String)
    /// `Conversation.attachmentThumbnail` — по адресу строки на сервере.
    case server
}
