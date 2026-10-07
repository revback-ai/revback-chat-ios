import CoreText
import UIKit

/// §4 строка 78: вложения внутри пузыря колонкой, зазор 4, отступ сверху 5 (он у `BubbleView`), слева и у своих.
/// Вложения на UIKit:
/// картинка (плашка 200×150 → вписанная `Theme.photoFittedSize`, r8; тап → просмотрщик с ОРИГИНАЛЬНЫМИ байтами),
/// ссылка (13, подчёркнута, одна строка, обрезка в середине; тап → просмотрщик), «не поддерживается» (13, opacity .6,
/// без тапа).
///
/// Без мигания: тот же id строки и те же вложения — показанное не сбрасывается и загрузка не перезапускается
/// (путь `reconfigureItems`); иначе сначала синхронный кэш модели — есть картинка, она ставится сразу, вписанный
/// размер тоже сразу; нет — плашка и загрузка с отменой при переиспользовании.
///
/// Видео (вид `video` или MIME `video/*`) — обложка с «плей» 44 по центру и
/// длительностью у нижнего leading-края; размер обложки известен ДО загрузки (`Theme.videoCoverSize` по
/// `width`/`height`, иначе 16:9), поэтому высота строки не прыгает. Обложка: своя — файл рядом с локальной копией,
/// иначе `attachmentThumbnail`; нет ни того, ни другого или отказ — ссылка с именем файла. Фото с
/// известными размерами занимает вписанный размер сразу, а не плашку 200×150. Своё без локального файла (копию
/// почистила система, переустановка) — с сервера: ядро отдаёт и свои вложения, как только сервер подтвердил
/// сообщение (`AttachmentRow.onServer`). До подтверждения такое вложение — ссылка сразу, и этот отказ не запоминается.
/// Подтверждение меняет у вложений только `onServer`: слоты не пересоздаются — показанное и идущая загрузка остаются,
/// а ссылка «ещё не на сервере» грузится заново.
final class AttachmentStackView: UIView {

    /// Одно вложение. Фото и видео с отказом рисуются ссылкой (§5 п. 7), поэтому у них есть и картинка, и ссылка.
    final class Slot {
        /// Меняется на месте только признак `onServer` (подтверждение своего); прочее — новый слот.
        var attachment: AttachmentRow
        let imageView = BubbleAXImageView()
        let label = BubbleAXLabel()
        /// «Плей» и длительность поверх обложки видео; у прочих — нет.
        let videoOverlay: VideoOverlayView?
        var state: ImageSlotState
        var task: Task<Void, Never>?
        /// Источники обложки видео по порядку; у фото и ссылок пусто.
        var coverSources: [CoverSource] = []

        init(attachment: AttachmentRow, state: ImageSlotState) {
            self.attachment = attachment
            self.state = state
            videoOverlay = !attachment.unsupported && attachment.kind == .video ? VideoOverlayView() : nil
        }

        var isPhoto: Bool { !attachment.unsupported && attachment.kind == .photo }
        var isVideo: Bool { !attachment.unsupported && attachment.kind == .video }
        /// Рисуется картинкой (фото или обложка видео), пока не случился отказ.
        var isMedia: Bool { isPhoto || isVideo }
        /// На экране ссылка/подпись, а не картинка.
        var showsLabel: Bool { !isMedia || state == .failed }
    }

    private(set) var slots: [Slot] = []
    private var rowId: String?
    private var isMine = false
    private var primaryHex = Theme.neutralHeaderHex
    private var strings: Strings?
    private var actions: CellActions?

    /// Высота/ширина колонки изменилась (картинка доехала, отказ → ссылка) — пузырь перемеряется.
    var onSizeChange: (() -> Void)?
    /// Фокус VoiceOver на элементе вложения.
    var onFocus: (() -> Void)? {
        didSet { slots.forEach { $0.imageView.onFocus = onFocus; $0.label.onFocus = onFocus } }
    }

    private var frames: [CGRect] = []

    // MARK: начальное состояние картинок строки (для ключа кэша высот)

