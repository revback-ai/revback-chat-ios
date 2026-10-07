import UIKit

/// Цвета и шрифты пузыря на UIKit — те же значения `Theme`, что у SwiftUI-пузыря (§4 строки 65–78).
/// `Theme` держит SwiftUI-`Color`; UIKit-ячейке нужны `UIColor`/`UIFont` из тех же hex и размеров.
enum BubbleStyle {

    static func color(hex: String) -> UIColor? {
        guard let normalized = Theme.normalizedHex(hex),
              let v = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255,
                       alpha: 1)
    }

    /// Цвет канала; не цвет — нейтральный серый шапки (§7), как у старого SwiftUI-пузыря (`MessageBubble.primary`).
    static func primary(_ hex: String) -> UIColor {
        color(hex: hex) ?? color(hex: Theme.neutralHeaderHex)!
    }

    static var ink: UIColor { color(hex: Theme.inkHex)! }
    static var surface: UIColor { color(hex: Theme.surfaceHex)! }
    static var hairline: UIColor { color(hex: Theme.hairlineHex)! }
    static var videoCoverBackground: UIColor { color(hex: Theme.videoCoverBackgroundHex)! }
    static var readTicks: UIColor { color(hex: Theme.readTicksHex)! }
    static var failedOutline: UIColor { color(hex: Theme.failedOutlineHex)! }

    /// Шрифты пузыря по роли (§4 строки 71–78) — ОДНО место для ячейки и оценщика высот (`RowHeightEstimator`):
    /// оценка обязана считать теми же шрифтами, что рисует пузырь, иначе оценка и самоизмерение разойдутся.
    enum Role {
        /// Подпись отправителя, 11.
        case sender
        /// Текст сообщения, 14; `dim` — удалённое/нечитаемое (курсив).
        case text(dim: Bool)
        /// Время, 10.
        case time
        /// Галочки, 11.
        case ticks
        /// Ссылка на файл и «не поддерживается», 13.
        case link

        var size: CGFloat {
            switch self {
            case .sender: return Theme.senderFontSize
            case .text: return Theme.bubbleFontSize
            case .time: return Theme.timeFontSize
            case .ticks: return Theme.ticksFontSize
            case .link: return Theme.fileLinkFontSize
            }
        }

        var italic: Bool {
            if case .text(let dim) = self { return dim }
            return false
        }
    }

    static func font(_ role: Role, legibilityWeight: UILegibilityWeight) -> UIFont {
        font(size: role.size, italic: role.italic, legibilityWeight: legibilityWeight)
    }

    /// Системный шрифт фиксированного размера — пара SwiftUI `.font(.system(size:))`. «Жирный шрифт»
    /// (`legibilityWeight` меняет метрики и у SwiftUI, и у UIKit): SwiftUI утяжеляет `.system` сам по среде, UIKit-шрифт
    /// фиксированного размера по трейту окна не меняется — вес берём из трейта явно (сверено тестом паритета).
    /// Защита от двойного утяжеления (замер на симуляторе iOS 26.3 с глобальным «Жирным шрифтом»):
    /// при ГЛОБАЛЬНОЙ настройке UIKit сам утяжеляет системный шрифт — `systemFont(ofSize:)` рисуется как
    /// `.SFUI-Semibold` (ширина = SwiftUI при «Жирном шрифте»), а `systemFont(ofSize:weight: .semibold)` — как
    /// `.SFUI-Heavy` (чужое с подписью 274 pt против 260,67 у SwiftUI). При этом `fontDescriptor.traits[.weight]`
    /// утяжеления НЕ показывает (0 и 0,3) — по весу его не распознать, признак — `UIAccessibility.isBoldTextEnabled`.
    /// Правило: система утяжеляет сама (глобальная настройка) или база уже тяжелее обычной — база как есть; иначе
    /// (трейт окна `.bold` без глобальной настройки — переопределение трейтов хостом) — `.semibold` явно.
    /// Курсив (удалённое, нечитаемое) по трейту НЕ утяжеляется — ширина `Text.italic()` та же, что без него (замер:
    /// 164 pt «Сообщение удалено» в обоих режимах); при глобальной настройке курсив утяжеляют оба (170 pt).
    static func font(size: CGFloat, italic: Bool = false, legibilityWeight: UILegibilityWeight) -> UIFont {
        font(base: UIFont.systemFont(ofSize: size), italic: italic, legibilityWeight: legibilityWeight,
             systemBoldText: UIAccessibility.isBoldTextEnabled)
    }

    /// Разбор от готовой базы — internal для теста защиты от двойного утяжеления.
    static func font(base: UIFont, italic: Bool, legibilityWeight: UILegibilityWeight,
                     systemBoldText: Bool) -> UIFont {
        let size = base.pointSize
        var font = base
        let alreadyHeavier = systemBoldText || weight(of: base) > UIFont.Weight.regular.rawValue + 0.01
        if legibilityWeight == .bold, !italic, !alreadyHeavier {
            font = UIFont.systemFont(ofSize: size, weight: boldTextWeight)
        }
        guard italic else { return font }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitItalic)) else {
            return UIFont.italicSystemFont(ofSize: size)
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// Вес шрифта из `fontDescriptor.traits[.weight]` (нет записи — обычный, 0).
    static func weight(of font: UIFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        if let n = traits?[.weight] as? NSNumber { return CGFloat(n.doubleValue) }
        if let v = traits?[.weight] as? CGFloat { return v }
        return UIFont.Weight.regular.rawValue
    }

    /// «Жирный шрифт» по трейту вида. Ячейку таблица настраивает и меряет, бывает, ДО вставки в окно — тогда трейт
    /// не задан, и берётся системная настройка, иначе первая высота строки вышла бы по обычному шрифту.
    static func legibility(_ traits: UITraitCollection) -> UILegibilityWeight {
        switch traits.legibilityWeight {
        case .bold: return .bold
        case .regular: return .regular
        default: return UIAccessibility.isBoldTextEnabled ? .bold : .regular
        }
    }

    /// Вес обычного текста при «Жирном шрифте» — тот, что даёт SwiftUI `.system(size:)` при `legibilityWeight == .bold`.
    static let boldTextWeight: UIFont.Weight = .semibold

    /// Округление вверх до пикселя экрана: у SwiftUI размеры текста дробные, рамки — по пикселям.
    static func ceilToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let s = scale > 0 ? scale : UIScreen.main.scale
        return ceil(value * s - 0.001) / s
    }
}

