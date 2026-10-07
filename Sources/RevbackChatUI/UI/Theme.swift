import SwiftUI
import UIKit

/// Константы визуальной спецификации — внутренняя спецификация UI, §4.
/// Номера строк спеки указаны у каждой группы. px = dp = pt.
/// Серые `muted`/`controlGlyph`/`chipClose` и время на 55 % ниже WCAG AA — осознанно, синхронно с веб-виджетом;
/// менять только вместе с ним.
enum Theme {

    // MARK: Цвета (§4 строки 65–81)

    /// §4 строка 65: поверхность.
    static let surfaceHex = "#ffffff"
    /// §4 строка 65: чернила.
    static let inkHex = "#1c1c1e"
    /// §4 строка 67: фон полосы ошибки.
    static let errorBackgroundHex = "#fdecea"
    /// §4 строка 67: текст полосы ошибки.
    static let errorTextHex = "#b3261e"
    /// §4 строка 68: фон ленты.
    static let listBackgroundHex = "#f5f6f8"
    /// §4 строка 69: пустое состояние.
    static let mutedHex = "#9ca3af"
    /// §4 строка 70: рамка чужого пузыря; §4 строка 79: линия над композером.
    static let hairlineHex = "#e3e5e8"
    /// §4 строка 73: «✓✓» прочитано оператором.
    static let readTicksHex = "#bfe3ff"
    /// §4 строка 74: пунктир недоставленного.
    static let failedOutlineHex = "#e53935"
    /// §4 строка 79: рамка скрепки и поля, глиф скрепки.
    static let controlBorderHex = "#d4d7dc"
    static let controlGlyphHex = "#9aa1ad"
    /// §4 строка 80: чип файла.
    static let chipBackgroundHex = "#eef1f6"
    static let chipTextHex = "#41485a"
    static let chipCloseHex = "#6b7280"
    /// §4 строка 81 и §7: шапка без брендинга.
    static let neutralHeaderHex = "#6b7280"

    static var surface: Color { color(hex: surfaceHex)! }
    static var ink: Color { color(hex: inkHex)! }
    static var errorBackground: Color { color(hex: errorBackgroundHex)! }
    static var errorText: Color { color(hex: errorTextHex)! }
    static var listBackground: Color { color(hex: listBackgroundHex)! }
    static var muted: Color { color(hex: mutedHex)! }
    static var hairline: Color { color(hex: hairlineHex)! }
    static var controlBorder: Color { color(hex: controlBorderHex)! }
    static var controlGlyph: Color { color(hex: controlGlyphHex)! }
    static var chipBackground: Color { color(hex: chipBackgroundHex)! }
    static var chipText: Color { color(hex: chipTextHex)! }
    static var chipClose: Color { color(hex: chipCloseHex)! }

    // MARK: Шапка (§4 строка 66)

    static let headerHeight: CGFloat = 58
    static let headerPaddingVertical: CGFloat = 12
    static let headerPaddingHorizontal: CGFloat = 14
    static let headerGap: CGFloat = 10                 // веб-виджет: «flex, gap 10»
    static let avatarSize: CGFloat = 34
    static let avatarFillOpacity: Double = 0.22        // rgba(255,255,255,.22)
    static let headerIconSize: CGFloat = 20
    static let headerTitleSize: CGFloat = 15
    static let headerTitleWeight: Font.Weight = .semibold   // 600
    static let closeGlyphSize: CGFloat = 20
    static let closeGlyphOpacity: Double = 0.85
    static let minHitTarget: CGFloat = 44              // §4 строка 66, §9

    /// Перехлёст зоны касания 44 над кругом 34: `(44 − 34) / 2`. Шапка и композер вычитают его
    /// из вертикального паддинга, чтобы от края до КРУГА остались §4-шные 12 и 10, а высоты —
    /// 58 и 54 (единое значение с Android, `ChatDims.touchOverhang`).
    static let touchOverhang: CGFloat = (minHitTarget - avatarSize) / 2

