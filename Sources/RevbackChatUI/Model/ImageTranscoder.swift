import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Подготовка выбранной картинки к загрузке. Правило — тяжёлое ужимается до размера, который доезжает по слабой
/// мобильной сети (скриншот PNG 6,6 МБ на ней обрывался посреди заливки), лёгкое не трогается:
///
/// - Размер (`targetLongSide`, общее с Android): скриншот телефона (короткая ≤ 1290, длинная ≤ 4096) по размеру не
///   уменьшается; остальное — до ~5 Мп и длинной стороны 4096; если короткая вышла бы < 750 (скриншот-прокрутка) —
///   длинной разрешено до 8192.
/// - Неподвижная картинка в формате из списка сервера (`serverImageTypes`) ≤ `shrinkBytes`, которую по размеру
///   уменьшать не нужно, уходит как есть — те же байты. Иначе — перекодируется (`transcode`): JPEG
///   (с настоящей прозрачностью — PNG), размер по правилу, ступени качества. Вышло не меньше исходника, а
///   уменьшать по размеру было нечего — уходит исходник. GIF и многокадровые (APNG, анимированный WebP) — как есть.
/// - Картинка вне списка (HEIC с iPhone, TIFF и т. п.) перекодируется всегда: сервер хранит её как поток байтов,
///   и вложение превращается в документ — у клиента в пузыре имя файла вместо фото, у оператора файл, который браузер
///   не откроет. Уходит JPEG (с прозрачностью — PNG), размер по правилу, ступени качества.
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
    static let jpegQualities: [CGFloat] = [0.8, 0.7, 0.55, 0.4]

    /// Потолок площади: больше ~5 Мп (2560×1960) — уменьшается до него. Фото с камеры 4032×3024 → 2582×1937.
    static let maxPixels = 5_000_000
    /// Потолок длинной стороны (панорамы).
    static let maxLongSide = 4096
    /// Не уменьшается по размеру вовсе: обычный скриншот телефона — короткая ≤ `phoneShortSide`, длинная ≤ `maxLongSide`.
    static let phoneShortSide = 1290
    /// Мягкая граница короткой стороны: вышла бы ниже — длинной разрешено до `tallLongSide`, и текст прокрутки
    /// остаётся читаемым (1290×9000 → 847×5906). Не гарантия: очень длинная полоса (1290×20000 → 528×8192)
    /// всё равно выйдет уже 750.
    static let minShortSide = 750
    static let tallLongSide = 8192

    /// Картинка из списка сервера тяжелее этого (~1,5 МБ) перекодируется, даже если по размеру уменьшать не нужно.
    /// Общий с Android (`IMAGE_SHRINK_BYTES`).
    static let shrinkBytes: Int64 = 1_536 * 1_024

    /// Длинная сторона после уменьшения (равна исходной — уменьшать не нужно). Правило общее с Android
    /// (`imageTargetLongSide`): скриншот телефона не трогается; иначе масштаб = min(1, √(5 Мп / площадь),
    /// 4096 / длинная); вышла короткая < 750 — тот же расчёт с 8192 вместо 4096. Меньшая картинка не растягивается.
    static func targetLongSide(width: Int, height: Int) -> Int {
        let long = max(width, height), short = min(width, height)
        guard long > 0, short > 0 else { return long }
        if short <= phoneShortSide, long <= maxLongSide { return long }
        let byArea = (Double(maxPixels) / (Double(width) * Double(height))).squareRoot()
        var scale = min(1, byArea, Double(maxLongSide) / Double(long))
        if Double(short) * scale < Double(minShortSide) {
            scale = min(1, byArea, Double(tallLongSide) / Double(long))
        }
        return max(1, Int((Double(long) * scale).rounded()))
    }

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

    /// Картинка вне списка сервера — в JPEG или PNG; из списка сервера — ужатие тяжёлой (`needsShrinking`), лёгкая,
    /// GIF, многокадровая и не-картинки — как есть.
    ///
    /// Геометка (GPS из EXIF) оператору не уходит: перекодированное пишется без метаданных вовсе, а картинка «как есть»
    /// с GPS копируется без него (`withoutGPS`) — те же сжатые данные, без пережатия.
    static func transcode(data: Data, name: String, maxBytes: Int64) -> Result {
        let result = shrinkOrConvert(data: data, name: name, maxBytes: maxBytes)
        guard result == .unchanged, let source = CGImageSourceCreateWithData(data as CFData, nil), hasGPS(source)
        else { return result }
        if let stripped = withoutGPS(source), let mime = mimeOf(source) {
            return .converted(name: name, mime: mime, data: stripped)
        }
        // Копия без GPS не вышла — неподвижная перекодируется (метаданные не переносятся); многокадровую без потери
        // анимации не перекодировать — уходит как есть.
        guard isShrinkableStill(source), let image = uprightFirstFrame(source),
              case let .converted(newName, newMime, encoded)? = encodeWithin(image, name: name, maxBytes: maxBytes)
        else { return .unchanged }
        return .converted(name: newName, mime: newMime, data: encoded)
    }

    /// Есть ли геометка у какого-либо кадра.
    static func hasGPS(_ source: CGImageSource) -> Bool {
        (0..<CGImageSourceGetCount(source)).contains { index in
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return props?[kCGImagePropertyGPSDictionary] != nil
        }
    }

    /// Те же сжатые данные без GPS (`CGImageDestinationCopyImageSource` не пережимает кадры); не вышло — nil.
    static func withoutGPS(_ source: CGImageSource) -> Data? {
        guard let type = CGImageSourceGetType(source) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, CGImageSourceGetCount(source), nil) else {
            return nil
        }
        // Одного `ShouldExcludeGPS` мало: копия тогда теряет весь {Exif}/{TIFF}, а с ним ориентацию — снимок «на боку»
        // лёг бы набок. Метаданные исходника передаются явно, GPS из них снимается тем же ключом.
        var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            options[kCGImageDestinationMetadata] = metadata
        }
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil) else { return nil }
        // Проверка, а не вера: копия с геометкой или с другой ориентацией не годится — тогда пережатие с разворотом.
        guard let copy = CGImageSourceCreateWithData(data, nil), !hasGPS(copy),
              orientation(copy) == orientation(source) else { return nil }
        return data as Data
    }

    /// EXIF-ориентация первого кадра; тега нет — 1.
    static func orientation(_ source: CGImageSource) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    private static func mimeOf(_ source: CGImageSource) -> String? {
        (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredMIMEType }
    }

    private static func shrinkOrConvert(data: Data, name: String, maxBytes: Int64) -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .unchanged }
        if needsTranscoding(source) {
            guard let image = uprightFirstFrame(source) else { return .unchanged }
            return encodeWithin(image, name: name, maxBytes: maxBytes) ?? .unchanged
        }
        guard needsShrinking(source, byteCount: Int64(data.count)), let image = uprightFirstFrame(source) else {
            return .unchanged
        }
        // Исходник и так в потолке: ужатие, которое не влезло (`.tooBig`) или не закодировалось, — не повод отказывать.
        let result = encodeWithin(image, name: name, maxBytes: maxBytes) ?? .unchanged
        guard case let .converted(_, _, encoded) = result else { return .unchanged }
        // Сторона в пределах, а перекодированное не меньше исходника (JPEG, уже сжатый сильнее 0,8) — смысла нет.
        if !needsResize(source), encoded.count >= data.count { return .unchanged }
        return result
    }

    /// Картинка из списка сервера, которую стоит ужать: неподвижная, не GIF, и файл больше `shrinkBytes` или размер
    /// больше правила `targetLongSide`.
    static func needsShrinking(_ source: CGImageSource, byteCount: Int64) -> Bool {
        guard isShrinkableStill(source),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), !type.conforms(to: .gif) else { return false }
        return byteCount > shrinkBytes || needsResize(source)
    }

    /// Размер первого кадра в хранимых пикселях; не прочитался — nil.
    static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// Правило `targetLongSide` требует уменьшить.
    static func needsResize(_ source: CGImageSource) -> Bool {
        guard let size = pixelSize(source) else { return false }
        return targetLongSide(width: size.width, height: size.height) < max(size.width, size.height)
    }

    /// Файл больше потолка (`maxBytes`): неподвижная картинка любого формата, который читает ImageIO, ужимается по
    /// правилу `targetLongSide` и по ступеням качества в JPEG (PNG при настоящей прозрачности) — декодирование прямо с `url`, файл в
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

    /// Первый кадр, уменьшенный по правилу `targetLongSide` и повёрнутый по EXIF-ориентации: у JPEG на выходе
    /// ориентация 1, и снимок «на боку» стоит правильно в любом просмотрщике, в том числе в тех, что тег ориентации не
    /// читают. Кадр декодируется сразу уменьшенным — полного снимка в памяти не бывает. У многокадровых (HEIC-серии)
    /// остаётся первый кадр.
    private static func uprightFirstFrame(_ source: CGImageSource) -> CGImage? {
        var side = maxLongSide
        if let size = pixelSize(source) {
            side = targetLongSide(width: size.width, height: size.height)
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
