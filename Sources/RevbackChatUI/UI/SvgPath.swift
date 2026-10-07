import CoreGraphics
import Foundation

/// Разбор подмножества SVG-атрибута `d` — `M m L l H h V v C c A a Z z` — в `CGPath`.
///
/// Иконок в брифе три, и все дуги в них круговые (`rx == ry`), поэтому эллиптические
/// дуги с поворотом не поддерживаются: параметр `x-axis-rotation` читается и игнорируется.
/// Флаги `large-arc`/`sweep` читаются обычным числовым сканером — склейка вида `011`
/// (три флага без разделителей) не поддерживается; в брифе её нет.
enum SvgPath {

    /// Кэш готовых путей по (`d`, `box`, `size`). Иконок в брифе три, размеров у них — единицы,
    /// а разбор строки шёл на каждую перерисовку каждого кадра: `SvgIcon` строит путь прямо в
    /// `body`, и лента с композером пересобираются на каждую букву черновика.
    /// Кэш пополняется только с главного потока — `body` вьюхи изолирован им (`@MainActor`).
    private static var cache: [String: CGPath] = [:]

    /// Строит путь в координатах `0…size`, считая исходный `viewBox` равным `0 0 box box`.
    static func cgPath(d: String, box: CGFloat, size: CGFloat) -> CGPath {
        let key = "\(size)|\(box)|\(d)"
        if let cached = cache[key] { return cached }
        let path = parse(d: d, box: box, size: size)
        cache[key] = path
        return path
    }

    private static func parse(d: String, box: CGFloat, size: CGFloat) -> CGPath {
        let raw = CGMutablePath()
        var s = Scanner(d)
        var cur = CGPoint.zero
        var subStart = CGPoint.zero
        var cmd: Character = " "

        while !s.atEnd {
            if let c = s.command() {
                cmd = c
            } else if cmd == "M" {
                cmd = "L"           // лишние пары после M — это L (SVG 9.3.3)
            } else if cmd == "m" {
                cmd = "l"
            } else if cmd == " " {
                break               // мусор в начале строки
            }

            let rel = cmd.isLowercase
            switch Character(cmd.uppercased()) {
            case "M":
                guard let x = s.number(), let y = s.number() else { return finish(raw, box: box, size: size) }
                cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                subStart = cur
                raw.move(to: cur)

            case "L":
                guard let x = s.number(), let y = s.number() else { return finish(raw, box: box, size: size) }
                cur = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                raw.addLine(to: cur)

            case "H":
                guard let x = s.number() else { return finish(raw, box: box, size: size) }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                raw.addLine(to: cur)

            case "V":
                guard let y = s.number() else { return finish(raw, box: box, size: size) }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                raw.addLine(to: cur)

            case "C":
                guard let x1 = s.number(), let y1 = s.number(),
                      let x2 = s.number(), let y2 = s.number(),
                      let x = s.number(), let y = s.number()
                else { return finish(raw, box: box, size: size) }
                let o = rel ? cur : CGPoint.zero
                let c1 = CGPoint(x: o.x + x1, y: o.y + y1)
                let c2 = CGPoint(x: o.x + x2, y: o.y + y2)
                cur = CGPoint(x: o.x + x, y: o.y + y)
                raw.addCurve(to: cur, control1: c1, control2: c2)

            case "A":
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let large = s.number(), let sweep = s.number(),
                      let x = s.number(), let y = s.number()
                else { return finish(raw, box: box, size: size) }
                _ = rot
                let end = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
                addCircularArc(raw, from: cur, to: end, radius: max(rx, ry),
                               largeArc: large != 0, sweep: sweep != 0)
                cur = end

            case "Z":
                raw.closeSubpath()
                cur = subStart

            default:
                return finish(raw, box: box, size: size)
            }
        }
        return finish(raw, box: box, size: size)
    }

    private static func finish(_ path: CGMutablePath, box: CGFloat, size: CGFloat) -> CGPath {
        guard box > 0, size != box else { return path }
        var t = CGAffineTransform(scaleX: size / box, y: size / box)
        return path.copy(using: &t) ?? path
    }

    /// Дуга SVG в эндпоинт-форме → центровая (SVG 1.1, F.6.5), частный случай `rx == ry`.
    private static func addCircularArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                                       radius: CGFloat, largeArc: Bool, sweep: Bool) {
        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        let chord = (dx * dx + dy * dy).squareRoot()
        guard chord > 0, radius > 0 else {
            path.addLine(to: p1)
            return
        }
        // F.6.6: радиус меньше половины хорды — растягиваем до половины
        let r = max(radius, chord / 2)
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let h = max(0, r * r - chord * chord / 4).squareRoot()
        let nx = -dy / chord           // единичная нормаль к хорде
        let ny = dx / chord
        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let c = CGPoint(x: mid.x + sign * h * nx, y: mid.y + sign * h * ny)
        let a0 = atan2(p0.y - c.y, p0.x - c.x)
        let a1 = atan2(p1.y - c.y, p1.x - c.x)
        // CGPath меряет углы против часовой в сторону роста; sweep = 1 у SVG — тоже рост угла
        // в той же (y-вниз) числовой системе, поэтому clockwise = !sweep.
        path.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: !sweep)
    }

    private struct Scanner {
        private let chars: [Character]
        private var i = 0

        init(_ s: String) { chars = Array(s) }

        private mutating func skip() {
            while i < chars.count, chars[i] == " " || chars[i] == "," ||
                    chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" {
                i += 1
            }
        }

        var atEnd: Bool {
            mutating get { skip(); return i >= chars.count }
        }

        mutating func command() -> Character? {
            skip()
            guard i < chars.count, chars[i].isLetter else { return nil }
            defer { i += 1 }
            return chars[i]
        }

        mutating func number() -> CGFloat? {
            skip()
            var j = i
            if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
            var hasDigits = false
            while j < chars.count, isDigit(chars[j]) { j += 1; hasDigits = true }
            if j < chars.count, chars[j] == "." {
                j += 1
                while j < chars.count, isDigit(chars[j]) { j += 1; hasDigits = true }
            }
            if hasDigits, j < chars.count, chars[j] == "e" || chars[j] == "E" {
                var k = j + 1
                if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
                var expDigits = false
                while k < chars.count, isDigit(chars[k]) { k += 1; expDigits = true }
                if expDigits { j = k }
            }
            guard hasDigits, let v = Double(String(chars[i..<j])) else { return nil }
            i = j
            return CGFloat(v)
        }

        private func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
    }
}
