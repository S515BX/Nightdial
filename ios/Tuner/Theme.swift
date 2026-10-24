import SwiftUI
import UIKit
import CoreText

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Small color math on 0xRRGGBB values (same rules as the TV and web versions).
enum Hex {
    static func parts(_ h: UInt32) -> (Double, Double, Double) {
        (Double((h >> 16) & 0xFF), Double((h >> 8) & 0xFF), Double(h & 0xFF))
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let x = parts(a), y = parts(b)
        func c(_ p: Double, _ q: Double) -> UInt32 { UInt32(max(0, min(255, (p + (q - p) * t).rounded()))) }
        return (c(x.0, y.0) << 16) | (c(x.1, y.1) << 8) | c(x.2, y.2)
    }

    static func luminance(_ h: UInt32) -> Double {
        let p = parts(h)
        func lin(_ v: Double) -> Double { let s = v / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(p.0) + 0.7152 * lin(p.1) + 0.0722 * lin(p.2)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// White or `dark`, whichever reads better on `h`.
    static func ink(_ h: UInt32, dark: UInt32) -> UInt32 {
        contrast(h, 0xFFFFFF) >= contrast(h, dark) ? 0xFFFFFF : dark
    }

    static func string(_ h: UInt32) -> String { String(format: "#%06X", h) }

    static func parse(_ s: String) -> UInt32? {
        let t = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard t.count == 6 else { return nil }
        return UInt32(t, radix: 16)
    }
}

// MARK: - Themes

struct ThemeDef: Identifiable, Hashable {
    let id: String
    let name: String
    var season = false
    let bg: UInt32
    let panel: UInt32
    let accent: UInt32
    let accent2: UInt32
    var glowA: UInt32? = nil
    var glowB: UInt32? = nil
    var hl: UInt32? = nil
    var paper: UInt32? = nil
    var deco: String? = nil      // snow, bats, leaves, hearts, clover, petals, fireworks, sparkle
    var glyph: String? = nil     // small badge on the logo, e.g. "deco-tree"
    var glyphColor: UInt32? = nil
}

enum Themes {
    static let all: [ThemeDef] = [
        ThemeDef(id: "midnight", name: "Midnight", bg: 0x161922, panel: 0x1F2330, accent: 0x5EE6C4, accent2: 0x4CC9F0, glowA: 0x4CC9F0, glowB: 0xFF6B8B),
        ThemeDef(id: "aurora", name: "Aurora", bg: 0x13131F, panel: 0x1D1D2E, accent: 0xA99CFF, accent2: 0xFF7EB6, glowA: 0x7B6CFF, glowB: 0xFF6BB0),
        ThemeDef(id: "ocean", name: "Ocean", bg: 0x0C1622, panel: 0x14222F, accent: 0x4CC9F0, accent2: 0x5EE6C4, glowA: 0x2F8CFF, glowB: 0x2EE6D6),
        ThemeDef(id: "sunset", name: "Sunset", bg: 0x1A1220, panel: 0x261B2D, accent: 0xFF9A62, accent2: 0xFF5F8F, glowA: 0xFF8A4C, glowB: 0xC25BFF),
        ThemeDef(id: "oled", name: "OLED black", bg: 0x000000, panel: 0x111216, accent: 0x5EE6C4, accent2: 0x4CC9F0),
        ThemeDef(id: "forest", name: "Forest", bg: 0x0F1613, panel: 0x18221D, accent: 0x8BE15B, accent2: 0x3DDC97, glowA: 0x3DDC97, glowB: 0xC7E15B),
        ThemeDef(id: "rose", name: "Rosé", bg: 0x1A1216, panel: 0x271C22, accent: 0xFF8FAB, accent2: 0xFFC29E, glowA: 0xFF6B8B, glowB: 0xFFB38A, hl: 0xFFF1F4),
        ThemeDef(id: "classic", name: "Classic", bg: 0x0A0F15, panel: 0x0F1720, accent: 0xF5A83C, accent2: 0xF7C46C, hl: 0xF5A83C),
        ThemeDef(id: "newyear", name: "New Year", season: true, bg: 0x0C0C14, panel: 0x18182A, accent: 0xF5D06F, accent2: 0xE2E4FF, glowA: 0xF5D06F, glowB: 0x8B8CFF, deco: "sparkle", glyph: "deco-spark", glyphColor: 0xF5D06F),
        ThemeDef(id: "valentine", name: "Valentine's", season: true, bg: 0x1A0F17, panel: 0x281723, accent: 0xFF4D8D, accent2: 0xFF9EB5, glowA: 0xFF4D8D, glowB: 0xFF2E63, hl: 0xFFE3EC, deco: "hearts", glyph: "deco-heart", glyphColor: 0xFF4D8D),
        ThemeDef(id: "stpatricks", name: "St. Patrick's", season: true, bg: 0x0C1711, panel: 0x13241A, accent: 0x3DDC84, accent2: 0xF2C94C, glowA: 0x3DDC84, glowB: 0xF2C94C, deco: "clover", glyph: "deco-clover", glyphColor: 0x3DDC84),
        ThemeDef(id: "easter", name: "Easter", season: true, bg: 0x171625, panel: 0x222035, accent: 0xB8A1FF, accent2: 0x7EE8C8, glowA: 0xB8A1FF, glowB: 0xFFB3D1, deco: "petals", glyph: "deco-flower", glyphColor: 0xFFB3D1),
        ThemeDef(id: "july4", name: "4th of July", season: true, bg: 0x0D1222, panel: 0x161D34, accent: 0xFF4D5E, accent2: 0x5B8CFF, glowA: 0xFF4D5E, glowB: 0x3D6BFF, deco: "fireworks", glyph: "deco-star", glyphColor: 0xFF4D5E),
        ThemeDef(id: "halloween", name: "Halloween", season: true, bg: 0x130E16, panel: 0x1F1623, accent: 0xFF7A1A, accent2: 0xB45CFF, glowA: 0xFF7A1A, glowB: 0x8F3DFF, hl: 0xFF8A2A, deco: "bats", glyph: "deco-pumpkin", glyphColor: 0xFF7A1A),
        ThemeDef(id: "thanksgiving", name: "Thanksgiving", season: true, bg: 0x18120D, panel: 0x251B13, accent: 0xF29E4C, accent2: 0xE0605E, glowA: 0xF29E4C, glowB: 0xC2410C, hl: 0xFDF1DF, deco: "leaves", glyph: "deco-leaf", glyphColor: 0xF29E4C),
        ThemeDef(id: "christmas", name: "Christmas", season: true, bg: 0x0D1813, panel: 0x15261E, accent: 0xEF4B4B, accent2: 0xF3C75F, glowA: 0xE63946, glowB: 0x2ECC71, hl: 0xFBF7EE, paper: 0xFBF7EE, deco: "snow", glyph: "deco-tree", glyphColor: 0x3CCF7A)
    ]

    static func find(_ id: String) -> ThemeDef { all.first { $0.id == id } ?? all[0] }

    static let highlightColors: [(String, String)] = [("auto", "Theme color"), ("#FFFFFF", "White"), ("#5EE6C4", "Mint"), ("#4CC9F0", "Sky"), ("#A99CFF", "Lavender"), ("#FF7EB6", "Pink"), ("#F6C453", "Gold"), ("#FF8A3D", "Orange"), ("#FF5A6E", "Red"), ("#8BE15B", "Lime")]
    static let menuColors: [(String, String)] = [("auto", "Theme color"), ("#1D2130", "Slate"), ("#0B0C10", "Black"), ("#131B33", "Navy"), ("#22152F", "Plum"), ("#10231B", "Forest"), ("#2B1219", "Wine"), ("#251D17", "Mocha"), ("#2A2D35", "Graphite")]
}

/// Holiday seasons (US dates). Each holiday theme turns on in its season when "automatic" is on.
enum Holidays {
    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    private static func addDays(_ d: Date, _ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: d) ?? d }

    static func easter(_ y: Int) -> Date {
        let a = y % 19, b = y / 100, c = y % 100, d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30, i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = (a + 11 * h + 22 * l) / 451
        return day(y, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1)
    }

    static func thanksgiving(_ y: Int) -> Date {
        let first = day(y, 11, 1)
        let wd = Calendar.current.component(.weekday, from: first)   // 1 = Sunday, 5 = Thursday
        return day(y, 11, 1 + (5 - wd + 7) % 7 + 21)
    }

    static func range(_ id: String, _ y: Int) -> (Date, Date) {
        switch id {
        case "newyear": return (day(y, 12, 27), day(y + 1, 1, 2))
        case "valentine": return (day(y, 2, 7), day(y, 2, 14))
        case "stpatricks": return (day(y, 3, 11), day(y, 3, 17))
        case "easter": let e = easter(y); return (addDays(e, -7), addDays(e, 1))
        case "july4": return (day(y, 6, 28), day(y, 7, 5))
        case "halloween": return (day(y, 10, 1), day(y, 10, 31))
        case "thanksgiving": let t = thanksgiving(y); return (addDays(t, -10), addDays(t, 1))
        default: return (day(y, 12, 1), day(y, 12, 26))
        }
    }

    static let order = ["newyear", "valentine", "stpatricks", "easter", "july4", "halloween", "thanksgiving", "christmas"]

    static func active(_ now: Date = Date()) -> (id: String, until: Date)? {
        let today = Calendar.current.startOfDay(for: now)
        let y = Calendar.current.component(.year, from: now)
        for id in order {
            for yy in [y - 1, y] {
                let (a, b) = range(id, yy)
                if today >= a && today <= b { return (id: id, until: b) }
            }
        }
        return nil
    }

    static func next(_ now: Date = Date()) -> (id: String, from: Date)? {
        let y = Calendar.current.component(.year, from: now)
        var best: (String, Date)? = nil
        for id in order {
            for yy in [y, y + 1] {
                let a = range(id, yy).0
                if a > now && (best == nil || a < best!.1) { best = (id, a) }
            }
        }
        if let b = best { return (id: b.0, from: b.1) }
        return nil
    }
}

// MARK: - Fonts

struct FontChoice: Identifiable, Hashable {
    let id: String
    let name: String
    /// PostScript names for regular, medium, semibold, bold. Empty for the system font.
    let faces: [String]
    /// Some families run wider than San Francisco; this keeps guide titles from getting cut off.
    let scale: CGFloat
}

enum Fonts {
    static let all: [FontChoice] = [
        FontChoice(id: "poppins", name: "Poppins", faces: ["Poppins-Regular", "Poppins-Medium", "Poppins-SemiBold", "Poppins-Bold"], scale: 0.92),
        FontChoice(id: "outfit", name: "Outfit", faces: ["Outfit-Regular", "Outfit-Medium", "Outfit-SemiBold", "Outfit-Bold"], scale: 0.99),
        FontChoice(id: "manrope", name: "Manrope", faces: ["Manrope-Regular", "Manrope-Medium", "Manrope-SemiBold", "Manrope-Bold"], scale: 0.94),
        FontChoice(id: "nunito", name: "Nunito", faces: ["Nunito-Regular", "Nunito-Medium", "Nunito-SemiBold", "Nunito-Bold"], scale: 0.98),
        FontChoice(id: "barlow", name: "Barlow", faces: ["BarlowSemiCondensed-Medium", "BarlowSemiCondensed-Medium", "BarlowSemiCondensed-SemiBold", "BarlowSemiCondensed-Bold"], scale: 1.04),
        FontChoice(id: "system", name: "System", faces: [], scale: 0.96)
    ]

