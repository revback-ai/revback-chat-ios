import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// ui-спека §12 п. 50: имя временного файла просмотрщика. QuickLook определяет тип файла ТОЛЬКО по
/// расширению, поэтому безымянное вложение оператора («Вложение» без расширения) не открывалось, а фото
/// любого формата называлось `photo.jpg`. Правило одно для фото и файла:
/// - имя непустое и с расширением → как есть;
/// - иначе расширение из `mime` (`UTType(mimeType:)?.preferredFilenameExtension`), основа — имя или
///   `photo` / `attachment`;
/// - нет и его → `jpg` для фото (как было), `bin` для файла.
///
/// На вход — СЫРОЕ `AttachmentRow.fileName`, не заголовок ссылки: заголовок при пустом имени —
/// локализованное «Вложение», и из него вышло бы «Вложение.pdf». Android отдаёт `mime` системному
/// просмотру напрямую (`setDataAndType`), безымянный файл кладёт как `revback-attachment` — у каждой
/// платформы свой механизм, результат один: файл открывается.
enum PreviewFileName {

    static func make(fileName: String?, mime: String?, isPhoto: Bool) -> String {
        let name = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty, !URL(fileURLWithPath: name).pathExtension.isEmpty {
            return name
        }
        let base = name.isEmpty ? (isPhoto ? "photo" : "attachment") : name
        if let ext = extensionFor(mime: mime) { return "\(base).\(ext)" }
        // Ни расширения, ни mime. Фото — `jpg` (ImageIO читает по сигнатуре); безымянный
        // файл — `attachment.bin`; а НЕПУСТОЕ имя без расширения оставляем как есть: `.bin` для
        // QuickLook — архив MacBinary (`com.apple.macbinary-archive`), и в заголовке просмотрщика появилось бы
        // выдуманное имя вроде «Договор.bin», хотя превью нет в обоих случаях.
        if isPhoto { return "\(base).jpg" }
        return name.isEmpty ? "\(base).bin" : name
    }

    /// Параметры MIME (`; charset=…`) `UTType` не разбирает — отрезаем. `application/octet-stream`
    /// даёт `public.data` без расширения → `nil`, и срабатывает запасное.
    private static func extensionFor(mime: String?) -> String? {
        guard let raw = mime?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty,
              let ext = UTType(mimeType: raw)?.preferredFilenameExtension,
              !ext.isEmpty
        else { return nil }
        return ext
    }
}

/// §5 п. 8: байты → временный файл в кэше приложения → `QLPreviewController`.
final class FilePreviewItem: NSObject, QLPreviewItem, Identifiable {
    let id = UUID()
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String?) {
        previewItemURL = url
        previewItemTitle = title
    }

    /// Общий корень временных файлов просмотрщика. Экран САМ его никогда не удаляет: под ним лежат
    /// каталоги всех открытых экранов (см. `directory(session:)`). Удаляет его ядро — целиком, при
    /// смене хозяина переписки (`ATTACHMENT_FILES_DIR` в `Platform.kt` ядра); имя меняется только
    /// вместе с ним.
    private static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("revback-chat", isDirectory: true)
    }

    /// Каталог ОДНОГО экрана. Идентификатор сессии заводит `ChatModel` (по одному на экран):
    /// экранов бывает два сразу (`RevbackChatViewController` поверх встроенного
    /// `RevbackChatView`), и уборка при закрытии первого стирала общий корень — вместе с
    /// файлом, который прямо сейчас показывает QuickLook второго.
    private static func directory(session: String) -> URL {
        root.appendingPathComponent(sanitized(session), isDirectory: true)
    }

    /// «/» увёл бы файл в чужой каталог, «:» ломает запись на некоторых томах.
    private static func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Кладёт байты во временный файл. nil — записать не удалось. Звать ВНЕ главного потока:
    /// вложение бывает на десятки мегабайт, а `write` синхронный.
    ///
    /// Каждое вложение пишется в СВОЙ подкаталог `<сессия>/messageId#index`: имена приходят от
    /// оператора и повторяются сплошь и рядом («photo.jpg» у половины сообщений), а общий
    /// каталог означал бы, что открытие второго такого вложения перезаписывает файл,
    /// который прямо сейчас показывает QuickLook.
    static func make(data: Data, fileName: String?, messageId: String, index: Int32,
                     session: String) -> FilePreviewItem? {
        let raw = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Сторож: экран зовёт `make` с именем от `PreviewFileName.make`, оно пустым не бывает
        // (ui-спека §12 п. 50). Запасное оставлено на случай нового вызова мимо правила.
        let name = sanitized(raw).isEmpty ? "attachment" : sanitized(raw)
        let scope = sanitized("\(messageId)#\(index)")
        let dir = directory(session: session).appendingPathComponent(scope, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return FilePreviewItem(url: url, title: name)
    }

    /// Уборка при закрытии экрана (`ChatModel.deinit`): файлы нужны ровно на время показа.
    /// Стирается ТОЛЬКО каталог своей сессии — общий корень принадлежит и другим экранам.
    static func cleanup(session: String) {
        let dir = directory(session: session)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

struct FilePreview: UIViewControllerRepresentable {
    let item: FilePreviewItem

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = QLPreviewController()
        vc.dataSource = context.coordinator
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(item: item) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let item: FilePreviewItem
        init(item: FilePreviewItem) { self.item = item }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem { item }
    }
}