/// Текстовый элемент пузыря: фокус VoiceOver на нём сообщает координатору строку — у края
/// загруженного лента докручивает соседей. `onActivate` — действие двойного тапа (ссылка на файл).
final class BubbleAXLabel: UILabel {
    var onFocus: (() -> Void)?
    var onActivate: (() -> Void)?

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        onFocus?()
    }

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }
}

/// Картинка вложения как элемент доступности (§9: имя файла, `.image`, активация → просмотрщик).
final class BubbleAXImageView: UIImageView {
    var onFocus: (() -> Void)?
    var onActivate: (() -> Void)?

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        onFocus?()
    }

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }
}

/// Пузырь сообщения на UIKit — 1:1 с раскладкой SwiftUI-пузыря (`VStack`/`HStack`), по которой сверены размеры.
///
/// Раскладка — ручная (`measure`), а не стеки с констрейнтами: у SwiftUI-пузыря ширина ПО СОДЕРЖИМОМУ (80 % —
/// только потолок, §4 строка 69), внешний столбец прижимает время и галочки вправо, внутренний держит подпись,
/// текст и вложения слева, и сам внутренний столбец стоит у ПРАВОГО края внешнего (`VStack(alignment: .trailing)`).
/// Многострочные `UILabel` в сжимающихся по содержимому стеках дают неоднозначную высоту; ручной расчёт
/// детерминирован, считается в одном месте и отдаётся ячейке через `intrinsicContentSize` — её Auto Layout
/// (`leading`/`trailing`, RTL) и самоизмерение таблицы работают как обычно.
final class BubbleView: UIView {

    let senderLabel = BubbleAXLabel()
    let textLabel = BubbleAXLabel()
    let timeLabel = BubbleAXLabel()
    let ticksLabel = BubbleAXLabel()
    let attachmentsView = AttachmentStackView()

    private let fillLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()

    private(set) var row: BubbleRow?
    private var primaryHex = Theme.neutralHeaderHex
    private var strings: Strings?
    private var actions: CellActions?
    /// Потолок ширины пузыря: `(ширина ленты − 2 · боковой отступ) · 0,8` (§4 строка 69).
    private(set) var maxBubbleWidth: CGFloat = 0

    private var tapRecognizer: UITapGestureRecognizer?
    private var longPressRecognizer: UILongPressGestureRecognizer?