    /// Состояние картинок строки из СИНХРОННОГО кэша модели — то, что ячейка покажет при `configure` без
    /// загрузки: вписанный размер для уже декодированной, `.failed` для видео без обложки (ссылка сразу), иначе
    /// `.placeholder`. Массив — ПО ПОЗИЦИИ в `row.attachments`, как читает его `RowHeightCache.contentKey`; у ссылок и
    /// «не поддерживается» — `.placeholder` (ключом не читается). Дальше состояние меняет только
    /// `CellActions.imageSettled` (см. `MessageCell.settling`). Известный отказ (`imageFailed`) —
    /// тоже `.failed` сразу.
    static func initialImageStates(row: BubbleRow, actions: CellActions) -> [ImageSlotState] {
        row.attachments.map { a in
            guard !a.unsupported else { return .placeholder }
            switch a.kind {
            case .photo: return initialPhoto(a, rowId: row.id, actions: actions).0
            case .video: return initialVideo(a, rowId: row.id, actions: actions).0
            case .file: return .placeholder
            }
        }
    }

    /// ОДНО правило начального состояния фото — и для ключа кэша высот, и для `configure` (иначе они разойдутся):
    /// синхронный кэш → вписанная картинка; известный отказ → ссылка; своё ещё не на сервере и без копии на диске →
    /// ссылка (загружать неоткуда — как у видео без источников обложки); иначе плашка и загрузка. Своё без локальной
    /// копии — тоже загрузка: ядро отдаёт и свои байты.
    private static func initialPhoto(_ a: AttachmentRow, rowId: String,
                                     actions: CellActions) -> (ImageSlotState, UIImage?) {
        if let image = cachedPhoto(a, rowId: rowId, actions: actions) {
            return (.fitted(Theme.photoFittedSize(image.size)), image)
        }
        if actions.imageFailed(rowId, a.index) { return (.failed, nil) }
        if !a.onServer, !(a.localUri.map(actions.localFileExists) ?? false) { return (.failed, nil) }
        return (.placeholder, nil)
    }

    /// Порядок: сначала своя копия, потом картинка ядра (и у своих).
    private static func cachedPhoto(_ a: AttachmentRow, rowId: String, actions: CellActions) -> UIImage? {
        if let uri = a.localUri, let local = actions.cachedLocalImage(uri) { return local }
        return actions.cachedImage(rowId, a.index)
    }

    /// Источники обложки видео: своя — файл рядом с копией, если он есть; сервер — при `thumbnailBlobRef`, без
    /// известного отказа и когда сервер сообщение уже знает (`onServer`: своё неподтверждённое он не отдаёт).
    static func coverSources(_ a: AttachmentRow, rowId: String, actions: CellActions) -> [CoverSource] {
        let hasServer = a.hasThumbnail && a.onServer && !actions.thumbnailFailed(rowId, a.index)
        return MediaRules.coverSources(localUri: a.localUri, hasThumbnail: hasServer,
                                       localFileExists: actions.localFileExists)
    }

    /// Начальное состояние обложки видео: нет источников или известный отказ — ссылка сразу; обложка в синхронном
    /// кэше — сразу картинка; иначе плашка размера обложки и загрузка. Размер в обоих случаях один.
    private static func initialVideo(_ a: AttachmentRow, rowId: String,
                                     actions: CellActions) -> (ImageSlotState, UIImage?) {
        let sources = coverSources(a, rowId: rowId, actions: actions)
        guard !sources.isEmpty, !actions.imageFailed(rowId, a.index) else { return (.failed, nil) }
        let size = Theme.videoCoverSize(width: a.width, height: a.height)
        for source in sources {
            switch source {
            case .local(let uri):
                if let image = actions.cachedLocalImage(uri) { return (.fitted(size), image) }
            case .server:
                if let image = actions.cachedThumbnail(rowId, a.index) { return (.fitted(size), image) }
            }
        }
        return (.placeholder, nil)
    }

    // MARK: настройка