    /// Перехлёст зоны касания 44 над ГЛИФОМ крестика 20: `(44 − 20) / 2`.
    /// Вычитается из ПРАВОГО отступа шапки — см. `ChatHeader`.
    static let closeTouchOverhang: CGFloat = (minHitTarget - closeGlyphSize) / 2

    // MARK: Полоса ошибки (§4 строка 67)

    static let errorBarFontSize: CGFloat = 13
    static let errorBarPaddingVertical: CGFloat = 8
    static let errorBarPaddingHorizontal: CGFloat = 12

    // MARK: Лента (§4 строка 68)

    static let listPadding: CGFloat = 12
    static let bubbleGap: CGFloat = 8

    // MARK: Пустое состояние (§4 строка 69)

    static let emptyIconSize: CGFloat = 64
    static let emptyIconOpacity: Double = 0.5
    static let emptyTextSize: CGFloat = 14
    static let emptyGap: CGFloat = 12

    // MARK: Пузырь (§4 строки 70–77)

    static let bubbleMaxWidthFraction: CGFloat = 0.8
    static let bubblePaddingVertical: CGFloat = 8
    static let bubblePaddingHorizontal: CGFloat = 12
    static let bubbleRadius: CGFloat = 12
    static let bubbleTailRadius: CGFloat = 4
    static let bubbleFontSize: CGFloat = 14
    static let bubbleLineHeightRatio: CGFloat = 1.35

    /// CSS `line-height: 1.35` → добавка между строками в SwiftUI.
    static var bubbleLineSpacing: CGFloat {
        max(0, bubbleFontSize * bubbleLineHeightRatio - UIFont.systemFont(ofSize: bubbleFontSize).lineHeight)
    }

    static let senderFontSize: CGFloat = 11
    static let senderOpacity: Double = 0.7
    static let senderBottomGap: CGFloat = 2

    static let timeFontSize: CGFloat = 10
    static let timeOpacity: Double = 0.55
    static let timeTopGap: CGFloat = 3

    static let ticksFontSize: CGFloat = 11
    static let ticksOpacity: Double = 0.8
    static let ticksKerning: CGFloat = -1

    static let failedBubbleOpacity: Double = 0.55
    static let failedOutlineWidth: CGFloat = 1
    /// Веб-виджет: `border:1px dashed #e53935`; шаг пунктира — [3, 3], единое значение с Android.
    static let failedDash: [CGFloat] = [3, 3]

    static let deletedOpacity: Double = 0.6

    // MARK: Вложения (§4 строка 78)

    static let attachmentGap: CGFloat = 4
    static let attachmentTopGap: CGFloat = 5
    static let photoMaxWidth: CGFloat = 200
    static let photoMaxHeight: CGFloat = 180
    static let photoRadius: CGFloat = 8
    /// §5 п. 7: серая плашка, пока байт нет.
    static let photoPlaceholderWidth: CGFloat = 200
    static let photoPlaceholderHeight: CGFloat = 150
    static let fileLinkFontSize: CGFloat = 13

