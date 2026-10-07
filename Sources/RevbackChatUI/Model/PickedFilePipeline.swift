import Foundation

/// Итог подготовки одного выбранного файла.
enum PickOutcome: Equatable {
    case picked(PickedFile)
    case rejected(TransientError)
}

/// Один выбор файлов в пикере (`ChatModel.beginPick`): писать ли свою копию и куда доставить итог. Оба замыкания
/// зовутся на главном потоке.
struct PickSink {
    let writeCopy: Bool
    let picked: (PickedFile) -> Void
    let rejected: (TransientError) -> Void

    /// Итог всей пачки — сначала все плашки в порядке выбора, потом ОДИН отказ по старшинству лимит > размер > чтение
    /// (`DocumentPicker.worse`, единое правило с Android): плашка снимает полосу отказа, и отказ, доставленный между
    /// плашками, не показался бы вовсе. Главный поток.
    func deliver(_ outcomes: [PickOutcome]) {
        var worst: TransientError?
        for outcome in outcomes {
            switch outcome {
            case let .picked(file): picked(file)
            case let .rejected(error): worst = DocumentPicker.worse(worst, error)
            }
        }
        if let worst { rejected(worst) }
    }
}

/// Подготовка выбранного файла — общая для «Фото и видео» и «Файл»; исходный файл пикера ещё жив.
/// Порядок: размер по атрибутам файла → байты (или ужатие картинки сверх потолка прямо с файла) → перекодирование
/// картинки вне списка сервера (`ImageTranscoder`) → своя копия в кэше (только если её можно писать) → плашка и
/// превью → потолок каталога копий.
///
/// Превью снимается с копии, а без копии — с исходного файла, поэтому зовущий удаляет исходник только после этой
/// функции: иначе у файла без копии пропали бы миниатюра, размеры, кадр и длительность.
/// Синхронная — звать вне главного потока.
enum PickedFilePipeline {

    /// Файл больше `maxFileSize` до чтения байтов не доходит (видео на сотни мегабайт в память не тянем): неподвижная
    /// картинка ужимается прямо с файла (`ImageTranscoder.shrinkOversized`, решение — по заголовку), всё прочее —
    /// отказ «слишком большой». Размер неизвестен (каталог) — к чтению, там и откажет.
    static func prepare(source: URL, name: String, mime: String, maxFileSize: Int64, writeCopy: Bool,
                        caches: URL? = CacheUri.caches, fileManager fm: FileManager = .default) -> PickOutcome {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, Int64(size) > maxFileSize {
            let shrunk = MediaPreviewExtractor.serially {
                ImageTranscoder.shrinkOversized(url: source, name: name, maxBytes: maxFileSize)
            }
            guard case let .converted(newName, newMime, newData) = shrunk else { return .rejected(.tooBig) }
            return finish(source: source, data: newData, name: newName, mime: newMime, transcoded: true,
                          writeCopy: writeCopy, caches: caches, fileManager: fm)
        }
        guard let data = try? Data(contentsOf: source) else { return .rejected(.attachFailed) }
        return prepare(source: source, data: data, name: name, mime: mime, maxFileSize: maxFileSize,
                       writeCopy: writeCopy, caches: caches, fileManager: fm)
    }

    /// Байты уже прочитаны и в потолок укладываются.
    private static func prepare(source: URL, data: Data, name: String, mime: String, maxFileSize: Int64, writeCopy: Bool,
                        caches: URL? = CacheUri.caches, fileManager fm: FileManager = .default) -> PickOutcome {
        let transcoded = MediaPreviewExtractor.serially {
            ImageTranscoder.transcode(data: data, name: name, maxBytes: maxFileSize)
        }
        switch transcoded {
        case .unchanged:
            return finish(source: source, data: data, name: name, mime: mime, transcoded: false,
                          writeCopy: writeCopy, caches: caches, fileManager: fm)
        case .tooBig:
            return .rejected(.tooBig)
        case let .converted(newName, newMime, newData):
            return finish(source: source, data: newData, name: newName, mime: newMime, transcoded: true,
                          writeCopy: writeCopy, caches: caches, fileManager: fm)
        }
    }

    private static func finish(source: URL, data: Data, name: String, mime: String, transcoded: Bool,
                               writeCopy: Bool, caches: URL?, fileManager fm: FileManager) -> PickOutcome {
        // Своя копия (§5 п. 7) — из тех байтов, что уйдут на сервер: у перекодированной картинки свой пузырь
        // показывает то же, что увидит оператор.
        let localUri = writeCopy ? CacheUri.write(data, name: name, caches: caches, fileManager: fm) : nil
        let file = MediaPreviewExtractor.picked(name: name, mime: mime, data: data, localUri: localUri,
                                                source: source, transcoded: transcoded, caches: caches)
        // Потолок — после записи и копии, и обложки видео рядом с ней: только они и говорят, на сколько вырос каталог.
        if let localUri { CacheUri.trimCopies(keep: localUri, caches: caches, fileManager: fm) }
        return .picked(file)
    }
}