    private struct Layout {
        var size: CGSize
        var sender: CGRect?
        var text: CGRect?
        var attachments: CGRect?
        var time: CGRect?
        var ticks: CGRect?
    }

    private var cachedLayout: Layout?
    private var appliedLegibility: UILegibilityWeight?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.addSublayer(fillLayer)
        layer.addSublayer(strokeLayer)
        strokeLayer.fillColor = nil
        for label in [senderLabel, textLabel, timeLabel, ticksLabel] {
            label.backgroundColor = .clear
            label.textAlignment = .natural
            addSubview(label)
        }
        senderLabel.numberOfLines = 0
        textLabel.numberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        timeLabel.numberOfLines = 1
        ticksLabel.numberOfLines = 1
        addSubview(attachmentsView)
        attachmentsView.onSizeChange = { [weak self] in self?.contentSizeChanged() }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не поддерживается") }

    // MARK: настройка

    func configure(row: BubbleRow, primaryHex: String, strings: Strings, maxBubbleWidth: CGFloat,
                   actions: CellActions) {
        self.row = row
        self.primaryHex = primaryHex
        self.strings = strings
        self.actions = actions
        self.maxBubbleWidth = maxBubbleWidth
        applyContent()
        attachmentsView.configure(row: row, primaryHex: primaryHex, strings: strings, actions: actions)
        attachmentsView.isHidden = row.attachments.isEmpty
        applyInteraction()
        applyAccessibility()
        contentSizeChanged()
    }

    /// Переиспользование ячейки: загрузки картинок прежней строки отменяются.
    func prepareForReuse() {
        attachmentsView.cancelLoads()
    }

    private var legibility: UILegibilityWeight { BubbleStyle.legibility(traitCollection) }

    private var textColor: UIColor { (row?.isMine ?? false) ? .white : BubbleStyle.ink }

    private func applyContent() {
        guard let row else { return }
        let weight = legibility
        appliedLegibility = weight

        // §4 строка 71: подпись отправителя первой строкой, 11, opacity .7
        if let name = row.senderName {
            senderLabel.isHidden = false
            senderLabel.text = name
            senderLabel.font = BubbleStyle.font(.sender, legibilityWeight: weight)
            senderLabel.textColor = textColor
            senderLabel.alpha = CGFloat(Theme.senderOpacity)
        } else {
            senderLabel.isHidden = true
            senderLabel.text = nil
        }

        // §4 строка 75: удалённое и нечитаемое — курсивом, opacity .6; межстрочный 1,35
        if let text = row.text, !text.isEmpty {
            let dim = row.deleted || row.unreadable
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = Theme.bubbleLineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = .natural
            textLabel.isHidden = false
            textLabel.attributedText = NSAttributedString(string: text, attributes: [
                .font: BubbleStyle.font(.text(dim: dim), legibilityWeight: weight),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph,
            ])
            textLabel.alpha = dim ? CGFloat(Theme.deletedOpacity) : 1
        } else {
            textLabel.isHidden = true
            textLabel.attributedText = nil
        }

        // §4 строка 72: время — nil у приветствия и у недоставленного
        if let time = row.time {
            timeLabel.isHidden = false
            timeLabel.text = time
            timeLabel.font = BubbleStyle.font(.time, legibilityWeight: weight)
            timeLabel.textColor = textColor
            timeLabel.alpha = CGFloat(Theme.timeOpacity)
        } else {
            timeLabel.isHidden = true
            timeLabel.text = nil
        }

        // §4 строка 73: галочки 11, трекинг −1; «✓✓» #bfe3ff opacity 1, иначе белые .8
        if row.ticks != .none {
            let double = row.ticks == .double
            ticksLabel.isHidden = false
            ticksLabel.attributedText = NSAttributedString(string: double ? "✓✓" : "✓", attributes: [
                .font: BubbleStyle.font(.ticks, legibilityWeight: weight),
                .foregroundColor: double ? BubbleStyle.readTicks : UIColor.white,
                .kern: Theme.ticksKerning,
            ])
            ticksLabel.alpha = double ? 1 : CGFloat(Theme.ticksOpacity)
        } else {
            ticksLabel.isHidden = true
            ticksLabel.attributedText = nil
        }

        // §4 строки 70, 74: фон-форма, рамка чужого, пунктир и opacity .55 недоставленного
        fillLayer.fillColor = (row.isMine ? BubbleStyle.primary(primaryHex) : BubbleStyle.surface).cgColor
        if row.failed {
            strokeLayer.isHidden = false
            strokeLayer.strokeColor = BubbleStyle.failedOutline.cgColor
            strokeLayer.lineWidth = Theme.failedOutlineWidth
            strokeLayer.lineDashPattern = Theme.failedDash.map { NSNumber(value: Double($0)) }
        } else if !row.isMine {
            strokeLayer.isHidden = false
            strokeLayer.strokeColor = BubbleStyle.hairline.cgColor
            strokeLayer.lineWidth = 1
            strokeLayer.lineDashPattern = nil
        } else {
            strokeLayer.isHidden = true
        }
        alpha = row.failed ? CGFloat(Theme.failedBubbleOpacity) : 1
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if appliedLegibility != nil, appliedLegibility != legibility {
            applyContent()
            attachmentsView.legibilityChanged()
            contentSizeChanged()
            // Высота строки сменилась не через `configure` и не картинкой — таблица сама не перемеряет.
            if let id = row?.id { actions?.contentHeightChanged(id) }
        } else if previous?.layoutDirection != traitCollection.layoutDirection
                    || previous?.displayScale != traitCollection.displayScale {
            contentSizeChanged()
        }
    }