    func configure(row: BubbleRow, primaryHex: String, strings: Strings, actions: CellActions) {
        let sameContent = rowId == row.id && slots.count == row.attachments.count
            && zip(slots, row.attachments).allSatisfy { Self.sameExceptServer($0.attachment, $1) }
        self.primaryHex = primaryHex
        self.strings = strings
        self.actions = actions
        self.isMine = row.isMine

        if sameContent {
            // Подтверждение своего: у вложения сменился только `onServer` — слот тот же (показанное и идущая загрузка
            // остаются), а ссылка «ещё не на сервере» получает начальное состояние заново.
            for (slot, a) in zip(slots, row.attachments) where slot.attachment != a {
                slot.attachment = a
                guard slot.isMedia, slot.state == .failed, slot.task == nil else { continue }
                if slot.isVideo { slot.coverSources = Self.coverSources(a, rowId: row.id, actions: actions) }
                let (state, image) = slot.isVideo ? Self.initialVideo(a, rowId: row.id, actions: actions)
                    : Self.initialPhoto(a, rowId: row.id, actions: actions)
                slot.imageView.image = image
                slot.state = state
            }
            // Показанное не трогаем; заново — только то, что ждёт загрузки без живой задачи
            // (переиспользование отменило её в `prepareForReuse`).
            for slot in slots {
                // Отказ, случившийся в ДРУГОЙ ячейке этой строки, пока загрузка здесь была отменена
                // переиспользованием, — ссылка сразу; `imageSettled` уже отправила та ячейка.
                if slot.isMedia, slot.state == .placeholder, slot.task == nil,
                   actions.imageFailed(row.id, slot.attachment.index) {
                    slot.state = .failed
                }
                applyStyle(slot)
                if slot.isMedia, slot.state == .placeholder, slot.task == nil { startLoad(slot) }
            }
        } else {
            cancelLoads()
            slots.forEach {
                $0.imageView.removeFromSuperview()
                $0.label.removeFromSuperview()
            }
            rowId = row.id
            slots = row.attachments.map { a in
                let slot = Slot(attachment: a, state: .placeholder)
                if slot.isPhoto {
                    // Из кэша — сразу картинка и вписанный размер, без плашки и без сообщения;
                    // известный отказ — имя файла сразу, ядро не зовём.
                    let (state, image) = Self.initialPhoto(a, rowId: row.id, actions: actions)
                    slot.imageView.image = image
                    slot.state = state
                } else if slot.isVideo {
                    // Обложки нет (ни своей, ни на сервере) или отказ известен — ссылка сразу.
                    slot.coverSources = Self.coverSources(a, rowId: row.id, actions: actions)
                    let (state, image) = Self.initialVideo(a, rowId: row.id, actions: actions)
                    slot.imageView.image = image
                    slot.state = state
                }
                return slot
            }
            for slot in slots {
                setUp(slot)
                applyStyle(slot)
                if slot.isMedia, slot.state == .placeholder { startLoad(slot) }
            }
        }
        invalidateMeasure()
    }

    /// Те же вложения с точностью до `onServer`.
    private static func sameExceptServer(_ a: AttachmentRow, _ b: AttachmentRow) -> Bool {
        var b = b
        b.onServer = a.onServer
        return a == b
    }

    /// Отмена загрузок прежней строки (переиспользование ячейки).
    func cancelLoads() {
        for slot in slots {
            slot.task?.cancel()
            slot.task = nil
        }
    }

    /// «Жирный шрифт» переключили — шрифты ссылок заново.
    func legibilityChanged() {
        slots.forEach(applyStyle)
        invalidateMeasure()
    }

