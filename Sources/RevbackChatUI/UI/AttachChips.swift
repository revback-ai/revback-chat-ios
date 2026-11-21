import SwiftUI

/// Плашки выбранных файлов над композером.
/// Фото — плитка 72×72 с миниатюрой (обрезка по центру), скругление 12, рамка 1 `hairline`; видео — та же плитка с
/// кадром, «плей» по центру и длительностью у нижнего leading-края; документ — карточка 200×72: значок, имя в
/// одну строку с обрезкой ПО СЕРЕДИНЕ (расширение видно), под ним размер. Крестик — круг 20 в углу trailing/top со
/// сдвигом наружу, зона касания 44, ярлык «Убрать файл». Зазор 12; ряд листается и прокручивается к новому.
///
/// Высота ряда одна при любом составе и состоянии (плитка и карточка — по 72, «грузится» — те же габариты, без
/// отдельного вида): ряд не прыгает. Отступ сверху (`composerPaddingVertical`) больше сдвига крестика — он не
/// обрезается прокруткой.
struct AttachChips: View {
    let chips: [ChipRow]
    let strings: Strings
    let onRemove: (String) -> Void

    /// Сколько плашек было при прошлой смене — отличить добавление от снятия.
    @State private var shownCount = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.tileGap) {
                    ForEach(chips) { chip in
                        ChipItem(chip: chip, strings: strings, onRemove: { onRemove(chip.id) })
                            .id(chip.id)
                    }
                }
                .padding(.horizontal, Theme.composerPaddingHorizontal)
                .padding(.top, Theme.composerPaddingVertical)
                #if DEBUG
                .reportChipFrame(id: "", part: .content)
                #endif
            }
            #if DEBUG
            .coordinateSpace(name: ChipFrame.space)
            #endif
            .onChange(of: chips.count) { count in
                // Только после добавления — к новому; снятие плашки ряд не дёргает.
                defer { shownCount = count }
                guard count > shownCount, let last = chips.last?.id else { return }
                withAnimation { proxy.scrollTo(last, anchor: .trailing) }
            }
            .onAppear { shownCount = chips.count }
        }
    }
}

/// Одна плашка: плитка или карточка плюс крестик поверх угла.
struct ChipItem: View {
    let chip: ChipRow
    let strings: Strings
    let onRemove: () -> Void

    var body: some View {
        content
            #if DEBUG
            .reportChipFrame(id: chip.id, part: .tile)
            #endif
            .overlay(alignment: .topTrailing) { removeButton }
    }

    @ViewBuilder
    private var content: some View {
        switch chip.media.kind {
        case .photo, .video:
            ChipTile(chip: chip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ChipItem.accessibilityLabel(chip, strings: strings))
                .accessibilityAddTraits(.isImage)
        case .file:
            FileCard(chip: chip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ChipItem.accessibilityLabel(chip, strings: strings))
        }
    }

    /// §9: фото — имя файла; видео — «Видео, <длительность>, <имя>»; документ — имя и размер. Пока файл грузится —
    /// в конце «, загружается» (паритет Android): ход загрузки на плитке VoiceOver не видит.
    static func accessibilityLabel(_ chip: ChipRow, strings: Strings) -> String {
        let base: String
        switch chip.media.kind {
        case .video:
            base = MediaRules.videoAccessibilityLabel(video: strings.video, durationMs: chip.media.durationMs,
                                                      name: chip.fileName)
        case .photo:
            base = chip.fileName
        case .file:
            base = "\(chip.fileName), \(MediaRules.fileSizeText(chip.media.byteCount))"
        }
        return chip.uploading && !strings.uploading.isEmpty ? "\(base), \(strings.uploading)" : base
    }