    // MARK: жесты недоставленного (§5 п. 9)

    /// Жесты — ТОЛЬКО у недоставленного: иначе тап по пузырю перехватывал бы тап по картинке и по ссылке файла.
    private func applyInteraction() {
        let failed = row?.failed ?? false
        if failed, tapRecognizer == nil {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
            addGestureRecognizer(tap)
            addGestureRecognizer(long)
            tapRecognizer = tap
            longPressRecognizer = long
        } else if !failed, let tap = tapRecognizer {
            removeGestureRecognizer(tap)
            if let long = longPressRecognizer { removeGestureRecognizer(long) }
            tapRecognizer = nil
            longPressRecognizer = nil
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) { handleTap(state: recognizer.state) }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        handleLongPress(state: recognizer.state)
    }

    /// Тап распознан → повтор (§5 п. 9). Internal — тесты зовут с состоянием распознавателя.
    func handleTap(state: UIGestureRecognizer.State) {
        guard state == .ended, let row, row.failed else { return }
        actions?.retry(row.id)
    }

    /// Долгое нажатие → отмена, ОДИН раз — в начале (`.changed`/`.ended` того же жеста не повторяют).
    func handleLongPress(state: UIGestureRecognizer.State) {
        guard state == .began, let row, row.failed else { return }
        actions?.cancel(row.id)
    }

