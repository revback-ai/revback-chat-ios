import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Вид плашки над композером: плитка фото, плитка видео, карточка документа.
enum ChipKind: Equatable {
    case photo
    case video
    case file

    /// По MIME выбранного файла: `image/*` — фото, `video/*` — видео, остальное — документ.
    static func of(mime: String) -> ChipKind {
        let m = mime.lowercased()
        if m.hasPrefix("image/") { return .photo }
        if m.hasPrefix("video/") { return .video }
        return .file
    }
}

/// Данные плашки: едут к экрану через `onPicked` отдельно от превью для ядра.
struct ChipMedia: Equatable {
    var kind: ChipKind
    /// Миниатюра плитки (фото — сама картинка, видео — кадр); `nil` — плитка-заглушка.
    var tile: UIImage?
    /// Размер файла в байтах — подпись карточки документа (`ByteCountFormatter`).
    var byteCount: Int64
    /// Длительность видео; `nil` — плашки длительности нет.
    var durationMs: Int64?

    static func file(byteCount: Int64) -> ChipMedia {
        ChipMedia(kind: .file, tile: nil, byteCount: byteCount, durationMs: nil)
    }
}

/// Превью для ядра (`MediaPreview` ядра собирает `LiveChatBackend`): типов Kotlin здесь нет — модель и фейк их не знают.
struct UploadPreview: Equatable {
    /// Кадр-обложка видео (JPEG); у фото `nil` — миниатюра плитки на сервер не едет.
    var thumbnail: Data?
    var thumbnailMime: String?
    var durationMs: Int64?
    /// Размеры в ориентации показа.
    var width: Int?
    var height: Int?
}

/// Выбранный файл целиком: имя, MIME, байты и локальная копия, плюс плашка и превью.
struct PickedFile: Equatable {
    var name: String
    var mime: String
    var data: Data
    var localUri: String?
    var media: ChipMedia
    var preview: UploadPreview?
}

/// Снятие превью при выборе файла: фото — размеры и миниатюра через ImageIO,
/// видео — `AVAssetImageGenerator` (кадр из первой секунды, `maximumSize`, `appliesPreferredTrackTransform`),
/// длительность `AVAsset.duration`, размеры с учётом `preferredTransform`. Кадр ужимается до ≤ 640 px и JPEG ≤ 200 КБ
/// и кладётся файлом рядом с локальной копией. Кадр не снялся — длительность и размеры всё равно уходят (без
/// обложки, как Android и виджет), плитка-заглушка; не извлеклось ничего — без превью.
///
/// Звать ВНЕ главного потока: всё синхронно. Извлечения идут строго по одному — через последовательную очередь
/// (`PHPicker` отдаёт файлы параллельно, а кадр видео держит в памяти декодер).
enum MediaPreviewExtractor {

    private static let queue = DispatchQueue(label: "ai.revback.chat.ui.media-preview", qos: .userInitiated)

    /// Работа с полным кадром картинки — по одной за раз, на той же очереди, что и извлечения, с освобождением памяти
    /// сразу по выходе. Внутри `extract` звать нельзя: очередь последовательная.
    static func serially<T>(_ body: () -> T) -> T {
        queue.sync { autoreleasepool(invoking: body) }
    }

    /// Плашка и превью для файла `url` (живой файл пикера или локальная копия). `coverUrl` — куда положить кадр
    /// своего видео (рядом с локальной копией, `MediaRules.localCoverUri`); `nil` — не класть.
    static func extract(url: URL, mime: String, byteCount: Int64, coverUrl: URL?) -> (ChipMedia, UploadPreview?) {
        queue.sync {
            switch ChipKind.of(mime: mime) {
            case .photo: return photo(url: url, byteCount: byteCount)
            case .video: return video(url: url, byteCount: byteCount, coverUrl: coverUrl)
            case .file: return (.file(byteCount: byteCount), nil)
            }
        }
    }

    /// Готовый `PickedFile`: превью снимается с локальной копии, если она есть (её же адрес уйдёт в ядро), иначе —
    /// с исходного файла пикера (`source`). Ни того, ни другого — плашка по MIME без миниатюры, без превью.
    /// Без копии обложка видео на диск не пишется — она уходит только в превью для ядра. `transcoded` — байты `data` уже
    /// не те, что в исходнике (`ImageTranscoder`): без копии превью картинки снимается с них, иначе размеры ушли бы на
    /// сервер от неужатого оригинала.
    static func picked(name: String, mime: String, data: Data, localUri: String?, source: URL?,
                       transcoded: Bool = false, caches: URL? = CacheUri.caches) -> PickedFile {
        let byteCount = Int64(data.count)
        let copy = localUri.flatMap { CacheUri.resolve($0, caches: caches) }
        let cover = localUri.flatMap { CacheUri.resolve(MediaRules.localCoverUri(forLocalUri: $0), caches: caches) }
        if copy == nil, transcoded, ChipKind.of(mime: mime) == .photo {
            let (media, preview) = queue.sync {
                photo(source: CGImageSourceCreateWithData(data as CFData, nil), byteCount: byteCount)
            }
            return PickedFile(name: name, mime: mime, data: data, localUri: localUri, media: media, preview: preview)
        }
        guard let url = copy ?? source else {
            let media = ChipMedia(kind: ChipKind.of(mime: mime), tile: nil, byteCount: byteCount, durationMs: nil)
            return PickedFile(name: name, mime: mime, data: data, localUri: localUri, media: media, preview: nil)
        }
        let (media, preview) = extract(url: url, mime: mime, byteCount: byteCount, coverUrl: cover)
        return PickedFile(name: name, mime: mime, data: data, localUri: localUri, media: media, preview: preview)
    }