    /// Круг 20 в углу topTrailing зоны касания 44, а сама зона привязана к углу плашки и сдвинута наружу ровно на
    /// выступ круга `tileRemoveOutset` (паритет Android): круг выступает за угол на 6, зона целиком
    /// в ряду (отступы ряда сверху и сбоку больше 6) — прокрутка её не режет; 38 из 44 уходят внутрь плашки, зоны
    /// соседей не пересекаются (зазор 12 > 6). Сдвиг по горизонтали — к trailing (в RTL — влево).
    private var removeButton: some View {
        let shift = Theme.tileRemoveOutset
        return Button(action: onRemove) {
            ZStack {
                Circle().fill(Theme.chipClose)
                Circle().strokeBorder(Theme.surface, lineWidth: 1)
                RemoveGlyph()
                    .stroke(Theme.surface, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: Theme.tileRemoveGlyphSize, height: Theme.tileRemoveGlyphSize)
            }
            .frame(width: Theme.tileRemoveSize, height: Theme.tileRemoveSize)
            #if DEBUG
            .reportChipFrame(id: chip.id, part: .removeCircle)
            #endif
            .frame(width: Theme.minHitTarget, height: Theme.minHitTarget, alignment: .topTrailing)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(strings.attachRemove)   // §9
        // Замер — ДО сдвига: так рамка зоны в координатах ряда учитывает сам сдвиг (`offset` — эффект геометрии).
        #if DEBUG
        .reportChipFrame(id: chip.id, part: .removeZone)
        #endif
        // В RTL `offset` по горизонтали SwiftUI зеркалит сам (как `offset` Compose) — второй раз не зеркалим.
        .offset(x: shift, y: -shift)
    }
}

/// Рамка части ряда плашек в координатах ряда (`ChipFrame.space` — видимая область прокрутки): содержимое, плашка,
/// зона касания крестика и его круг. Наружу — предпочтением `ChipFrameKey`; читает его только тест геометрии (зона
/// крестика целиком в ряду, зоны соседей не пересекаются). Только в debug-сборке (тесты гоняются в ней): в релизе ни замеров, ни `GeometryReader`, ни предпочтения нет — как и вызовов `reportChipFrame`.
#if DEBUG
struct ChipFrame: Equatable {
    enum Part: Equatable { case content, tile, removeZone, removeCircle }

    static let space = "revback.chips"

    var id: String
    var part: Part
    var rect: CGRect
}

struct ChipFrameKey: PreferenceKey {
    static let defaultValue: [ChipFrame] = []

    static func reduce(value: inout [ChipFrame], nextValue: () -> [ChipFrame]) {
        value += nextValue()
    }
}

private extension View {
    func reportChipFrame(id: String, part: ChipFrame.Part) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: ChipFrameKey.self,
                                   value: [ChipFrame(id: id, part: part, rect: g.frame(in: .named(ChipFrame.space)))])
        })
    }
}
#endif

/// Плитка 72×72: миниатюра (обрезка по центру) или заглушка; у видео — «плей» и длительность.
struct ChipTile: View {
    let chip: ChipRow
    @State private var showsUpload = false

    var body: some View {
        ZStack {
            Theme.chipBackground
            if let tile = chip.media.tile {
                Image(uiImage: tile)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Theme.tileSize, height: Theme.tileSize)
                    .clipped()
            } else if chip.media.kind == .photo {
                // Как Android: у фото без миниатюры — значок картинки, а не пустой фон.
                ImageGlyph()
                    .stroke(Theme.controlGlyph, style: Theme.glyphStroke)
                    .frame(width: Theme.tileGlyphSize, height: Theme.tileGlyphSize)
                    .accessibilityHidden(true)
            }
            // Миниатюры нет (сбой извлечения) — плитка-заглушка: фон плашки; у видео остаются «плей» и длительность.
            // Пока файл грузится — по центру ход загрузки (паритет Android), у видео вместо «плей».
            if chip.uploading && showsUpload {
                UploadBadge(size: Theme.tilePlaySize)
            } else if chip.media.kind == .video {
                PlayBadge(size: Theme.tilePlaySize)
            }
            if chip.media.kind == .video {
                if let duration = MediaRules.formatDuration(ms: chip.media.durationMs) {
                    DurationBadge(text: duration, fontSize: Theme.tileDurationFontSize)
                        .padding(Theme.tileDurationInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
        }
        .frame(width: Theme.tileSize, height: Theme.tileSize)
        .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius)
            .strokeBorder(Theme.hairline, lineWidth: Theme.tileBorderWidth))
        .delayedUploadIndicator(chip.uploading, shown: $showsUpload)
    }
}

/// Карточка документа 200×72 (как Android): значок 24, имя (обрезка посередине), размер.
struct FileCard: View {
    let chip: ChipRow
    @State private var showsUpload = false

    var body: some View {
        HStack(spacing: Theme.fileCardGap) {
            // Пока файл грузится — ход загрузки на месте значка, тем же цветом и в тех же габаритах (паритет Android).
            Group {
                if chip.uploading && showsUpload {
                    UploadSpinner(color: Theme.chipText, lineWidth: 2)
                        .padding(Theme.fileCardIconSize * 0.125)
                } else {
                    FileGlyph().stroke(Theme.chipText, style: Theme.glyphStroke)
                }
            }
            .frame(width: Theme.fileCardIconSize, height: Theme.fileCardIconSize)
            VStack(alignment: .leading, spacing: Theme.fileCardLineGap) {
                Text(chip.fileName)
                    .font(.system(size: Theme.fileCardNameFontSize))
                    .foregroundColor(Theme.chipText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(MediaRules.fileSizeText(chip.media.byteCount))
                    .font(.system(size: Theme.fileCardSizeFontSize))
                    .foregroundColor(Theme.chipClose)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.fileCardPadding)
        .frame(width: Theme.fileCardWidth, height: Theme.tileSize)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius).fill(Theme.chipBackground))
        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius)
            .strokeBorder(Theme.hairline, lineWidth: Theme.tileBorderWidth))
        .delayedUploadIndicator(chip.uploading, shown: $showsUpload)
    }
}