    static let files = ["Poppins-Regular", "Poppins-Medium", "Poppins-SemiBold", "Poppins-Bold",
                        "Outfit-Regular", "Outfit-Medium", "Outfit-SemiBold", "Outfit-Bold",
                        "Manrope-Regular", "Manrope-Medium", "Manrope-SemiBold", "Manrope-Bold",
                        "Nunito-Regular", "Nunito-Medium", "Nunito-SemiBold", "Nunito-Bold",
                        "BarlowSemiCondensed-Medium", "BarlowSemiCondensed-SemiBold", "BarlowSemiCondensed-Bold"]

    /// The fonts ship inside the asset catalog as data; register them once at launch.
    static func registerAll() {
        for name in files {
            guard let asset = NSDataAsset(name: "font-" + name),
                  let provider = CGDataProvider(data: asset.data as CFData),
                  let font = CGFont(provider) else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
        }
    }

    static func find(_ id: String) -> FontChoice { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Look (theme + colors + font + size), shared by every screen

struct ThemeColors {
    var bg, panel, menu, railBack, cell, cellNow, cellHover, line, lineSoft, fg, fg2, fg3: UInt32
    var accent, accent2, accentInk, hl, hlInk, paper, paperInk, paper2: UInt32
    var glowA: UInt32?
    var glowB: UInt32?
    var menuTinted: Bool
}

final class Look: ObservableObject {
    static let shared = Look()
    static let sizes: [(String, String, CGFloat)] = [("xs", "Smallest", 0.86), ("s", "Smaller", 0.93), ("m", "Standard", 1.0), ("l", "Larger", 1.1)]
    private let defaults = UserDefaults.standard

    @Published var themeId: String { didSet { changed("theme", themeId) } }
    @Published var highlight: String { didSet { changed("hl", highlight) } }
    @Published var menu: String { didSet { changed("menu", menu) } }
    @Published var font: String { didSet { changed("font", font) } }
    @Published var size: String { didSet { changed("size", size) } }
    @Published var autoSeason: Bool { didSet { changed("auto", autoSeason) } }
    @Published var decorations: Bool { didSet { changed("deco", decorations) } }
    @Published var glow: Bool { didSet { changed("glow", glow) } }
    /// Bumps whenever anything changes; the main screen rebuilds on it.
    @Published private(set) var revision = 0

    private(set) var theme: ThemeDef
    private(set) var colors: ThemeColors
    private(set) var fontChoice: FontChoice

    private init() {
        func s(_ k: String, _ d: String) -> String { UserDefaults.standard.string(forKey: "tuner.look." + k) ?? d }
        func b(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: "tuner.look." + k) == nil ? d : UserDefaults.standard.bool(forKey: "tuner.look." + k) }
        themeId = s("theme", "midnight")
        highlight = s("hl", "auto")
        menu = s("menu", "auto")
        font = s("font", "poppins")
        size = s("size", "s")
        autoSeason = b("auto", false)
        decorations = b("deco", true)
        glow = b("glow", true)
        theme = Themes.all[0]
        colors = Look.makeColors(Themes.all[0], hl: "auto", menu: "auto")
        fontChoice = Fonts.all[0]
        recompute()
    }

    private func changed(_ key: String, _ value: Any) {
        defaults.set(value, forKey: "tuner.look." + key)
        recompute()
        revision += 1
    }

    var effectiveThemeId: String {
        if autoSeason, let h = Holidays.active() { return h.id }
        return themeId
    }

    /// Called on a timer so a holiday theme switches on (and off) by itself.
    func checkSeason() {
        if effectiveThemeId != theme.id {
            recompute()
            revision += 1
        }
    }

    func resetLook() {
        themeId = "midnight"; highlight = "auto"; menu = "auto"; font = "poppins"; size = "s"
        autoSeason = false; decorations = true; glow = true
    }

    private func recompute() {
        theme = Themes.find(effectiveThemeId)
        colors = Look.makeColors(theme, hl: highlight, menu: menu)
        fontChoice = Fonts.find(font)
    }

    static func makeColors(_ t: ThemeDef, hl hlPick: String, menu menuPick: String) -> ThemeColors {
        let hl = Hex.parse(hlPick) ?? t.hl ?? 0xFFFFFF
        let menuColor = Hex.parse(menuPick) ?? Hex.mix(t.panel, t.bg, 0.3)
        let tinted = Hex.parse(menuPick) != nil
        return ThemeColors(
            bg: t.bg, panel: t.panel, menu: menuColor, railBack: tinted ? menuColor : t.bg,
            cell: Hex.mix(t.panel, 0xFFFFFF, 0.055), cellNow: Hex.mix(t.panel, 0xFFFFFF, 0.085), cellHover: Hex.mix(t.panel, 0xFFFFFF, 0.13),
            line: Hex.mix(t.panel, 0xFFFFFF, 0.08), lineSoft: Hex.mix(t.panel, 0xFFFFFF, 0.045),
            fg: 0xF3F5F9, fg2: Hex.mix(0xFFFFFF, t.bg, 0.34), fg3: Hex.mix(0xFFFFFF, t.bg, 0.56),
            accent: t.accent, accent2: t.accent2, accentInk: Hex.ink(t.accent, dark: Hex.mix(t.accent, 0x000000, 0.84)),
            hl: hl, hlInk: Hex.ink(hl, dark: Hex.mix(t.bg, 0x000000, 0.25)),
            paper: t.paper ?? 0xF4F6FB, paperInk: 0x161922, paper2: 0x5D6476,
            glowA: t.glowA, glowB: t.glowB, menuTinted: tinted)
    }

    var sizeScale: CGFloat { Look.sizes.first { $0.0 == size }?.2 ?? 0.93 }
    var fontScale: CGFloat { sizeScale * fontChoice.scale }

    func face(_ weight: UIFont.Weight) -> String? {
        let f = fontChoice.faces
        guard f.count == 4 else { return nil }
        switch weight {
        case .bold, .heavy, .black: return f[3]
        case .semibold: return f[2]
        case .medium: return f[1]
        default: return f[0]
        }
    }
}

/// UIKit colors for the current look.
enum Palette {
    private static var c: ThemeColors { Look.shared.colors }
    static var bg: UIColor { UIColor(hex: c.bg) }
    static var panel: UIColor { UIColor(hex: c.panel) }
    static var menu: UIColor { UIColor(hex: c.menu) }
    static var cell: UIColor { UIColor(hex: c.cell) }
    static var cellNow: UIColor { UIColor(hex: c.cellNow) }
    static var cellHover: UIColor { UIColor(hex: c.cellHover) }
    static var line: UIColor { UIColor(hex: c.line) }
    static var lineSoft: UIColor { UIColor(hex: c.lineSoft) }
    static var fg: UIColor { UIColor(hex: c.fg) }
    static var fg2: UIColor { UIColor(hex: c.fg2) }
    static var fg3: UIColor { UIColor(hex: c.fg3) }
    static var accent: UIColor { UIColor(hex: c.accent) }
    static var accent2: UIColor { UIColor(hex: c.accent2) }
    static var accentInk: UIColor { UIColor(hex: c.accentInk) }
    static var hl: UIColor { UIColor(hex: c.hl) }
    static var hlInk: UIColor { UIColor(hex: c.hlInk) }
    static let live = UIColor(hex: 0xFF5A6E)
    static let ok = UIColor(hex: 0x5EE6C4)
    static let warn = UIColor(hex: 0xF6C453)
    static let logoBack = UIColor(hex: 0x11141B)