    /// §4 строка 78 «max 200×180» — размер ВПИСАННОЙ картинки, а не потолок предложения.
    /// `.frame(maxWidth:maxHeight:)` задаёт только потолок: `Image` с `.fit` внутри него
    /// остался бы шириной 200 при любой высоте, и пузырь с вертикальным фото вышел бы втрое
    /// шире самой картинки. Коэффициент один на обе стороны (пропорции сохраняются),
    /// больше 1 не растим — маленькая картинка остаётся своего размера.
    static func photoFittedSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: photoPlaceholderWidth, height: photoPlaceholderHeight)
        }
        let k = min(photoMaxWidth / size.width, photoMaxHeight / size.height, 1)
        return CGSize(width: size.width * k, height: size.height * k)
    }

    // MARK: Композер (§4 строка 79)

    static let composerBorderWidth: CGFloat = 1
    static let composerPaddingVertical: CGFloat = 10
    static let composerPaddingHorizontal: CGFloat = 12
    static let composerGap: CGFloat = 8
    /// Веб-виджет: `.compose{padding:10px 12px}` + `.attach/.send{width:34;height:34}`:
    /// круг 34 стоит внутри зоны касания 44 (§9), поэтому строка композера меряется в 44,
    /// а вертикальный паддинг вычитает `touchOverhang` — итог те же 54 (как на Android).
    static let composerControlSize: CGFloat = 34
    static let attachGlyphSize: CGFloat = 16
    static let sendGlyphSize: CGFloat = 18
    static let fieldRadius: CGFloat = 10
    static let fieldPaddingVertical: CGFloat = 7
    static let fieldPaddingHorizontal: CGFloat = 12
    static let fieldFontSize: CGFloat = 14
    static let fieldMinHeight: CGFloat = 34
    static let fieldMaxLines = 4

    // MARK: Чип файла (§4 строка 80)

    static let chipRadius: CGFloat = 8
    static let chipPaddingVertical: CGFloat = 4
    static let chipPaddingHorizontal: CGFloat = 8
    static let chipFontSize: CGFloat = 12
    static let chipNameMaxWidth: CGFloat = 180
    static let chipGap: CGFloat = 8

    // MARK: Плашки вложений

    /// Плитка фото/видео 72×72, скругление 12, рамка 1 `hairline`; карточка документа той же высоты.
    static let tileSize: CGFloat = 72
    static let tileRadius: CGFloat = 12
    static let tileBorderWidth: CGFloat = 1
    /// Зазор между плашками.
    static let tileGap: CGFloat = 12
    /// Крестик — круг 20 в углу trailing/top, сдвинут наружу; зона касания — `minHitTarget`.
    static let tileRemoveSize: CGFloat = 20
    static let tileRemoveOutset: CGFloat = 6
    static let tileRemoveGlyphSize: CGFloat = 8
    /// «Плей» на плитке видео и плашка длительности у её нижнего leading-края.
    static let tilePlaySize: CGFloat = 24
    static let tileDurationFontSize: CGFloat = 11
    static let tileDurationInset: CGFloat = 4
    /// Значок картинки на плитке фото без миниатюры (Android `tileGlyph`), цвет `controlGlyph`.
    static let tileGlyphSize: CGFloat = 24
    /// Обводка значков картинки и документа — Feather, как Android (`RevbackIcons.STROKE_WIDTH` 1,7, круглые концы).
    static let glyphStroke = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
    /// Подложка длительности — одна на плитке и в ленте (виджет `.att-video .dur`, Android
    /// `durationRadius`/`durationPadH`/`durationPadV`): радиус 6, паддинги 6 по бокам и 1 сверху/снизу.
    static let durationRadius: CGFloat = 6
    static let durationPaddingHorizontal: CGFloat = 6
    static let durationPaddingVertical: CGFloat = 1
    /// Карточка документа (Android `docCardWidth`/`docIcon`): ширина 200 при любом имени, паддинг,
    /// значок 24, зазор; текст занимает остаток ширины.
    static let fileCardWidth: CGFloat = 200
    static let fileCardPadding: CGFloat = 12
    static let fileCardIconSize: CGFloat = 24
    static let fileCardGap: CGFloat = 10
    static let fileCardNameFontSize: CGFloat = 13
    static let fileCardSizeFontSize: CGFloat = 12
    static let fileCardLineGap: CGFloat = 2

    // MARK: Видео в ленте

    /// Обложка: ширина — `photoMaxWidth`, высота по пропорциям в рамках виджета (`.att-video` 60…240).
    /// Фон обложки до прихода кадра — как виджет (`.att-video` `background:#1f2329`) и Android.
    static let videoCoverBackgroundHex = "#1f2329"
    static let videoCoverMinHeight: CGFloat = 60
    static let videoCoverMaxHeight: CGFloat = 240
    /// «Плей» по центру обложки — круг 44, `rgba(0,0,0,.55)`; длительность — у нижнего leading-края.
    static let videoPlaySize: CGFloat = 44
    static let videoPlayGlyphSize: CGFloat = 16
    static let mediaScrimAlpha: CGFloat = 0.55
    static let videoDurationFontSize: CGFloat = 12
    static let videoDurationInset: CGFloat = 6

    /// Место фото в ленте ДО загрузки: известны размеры — сразу вписанный размер, иначе плашка 200×150.
    static func photoReservedSize(width: Int?, height: Int?) -> CGSize {
        guard let width, let height, width > 0, height > 0 else {
            return CGSize(width: photoPlaceholderWidth, height: photoPlaceholderHeight)
        }
        return photoFittedSize(CGSize(width: width, height: height))
    }

    /// Обложка видео в ленте — одна и та же до и после загрузки кадра (строка не прыгает).
    static func videoCoverSize(width: Int?, height: Int?) -> CGSize {
        MediaRules.videoCoverSize(width: width, height: height, maxWidth: photoMaxWidth,
                                  minHeight: videoCoverMinHeight, maxHeight: videoCoverMaxHeight)
    }

    // MARK: Экран «недоступен» (§4 строка 81)

    static let refreshButtonHeight: CGFloat = 34
    static let refreshButtonRadius: CGFloat = 10
    static let refreshButtonFontSize: CGFloat = 14
    /// Макет экрана: `.retry{height:34px;padding:0 18px}` — 18, не 16.
    static let refreshButtonPaddingHorizontal: CGFloat = 18

    // MARK: Hex

    /// Приводит цвет канала к каноничному `#rrggbb` в нижнем регистре; `nil` — не цвет (§7).
    /// Принимаются ОБЕ формы — `#d9412e` и `d9412e`, регистр любой: сервер отдаёт `primaryColor`
    /// и с решёткой, и без (единое правило с Android).
    static func normalizedHex(_ hex: String) -> String? {
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard body.count == 6, body.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return "#" + body.lowercased()
    }

    static func isValidHex(_ hex: String) -> Bool { normalizedHex(hex) != nil }

    static func color(hex: String) -> Color? {
        guard let normalized = normalizedHex(hex),
              let v = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
        return Color(
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255
        )
    }
}