    private func setUp(_ slot: Slot) {
        let imageView = slot.imageView
        // Фото рамкой вписано в свои пропорции; обложка видео — в рамку по `width`/`height` (или 16:9) с обрезкой.
        imageView.contentMode = slot.isVideo ? .scaleAspectFill : .scaleToFill
        imageView.clipsToBounds = true
        if let overlay = slot.videoOverlay {
            overlay.isUserInteractionEnabled = false
            imageView.addSubview(overlay)
        }
        imageView.layer.cornerRadius = Theme.photoRadius
        imageView.isUserInteractionEnabled = true
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(photoTapped(_:))))
        imageView.onActivate = { [weak self, weak slot] in
            guard let self, let slot else { return }
            self.openMedia(slot)
        }
        imageView.onFocus = onFocus
        addSubview(imageView)

        let label = slot.label
        label.backgroundColor = .clear
        label.isUserInteractionEnabled = true
        label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(linkTapped(_:))))
        label.onFocus = onFocus
        addSubview(label)
    }

    private var legibility: UILegibilityWeight { BubbleStyle.legibility(traitCollection) }

    private var linkColor: UIColor { isMine ? .white : BubbleStyle.primary(primaryHex) }

    private func applyStyle(_ slot: Slot) {
        guard let strings else { return }
        let a = slot.attachment
        let font = BubbleStyle.font(.link, legibilityWeight: legibility)
        if a.unsupported {
            // Цвет — как у ссылки (на своём пузыре белый), opacity .6, без подчёркивания и тапа.
            slot.label.attributedText = nil
            slot.label.text = strings.attachmentUnsupported
            slot.label.font = font
            slot.label.textColor = linkColor
            slot.label.alpha = CGFloat(Theme.deletedOpacity)
            slot.label.numberOfLines = 0
            slot.label.lineBreakMode = .byWordWrapping
            slot.label.accessibilityTraits = .staticText
            slot.label.onActivate = nil
        } else {
            let name = a.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            slot.label.attributedText = NSAttributedString(string: name.isEmpty ? strings.attachment : name, attributes: [
                .font: font,
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
            slot.label.alpha = 1
            slot.label.numberOfLines = 1
            slot.label.lineBreakMode = .byTruncatingMiddle
            slot.label.accessibilityTraits = [.staticText, .button]
            slot.label.onActivate = { [weak self, weak slot] in
                guard let self, let slot else { return }
                self.openFile(slot)
            }
        }
        applyPhotoState(slot)
    }

    private func applyPhotoState(_ slot: Slot) {
        let mediaVisible = slot.isMedia && slot.state != .failed
        slot.imageView.isHidden = !mediaVisible
        slot.label.isHidden = !slot.showsLabel
        if mediaVisible {
            let placeholder = slot.state == .placeholder
            // Обложка видео до кадра — тёмная, как у виджета (`.att-video`) и Android; фото — серая.
            let placeholderColor = slot.isVideo ? BubbleStyle.videoCoverBackground : BubbleStyle.hairline
            slot.imageView.backgroundColor = placeholder ? placeholderColor : .clear
            if placeholder { slot.imageView.image = nil }
            if slot.isVideo {
                // Обложка — кнопка «Видео, <длительность>, <имя>» и пока грузится (тап открывает файл сразу).
                slot.videoOverlay?.configure(duration: MediaRules.formatDuration(ms: slot.attachment.durationMs))
                slot.imageView.isAccessibilityElement = true
                slot.imageView.accessibilityLabel = MediaRules.videoAccessibilityLabel(
                    video: strings?.video ?? "", durationMs: slot.attachment.durationMs,
                    name: slot.attachment.fileName ?? strings?.attachment)
                slot.imageView.accessibilityTraits = [.image, .button]
            } else {
                // §9: картинка — «имя файла или Вложение», `.image`; плашка — не элемент (как у SwiftUI).
                slot.imageView.isAccessibilityElement = !placeholder
                slot.imageView.accessibilityLabel = slot.attachment.fileName ?? strings?.attachment
                slot.imageView.accessibilityTraits = .image
            }
        } else {
            slot.imageView.isAccessibilityElement = false
        }
        slot.label.isAccessibilityElement = slot.showsLabel
    }

    /// Элементы доступности колонки по порядку вложений.
    var accessibilityItems: [Any] {
        slots.compactMap { slot -> Any? in
            if slot.showsLabel { return slot.label }
            return slot.imageView.isAccessibilityElement ? slot.imageView : nil
        }
    }

    // MARK: загрузка (§5 п. 7)

    private func startLoad(_ slot: Slot) {
        guard let actions, let rowId else { return }
        let a = slot.attachment
        let isVideo = slot.isVideo
        let sources = slot.coverSources
        slot.task = Task { @MainActor [weak self, weak slot] in
            var image: UIImage?
            // Признак «на сервере» — на момент вопроса к серверу, а не старта: подтверждение, пришедшее во время
            // чтения копии, слот не перезапускает (`configure`), а меняет его вложение на месте.
            func onServer() -> Bool { slot?.attachment.onServer ?? a.onServer }
            if isVideo {
                // Своя обложка рядом с копией, не прочиталась — сервер (если обложка там есть).
                for source in sources where image == nil {
                    switch source {
                    case .local(let uri): image = await actions.localImage(uri)
                    case .server: image = await actions.thumbnail(rowId, a.index)
                    }
                }
                if image == nil, !sources.contains(.server), let now = slot?.attachment,
                   Self.coverSources(now, rowId: rowId, actions: actions).contains(.server) {
                    image = await actions.thumbnail(rowId, a.index)
                }
            } else {
                // Своя копия читается вне main (внутри `localImage`)
                if let uri = a.localUri { image = await actions.localImage(uri) }
                // Копии нет или она не читается — байты ядра, и у своих тоже (§12 п. 27);
                // своё неподтверждённое сервер не отдаёт — не спрашиваем
                if image == nil, onServer() { image = await actions.image(rowId, a.index) }
            }
            guard !Task.isCancelled, let self, let slot, self.rowId == rowId,
                  self.slots.contains(where: { $0 === slot }) else { return }
            slot.task = nil
            let fitted: (UIImage) -> ImageSlotState = isVideo
                ? { _ in .fitted(Theme.videoCoverSize(width: a.width, height: a.height)) }
                : { .fitted(Theme.photoFittedSize($0.size)) }
            let state: ImageSlotState = image.map(fitted) ?? .failed
            slot.imageView.image = image
            slot.state = state
            self.applyPhotoState(slot)
            self.invalidateMeasure()
            self.onSizeChange?()
            // Отказ запоминается в модели: строка в новой ячейке сразу ссылкой, без плашки. Своё неподтверждённое без
            // копии — не отказ картинки: подтверждение меняет `onServer`, и ссылка грузится с сервера.
            if state == .failed, slot.attachment.onServer { actions.rememberImageFailure(rowId, a.index) }
            actions.imageSettled(rowId, a.index, state)
        }
    }

    // MARK: просмотрщик (§5 п. 8)

    @objc private func photoTapped(_ recognizer: UITapGestureRecognizer) {
        guard let slot = slots.first(where: { $0.imageView === recognizer.view }) else { return }
        openMedia(slot)
    }

    /// Тап по картинке: фото — просмотрщик; видео — файл системным просмотрщиком (встроенного плеера нет) — и пока
    /// обложка грузится.
    func openMedia(_ slot: Slot) {
        if slot.isVideo {
            guard slot.state != .failed else { return }
            open(slot, isPhoto: false)
            return
        }
        openPhoto(slot)
    }

    @objc private func linkTapped(_ recognizer: UITapGestureRecognizer) {
        guard let slot = slots.first(where: { $0.label === recognizer.view }) else { return }
        openFile(slot)
    }

    /// Фото: имя временного файла — `PreviewFileName` с `isPhoto: true` (§12 п. 50, безымянный PNG → `photo.png`).
    func openPhoto(_ slot: Slot) {
        guard slot.isPhoto, case .fitted = slot.state else { return }
        open(slot, isPhoto: true)
    }

    /// Ссылка: «не поддерживается» не открывается; фото с отказом открывается как файл, но с `isPhoto` по виду
    /// строки.
    func openFile(_ slot: Slot) {
        guard !slot.attachment.unsupported else { return }
        open(slot, isPhoto: slot.attachment.kind == .photo)
    }

    /// §5 п. 8: просмотрщик получает ОРИГИНАЛЬНЫЕ байты. Свои — из `localUri` (§12 п. 27: адрес относительный,
    /// разворачивает `CacheUri`); копии нет или она не читается — `bytes` модели, и у своих тоже.
    /// Чтение и запись файла — вне main.
    private func open(_ slot: Slot, isPhoto: Bool) {
        guard let actions, let rowId else { return }
        let a = slot.attachment
        let name = PreviewFileName.make(fileName: a.fileName, mime: a.mime, isPhoto: isPhoto)
        let index = a.index
        let session = actions.previewSession
        Task { @MainActor in
            if let uri = a.localUri, let url = CacheUri.resolve(uri) {
                let local = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
                if let local {
                    let item = await Task.detached(priority: .userInitiated) {
                        FilePreviewItem.make(data: local, fileName: name, messageId: rowId,
                                             index: index, session: session)
                    }.value
                    if let item { actions.openPreview(item) }
                    return
                }
            }
            // §5 п. 8: при отказе полосу НЕ показываем — тап можно повторить
            guard let data = await actions.bytes(rowId, index) else { return }
            let item = await Task.detached(priority: .userInitiated) {
                FilePreviewItem.make(data: data, fileName: name, messageId: rowId, index: index, session: session)
            }.value
            if let item { actions.openPreview(item) }
        }
    }

    // MARK: раскладка

    private func invalidateMeasure() {
        setNeedsLayout()
    }

    private var scale: CGFloat {
        traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
    }

    /// Размер колонки при потолке ширины (без отступа сверху 5 — его держит пузырь).
    func measure(maxWidth: CGFloat) -> CGSize {
        var y: CGFloat = 0
        var width: CGFloat = 0
        frames = []
        for (i, slot) in slots.enumerated() {
            if i > 0 { y += Theme.attachmentGap }
            let size: CGSize
            if slot.showsLabel {
                let fit = slot.label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
                var width = fit.width
                if slot.label.numberOfLines == 1, width > maxWidth, let text = slot.label.attributedText {
                    // SwiftUI `Text.lineLimit(1).truncationMode(.middle)` занимает ширину ОБРЕЗАННОЙ строки, а не
                    // весь потолок: пузырь со ссылкой-обрезкой уже 80 %. Та же обрезка — CoreText, «…» посередине.
                    width = Self.middleTruncatedWidth(text, maxWidth: maxWidth)
                }
                size = CGSize(width: min(BubbleStyle.ceilToPixel(width, scale: scale), maxWidth),
                              height: BubbleStyle.ceilToPixel(fit.height, scale: scale))
            } else if case .fitted(let fitted) = slot.state {
                size = fitted
            } else if slot.isVideo {
                size = Theme.videoCoverSize(width: slot.attachment.width, height: slot.attachment.height)
            } else {
                // Размеры известны — место вписанной картинки сразу, иначе плашка 200×150 (§5 п. 7).
                size = Theme.photoReservedSize(width: slot.attachment.width, height: slot.attachment.height)
            }
            frames.append(CGRect(x: 0, y: y, width: size.width, height: size.height))
            width = max(width, size.width)
            y += size.height
        }
        return CGSize(width: width, height: y)
    }

    /// Ширина строки, обрезанной посередине до `maxWidth` (тем же шрифтом и атрибутами).
    static func middleTruncatedWidth(_ text: NSAttributedString, maxWidth: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(text)
        var tokenAttributes = text.attributes(at: 0, effectiveRange: nil)
        tokenAttributes[.underlineStyle] = nil
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: tokenAttributes))
        guard let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .middle, token) else { return maxWidth }
        return min(CGFloat(CTLineGetTypographicBounds(truncated, nil, nil, nil)), maxWidth)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard frames.count == slots.count else { return }
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (slot, f) in zip(slots, frames) {
            // alignment .leading: в RTL колонка прижата вправо
            let frame = rtl ? CGRect(x: bounds.width - f.maxX, y: f.minY, width: f.width, height: f.height) : f
            if slot.showsLabel { slot.label.frame = frame } else { slot.imageView.frame = frame }
            slot.videoOverlay?.frame = slot.imageView.bounds
        }
    }
}

