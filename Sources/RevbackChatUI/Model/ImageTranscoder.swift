import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Подготовка выбранной картинки к загрузке. Правило — картинку пользователя не трогать без необходимости:
///
/// - Картинка в формате из списка сервера (`serverImageTypes`), файл которой укладывается в потолок размера, уходит как
///   есть — те же байты, любой размер в пикселях: длинный скриншот или панорама не ужимаются.
/// - Картинка вне списка (HEIC с iPhone, TIFF и т. п.) перекодируется (`transcode`): сервер хранит её как поток байтов,
///   и вложение превращается в документ — у клиента в пузыре имя файла вместо фото, у оператора файл, который браузер
///   не откроет. Уходит JPEG (с прозрачностью — PNG), большая сторона до `maxSide`, ступени качества.
/// - Неподвижная картинка любого формата, который читает ImageIO (JPEG, PNG, HEIC/HEIF, WebP, BMP, AVIF, TIFF…),
///   файл которой больше потолка, ужимается по тем же правилам прямо с файла, не поднимая его в память
///   (`shrinkOversized`); не влезло — отказ «слишком большой». Анимированные и многокадровые сверх потолка и
///   не-картинки сверх потолка — тоже отказ.
///
/// Прозрачность — по пикселям, а не по наличию альфа-канала: снимок iPhone (HEIC, 10 бит, портрет) декодируется с
/// альфа-каналом и при полностью непрозрачном содержимом, и в PNG он стал бы в разы больше. PNG, не влезший в потолок,
/// уходит в JPEG по тем же ступеням качества — прозрачное ложится на белый фон.
///
/// Решение — по содержимому (`CGImageSourceGetType`), а не по имени и не по типу, которым файл отдал пикер: один и тот
/// же снимок приходит и из «Фото и видео», и из «Файл», с любым расширением. Не-картинки (PDF и прочее) и файлы,
/// которые ImageIO не читает, не трогаются — уходят как есть.
///
/// Чистая и синхронная: звать вне главного потока. Пикеры зовут её через `MediaPreviewExtractor.serially` — по одной
/// картинке за раз, декодированный кадр в памяти держит только она.
enum ImageTranscoder {

    /// Картинки, которые сервер принимает как картинки.
    static let serverImageTypes: [UTType] = [.png, .jpeg, .gif, .webP, .bmp] + [UTType("public.avif")].compactMap { $0 }

    /// Ступени качества JPEG: первая — обычное качество перекодирования; не влезло в потолок размера — следующая
    /// (как у кадра-обложки, `FrameJPEG`). Не влезло ни на одной — отказ «файл слишком большой».
    static let jpegQualities: [CGFloat] = [0.85, 0.7, 0.55, 0.4]

    /// Большая сторона перекодированной или ужатой картинки. Оператору нужно фото для просмотра, а не оригинал на 48 Мп:
    /// кадр декодируется сразу ужатым, и в памяти не бывает полного снимка. Меньшая картинка не растягивается.
    static let maxSide = 4096

    /// Большая сторона уменьшенной копии, по которой ищутся прозрачные пиксели.
    static let alphaProbeSide = 512

    static let jpegMime = "image/jpeg"
    static let pngMime = "image/png"

    enum Result: Equatable {
        /// Перекодировать не нужно или нечем — файл уходит как есть.
        case unchanged
        case converted(name: String, mime: String, data: Data)
        /// Перекодированное или ужатое не влезло в потолок размера ни на одной ступени качества (или ужать нельзя).
        case tooBig
    }