    /// Касание только внутри формы пузыря (`contentShape(BubbleShape)` старого пузыря).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard row?.failed == true else { return super.point(inside: point, with: event) }
        return BubblePath.make(rect: bounds, isMine: row?.isMine ?? false).contains(point)
    }

    // MARK: доступность (§9)

    private func applyAccessibility() {
        guard let row, let strings else { return }
        let focus: () -> Void = { [weak self] in
            guard let self, let id = self.row?.id else { return }
            self.actions?.accessibilityFocused(id)
        }
        for label in [senderLabel, textLabel, timeLabel, ticksLabel] { label.onFocus = focus }
        attachmentsView.onFocus = focus

        if row.failed {
            // §12 пп. 31, 40, 42: недоставленное — ОДИН элемент-кнопка «Не доставлено»; активация — повтор,
            // «Отменить отправку» — именованным действием (долгое нажатие VoiceOver не отдаёт).
            isAccessibilityElement = true
            accessibilityLabel = strings.failed
            accessibilityTraits = .button
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: strings.cancelSending) { [weak self] _ in
                    guard let self, let id = self.row?.id else { return false }
                    self.actions?.cancel(id)
                    return true
                }
            ]
            accessibilityElements = nil
        } else {
            isAccessibilityElement = false
            accessibilityLabel = nil
            accessibilityTraits = .none
            accessibilityCustomActions = nil
            // Порядок как у SwiftUI-пузыря: подпись, текст, вложения, время, галочки.
            var elements: [Any] = []
            if !senderLabel.isHidden { elements.append(senderLabel) }
            if !textLabel.isHidden { elements.append(textLabel) }
            elements.append(contentsOf: attachmentsView.accessibilityItems)
            if !timeLabel.isHidden { elements.append(timeLabel) }
            if !ticksLabel.isHidden { elements.append(ticksLabel) }
            accessibilityElements = elements
        }
    }

    override func accessibilityActivate() -> Bool {
        guard let row, row.failed else { return super.accessibilityActivate() }
        actions?.retry(row.id)
        return true
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        if let id = row?.id { actions?.accessibilityFocused(id) }
    }

    // MARK: раскладка

    private func contentSizeChanged() {
        cachedLayout = nil
        if row?.failed == false { applyAccessibility() }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private var scale: CGFloat {
        traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
    }

    private func labelSize(_ label: UILabel, maxWidth: CGFloat) -> CGSize {
        let fit = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(BubbleStyle.ceilToPixel(fit.width, scale: scale), maxWidth),
                      height: BubbleStyle.ceilToPixel(fit.height, scale: scale))
    }

    private func measure() -> Layout {
        if let cachedLayout { return cachedLayout }
        if appliedLegibility != nil, appliedLegibility != legibility {
            applyContent()
            attachmentsView.legibilityChanged()
        }
        let innerMax = max(0, maxBubbleWidth - 2 * Theme.bubblePaddingHorizontal)
        let origin = CGPoint(x: Theme.bubblePaddingHorizontal, y: Theme.bubblePaddingVertical)

        // Внутренний столбец (alignment .leading): подпись + 2, текст, вложения (отступ сверху 5 — внутри них).
        var innerItems: [(key: String, size: CGSize, topGap: CGFloat, bottomGap: CGFloat)] = []
        if !senderLabel.isHidden {
            innerItems.append(("sender", labelSize(senderLabel, maxWidth: innerMax), 0, Theme.senderBottomGap))
        }
        if !textLabel.isHidden {
            innerItems.append(("text", labelSize(textLabel, maxWidth: innerMax), 0, 0))
        }
        if !attachmentsView.isHidden {
            let s = attachmentsView.measure(maxWidth: innerMax)
            innerItems.append(("attachments", s, Theme.attachmentTopGap, 0))
        }
        let innerWidth = innerItems.map(\.size.width).max() ?? 0

        // Внешний столбец (alignment .trailing): внутренний, время (+3 сверху), галочки.
        let timeSize = timeLabel.isHidden ? nil : labelSize(timeLabel, maxWidth: innerMax)
        let ticksSize = ticksLabel.isHidden ? nil : labelSize(ticksLabel, maxWidth: innerMax)
        let outerWidth = max(innerWidth, timeSize?.width ?? 0, ticksSize?.width ?? 0)

        var layout = Layout(size: .zero)
        var y = origin.y
        let innerX = origin.x + outerWidth - innerWidth
        for item in innerItems {
            y += item.topGap
            let frame = CGRect(x: innerX, y: y, width: item.size.width, height: item.size.height)
            switch item.key {
            case "sender": layout.sender = frame
            case "text": layout.text = frame
            default: layout.attachments = frame
            }
            y += item.size.height + item.bottomGap
        }
        if let timeSize {
            y += Theme.timeTopGap
            layout.time = CGRect(x: origin.x + outerWidth - timeSize.width, y: y,
                                 width: timeSize.width, height: timeSize.height)
            y += timeSize.height
        }
        if let ticksSize {
            layout.ticks = CGRect(x: origin.x + outerWidth - ticksSize.width, y: y,
                                  width: ticksSize.width, height: ticksSize.height)
            y += ticksSize.height
        }
        layout.size = CGSize(width: outerWidth + 2 * Theme.bubblePaddingHorizontal,
                             height: y + Theme.bubblePaddingVertical)
        cachedLayout = layout
        return layout
    }

    /// Размер пузыря при текущем потолке ширины — его берёт Auto Layout ячейки.
    var measuredSize: CGSize { measure().size }

    override var intrinsicContentSize: CGSize { measure().size }

    override func sizeThatFits(_ size: CGSize) -> CGSize { measure().size }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = measure()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        // SwiftUI зеркалит стеки в RTL (leading/trailing), форма пузыря — нет (как у старого `BubbleShape`).
        func place(_ view: UIView, _ frame: CGRect?) {
            guard let frame else { return }
            view.frame = rtl
                ? CGRect(x: layout.size.width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
                : frame
        }
        place(senderLabel, layout.sender)
        place(textLabel, layout.text)
        place(attachmentsView, layout.attachments)
        place(timeLabel, layout.time)
        place(ticksLabel, layout.ticks)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = BubblePath.make(rect: bounds, isMine: row?.isMine ?? false)
        fillLayer.frame = bounds
        strokeLayer.frame = bounds
        fillLayer.path = path
        strokeLayer.path = path
        CATransaction.commit()
    }
}