/// «Плей» 44 по центру обложки и длительность у нижнего leading-края (как `.att-video .play`/`.dur` виджета;
/// угол длительности — leading). Не принимает касаний — тап ловит картинка.
final class VideoOverlayView: UIView {

    let playCircle = UIView()
    private let triangle = CAShapeLayer()
    let durationLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        playCircle.backgroundColor = UIColor.black.withAlphaComponent(Theme.mediaScrimAlpha)
        playCircle.layer.cornerRadius = Theme.videoPlaySize / 2
        triangle.fillColor = UIColor.white.cgColor
        playCircle.layer.addSublayer(triangle)
        addSubview(playCircle)

        durationLabel.font = UIFont.monospacedDigitSystemFont(ofSize: Theme.videoDurationFontSize, weight: .regular)
        durationLabel.textColor = .white
        durationLabel.textAlignment = .center
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        durationLabel.layer.cornerRadius = Theme.durationRadius
        durationLabel.clipsToBounds = true
        addSubview(durationLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    func configure(duration: String?) {
        durationLabel.text = duration
        durationLabel.isHidden = duration == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = Theme.videoPlaySize
        playCircle.frame = CGRect(x: bounds.midX - s / 2, y: bounds.midY - s / 2, width: s, height: s)
        let g = Theme.videoPlayGlyphSize
        // Оптический центр треугольника — чуть правее геометрического.
        let origin = CGPoint(x: (s - g) / 2 + g * 0.1, y: (s - g) / 2)
        let path = UIBezierPath()
        path.move(to: origin)
        path.addLine(to: CGPoint(x: origin.x + g, y: origin.y + g / 2))
        path.addLine(to: CGPoint(x: origin.x, y: origin.y + g))
        path.close()
        triangle.path = path.cgPath

        guard !durationLabel.isHidden else { return }
        let fit = durationLabel.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: ceil(fit.width) + 2 * Theme.durationPaddingHorizontal,
                          height: ceil(fit.height) + 2 * Theme.durationPaddingVertical)
        let inset = Theme.videoDurationInset
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let x = rtl ? bounds.width - inset - size.width : inset
        durationLabel.frame = CGRect(x: x, y: bounds.height - inset - size.height, width: size.width,
                                     height: size.height)
    }
}