extension View {
    /// §9: минимальная зона касания 44×44. Растит САМ узел кнопки, а не кладётся накладкой:
    /// `overlay` размера родителя не меняет, и в дереве доступности кнопки остались бы
    /// 34×34, а крестик шапки — вовсе 15×24, то есть §9 не выполнялся бы.
    /// Единое правило с Android (`TouchCircle` = `requiredSize(44)` вокруг круга 34);
    /// лишние 5 по вертикали шапка и композер вычитают из своего паддинга.
    func touchTarget() -> some View {
        frame(width: Theme.minHitTarget, height: Theme.minHitTarget)
            .contentShape(Rectangle())
    }

    /// Возвращает в РАСКЛАДКУ круг 34, оставляя касанию все 44 (§9): отрицательный отступ
    /// уменьшает измеряемую ширину до `composerControlSize`, а сама кнопка рисуется и ловит
    /// касания по-прежнему в 44 и просто вылезает на паддинг композера.
    ///
    /// Без этого горизонталь §4 строки 79 ломается: круги начинаются на 17 вместо 12,
    /// а зазор круг↔поле выходит 13 вместо 8 — перехлёст `touchTarget()` вычитается только
    /// по вертикали. Вычитать его из паддинга и зазора всей строки нельзя: при выключенных
    /// вложениях скрепки нет, и поле уехало бы к краю.
    func touchTargetHorizontalOverhang() -> some View {
        padding(.horizontal, -Theme.touchOverhang)
    }
}
