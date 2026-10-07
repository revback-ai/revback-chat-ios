import Foundation

/// Адрес локальной копии СВОЕГО вложения (§5 п. 7, §12 п. 27).
///
/// Копия лежит в `<Caches>/revback-chat/<метка>-<uuid>-<имя>` (копии прежнего формата — `<uuid>-<имя>`),
/// но в `FileSource.localUri` уезжает НЕ абсолютный `file://`, а относительный путь от каталога `Caches`
/// под своей схемой: `revback-cache://revback-chat/<имя файла копии>`.
///
/// Почему не абсолютный путь: он содержит UUID контейнера данных приложения
/// (`…/Containers/Data/Application/<UUID>/Library/Caches/…`), а iOS выдаёт контейнеру новый UUID
/// при каждой переустановке и обновлении — файл переезжает вместе с контейнером, а сохранённый
/// ядром в кэше беседы `local_uri` указывает в никуда. Своё фото после обновления приложения
/// переставало рисоваться совсем: байты своих вложений ядро не отдаёт (§12 п. 27), и ссылка
/// оставалась мёртвой.
///
/// Почему своя схема, а не голый относительный путь: ядро `localUri` не интерпретирует, хранит
/// строку как есть (`MessageCache.kt:172`), и в кэше уже лежат старые записи с `file://` —
/// новый формат обязан быть отличим от них при чтении.
///
/// Строка НЕ проходит через `URL(string:)` ни при записи, ни при разборе: имя приходит из
/// библиотеки фото и сплошь и рядом несёт пробелы и кириллицу, то есть валидным URL не является,
/// а процентное кодирование пришлось бы снимать обратно. Склейка и разбор — по префиксу.
enum CacheUri {

    /// Схема относительного адреса. Старым записям остаётся `file://` (§12 п. 27).
    static let scheme = "revback-cache://"

    /// Каталог копий внутри `Caches`. Имя общее с ядром: при смене хозяина переписки (выход,
    /// смена личности, смена ключа канала) ядро стирает этот каталог целиком (`ATTACHMENT_FILES_DIR`
    /// в `Platform.kt` ядра) — меняется только вместе с ним.
    static let directory = "revback-chat"