    /// Картинка вне списка сервера — в JPEG или PNG; из списка сервера и не-картинки — как есть.
    static func transcode(data: Data, name: String, maxBytes: Int64) -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), needsTranscoding(source),
              let image = uprightFirstFrame(source) else { return .unchanged }
        return encodeWithin(image, name: name, maxBytes: maxBytes) ?? .unchanged
    }

    /// Файл больше потолка (`maxBytes`): неподвижная картинка любого формата, который читает ImageIO, ужимается до
    /// `maxSide` и по ступеням качества в JPEG (PNG при настоящей прозрачности) — декодирование прямо с `url`, файл в
    /// память целиком не читается. Итог — `.converted` или `.tooBig`: многокадровое и не картинка сверх потолка не
    /// проходят.
    static func shrinkOversized(url: URL, name: String, maxBytes: Int64) -> Result {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options), isShrinkableStill(source),
              let image = uprightFirstFrame(source) else { return .tooBig }
        return encodeWithin(image, name: name, maxBytes: maxBytes) ?? .tooBig
    }

    /// Неподвижная (один кадр) картинка — тип по содержимому. Решается по заголовку файла.
    static func isShrinkableStill(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) == 1,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return false }
        return type.conforms(to: .image)
    }

    /// Картинка вне списка сервера. Тип по содержимому, а не по имени файла.
    static func needsTranscoding(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              type.conforms(to: .image) else { return false }
        return !serverImageTypes.contains { type.conforms(to: $0) }
    }

    /// Кадр — в PNG при настоящей прозрачности, иначе (или PNG не влез) в JPEG по ступеням качества. Не влезло ни на
    /// одной — `.tooBig`; не закодировалось вовсе — `nil`.
    private static func encodeWithin(_ image: CGImage, name: String, maxBytes: Int64) -> Result? {
        var encoded = false
        if isTranslucent(image), let png = encode(image, type: .png, quality: nil) {
            if Int64(png.count) <= maxBytes {
                return .converted(name: renamed(name, ext: "png"), mime: pngMime, data: png)
            }
            encoded = true
        }
        for quality in jpegQualities {
            guard let jpeg = encode(image, type: .jpeg, quality: quality) else { continue }
            encoded = true
            if Int64(jpeg.count) <= maxBytes {
                return .converted(name: renamed(name, ext: "jpg"), mime: jpegMime, data: jpeg)
            }
        }
        return encoded ? .tooBig : nil
    }

    /// Первый кадр, ужатый по большей стороне до `maxSide` и повёрнутый по EXIF-ориентации: у JPEG на выходе
    /// ориентация 1, и снимок «на боку» стоит правильно в любом просмотрщике, в том числе в тех, что тег ориентации не
    /// читают. У многокадровых (HEIC-серии) остаётся первый кадр.
    private static func uprightFirstFrame(_ source: CGImageSource) -> CGImage? {
        var side = maxSide
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           w > 0, h > 0 {
            side = min(max(w, h), maxSide)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Есть ли в картинке хоть один не полностью непрозрачный пиксель. Без альфа-канала — нет; с ним — смотрится
    /// альфа уменьшенной копии (`alphaProbeSide`), чтобы не держать в памяти второй кадр в полном размере.
    static func isTranslucent(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: break
        case .none, .noneSkipFirst, .noneSkipLast: return false
        @unknown default: return false
        }
        let scale = min(1, Double(alphaProbeSide) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        // RGBA, альфа — последний байт пикселя; холст прозрачный (очищен явно: содержимое выделенной памяти не
        // обещано), непрозрачная картинка закрашивает его весь в 255. Усреднение при уменьшении оставляет
        // прозрачному участку альфу ниже 255, а не теряет его между выборками.
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = ctx.data else { return true }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = CGInterpolationQuality.high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = pixels.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        for row in 0..<h {
            let line = bytes + row * ctx.bytesPerRow
            for x in 0..<w where line[x * 4 + 3] < 255 { return true }
        }
        return false
    }

    /// У JPEG альфы нет: фон под прозрачным задан явно — белый, а не на усмотрение кодера.
    private static func encode(_ image: CGImage, type: UTType, quality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        if type == .jpeg { options[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1) }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// `IMG_0001.HEIC` → `IMG_0001.jpg`; без расширения — расширение дописывается.
    static func renamed(_ name: String, ext: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? "attachment" : base) + "." + ext
    }
}
