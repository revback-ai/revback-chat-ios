import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// §5 п. 6: пункт «Файл» меню скрепки — системный `UIDocumentPickerViewController` (§12 п. 51:
/// меню «Фото и видео» / «Файл» одинаковое на обеих платформах).
/// Сигнатура и цепочка проверок — те же, что у `PhotoPicker`: лимит 10 → подготовка файла (`PickedFilePipeline`:
/// размер ДО чтения, байты) → плашка на главном потоке.
struct DocumentPicker: UIViewControllerRepresentable {
    /// Начало выбора: зовётся на главном потоке в момент, когда файлы выбраны; отдаёт, писать ли копию, и куда
    /// доставить плашки и отказ (`ChatModel.beginPick`).
    let begin: () -> PickSink
    /// Пикер закончил работу — вьюха снимает лист.
    let onFinish: () -> Void
    /// Сколько ещё файлов можно взять (§5 п. 6: лимит 10 на сообщение).
    let remaining: Int
    /// `branding.maxFileSize`: файл на сотни мегабайт нельзя читать в память.
    let maxFileSize: Int64

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `.data` — «любой файл», но НЕ каталог (`.item` включал бы папки: Files дал бы выбрать папку,
        // `asCopy` скопировал бы её во tmp целиком, а отказ пришёл бы только на чтении байтов). Пакеты-каталоги (`.pages`, `.key`) проходят как папки →
        // `attachFailed`, это осознанно (§12 п. 51).
        // `asCopy: true` — система отдаёт СВОЮ копию во tmp приложения; после копирования в кэш она снимается.
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        // Сам пикер число выбранных не ограничивает — лишние режет `process` по `remaining`.
        vc.allowsMultipleSelection = remaining > 1
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(begin: begin, onFinish: onFinish, remaining: remaining, maxFileSize: maxFileSize)
    }

    /// Обработка выбранных урлов по порядку (звать ВНЕ главного потока — чтение байтов синхронное):
    /// лимит `remaining` (первый лишний → `.limit`, дальше не идём), имя, MIME, подготовка файла
    /// (`PickedFilePipeline`: размер по `fileSizeKey` до чтения, байты, перекодирование или ужатие картинки, копия,
    /// плашка и превью), снятие tmp-копии.
    /// Чистая функция, чтобы её можно было проверить на временных файлах без UIKit.
    static func process(urls: [URL], remaining: Int, maxFileSize: Int64, writeCopy: Bool,
                        caches: URL? = CacheUri.caches,
                        fileManager fm: FileManager = .default) -> [PickOutcome] {
        var outcomes: [PickOutcome] = []
        for (i, url) in urls.enumerated() {
            // Порядок проверок — СНАЧАЛА лимит 10 чипов, ПОТОМ размер (единое правило с `PhotoPicker` и Android).
            guard i < remaining else {
                outcomes.append(.rejected(.limit))
                return outcomes
            }
            // Копия `asCopy` лежит в своей песочнице и scope ей не нужен (вернёт `false`), но Apple режимы
            // документально не разделяет («URLs are security-scoped») — дешёвая страховка без вреда.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
            // Размер до чтения, байты, подготовка (`PickedFilePipeline`); каталог, пакет, отозванный доступ — отказ
            // чтения (§6 строка 126: молчать нельзя). Превью снимается здесь, пока tmp-копия системы жива: своей копии
            // может и не быть (без хранения истории).
            outcomes.append(PickedFilePipeline.prepare(source: url, name: name, mime: mime(of: url),
                                                       maxFileSize: maxFileSize, writeCopy: writeCopy,
                                                       caches: caches, fileManager: fm))
            // tmp-копия системы больше не нужна: байты в памяти, своя копия (если пишется) — в кэше (§5 п. 7); при
            // отказе — тем более.
            try? fm.removeItem(at: url)
        }
        return outcomes
    }

    /// Старшинство отказов пачки: лимит старше размера, размер старше отказа чтения (единое правило с Android).
    static func worse(_ a: TransientError?, _ b: TransientError) -> TransientError {
        let rank: [TransientError] = [.attachFailed, .tooBig, .limit]
        guard let a else { return b }
        return rank.firstIndex(of: b)! > rank.firstIndex(of: a)! ? b : a
    }

    /// MIME: сначала тип файла по данным системы (`contentTypeKey`), потом по расширению, иначе поток байтов.
    static func mime(of url: URL) -> String {
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
           let mime = type.preferredMIMEType {
            return mime
        }
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
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

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // Лист закрывает вьюха через `onFinish`, контроллер сам не гасим.
            onFinish()
            // Настройка хранения и поколение экрана — на момент выбора.
            let sink = begin()
            let remaining = self.remaining
            let maxFileSize = self.maxFileSize
            // Чтение и подготовка — вне main, как у `PhotoPicker`; `sink` захвачен сильно — координатор листа
            // к концу подготовки может быть уже освобождён.
            DispatchQueue.global(qos: .userInitiated).async {
                let outcomes = DocumentPicker.process(urls: urls, remaining: remaining, maxFileSize: maxFileSize,
                                                      writeCopy: sink.writeCopy)
                DispatchQueue.main.async { sink.deliver(outcomes) }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}