    // MARK: фото

    private static func photo(url: URL, byteCount: Int64) -> (ChipMedia, UploadPreview?) {
        photo(source: CGImageSourceCreateWithURL(url as CFURL, nil), byteCount: byteCount)
    }

    private static func photo(source: CGImageSource?, byteCount: Int64) -> (ChipMedia, UploadPreview?) {
        let placeholder = ChipMedia(kind: .photo, tile: nil, byteCount: byteCount, durationMs: nil)
        guard let source else { return (placeholder, nil) }
        let tile = thumbnail(source: source, maxPixels: MediaRules.tileMaxPixels).map { UIImage(cgImage: $0) }
        let media = ChipMedia(kind: .photo, tile: tile, byteCount: byteCount, durationMs: nil)
        guard let size = displayPixelSize(source: source) else { return (media, nil) }
        return (media, UploadPreview(thumbnail: nil, thumbnailMime: nil, durationMs: nil,
                                     width: size.width, height: size.height))
    }

    /// Размер картинки в ориентации показа: EXIF-ориентации 5–8 поворачивают на 90°.
    static func displayPixelSize(source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (h, w) : (w, h)
    }

    private static func thumbnail(source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: видео

    /// Снятие кадра: `AVAssetImageGenerator` из первой секунды. Подменяют только тесты (сбой кадра при живой дорожке).
    typealias FrameGrabber = (AVAsset, Double) -> CGImage?

    static let systemFrameGrabber: FrameGrabber = { asset, seconds in
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: MediaRules.frameMaxSide, height: MediaRules.frameMaxSide)
        let at = MediaRules.frameTime(durationSeconds: seconds)
        // Кадр — из первой секунды: раньше момента можно сколько угодно (ключевой кадр в начале), позже — до 1 с.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = CMTime(seconds: max(0, 1 - at), preferredTimescale: 600)
        do {
            return try generator.copyCGImage(at: CMTime(seconds: at, preferredTimescale: 600), actualTime: nil)
        } catch {
            NSLog("[RevbackChatUI] кадр видео не снят: %@", error.localizedDescription)
            return nil
        }
    }

    static func video(url: URL, byteCount: Int64, coverUrl: URL?,
                      grabFrame: FrameGrabber = systemFrameGrabber) -> (ChipMedia, UploadPreview?) {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        // Как виджет и Android: длительность, размеры и кадр — по отдельности; что известно, то и
        // уходит ядру. Нет ничего — без превью.
        let durationMs = seconds.isFinite && seconds > 0 ? Int64((seconds * 1000).rounded()) : nil
        let size = asset.tracks(withMediaType: .video).first.flatMap {
            MediaRules.displaySize(natural: $0.naturalSize, transform: $0.preferredTransform)
        }
        let frame = size == nil ? nil : grabFrame(asset, durationMs == nil ? 0 : seconds)
        let jpeg = frame.flatMap {
            FrameJPEG.encode($0, maxSide: MediaRules.frameMaxSide, maxBytes: MediaRules.frameMaxBytes)
        }
        if frame != nil, jpeg == nil {
            NSLog("[RevbackChatUI] кадр видео не уложился в потолок обложки — без неё")
        }
        let media = ChipMedia(kind: .video,
                              tile: jpeg.flatMap { ImageCache.decodeSampled($0, maxSide: MediaRules.tileMaxPixels)?.image },
                              byteCount: byteCount, durationMs: durationMs)
        guard let jpeg else {
            guard durationMs != nil || size != nil else { return (media, nil) }
            return (media, UploadPreview(thumbnail: nil, thumbnailMime: nil, durationMs: durationMs,
                                         width: size?.width, height: size?.height))
        }

        if let coverUrl {
            // Обложка своего видео — файлом рядом с копией: лента не достаёт кадр при каждом показе.
            // Не записалась — лента возьмёт обложку с сервера, превью от этого не страдает.
            do {
                try jpeg.write(to: coverUrl, options: .atomic)
            } catch {
                NSLog("[RevbackChatUI] обложка видео не записана рядом с копией: %@", error.localizedDescription)
            }
        }
        return (media, UploadPreview(thumbnail: jpeg, thumbnailMime: MediaRules.frameMime, durationMs: durationMs,
                                     width: size?.width, height: size?.height))
    }
}

/// Ужатие кадра до JPEG по рекомендациям сервера: длинная сторона ≤ `maxSide`, файл ≤ `maxBytes`. Сначала ступени
/// качества (`MediaRules.jpegQualities`), не влезло — сторона меньше в `frameShrinkFactor` раз, не ниже
/// `frameMinSide`. Не влезло совсем — `nil` (вложение уходит без обложки).
enum FrameJPEG {

    static func encode(_ image: CGImage, maxSide: CGFloat, maxBytes: Int) -> Data? {
        var side = min(maxSide, CGFloat(max(image.width, image.height)))
        while true {
            guard let size = MediaRules.scaledToMaxSide(CGSize(width: image.width, height: image.height),
                                                        maxSide: side),
                  let scaled = render(image, size: size) else { return nil }
            for quality in MediaRules.jpegQualities {
                if let data = jpeg(scaled, quality: quality), data.count <= maxBytes { return data }
            }
            let next = (side * MediaRules.frameShrinkFactor).rounded(.down)
            guard next >= MediaRules.frameMinSide, next < side else { return nil }
            side = next
        }
    }

    private static func render(_ image: CGImage, size: CGSize) -> CGImage? {
        if CGFloat(image.width) == size.width && CGFloat(image.height) == size.height { return image }
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
