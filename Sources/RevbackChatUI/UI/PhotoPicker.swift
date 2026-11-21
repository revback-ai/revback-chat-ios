import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// §5 п. 6: пункт «Фото и видео» меню скрепки — `PHPickerViewController` (фото/видео).
/// Пункт «Файл» — `DocumentPicker` (§12 п. 51); цепочка проверок у обоих одна.
struct PhotoPicker: UIViewControllerRepresentable {
    /// Начало выбора: зовётся на главном потоке в момент, когда файлы выбраны; отдаёт, писать ли копию, и куда
    /// доставить плашки и отказы (`ChatModel.beginPick`). Отказ ДО чтения байтов — лимит 10 файлов или размер больше
    /// `maxFileSize` (§6 строка 126), кроме неподвижных картинок: их ужимает `ImageTranscoder.shrinkOversized`.
    let begin: () -> PickSink
    /// Пикер закончил работу — вьюха снимает `showPicker`.
    let onFinish: () -> Void
    /// Сколько ещё файлов можно взять (§5 п. 6: лимит 10 на сообщение).
    let remaining: Int
    /// `branding.maxFileSize`: видео на сотни мегабайт нельзя читать в память.
    let maxFileSize: Int64

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = max(1, remaining)
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(begin: begin, onFinish: onFinish, remaining: remaining, maxFileSize: maxFileSize)
    }

    /// Тип, в котором брать файл у провайдера: сначала HEIC/HEIF, затем картинка, которую сервер понимает как картинку
    /// (`ImageTranscoder.serverImageTypes` — у пары RAW+JPEG это JPEG), затем любая другая картинка, затем видео.
    /// HEIC — первым: снимок iPhone медиатека отдаёт и системным JPEG в полном размере, а «Файл» — самим HEIC; взятый
    /// HEIC перекодируется (`ImageTranscoder`, размер по `targetLongSide`), и один и тот же снимок уходит одинаково из обоих
    /// пунктов. Порядок типов у провайдера не обещан (у Live Photo впереди бывает пакет снимка и ролика), а брать нужно
    /// файл, который понятен как фото или видео; пакеты-каталоги не берутся — их файлом не прочитать. Ничего — `nil`.
    static func fileType(of identifiers: [String]) -> String? {
        let types = identifiers.compactMap { id in UTType(id).map { (id, $0) } }.filter { !$0.1.conforms(to: .directory) }
        let heif = types.first { $0.1.conforms(to: .heic) || $0.1.conforms(to: .heif) }
        let server = types.first { type in ImageTranscoder.serverImageTypes.contains { type.1.conforms(to: $0) } }
        return heif?.0
            ?? server?.0
            ?? types.first { $0.1.conforms(to: .image) }?.0
            ?? types.first { $0.1.conforms(to: .movie) }?.0
    }

    /// Итоги одной пачки «Фото и видео»: провайдеры отвечают асинхронно и в любом порядке, и каждая плашка
    /// доставляется сразу, как готов её файл, — провайдер, который так и не ответил (оригинал в iCloud без сети),
    /// теряет только свой файл и остальных не держит. Отказ у пачки один, по старшинству лимит > размер > чтение
    /// (`DocumentPicker.worse`, единое правило с Android): новый отказ поднимает полосу до старшего из пришедших, а
    /// плашка, которая полосу снимает, поднимает его заново. Байты и копии файлов здесь не копятся — только отметки
    /// «итог пришёл» и старший отказ. Только главный поток.
    final class Batch {
        private let sink: PickSink
        private var finished: [Bool]
        private var worst: TransientError?

        init(sink: PickSink, count: Int) {
            self.sink = sink
            finished = Array(repeating: false, count: count)
        }

        func finish(_ index: Int, _ outcome: PickOutcome) {
            guard finished.indices.contains(index), !finished[index] else { return }
            finished[index] = true
            switch outcome {
            case let .picked(file):
                sink.picked(file)
                if let worst { sink.rejected(worst) }
            case let .rejected(error):
                let senior = DocumentPicker.worse(worst, error)
                worst = senior
                sink.rejected(senior)
            }
        }
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let begin: () -> PickSink
        private let onFinish: () -> Void
        private let remaining: Int
        private let maxFileSize: Int64

        init(begin: @escaping () -> PickSink,
             onFinish: @escaping () -> Void,
             remaining: Int,
             maxFileSize: Int64) {
            self.begin = begin
            self.onFinish = onFinish
            self.remaining = remaining
            self.maxFileSize = maxFileSize
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // `picker.dismiss` здесь НЕ зовём — лист принадлежит вьюхе.
            // Координатор закрыл бы контроллер, а `@State showPicker` остался бы `true`,
            // и второй тап по скрепке уже ничего не открыл бы. Закрывает `onFinish`.
            onFinish()
            handle(results.map(\.itemProvider))
        }

        /// Выбранные файлы по провайдерам (с главного потока). Отдельно от делегата — чтобы проверить на своих
        /// провайдерах без системного пикера.
        func handle(_ providers: [NSItemProvider]) {
            guard !providers.isEmpty else { return }
            // Настройка хранения и поколение экрана — на момент выбора.
            let sink = begin()
            let maxFileSize = self.maxFileSize
            // Порядок проверок — СНАЧАЛА лимит 10 чипов, ПОТОМ размер (единое правило с Android): лишние
            // файлы дают отказ `.limit` — старший у пачки, и полоса держит его до конца.
            let taken = providers.prefix(max(0, remaining))
            let overLimit = providers.count > taken.count
            let batch = Batch(sink: sink, count: taken.count + (overLimit ? 1 : 0))
            if overLimit { batch.finish(taken.count, .rejected(.limit)) }

            for (i, provider) in taken.enumerated() {
                guard let uti = PhotoPicker.fileType(of: provider.registeredTypeIdentifiers) else {
                    batch.finish(i, .rejected(.attachFailed))
                    continue
                }
                let finish: (PickOutcome) -> Void = { outcome in DispatchQueue.main.async { batch.finish(i, outcome) } }
                // Замыкание держит итоги пачки (а через них `sink`) сильно, а не координатор: лист закрыт уже
                // сейчас, и координатор может освободиться раньше, чем система отдаст файл (фото из iCloud,
                // перекодирование видео) — файл пропал бы молча.
                provider.loadFileRepresentation(forTypeIdentifier: uti) { url, _ in
                    // Файла нет — фото из iCloud не докачалось, доступ отозван и т. п.
                    // §6 строка 126: молчать нельзя, чипа не будет, и тап по скрепке
                    // выглядел бы как «ничего не произошло».
                    guard let url else {
                        finish(.rejected(.attachFailed))
                        return
                    }
                    // url живёт только внутри замыкания — читаем и готовим сразу (уже не на main)
                    let name = url.lastPathComponent.isEmpty
                        ? (provider.suggestedName ?? "attachment")
                        : url.lastPathComponent
                    let mime = UTType(uti)?.preferredMIMEType ?? "application/octet-stream"
                    // §5 п. 7: файл пикера исчезает вместе с замыканием, поэтому своя копия
                    // в кэше — её адрес уезжает в `FileSource.localUri`, и свой пузырь
                    // показывает картинку сразу, не качая её обратно с сервера.
                    // §12 п. 27: адрес ОТНОСИТЕЛЬНЫЙ (`revback-cache://…`, см. `CacheUri`).
                    // Плашка и превью — здесь же, вне main и пока файл пикера жив; перекодирование и извлечения
                    // идут по одному (последовательная очередь `MediaPreviewExtractor`), хотя замыкания провайдеров
                    // параллельны.
                    // Размер — из атрибутов файла ДО чтения байтов (внутри `prepare`): видео на сотни
                    // мегабайт в память не тянем, картинку сверх потолка ужимает `ImageTranscoder` прямо с файла.
                    finish(PickedFilePipeline.prepare(source: url, name: name, mime: mime,
                                                      maxFileSize: maxFileSize, writeCopy: sink.writeCopy))
                }
            }
        }
    }
}