    static func logo(_ hue: Double) -> UIColor {
        var h = hue.truncatingRemainder(dividingBy: 360) / 360
        if h < 0 { h += 1 }
        return UIColor(hue: CGFloat(h), saturation: 0.46, brightness: 0.5, alpha: 1)
    }
}

/// SwiftUI colors for the current look.
enum Theme {
    private static var c: ThemeColors { Look.shared.colors }
    private static func col(_ h: UInt32, _ a: Double = 1) -> Color { Color(uiColor: UIColor(hex: h, alpha: a)) }
    static var bg: Color { col(c.bg) }
    static var panel: Color { col(c.panel) }
    static var menu: Color { col(c.menu) }
    static var railBack: Color { c.menuTinted ? col(c.menu) : .clear }
    static var cell: Color { col(c.cell) }
    static var cellNow: Color { col(c.cellNow) }
    static var cellHover: Color { col(c.cellHover) }
    static var line: Color { col(c.line) }
    static var fg: Color { col(c.fg) }
    static var fg2: Color { col(c.fg2) }
    static var fg3: Color { col(c.fg3) }
    static var accent: Color { col(c.accent) }
    static var accent2: Color { col(c.accent2) }
    static var accentInk: Color { col(c.accentInk) }
    static var accentSoft: Color { col(c.accent, 0.17) }
    static var hl: Color { col(c.hl) }
    static var hlInk: Color { col(c.hlInk) }
    static var paper: Color { col(c.paper) }
    static var paperInk: Color { col(c.paperInk) }
    static var paper2: Color { col(c.paper2) }
    static var glowA: Color { c.glowA.map { col($0, 0.22) } ?? .clear }
    static var glowB: Color { c.glowB.map { col($0, 0.17) } ?? .clear }
    static let live = Color(uiColor: Palette.live)
    static let ok = Color(uiColor: Palette.ok)
    static let warn = Color(uiColor: Palette.warn)
    static var accentGradient: LinearGradient { LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing) }
}

enum TFont {
    /// Headings and guide text in the chosen font, scaled for the chosen size.
    static func cond(_ size: CGFloat, _ weight: UIFont.Weight = .semibold) -> UIFont {
        let look = Look.shared
        let s = size * look.fontScale
        if let face = look.face(weight), let f = UIFont(name: face, size: s) { return f }
        return UIFont.systemFont(ofSize: s, weight: weight)
    }

