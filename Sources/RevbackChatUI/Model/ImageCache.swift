import ImageIO
import UIKit

/// §5 п. 7 + §12 п. 45: бюджет памяти вложений экрана — паритет с Android по сути, а не по цифре.
/// Картинки ленты декодируются С ПОДВЫБОРКОЙ (как `decodeSampled` в `Attachments.kt`, `MAX_IMAGE_PX`),
/// стоимость записи в кэше — РАСПАКОВАННЫЕ байты (как `Bitmap.byteCount`), лимит — те же 20 МБ.
/// Байты для просмотрщика (`ChatModel.bytesCache`, §12 п. 3) — не второй LRU, а один последний файл.
enum AttachmentMemoryBudget {

    /// §5 п. 7: «кэш в памяти (LRU ~20 МБ)» — распакованные картинки ленты, как `LruCache` на Android.
    static let imageBytes = 20 * 1024 * 1024

    /// Просмотрщик держит ОДИН файл — тот, что открыт или открывался последним (§12 п. 3: побайтовый
    /// перевод `KotlinByteArray → Data` не повторяется при повторном тапе по той же ссылке). Потолок —
    /// размер одного вложения у ядра (`Branding.DEFAULT_MAX_FILE_SIZE` = 10 МБ, `Models.kt`).
    static let viewerFiles = 1
    static let viewerBytes = 10 * 1024 * 1024

    /// Как `MAX_IMAGE_PX = 800` на Android: там половинят, пока ОБЕ стороны не меньше порога, то есть
    /// длинная сторона остаётся < 1600 px. Здесь ImageIO ограничивает длинную сторону напрямую.
    static let maxImageSide = 1600
}

/// §5 п. 7: кэш картинок в памяти на время жизни экрана, LRU по распакованным байтам.
final class ImageCache {

    static let limitBytes = AttachmentMemoryBudget.imageBytes

    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.totalCostLimit = Self.limitBytes
    }

    static func key(messageId: String, index: Int32) -> NSString {
        "\(messageId)#\(index)" as NSString
    }

    func image(messageId: String, index: Int32) -> UIImage? {
        cache.object(forKey: Self.key(messageId: messageId, index: index))
    }

    func store(_ image: UIImage, messageId: String, index: Int32, cost: Int) {
        cache.setObject(image, forKey: Self.key(messageId: messageId, index: index), cost: cost)
    }

    /// Свои картинки из `localUri` — в том же кэше и том же бюджете §12 п. 43, под своим
    /// префиксом: ключ серверной картинки — `id#index`, своей — `local#uri`. `NSCache` потокобезопасен, запись идёт
    /// из фонового декодирования `ChatModel.localImage(uri:)`.
    static func localKey(uri: String) -> NSString {
        "local#\(uri)" as NSString
    }

    func localImage(uri: String) -> UIImage? {
        cache.object(forKey: Self.localKey(uri: uri))
    }

    func storeLocal(_ image: UIImage, uri: String, cost: Int) {
        cache.setObject(image, forKey: Self.localKey(uri: uri), cost: cost)
    }

    /// Обложка видео с сервера — в том же кэше и бюджете, но под СВОИМ ключом `thumb#id#index`: у той же
    /// пары (`id`, `index`) есть и сам файл, и обложка, их нельзя путать.
    static func thumbnailKey(messageId: String, index: Int32) -> NSString {
        "thumb#\(messageId)#\(index)" as NSString
    }

    func thumbnail(messageId: String, index: Int32) -> UIImage? {
        cache.object(forKey: Self.thumbnailKey(messageId: messageId, index: index))
    }

    func storeThumbnail(_ image: UIImage, messageId: String, index: Int32, cost: Int) {
        cache.setObject(image, forKey: Self.thumbnailKey(messageId: messageId, index: index), cost: cost)
    }

    /// Декодирование с подвыборкой (аналог `decodeSampled`): длинная сторона ≤ `maxSide`, битые байты —
    /// `nil`. Стоимость — распакованные байты (`bytesPerRow × height`), как `Bitmap.byteCount`.
    /// Звать ВНЕ главного потока: декодирование 12-Мп фото на main подвешивает прокрутку.
    static func decodeSampled(_ data: Data, maxSide: Int = AttachmentMemoryBudget.maxImageSide) -> (image: UIImage, cost: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF-поворот применяется, как у UIImage(data:)
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (UIImage(cgImage: cg), cg.bytesPerRow * cg.height)
    }
}