    /// Каталог `Caches` приложения. `nil` — только у сломанной песочницы.
    static var caches: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    /// Копия выбранного файла в `<caches>/revback-chat/<метка>-<uuid>-<имя>` — из байтов, которые уйдут на сервер (у
    /// перекодированной картинки это уже не байты исходного файла); возвращает готовый `localUri`. `nil` — записать
    /// не удалось (тогда свой пузырь просто подождёт байты вложения, как чужой).
    /// Метка — момент записи копии (`writeStamp`): по ней потолок каталога (`trimCopies`) сносит старые копии первыми.
    /// Возраст берётся из имени, а не из дат файловой системы: даты файлов — API с обязательной причиной в манифесте
    /// приватности Apple, а манифест SDK таких API не заявляет.
    static func write(_ data: Data, name: String, caches: URL? = CacheUri.caches,
                      fileManager fm: FileManager = .default) -> String? {
        guard let caches else { return nil }
        let dir = caches.appendingPathComponent(directory, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // UUID: два «IMG_0001.HEIC» в одну миллисекунду — тоже не повод для столкновения.
        let file = stampedFileName(UUID().uuidString + "-" + sanitized(name), stamp: nextWriteStamp())
        guard (try? data.write(to: dir.appendingPathComponent(file), options: .atomic)) != nil else { return nil }
        return scheme + directory + "/" + file
    }

    // MARK: метка записи в имени копии

    /// Ширина метки: миллисекунды от 1970 года, дополненные нулями слева. 16 цифр хватает с запасом, а фиксированная
    /// ширина отличает метку от первой группы UUID (8 знаков) в именах прежнего формата `<uuid>-<имя>`.
    static let stampWidth = 16

    /// `<метка>-<остаток>`: метка ровно `stampWidth` цифр. Отрицательная метка не пишется (нечего кодировать).
    static func stampedFileName(_ rest: String, stamp: Int64) -> String {
        let digits = String(max(0, stamp))
        return String(repeating: "0", count: max(0, stampWidth - digits.count)) + digits + "-" + rest
    }

    /// Метка записи из имени копии или её обложки (обложка — имя копии плюс суффикс, метка у них общая). Имя без
    /// метки (копии, записанные до её появления) — `nil`: такие считаются самыми старыми.
    static func writeStamp(of fileName: String) -> Int64? {
        let utf8 = Array(fileName.utf8)
        guard utf8.count > stampWidth, utf8[stampWidth] == UInt8(ascii: "-") else { return nil }
        let head = utf8[0..<stampWidth]
        guard head.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        return Int64(String(decoding: head, as: UTF8.self))
    }

    private static let stampLock = NSLock()
    private static var lastStamp: Int64 = 0

    /// Возрастающая метка: текущее время в миллисекундах, но строго больше прежней за жизнь процесса — две копии
    /// подряд не получат одну метку, и часы, переведённые назад, не сделают новую копию «старше» прежних.
    static func nextWriteStamp(now: Date = Date()) -> Int64 {
        stampLock.lock()
        defer { stampLock.unlock() }
        let ms = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        lastStamp = max(ms, lastStamp + 1)
        return lastStamp
    }

    /// Потолок каталога копий своих вложений: 50 МБ — пять вложений предельного размера (10 МБ), как на Android.
    /// Своего срока жизни у копий нет (каталог стирает ядро при смене хозяина переписки, остальное — система при
    /// нехватке места), а лента растёт бесконечно.
    static let copiesMaxBytes: Int64 = 50 * 1024 * 1024

    /// Удерживает каталог копий в `maxBytes`, снося самые старые по метке записи в имени (`writeStamp`); копии без
    /// метки (прежний формат имени) — самые старые. Зовётся ПОСЛЕ записи копии и её обложки, поэтому свежая копия
    /// `keep` не трогается никогда: вложение, которое одно перебирает потолок, иначе стиралось бы у себя из-под ног.
    ///
    /// Обложка своего видео (`<копия>.cover.jpg`) живёт парой со своей копией: размер считается вместе, сносятся
    /// вместе, возраст — по копии; `keep` бережёт и её обложку. Файл с суффиксом обложки, у которого копии рядом нет,
    /// — отдельная единица. Любой отказ — только лог: потолок кэша не повод ронять вложение.
    static func trimCopies(keep: String?, maxBytes: Int64 = copiesMaxBytes, caches: URL? = CacheUri.caches,
                           fileManager fm: FileManager = .default) {
        guard let caches else { return }
        let dir = caches.appendingPathComponent(directory, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let listed = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        struct Entry { let url: URL; let size: Int64; let stamp: Int64 }
        let files: [Entry] = listed.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                return nil
            }
            return Entry(url: url, size: Int64(values.fileSize ?? 0), stamp: writeStamp(of: url.lastPathComponent) ?? -1)
        }
        let names = Set(files.map(\.url.lastPathComponent))
        let suffix = MediaRules.localCoverSuffix
        func isCoverOfCopy(_ entry: Entry) -> Bool {
            let name = entry.url.lastPathComponent
            return name.hasSuffix(suffix) && names.contains(String(name.dropLast(suffix.count)))
        }
        var coverOf: [String: Entry] = [:]
        for entry in files where isCoverOfCopy(entry) {
            coverOf[String(entry.url.lastPathComponent.dropLast(suffix.count))] = entry
        }
        let copies = files.filter { !isCoverOfCopy($0) }
        func unitSize(_ copy: Entry) -> Int64 { copy.size + (coverOf[copy.url.lastPathComponent]?.size ?? 0) }
        var total = copies.reduce(Int64(0)) { $0 + unitSize($1) }
        guard total > maxBytes else { return }
        let keepName = keep.flatMap { ownFileName($0) }
        // При равной метке — по имени: порядок обхода каталога не задан, а потолок должен вести себя одинаково.
        let oldestFirst = copies.sorted {
            $0.stamp != $1.stamp ? $0.stamp < $1.stamp : $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        for copy in oldestFirst {
            if total <= maxBytes { break }
            if copy.url.lastPathComponent == keepName { continue }
            let size = unitSize(copy)
            do {
                try fm.removeItem(at: copy.url)
                total -= size
                if let cover = coverOf[copy.url.lastPathComponent] { try? fm.removeItem(at: cover.url) }
            } catch {
                NSLog("[RevbackChatUI] потолок копий вложений: копия не удалена: %@", error.localizedDescription)
            }
        }
    }

    /// Удаляет одну свою копию вместе с обложкой рядом — для файла, подготовленного, но так и не ставшего плашкой.
    /// Адрес не своей схемы — ничего не делает.
    static func deleteCopy(_ uri: String, caches: URL? = CacheUri.caches, fileManager fm: FileManager = .default) {
        guard uri.hasPrefix(scheme) else { return }
        if let copy = resolve(uri, caches: caches, fileManager: fm) { try? fm.removeItem(at: copy) }
        if let cover = resolve(MediaRules.localCoverUri(forLocalUri: uri), caches: caches, fileManager: fm) {
            try? fm.removeItem(at: cover)
        }
    }

    /// Имя файла копии по своему адресу (`revback-cache://revback-chat/<имя>`); чужой адрес — `nil`.
    private static func ownFileName(_ uri: String) -> String? {
        let prefix = scheme + directory + "/"
        guard uri.hasPrefix(prefix) else { return nil }
        return String(uri.dropFirst(prefix.count))
    }

    /// Файл по `localUri` из ядра. `nil` — разобрать адрес нечем.
    ///
    /// - `revback-cache://…` — путь внутри ТЕКУЩЕГО `Caches`, переезд контейнера ему безразличен.
    /// - `file://…` (записи прежнего формата) — сначала как есть; если файла там нет, пробуем то же
    ///   место внутри текущего `Caches` по последним двум компонентам пути
    ///   (`revback-chat/<uuid>-<имя>`): контейнер переехал, а сам файл кэш пережил.
    /// - прочее (`http(s)://…` и любая другая схема) — `nil`. Свой `localUri` таким не бывает, но
    ///   строку ядро хранит как есть, а зовущие `resolve` читают файл через `Data(contentsOf:)` —
    ///   он по сетевой схеме молча уходит в сеть синхронным запросом. Испорченный в кэше беседы
    ///   `local_uri` не должен превращаться в поход наружу: пусть вложение покажет имя файла
    ///   (§12 п. 27).
    static func resolve(_ uri: String, caches: URL? = CacheUri.caches,
                        fileManager fm: FileManager = .default) -> URL? {
        if uri.hasPrefix(scheme) {
            let relative = String(uri.dropFirst(scheme.count))
            return inCaches(components: relative.components(separatedBy: "/"), caches: caches)
        }
        guard let url = URL(string: uri) else { return nil }
        guard url.isFileURL else { return nil }
        if fm.fileExists(atPath: url.path) { return url }
        let tail = Array(url.pathComponents.suffix(2))
        if tail.count == 2, let moved = inCaches(components: tail, caches: caches),
           fm.fileExists(atPath: moved.path) {
            return moved
        }
        // Файла нет нигде: отдаём исходный адрес — чтение по нему провалится,
        // и вложение покажет имя файла (§12 п. 27).
        return url
    }

    /// Предел длины имени файла. APFS считает 255 знаков UTF-16, другие тома — 255 байт; имя меряется в байтах
    /// UTF-8 разложенной формы (`fileSystemBytes`) — это не меньше длины в любых из этих единиц и при любой
    /// нормализации, так что имя в пределах `maxFileNameBytes` укладывается в предел где угодно.
    static let maxFileNameBytes = 255

    /// Сколько байт остаётся исходному имени: имя копии — `<метка>-<uuid>-<имя>`, а имя её обложки длиннее ещё на
    /// суффикс обложки; в предел должны укладываться оба.
    static let maxNameBytes = maxFileNameBytes - (stampWidth + 1) - (uuidBytes + 1) - MediaRules.localCoverSuffix.utf8.count

    /// `UUID().uuidString` — 36 знаков ASCII.
    private static let uuidBytes = 36

    /// Расширение длиннее этого — не расширение, а хвост имени: при обрезке не бережётся.
    private static let maxExtensionBytes = 16

    /// Имя приходит из библиотеки фото: «/» увёл бы файл в чужой каталог, «:» ломает запись
    /// на некоторых томах. Длинное имя вместе с меткой, UUID и суффиксом обложки перешагнуло бы предел длины имени
    /// файла, и копия или обложка не записалась бы — оно укорачивается до `maxBytes`.
    static func sanitized(_ name: String, maxBytes: Int = maxNameBytes) -> String {
        let safe = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return safe.isEmpty ? "attachment" : truncated(safe, maxBytes: maxBytes)
    }

    /// Имя не длиннее `maxBytes` байт UTF-8; расширение сохраняется, обрезается основа. Режется по границе символа
    /// (`Character` — расширенный кластер графем): ни кодовая точка, ни составной символ (эмодзи с модификаторами,
    /// буква с комбинируемым знаком) пополам не делятся. Длина — `fileSystemBytes`.
    static func truncated(_ name: String, maxBytes: Int) -> String {
        guard fileSystemBytes(name) > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let keepsExtension = !ext.isEmpty && fileSystemBytes(ext) <= maxExtensionBytes
        let tail = keepsExtension ? "." + ext : ""
        let base = keepsExtension ? (name as NSString).deletingPathExtension : name
        let budget = maxBytes - fileSystemBytes(tail)
        var kept = ""
        var used = 0
        for character in base {
            let size = fileSystemBytes(String(character))
            if used + size > budget { break }
            kept.append(character)
            used += size
        }
        return (kept.isEmpty ? "attachment" : kept) + tail
    }

    /// Длина имени для предела: байты UTF-8 разложенной формы (NFD). «й», «ё» и буквы с диакритикой в ней длиннее,
    /// а том может хранить имя и так.
    static func fileSystemBytes(_ s: String) -> Int {
        s.decomposedStringWithCanonicalMapping.utf8.count
    }

    /// Склейка пути внутри `Caches`. `.` и `..` выбрасываются: адрес приходит из кэша ядра,
    /// а он переживает и правку файла базы — за пределы своего каталога он уводить не должен.
    private static func inCaches(components: [String], caches: URL?) -> URL? {
        guard let caches else { return nil }
        let safe = components.filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !safe.isEmpty else { return nil }
        return safe.reduce(caches) { $0.appendingPathComponent($1) }
    }
}