    /// Body text: same family, scaled for size.
    static func ui(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont { cond(size, weight) }

    static func digits(_ size: CGFloat, _ weight: UIFont.Weight = .medium) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: size * Look.shared.sizeScale, weight: weight)
    }

    /// The demo's on-screen TV graphics keep a broadcast look whatever font is chosen.
    static func broadcast(_ size: CGFloat, _ weight: UIFont.Weight = .semibold) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight, width: .condensed)
    }
}

extension Font {
    static func cond(_ size: CGFloat, _ weight: UIFont.Weight = .semibold) -> Font {
        Font(TFont.cond(size, weight) as CTFont)
    }

    static func ui(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> Font {
        Font(TFont.ui(size, weight) as CTFont)
    }
}

enum Fmt {
    static func time(_ d: Date, _ h24: Bool) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let h = c.hour ?? 0, m = c.minute ?? 0
        if h24 { return String(format: "%02d:%02d", h, m) }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12):" + String(format: "%02d", m) + (h < 12 ? " am" : " pm")
    }

    static func day(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let diff = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return dayFormatter.string(from: d)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    static func shortDate(_ d: Date) -> String { shortFormatter.string(from: d) }

    /// Playback position: 4:05 or 1:02:09.
    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.isFinite ? seconds.rounded() : 0))
        let h = t / 3600, m = t % 3600 / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func localeUses24h() -> Bool {
        let f = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? ""
        return !f.contains("a")
    }
}