/// Задержка показа хода загрузки (паритет Android `UPLOAD_INDICATOR_DELAY_MS`): мгновенная заливка не мигает
/// индикатором. Загрузка кончилась — индикатор снимается сразу.
enum UploadIndicator {
    static let delayNanoseconds: UInt64 = 300_000_000
}

private extension View {
    func delayedUploadIndicator(_ uploading: Bool, shown: Binding<Bool>) -> some View {
        task(id: uploading) {
            shown.wrappedValue = false
            guard uploading else { return }
            try? await Task.sleep(nanoseconds: UploadIndicator.delayNanoseconds)
            if !Task.isCancelled { shown.wrappedValue = true }
        }
    }
}

/// «Плей»: круг `rgba(0,0,0,.55)` с белым треугольником (как `.att-video .play` виджета).
struct PlayBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(Double(Theme.mediaScrimAlpha)))
            PlayGlyph()
                .fill(Color.white)
                .frame(width: size * 0.4, height: size * 0.4)
                .offset(x: size * 0.04)   // оптический центр треугольника
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Ход загрузки на плитке: круг той же подложки, что у «плей» (`mediaScrimAlpha`), с белой вращающейся дугой.
/// Без процента: до сервера байты доходят через буфер HTTP/2 (до 1 МБ) — счёт отправленного показывал бы 100 % задолго
/// до конца, а на iOS ядро прогресс заливки и не отдаёт (`KtorHttpTransport`). Паритет Android `UploadBadge`.
struct UploadBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(Double(Theme.mediaScrimAlpha)))
            UploadSpinner(color: .white, lineWidth: 2)
                .padding(size * 0.2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Неопределённый ход: дуга в три четверти круга, оборот за `period` секунд.
struct UploadSpinner: View {
    let color: Color
    let lineWidth: CGFloat
    static let period: Double = 0.9

    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: Self.period).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityHidden(true)
    }
}

/// Длительность на тёмной подложке (как `.att-video .dur` виджета).
struct DurationBadge: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: fontSize).monospacedDigit())
            .foregroundColor(.white)
            .padding(.horizontal, Theme.durationPaddingHorizontal)
            .padding(.vertical, Theme.durationPaddingVertical)
            .background(RoundedRectangle(cornerRadius: Theme.durationRadius).fill(Color.black.opacity(0.6)))
            .accessibilityHidden(true)
    }
}

/// Треугольник «плей» вершиной в сторону воспроизведения.
struct PlayGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// «✕» крестика плашки.
struct RemoveGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}

/// Значок документа — Feather `file` (viewport 24, как Android `RevbackIcons.File`): лист с загнутым углом.
struct FileGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var p = Path()
        // M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z
        p.move(to: pt(13, 2))
        p.addLine(to: pt(6, 2))
        p.addArc(tangent1End: pt(4, 2), tangent2End: pt(4, 4), radius: 2 * k)
        p.addLine(to: pt(4, 20))
        p.addArc(tangent1End: pt(4, 22), tangent2End: pt(6, 22), radius: 2 * k)
        p.addLine(to: pt(18, 22))
        p.addArc(tangent1End: pt(20, 22), tangent2End: pt(20, 20), radius: 2 * k)
        p.addLine(to: pt(20, 9))
        p.closeSubpath()
        // M13 2v7h7
        p.move(to: pt(13, 2))
        p.addLine(to: pt(13, 9))
        p.addLine(to: pt(20, 9))
        return p
    }
}

/// Значок картинки — Feather `image` (viewport 24, как Android `RevbackIcons.Image`): рамка, солнце, склон.
struct ImageGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var p = Path()
        p.addRoundedRect(in: CGRect(origin: pt(3, 3), size: CGSize(width: 18 * k, height: 18 * k)),
                         cornerSize: CGSize(width: 2 * k, height: 2 * k))
        p.addEllipse(in: CGRect(origin: pt(7, 7), size: CGSize(width: 3 * k, height: 3 * k)))
        p.move(to: pt(21, 15))
        p.addLine(to: pt(16, 10))
        p.addLine(to: pt(5, 21))
        return p
    }
}
