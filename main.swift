// remtui — a terminal UI for the "Scheduled" view of Apple Reminders.
// Backed by EventKit. Gruvbox colors, never paints a background
// (so transparent terminals stay transparent).

import CoreGraphics
import Darwin
import EventKit
import Foundation

// MARK: - Gruvbox

struct RGB {
    let r: Int, g: Int, b: Int
    init(_ hex: Int) { r = (hex >> 16) & 0xff; g = (hex >> 8) & 0xff; b = hex & 0xff }
}

enum Gruv {
    static let fg = RGB(0xebdbb2)
    static let fg2 = RGB(0xd5c4a1)
    static let fg4 = RGB(0xa89984)
    static let gray = RGB(0x928374)
    static let bg3 = RGB(0x665c54)
    static let red = RGB(0xfb4934)
    static let green = RGB(0xb8bb26)
    static let yellow = RGB(0xfabd2f)
    static let blue = RGB(0x83a598)
    static let purple = RGB(0xd3869b)
    static let aqua = RGB(0x8ec07c)
    static let orange = RGB(0xfe8019)
}

enum Style {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let italic = "\u{1B}[3m"
    static let strike = "\u{1B}[9m"
    static func fg(_ c: RGB) -> String { "\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m" }
}

/// Foreground-only coloring; reset returns to the terminal's default
/// (transparent) background.
func paint(_ s: String, _ c: RGB, _ extra: String = "") -> String {
    s.isEmpty ? "" : Style.fg(c) + extra + s + Style.reset
}

func sp(_ n: Int) -> String { String(repeating: " ", count: max(0, n)) }

extension String {
    /// Truncate with an ellipsis and pad to exactly `w` columns.
    func fit(_ w: Int) -> String {
        guard w > 0 else { return "" }
        if count > w { return String(prefix(w - 1)) + "…" }
        return self + sp(w - count)
    }
    func clip(_ w: Int) -> String {
        guard w > 0 else { return "" }
        return count > w ? String(prefix(w - 1)) + "…" : self
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Split text into visual lines no wider than `w`: hard breaks at "\n",
/// soft breaks at the last space that fits (or mid-word if none). Ranges
/// exclude the "\n" itself; soft-wrapped ranges are contiguous.
func wrapRanges(_ text: [Character], width w: Int) -> [Range<Int>] {
    let w = max(1, w)
    var out: [Range<Int>] = []
    var start = 0
    while true {
        var end = start
        while end < text.count, text[end] != "\n" { end += 1 }
        // wrap the hard line start..<end
        var s = start
        while end - s > w {
            var cut = s + w
            if let sp = (s + 1..<s + w).last(where: { text[$0] == " " }) { cut = sp + 1 }
            out.append(s..<cut)
            s = cut
        }
        out.append(s..<end)
        if end >= text.count { break }
        start = end + 1
    }
    return out
}

/// Index of the visual line holding `cursor` (a soft-wrap boundary belongs to the next line).
func lineIndex(of cursor: Int, in lines: [Range<Int>]) -> Int {
    lines.lastIndex { $0.lowerBound <= cursor } ?? 0
}

/// Map an arbitrary list color onto the nearest Gruvbox accent by hue.
func gruvColor(for cg: CGColor?) -> RGB {
    guard let cg,
          let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let c = cg.converted(to: srgb, intent: .defaultIntent, options: nil),
          let comp = c.components, comp.count >= 3
    else { return Gruv.fg4 }
    let r = Double(comp[0]), g = Double(comp[1]), b = Double(comp[2])
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    if mx == 0 || d / mx < 0.2 { return Gruv.fg4 }
    var h: Double
    if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
    else if mx == g { h = (b - r) / d + 2 }
    else { h = (r - g) / d + 4 }
    h *= 60
    if h < 0 { h += 360 }
    switch h {
    case ..<15: return Gruv.red
    case 15..<40: return Gruv.orange
    case 40..<70: return Gruv.yellow
    case 70..<150: return Gruv.green
    case 150..<200: return Gruv.aqua
    case 200..<260: return Gruv.blue
    case 260..<355: return Gruv.purple
    default: return Gruv.red
    }
}

// MARK: - Terminal

enum Terminal {
    static var original = termios()
    static var active = false

    static func enter() {
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        withUnsafeMutableBytes(of: &raw.c_cc) { p in
            p[Int(VMIN)] = 1
            p[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        // alt screen, hide cursor, disable line wrap, and push kitty keyboard
        // protocol (flag 1: disambiguate) so ⌘/super combos reach us as CSI u.
        out("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[>1u")
        active = true
    }

    static func leave() {
        guard active else { return }
        out("\u{1B}[<u\u{1B}[0m\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        active = false
    }

    static func out(_ s: String) {
        var s = s
        s.withUTF8 { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(STDOUT_FILENO, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    static func size() -> (rows: Int, cols: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
            return (Int(ws.ws_row), Int(ws.ws_col))
        }
        return (24, 80)
    }
}

// MARK: - Keys

struct Mods: OptionSet {
    let rawValue: Int
    static let shift = Mods(rawValue: 1)
    static let alt = Mods(rawValue: 2)    // ⌥
    static let ctrl = Mods(rawValue: 4)   // ⌃
    static let cmd = Mods(rawValue: 8)    // ⌘ (kitty "super")
}

enum Key {
    case char(Character)
    case up, down, left, right, home, end, pageUp, pageDown
    case enter, esc, backspace, delete, tab
    case newline                  // ⌥↵ / ⇧↵ / ^J — literal line break in text fields
    case wordLeft, wordRight      // ⌥← ⌥→ (also ESC b / ESC f, ⌃← ⌃→)
    case wordBackspace, wordDelete // ⌥⌫ / ⌥⌦
    case lineBackspace            // ⌘⌫
    case ctrl(UInt8)              // 1...26 → a...z
    case cmd(Character, Mods)     // any ⌘ combo; character is lowercase
}

/// Translate a kitty-protocol key code + modifiers into a Key.
func keyFromCode(_ code: Int, _ mods: Mods) -> Key? {
    guard let scalar = UnicodeScalar(code) else { return nil }
    switch code {
    case 127, 8:
        if mods.contains(.cmd) { return .lineBackspace }
        if !mods.intersection([.alt, .ctrl]).isEmpty { return .wordBackspace }
    case 13:
        if !mods.intersection([.alt, .shift]).isEmpty { return .newline }
    default: break
    }
    if mods.contains(.cmd) {
        return .cmd(Character(String(Character(scalar)).lowercased()), mods)
    }
    switch code {
    case 27: return .esc
    case 13: return .enter
    case 9: return .tab
    case 127, 8: return .backspace
    default: break
    }
    if mods.contains(.ctrl), (97...122).contains(code) { return .ctrl(UInt8(code - 96)) }
    if mods.subtracting(.shift).isEmpty {
        let c = Character(scalar)
        return .char(mods.contains(.shift) ? Character(String(c).uppercased()) : c)
    }
    return nil
}

func readByte(timeoutMs: Int32 = -1) -> UInt8? {
    if timeoutMs >= 0 {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, timeoutMs) <= 0 { return nil }
    }
    var b: UInt8 = 0
    let n = read(STDIN_FILENO, &b, 1)
    if n == 0 { stdinEOF = true }
    return n == 1 ? b : nil
}

var stdinEOF = false

func readKey() -> Key? {
    guard let b = readByte() else { return nil }
    switch b {
    case 27:
        guard let b2 = readByte(timeoutMs: 25) else { return .esc }
        // Legacy meta sequences (Ghostty's default ⌥←/⌥→ send ESC b / ESC f).
        switch b2 {
        case UInt8(ascii: "b"): return .wordLeft
        case UInt8(ascii: "f"): return .wordRight
        case UInt8(ascii: "d"): return .wordDelete
        case 127, 8: return .wordBackspace
        case 13, 10: return .newline
        default: break
        }
        guard b2 == UInt8(ascii: "[") || b2 == UInt8(ascii: "O") else { return .esc }
        // Read CSI params up to the final byte (0x40–0x7E).
        var params = ""
        var final: UInt8 = 0
        while let c = readByte(timeoutMs: 25) {
            if (0x40...0x7E).contains(c) { final = c; break }
            params.append(Character(UnicodeScalar(c)))
            if params.count > 48 { return nil }
        }
        let fields = params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let modsRaw = fields.count > 1 ? Int(fields[1].split(separator: ":").first ?? "1") ?? 1 : 1
        let mods = Mods(rawValue: max(0, modsRaw - 1) & 0b1111)
        switch final {
        case UInt8(ascii: "u"):
            // code[:shifted[:base-layout]];mods[:event]u
            let sub = (fields.first ?? "").split(separator: ":", omittingEmptySubsequences: false)
            let code = Int(sub.first ?? "") ?? 0
            let base = sub.count > 2 ? Int(sub[2]) : nil
            return keyFromCode(base ?? code, mods)
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"):
            if mods.contains(.cmd) { return .end }
            return mods.intersection([.alt, .ctrl]).isEmpty ? .right : .wordRight
        case UInt8(ascii: "D"):
            if mods.contains(.cmd) { return .home }
            return mods.intersection([.alt, .ctrl]).isEmpty ? .left : .wordLeft
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "~"):
            switch fields.first ?? "" {
            case "5": return .pageUp
            case "6": return .pageDown
            case "3": return mods.intersection([.alt, .ctrl]).isEmpty ? .delete : .wordDelete
            case "1", "7": return .home
            case "4", "8": return .end
            default: return nil
            }
        default: return nil
        }
    case 13: return .enter
    case 10: return .newline
    case 127, 8: return .backspace
    case 9: return .tab
    case 1...26: return .ctrl(b)
    default:
        if b < 0x80 { return .char(Character(UnicodeScalar(b))) }
        var bytes = [b]
        let extra = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : 1
        for _ in 0..<extra { if let c = readByte(timeoutMs: 25) { bytes.append(c) } }
        if let s = String(bytes: bytes, encoding: .utf8), let ch = s.first { return .char(ch) }
        return nil
    }
}

// MARK: - Dates

enum Fmt {
    static func make(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    static let weekdayShort = make("EEEMMMd")
    static let weekday = make("EEEE")
    static let monthDay = make("MMMd")
    static let month = make("MMMM")
    static let monthYear = make("MMMMyyyy")
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

enum DateStyle { case timeOnly, full }

struct Section {
    let key: String
    let title: String
    let subtitle: String
    let color: RGB
    let style: DateStyle
}

func section(for d: Date, now: Date = Date(), history: Bool = false) -> Section {
    let cal = Calendar.current
    let today = cal.startOfDay(for: now)
    let day = cal.startOfDay(for: d)
    let diff = cal.dateComponents([.day], from: today, to: day).day ?? 0
    if history {
        // Completed reminders that were due in the past (shown with ⇧⌘H).
        let y = cal.component(.year, from: d), m = cal.component(.month, from: d)
        let title = y == cal.component(.year, from: today) ? Fmt.month.string(from: d) : Fmt.monthYear.string(from: d)
        return Section(key: "h\(y)-\(m)", title: title, subtitle: "completed", color: Gruv.gray, style: .full)
    }
    switch diff {
    case ..<0:
        return Section(key: "overdue", title: "Overdue", subtitle: "", color: Gruv.red, style: .full)
    case 0:
        return Section(key: "today", title: "Today", subtitle: Fmt.weekdayShort.string(from: d),
                       color: Gruv.orange, style: .timeOnly)
    case 1:
        return Section(key: "tomorrow", title: "Tomorrow", subtitle: Fmt.weekdayShort.string(from: d),
                       color: Gruv.yellow, style: .timeOnly)
    case 2...6:
        return Section(key: "d\(diff)", title: Fmt.weekday.string(from: d), subtitle: Fmt.monthDay.string(from: d),
                       color: Gruv.yellow, style: .timeOnly)
    default:
        let y = cal.component(.year, from: d), m = cal.component(.month, from: d)
        let sameMonth = y == cal.component(.year, from: today) && m == cal.component(.month, from: today)
        let title: String
        if sameMonth { title = "Later in " + Fmt.month.string(from: d) }
        else if y == cal.component(.year, from: today) { title = Fmt.month.string(from: d) }
        else { title = Fmt.monthYear.string(from: d) }
        return Section(key: "m\(y)-\(m)", title: title, subtitle: "", color: Gruv.aqua, style: .full)
    }
}

// MARK: - Recurrence

/// A standard repeat, as offered by Reminders.app (minus hourly, which
/// EventKit can't express).
struct RepeatPreset: Equatable {
    let label: String
    let short: String      // for the row's repeat column on narrow terminals
    let freq: EKRecurrenceFrequency
    var interval = 1
    var days: [Int] = []   // EKWeekday raw values (Sunday = 1); empty = the due date's own day

    static let all: [RepeatPreset] = [
        .init(label: "Daily", short: "daily", freq: .daily),
        .init(label: "Weekdays", short: "wkdays", freq: .weekly, days: [2, 3, 4, 5, 6]),
        .init(label: "Weekends", short: "wkends", freq: .weekly, days: [1, 7]),
        .init(label: "Weekly", short: "weekly", freq: .weekly),
        .init(label: "Every 2 weeks", short: "2 wks", freq: .weekly, interval: 2),
        .init(label: "Monthly", short: "monthly", freq: .monthly),
        .init(label: "Every 3 months", short: "3 mos", freq: .monthly, interval: 3),
        .init(label: "Every 6 months", short: "6 mos", freq: .monthly, interval: 6),
        .init(label: "Yearly", short: "yearly", freq: .yearly),
    ]

    var rule: EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: freq, interval: interval,
                         daysOfTheWeek: days.isEmpty ? nil : days.compactMap { EKWeekday(rawValue: $0).map(EKRecurrenceDayOfWeek.init) },
                         daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                         daysOfTheYear: nil, setPositions: nil, end: nil)
    }

    /// Whether an existing rule is this preset. A rule with no days, or just
    /// one day (how some clients spell "on the due date's day"), counts as
    /// the day-less preset.
    func matches(_ r: EKRecurrenceRule) -> Bool {
        guard r.frequency == freq, r.interval == interval, r.recurrenceEnd == nil else { return false }
        // EventKit pins monthly/yearly rules to the due date itself: a single
        // day/month, or — for the 29th–31st — "e.g. 28th/29th, last that
        // exists" (setPositions [-1]). Anything beyond that is a custom rule.
        let pinned = (r.daysOfTheMonth?.count ?? 0) <= 1 || r.setPositions == [-1]
        guard pinned, (r.monthsOfTheYear?.count ?? 0) <= 1,
              r.setPositions == nil || r.setPositions == [-1] else { return false }
        let rd = (r.daysOfTheWeek ?? []).filter { $0.weekNumber == 0 }.map { $0.dayOfTheWeek.rawValue }.sorted()
        guard rd.count == (r.daysOfTheWeek?.count ?? 0) else { return false }
        return days.isEmpty ? rd.count <= 1 : rd == days
    }

    static func matching(_ r: EKRecurrenceRule) -> RepeatPreset? { all.first { $0.matches(r) } }
}

/// Choices on the editor's Repeat line. `.keep` holds a rule made elsewhere
/// (e.g. "every Mon, Wed" from Reminders.app) that the presets can't express,
/// so editing such a reminder doesn't silently drop it.
enum RepeatOption: Equatable {
    case once, preset(RepeatPreset), keep(EKRecurrenceRule)

    /// The options for a reminder (nil = new) and which one is current.
    static func options(for r: EKReminder?) -> (opts: [RepeatOption], index: Int) {
        let base = [RepeatOption.once] + RepeatPreset.all.map(RepeatOption.preset)
        guard let rule = r?.recurrenceRules?.first else { return (base, 0) }
        if let p = RepeatPreset.matching(rule), let i = base.firstIndex(of: .preset(p)) { return (base, i) }
        return ([.keep(rule)] + base, 0)
    }

    var label: String {
        switch self {
        case .once: return "One time"
        case .preset(let p): return p.label
        case .keep(let rule): return Recur.describe(rule)
        }
    }

    var repeats: Bool { self != .once }

    func apply(to r: EKReminder) {
        switch self {
        case .once:
            if r.hasRecurrenceRules { r.recurrenceRules = nil }
        case .preset(let p):
            if !(r.recurrenceRules?.first.map(p.matches) ?? false) { r.recurrenceRules = [p.rule] }
            // Weekdays/Weekends must start on one of their days: move the
            // due date forward (keeping the time) if it's on another day.
            if !p.days.isEmpty, let it = Item(r) {
                let cal = Calendar.current
                for i in 0..<7 {
                    guard let d = cal.date(byAdding: .day, value: i, to: it.due) else { break }
                    if p.days.contains(cal.component(.weekday, from: d)) {
                        if i > 0 { setDue(r, d, allDay: it.allDay) }
                        break
                    }
                }
            }
        case .keep: break
        }
    }
}

enum Recur {
    /// "weekly", "every 2 weeks on Mon, Thu", "every weekday", "monthly until Dec 31".
    static func describe(_ r: EKRecurrenceRule) -> String {
        if let p = RepeatPreset.matching(r) { return p.label.lowercased() }
        let n = r.interval
        let (unit, adverb): (String, String)
        switch r.frequency {
        case .daily: (unit, adverb) = ("day", "daily")
        case .weekly: (unit, adverb) = ("week", "weekly")
        case .monthly: (unit, adverb) = ("month", "monthly")
        default: (unit, adverb) = ("year", "yearly")
        }
        let days = (r.daysOfTheWeek ?? []).filter { $0.weekNumber == 0 }.map { $0.dayOfTheWeek.rawValue }.sorted()
        var s: String
        if r.frequency == .weekly && n == 1 && days == [2, 3, 4, 5, 6] {
            s = "every weekday"
        } else if r.frequency == .weekly && n == 1 && days == [1, 7] {
            s = "every weekend"
        } else if r.frequency == .weekly && !days.isEmpty {
            let names = days.map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
            s = n == 1 ? "every \(names)" : "every \(n) weeks on \(names)"
        } else {
            s = n == 1 ? adverb : "every \(n) \(unit)s"
        }
        if let e = r.recurrenceEnd {
            if let d = e.endDate { s += " until " + Fmt.monthDay.string(from: d) }
            else if e.occurrenceCount > 0 { s += ", \(e.occurrenceCount) times" }
        }
        return s
    }

    static func describe(_ r: EKReminder) -> String? { r.recurrenceRules?.first.map(describe) }

    /// Compact form for narrow rows: "wkdays", "2 wks", or "custom".
    static func short(_ r: EKReminder) -> String? {
        r.recurrenceRules?.first.map { RepeatPreset.matching($0)?.short ?? "custom" }
    }
}

struct Parsed {
    var title: String
    var date: Date?
    var allDay: Bool
}

/// "call mom tomorrow at 5pm" → title "call mom", tomorrow 17:00.
func parseEntry(_ text: String) -> Parsed {
    let ns = text as NSString
    guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
          let m = det.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
          let date = m.date
    else { return Parsed(title: text.trimmed, date: nil, allDay: true) }

    let matched = ns.substring(with: m.range)
    var title = ns.replacingCharacters(in: m.range, with: " ")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    for w in [" at", " on", " by", " due"] where title.lowercased().hasSuffix(w) {
        title = String(title.dropLast(w.count))
    }
    let timeRe = try! NSRegularExpression(
        pattern: #"\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\b\d{1,2}:\d{2}\b|\b(noon|midnight|morning|afternoon|evening|tonight)\b"#,
        options: .caseInsensitive)
    let timed = timeRe.firstMatch(in: matched, range: NSRange(location: 0, length: (matched as NSString).length)) != nil
    return Parsed(title: title.trimmed, date: date, allDay: !timed)
}

func describeDue(_ d: Date, allDay: Bool) -> String {
    let s = section(for: d)
    let day: String
    switch s.key {
    case "today", "tomorrow": day = s.title
    default: day = Fmt.weekdayShort.string(from: d)
    }
    return allDay ? day : "\(day) at \(Fmt.time.string(from: d))"
}

// MARK: - Model

struct Item {
    let reminder: EKReminder
    let due: Date
    let allDay: Bool
    /// Completed + past-due (only visible with "show completed").
    var history = false

    init?(_ r: EKReminder) {
        guard let comps = r.dueDateComponents, let d = Calendar.current.date(from: comps) else { return nil }
        reminder = r
        due = d
        allDay = comps.hour == nil
    }

    var id: String { reminder.calendarItemIdentifier }

    func isOverdue(now: Date) -> Bool {
        if reminder.isCompleted { return false }
        return allDay ? due < Calendar.current.startOfDay(for: now) : due < now
    }
}

func sortItems(_ items: [Item]) -> [Item] {
    let cal = Calendar.current
    return items.sorted { a, b in
        if a.history != b.history { return a.history }
        let da = cal.startOfDay(for: a.due), db = cal.startOfDay(for: b.due)
        if da != db { return da < db }
        if a.allDay != b.allDay { return a.allDay }
        if a.due != b.due { return a.due < b.due }
        return (a.reminder.title ?? "") < (b.reminder.title ?? "")
    }
}

func setDue(_ r: EKReminder, _ date: Date, allDay: Bool) {
    let cal = Calendar.current
    var comps = cal.dateComponents(allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: date)
    comps.calendar = cal
    r.dueDateComponents = comps
    // Reminders.app pairs a timed due date with an alarm; keep that behavior.
    for a in r.alarms ?? [] where a.absoluteDate != nil { r.removeAlarm(a) }
    if !allDay { r.addAlarm(EKAlarm(absoluteDate: date)) }
}

/// Same day-of-week rules as Reminders.app's ⌘K / ⌥⌘K.
enum Relative {
    static func today() -> Date { Calendar.current.startOfDay(for: Date()) }
    static func tomorrow() -> Date { Calendar.current.date(byAdding: .day, value: 1, to: today())! }
    /// Saturday; if today is Friday or Saturday, the following weekend.
    static func weekend() -> Date {
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: today()) // 1 = Sun … 7 = Sat
        var add = (7 - wd) % 7
        if add <= 1 { add += 7 }
        return cal.date(byAdding: .day, value: add, to: today())!
    }
    /// Next Monday.
    static func nextWeek() -> Date {
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: today())
        var add = (9 - wd) % 7
        if add == 0 { add = 7 }
        return cal.date(byAdding: .day, value: add, to: today())!
    }
}

/// Move to `day`, keeping the reminder's time of day if it has one.
func moved(_ it: Item, to day: Date) -> Date {
    guard !it.allDay else { return day }
    let cal = Calendar.current
    let t = cal.dateComponents([.hour, .minute], from: it.due)
    return cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: day) ?? day
}

func priorityMark(_ p: Int) -> String {
    switch p {
    case 1...4: return "!!!"
    case 5: return "!!"
    case 6...9: return "!"
    default: return ""
    }
}

// MARK: - Text field

/// Single-line-display editable text with a cursor and macOS-style motions.
/// Notes may contain newlines; "line" motions respect them.
struct Field {
    var text: [Character]
    var cursor: Int
    var scroll = 0   // first visible character, maintained by the renderer

    init(_ s: String) { text = Array(s); cursor = text.count }

    var string: String { String(text) }

    static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "'" }

    var wordStartBefore: Int {
        var i = cursor
        while i > 0, !Field.isWord(text[i - 1]) { i -= 1 }
        while i > 0, Field.isWord(text[i - 1]) { i -= 1 }
        return i
    }
    var wordEndAfter: Int {
        var i = cursor
        while i < text.count, !Field.isWord(text[i]) { i += 1 }
        while i < text.count, Field.isWord(text[i]) { i += 1 }
        return i
    }
    var lineStart: Int {
        var i = cursor
        while i > 0, text[i - 1] != "\n" { i -= 1 }
        return i
    }
    var lineEnd: Int {
        var i = cursor
        while i < text.count, text[i] != "\n" { i += 1 }
        return i
    }

    /// Move the cursor up/down one visual (wrapped) line, keeping its column.
    /// Returns false when already on the first/last line.
    mutating func moveLine(_ d: Int, width: Int) -> Bool {
        let vis = wrapRanges(text, width: width)
        let cl = lineIndex(of: cursor, in: vis)
        let target = cl + d
        guard vis.indices.contains(target) else { return false }
        let col = cursor - vis[cl].lowerBound
        let t = vis[target]
        // on a soft-wrapped line, the end index belongs to the next line, so stop one short
        let softEnd = target + 1 < vis.count && vis[target + 1].lowerBound == t.upperBound
        cursor = t.lowerBound + min(col, max(0, t.count - (softEnd ? 1 : 0)))
        return true
    }

    mutating func insert(_ c: Character) { text.insert(c, at: cursor); cursor += 1 }
    mutating func move(to i: Int) { cursor = max(0, min(text.count, i)) }
    mutating func deleteRange(_ a: Int, _ b: Int) {
        let lo = max(0, min(a, b)), hi = min(text.count, max(a, b))
        guard lo < hi else { return }
        text.removeSubrange(lo..<hi)
        cursor = lo
    }

    /// Apply an editing/motion key. Returns false if the key isn't a field key.
    mutating func handle(_ key: Key, multiline: Bool) -> Bool {
        switch key {
        case .char(let c): insert(c)
        case .newline: if multiline { insert("\n") }
        case .left, .ctrl(2): move(to: cursor - 1)            // ← ^B
        case .right, .ctrl(6): move(to: cursor + 1)           // → ^F
        case .wordLeft: move(to: wordStartBefore)
        case .wordRight: move(to: wordEndAfter)
        case .home, .ctrl(1):                                 // ⌘← ^A
            move(to: cursor == lineStart && multiline ? 0 : lineStart)
        case .end, .ctrl(5):                                  // ⌘→ ^E
            move(to: cursor == lineEnd && multiline ? text.count : lineEnd)
        case .backspace: deleteRange(cursor - 1, cursor)
        case .delete, .ctrl(4): deleteRange(cursor, cursor + 1) // ⌦ ^D
        case .wordBackspace, .ctrl(23): deleteRange(wordStartBefore, cursor) // ⌥⌫ ^W
        case .wordDelete: deleteRange(cursor, wordEndAfter)
        case .lineBackspace, .ctrl(21):                      // ⌘⌫ ^U
            deleteRange(cursor == lineStart ? cursor - 1 : lineStart, cursor)
        case .ctrl(11): deleteRange(cursor, cursor == lineEnd ? cursor + 1 : lineEnd) // ^K
        default: return false
        }
        return true
    }
}

// MARK: - App

final class App {
    enum InputKind { case add, edit }
    enum Mode { case normal, input, confirmDelete(EKReminder) }
    enum Row {
        case header(Section), item(Int), notes(String), blank
    }

    struct Editor {
        enum Focus { case title, notes, repeats }
        let kind: InputKind
        let target: EKReminder?   // the reminder being edited (nil when adding)
        var title: Field
        var notes: Field
        var focus = Focus.title
        var repeatOpts: [RepeatOption]
        var repeatIdx: Int
        var repeatChoice: RepeatOption { repeatOpts[repeatIdx] }

        init(kind: InputKind, target: EKReminder?) {
            self.kind = kind
            self.target = target
            title = Field(target?.title ?? "")
            notes = Field(target?.notes ?? "")
            (repeatOpts, repeatIdx) = RepeatOption.options(for: target)
        }

        mutating func rotateRepeat(_ d: Int) {
            repeatIdx = (repeatIdx + d + repeatOpts.count) % repeatOpts.count
        }
    }

    /// Like Reminders.app: a just-checked reminder stays visible (struck
    /// through) until you pause for this long, then it's hidden — unless
    /// "show completed" is on. Each new completion restarts the countdown.
    static let doneLinger: TimeInterval = 3

    let store: EKEventStore
    var items: [Item] = []
    var sessionDone: Set<String> = []   // just completed; linger until doneClear fires
    var doneClear: DispatchWorkItem?
    var editor: Editor?
    var sel = 0
    var scroll = 0
    var mode: Mode = .normal
    var loaded = false
    var pendingSelect: String?
    var status: (String, RGB)?
    var statusClear: DispatchWorkItem?
    var listColors: [String: RGB] = [:]
    var bodyHeight = 10
    var notesWidth = 60      // wrap width for notes under the selected item (set by render)
    var noteFieldWidth = 60  // wrap width of the notes field in the editor (set by render)
    static let maxNoteRows = 8      // notes lines shown under the selected item
    static let maxNoteFieldRows = 5 // notes lines shown in the editor
    var showCompleted = false
    var showHelp = false

    init(store: EKEventStore) { self.store = store }

    var current: Item? { items.indices.contains(sel) ? items[sel] : nil }

    // MARK: data

    func reload() {
        let store = self.store
        let withCompleted = showCompleted
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: pred) { [weak self] rs in
            let open = rs ?? []
            guard withCompleted else {
                DispatchQueue.main.async { self?.apply(open, []) }
                return
            }
            let cpred = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: cpred) { cs in
                DispatchQueue.main.async { self?.apply(open, cs ?? []) }
            }
        }
    }

    func apply(_ open: [EKReminder], _ completed: [EKReminder]) {
        let keepID = pendingSelect ?? current?.id
        pendingSelect = nil
        var all = open
        var seen = Set(open.map(\.calendarItemIdentifier))
        for r in completed where seen.insert(r.calendarItemIdentifier).inserted { all.append(r) }
        for id in sessionDone {
            if let r = store.calendarItem(withIdentifier: id) as? EKReminder, r.isCompleted {
                if seen.insert(id).inserted { all.append(r) }
            } else {
                sessionDone.remove(id)
            }
        }
        let today = Calendar.current.startOfDay(for: Date())
        items = sortItems(all.compactMap { r -> Item? in
            guard var it = Item(r) else { return nil }
            it.history = r.isCompleted && !sessionDone.contains(it.id)
                && Calendar.current.startOfDay(for: it.due) < today
            return it
        })
        loaded = true
        if let keepID, let i = items.firstIndex(where: { $0.id == keepID }) { sel = i }
        sel = max(0, min(sel, items.count - 1))
        render()
    }

    func save(_ r: EKReminder) -> Bool {
        do { try store.save(r, commit: true); return true }
        catch { flash(error.localizedDescription, Gruv.red); return false }
    }

    func color(for cal: EKCalendar?) -> RGB {
        guard let cal else { return Gruv.fg4 }
        if let c = listColors[cal.calendarIdentifier] { return c }
        let c = gruvColor(for: cal.cgColor)
        listColors[cal.calendarIdentifier] = c
        return c
    }

    func flash(_ msg: String, _ color: RGB = Gruv.green) {
        status = (msg, color)
        statusClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.status = nil; self?.render() }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        render()
    }

    // MARK: actions

    func toggleDone() {
        guard let it = current else { return }
        let r = it.reminder
        let recurring = r.hasRecurrenceRules && !r.isCompleted
        r.isCompleted.toggle()
        guard save(r) else { r.isCompleted.toggle(); return }
        if recurring {
            // EventKit splits off a completed copy and rolls this reminder
            // (same ID, still incomplete) forward to its next occurrence.
            // Keep the cursor where it was instead of following it.
            pendingSelect = items.indices.contains(sel + 1) ? items[sel + 1].id
                          : sel > 0 ? items[sel - 1].id : nil
            let next = Item(r).map { " · next " + describeDue($0.due, allDay: $0.allDay) } ?? ""
            flash("Completed “\(r.title ?? "")”\(next)")
        } else if r.isCompleted {
            sessionDone.insert(it.id)
            scheduleDoneClear()
            flash("Completed “\(r.title ?? "")”")
        } else {
            sessionDone.remove(it.id)
            flash("Marked “\(r.title ?? "")” incomplete", Gruv.yellow)
        }
        reload()
    }

    /// Hide lingering completed reminders once the user pauses. Waits while
    /// an edit or delete prompt is open so rows don't shift under it.
    func scheduleDoneClear(after delay: TimeInterval = App.doneLinger) {
        doneClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.sessionDone.isEmpty else { return }
            guard case .normal = self.mode else { self.scheduleDoneClear(after: 1); return }
            self.sessionDone.removeAll()
            self.reload()
        }
        doneClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func shift(days: Int) {
        guard let it = current,
              let d = Calendar.current.date(byAdding: .day, value: days, to: it.due) else { return }
        setDue(it.reminder, d, allDay: it.allDay)
        guard save(it.reminder) else { return }
        pendingSelect = it.id
        flash("Moved to \(describeDue(d, allDay: it.allDay))", Gruv.blue)
        reload()
    }

    /// ⌘T / ⌥⌘T / ⌘K / ⌥⌘K
    func setDay(_ day: Date) {
        guard let it = current else { return }
        let d = moved(it, to: day)
        setDue(it.reminder, d, allDay: it.allDay)
        guard save(it.reminder) else { return }
        pendingSelect = it.id
        flash("Due \(describeDue(d, allDay: it.allDay))", Gruv.blue)
        reload()
    }

    /// ⌃⌘T — everything from previous days moves to today.
    func overdueToToday() {
        let today = Relative.today()
        let od = items.filter { !$0.reminder.isCompleted && Calendar.current.startOfDay(for: $0.due) < today }
        guard !od.isEmpty else { flash("Nothing overdue", Gruv.fg4); return }
        for it in od {
            setDue(it.reminder, moved(it, to: today), allDay: it.allDay)
            try? store.save(it.reminder, commit: false)
        }
        do { try store.commit() } catch { flash(error.localizedDescription, Gruv.red); return }
        flash("Moved \(od.count) overdue to Today", Gruv.blue)
        reload()
    }

    /// ⇧⌘H
    func toggleShowCompleted() {
        showCompleted.toggle()
        flash(showCompleted ? "Showing completed" : "Hiding completed", Gruv.fg4)
        reload()
    }

    /// R — step the selected reminder to the next repeat option.
    func cycleRepeat() {
        guard let it = current else { return }
        let r = it.reminder
        guard !r.isCompleted else { flash("Completed reminders can't repeat", Gruv.fg4); return }
        let (opts, i) = RepeatOption.options(for: r)
        let next = opts[(i + 1) % opts.count]
        let old = r.recurrenceRules
        next.apply(to: r)
        guard save(r) else { r.recurrenceRules = old; return }
        pendingSelect = it.id
        flash(next.repeats ? "↻ Repeats \(next.label.lowercased())" : "No longer repeats", Gruv.aqua)
        reload()
    }

    func delete(_ r: EKReminder) {
        do {
            try store.remove(r, commit: true)
            sessionDone.remove(r.calendarItemIdentifier)
            flash("Deleted “\(r.title ?? "")”", Gruv.red)
        } catch {
            flash(error.localizedDescription, Gruv.red)
        }
        reload()
    }

    func beginAdd() {
        editor = Editor(kind: .add, target: nil)
        mode = .input
    }

    func beginEdit() {
        guard let r = current?.reminder else { return }
        editor = Editor(kind: .edit, target: r)
        mode = .input
    }

    func submit(_ ed: Editor) {
        let p = parseEntry(ed.title.string)
        let notesText = ed.notes.string
        let notes: String? = notesText.trimmed.isEmpty ? nil : notesText
        let choice = ed.repeatChoice
        let repeatNote = choice.repeats ? " · ↻ \(choice.label.lowercased())" : ""
        switch ed.kind {
        case .add:
            guard !p.title.isEmpty else { return }
            guard let list = store.defaultCalendarForNewReminders() else {
                flash("No default Reminders list", Gruv.red); return
            }
            let r = EKReminder(eventStore: store)
            r.title = p.title
            r.notes = notes
            r.calendar = list
            let date = p.date ?? Date()
            let allDay = p.date == nil ? true : p.allDay
            setDue(r, date, allDay: allDay)
            choice.apply(to: r)
            guard save(r) else { return }
            pendingSelect = r.calendarItemIdentifier
            let due = Item(r).map { describeDue($0.due, allDay: $0.allDay) } ?? ""   // may have moved (Weekdays/Weekends)
            flash("Added “\(p.title)” · \(due)\(repeatNote)")
        case .edit:
            guard let r = ed.target else { return }
            if !p.title.isEmpty { r.title = p.title }
            if let d = p.date { setDue(r, d, allDay: p.allDay) }
            let hadRepeat = r.hasRecurrenceRules
            choice.apply(to: r)
            if notes != r.notes { r.notes = notes }
            guard save(r) else { return }
            pendingSelect = r.calendarItemIdentifier
            flash("Updated “\(r.title ?? "")”" + (hadRepeat && !choice.repeats ? " · no longer repeats" : repeatNote))
        }
        reload()
    }

    func quit() -> Never {
        Terminal.leave()
        exit(0)
    }

    // MARK: input

    func handle(_ key: Key) {
        switch mode {
        case .normal: handleNormal(key)
        case .confirmDelete(let r):
            mode = .normal
            if case .char(let c) = key, c == "y" || c == "Y" { delete(r) } else { render() }
        case .input:
            guard var ed = editor else { mode = .normal; render(); return }
            switch key {
            case .esc, .ctrl(3):
                mode = .normal
                editor = nil
            case .enter:
                mode = .normal
                editor = nil
                submit(ed)
                return
            case .tab:
                switch ed.focus {
                case .title: ed.focus = .notes
                case .notes: ed.focus = .repeats
                case .repeats: ed.focus = .title
                }
            case .down where ed.focus == .title: ed.focus = .notes
            case .down where ed.focus == .notes:
                if !ed.notes.moveLine(1, width: noteFieldWidth) { ed.focus = .repeats }
            case .up where ed.focus == .notes:
                if !ed.notes.moveLine(-1, width: noteFieldWidth) { ed.focus = .title }
            case .up where ed.focus == .repeats: ed.focus = .notes
            case .up, .down: break
            default:
                switch ed.focus {
                case .title: _ = ed.title.handle(key, multiline: false)
                case .notes: _ = ed.notes.handle(key, multiline: true)
                case .repeats:
                    switch key {
                    case .char(" "), .right, .char("l"): ed.rotateRepeat(1)
                    case .left, .char("h"): ed.rotateRepeat(-1)
                    default: break
                    }
                }
            }
            if case .input = mode { editor = ed }
            render()
        }
    }

    /// "⌥⌘T"-style name in Apple's modifier order (⌃⌥⇧⌘).
    func comboName(_ c: Character, _ m: Mods) -> String {
        var s = ""
        if m.contains(.ctrl) { s += "⌃" }
        if m.contains(.alt) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        return s + "⌘" + String(c).uppercased()
    }

    /// Reminders.app's default shortcuts (the ones EventKit can support).
    func handleCmd(_ c: Character, _ m: Mods) {
        switch comboName(c, m) {
        case "⌘N": beginAdd()
        case "⌘I": beginEdit()
        case "⌘T": setDay(Relative.today()); return
        case "⌥⌘T": setDay(Relative.tomorrow()); return
        case "⌃⌘T": overdueToToday(); return
        case "⌘K": setDay(Relative.weekend()); return
        case "⌥⌘K": setDay(Relative.nextWeek()); return
        case "⇧⌘C": toggleDone(); return
        case "⇧⌘H": toggleShowCompleted(); return
        case "⌘W", "⌘Q": quit()
        case "⇧⌘F", "⌘E", "⇧⌘E", "⌘]", "⌘[":
            flash("\(comboName(c, m)): flags/subtasks aren't available through EventKit", Gruv.fg4); return
        default: return
        }
        render()
    }

    func handleNormal(_ key: Key) {
        if showHelp { showHelp = false; render(); return }
        switch key {
        case .cmd(let c, let m): handleCmd(c, m); return
        case .char("?"): showHelp = true
        case .backspace, .delete, .char("x"), .char("d"):
            guard let r = current?.reminder else { return }
            mode = .confirmDelete(r)
        case .char("q"), .ctrl(3), .esc: quit()
        case .char("j"), .down: sel = min(sel + 1, items.count - 1)
        case .char("k"), .up: sel = max(sel - 1, 0)
        case .char("g"), .home: sel = 0
        case .char("G"), .end: sel = max(0, items.count - 1)
        case .ctrl(4), .pageDown: sel = min(sel + max(1, bodyHeight / 2), items.count - 1)
        case .ctrl(21), .pageUp: sel = max(sel - max(1, bodyHeight / 2), 0)
        case .char(" "): toggleDone(); return
        case .char("a"), .char("n"): beginAdd()
        case .char("e"), .enter:
            guard current != nil else { return }
            beginEdit()
        case .char("+"), .char("="), .char("l"), .right: shift(days: 1); return
        case .char("-"), .char("_"), .char("h"), .left: shift(days: -1); return
        case .char("r"): reload(); flash("Refreshed", Gruv.fg4); return
        case .char("R"): cycleRepeat(); return
        default: return
        }
        sel = max(0, sel)
        render()
    }

    // MARK: rendering

    func buildRows() -> [Row] {
        var rows: [Row] = []
        var last: String?
        let now = Date()
        for (i, it) in items.enumerated() {
            let s = section(for: it.due, now: now, history: it.history)
            if s.key != last {
                if last != nil { rows.append(.blank) }
                rows.append(.header(s))
                last = s.key
            }
            rows.append(.item(i))
            if i == sel, let n = it.reminder.notes?.trimmed, !n.isEmpty {
                let chars = Array(n.replacingOccurrences(of: "\r\n", with: "\n")
                                   .replacingOccurrences(of: "\r", with: "\n"))
                var wrapped = wrapRanges(chars, width: notesWidth).map { String(chars[$0]) }
                if wrapped.count > App.maxNoteRows {
                    wrapped = Array(wrapped.prefix(App.maxNoteRows))
                    wrapped[wrapped.count - 1] = String(wrapped[wrapped.count - 1].prefix(notesWidth - 1)) + "…"
                }
                rows += wrapped.map { .notes($0) }
            }
        }
        return rows
    }

    func render() {
        let (H, W) = Terminal.size()
        let pad = 2
        let inner = max(20, W - pad * 2)
        let now = Date()
        var lines: [String] = []

        // ── header
        let open = items.filter { !$0.reminder.isCompleted }.count
        let overdue = items.filter { $0.isOverdue(now: now) }.count
        var countText = "\(open) scheduled"
        let overText = overdue > 0 ? " · \(overdue) overdue" : ""
        let title = "Scheduled"
        // Narrow: "2 · 1 overdue" instead of running into the title.
        if title.count + 1 + countText.count + overText.count > inner { countText = "\(open)" }
        lines.append("")
        lines.append(sp(pad) + paint(title, Gruv.red, Style.bold)
                     + sp(inner - title.count - countText.count - overText.count)
                     + paint(countText, Gruv.gray) + paint(overText, Gruv.red))
        lines.append(sp(pad) + paint(String(repeating: "─", count: inner), Gruv.bg3))

        // ── body
        // Bottom hint lines wrap on narrow terminals, so build them first to
        // know how much room the footer needs.
        var tail: [String] = []
        switch mode {
        case .normal:
            tail = flow([("⌘N", "new"), ("⇧⌘C", "done"), ("⌘T", "today"), ("⌥⌘T", "tomorrow"),
                         ("⌘K", "weekend"), ("⇧⌘H", "completed"), ("⌫", "delete"), ("?", "help")]
                        .map { k, label in Hint(sep: "   ", pieces: [(k, Gruv.yellow), (" " + label, Gruv.gray)]) },
                        width: inner)
        case .input: if let ed = editor { tail = editorTail(ed, width: inner) }
        case .confirmDelete: break
        }
        // separator + status (only while a message shows) + hints; or the delete prompt
        var footerH = 1 + tail.count + (status != nil ? 1 : 0)
        if case .confirmDelete = mode { footerH = 3 }   // separator + prompt + blank
        noteFieldWidth = max(1, inner - 9 - 1)   // 9 = label width ("Notes  › ")
        if case .input = mode, let ed = editor {
            let n = wrapRanges(ed.notes.text, width: noteFieldWidth).count
            footerH = 3 + min(App.maxNoteFieldRows, max(1, n)) + tail.count   // separator + title + notes + repeat + tail
        }
        bodyHeight = max(1, H - lines.count - footerH)
        notesWidth = max(1, inner - 6)
        let rows = buildRows()
        if showHelp {
            let groups: [(String, [(String, String)])] = [
                ("Reminders shortcuts", [
                    ("⌘N", "new reminder"), ("⌘I", "edit"), ("⇧⌘C", "mark complete / incomplete"),
                    ("⌘T", "due today"), ("⌥⌘T", "due tomorrow"), ("⌃⌘T", "all overdue → today"),
                    ("⌘K", "due this weekend"), ("⌥⌘K", "due next week"),
                    ("⇧⌘H", "show / hide completed"), ("⌫", "delete"), ("⌘W ⌘Q", "quit"),
                ]),
                ("Terminal extras", [
                    ("j k ↑ ↓", "move"), ("g G", "top / bottom"), ("^D ^U", "half page"),
                    ("space", "complete"), ("a e", "add / edit"), ("+ -", "±1 day"),
                    ("R", "next repeat option (one time, daily, weekly, …)"),
                    ("x", "delete"), ("r", "refresh"), ("q", "quit"),
                ]),
                ("While editing", [
                    ("tab ↑ ↓", "switch title / notes / repeat"), ("space ← →", "change repeat"), ("← →", "move cursor"),
                    ("⌥← ⌥→", "by word"), ("⌘← ⌘→", "line start / end (^A ^E)"),
                    ("⌥⌫ ⌘⌫", "delete word / to line start"), ("⌥↵ ^J", "newline in notes"),
                ]),
            ]
            for (gi, g) in groups.enumerated() {
                if gi > 0 { lines.append("") }
                lines.append(sp(pad) + paint(g.0, Gruv.orange, Style.bold))
                for (k, label) in g.1 {
                    lines.append(sp(pad + 2) + paint(k.fit(10), Gruv.yellow) + paint(label, Gruv.fg2))
                }
            }
            lines.append("")
            lines.append(sp(pad) + paint("press any key to close", Gruv.gray))
        } else if !loaded {
            lines.append(sp(pad) + paint("Loading…", Gruv.gray))
        } else if items.isEmpty {
            lines.append("")
            lines.append(sp(pad) + paint("Nothing scheduled. Press ", Gruv.gray) + paint("a", Gruv.yellow)
                         + paint(" to add a reminder.", Gruv.gray))
        } else {
            let selRow = rows.firstIndex { if case .item(let i) = $0 { return i == sel }; return false } ?? 0
            var selEnd = selRow
            while selEnd + 1 < rows.count, case .notes = rows[selEnd + 1] { selEnd += 1 }
            var top = selRow
            if selRow > 0, case .header = rows[selRow - 1] { top -= 1 }
            if sel == 0 { top = 0 }
            if top < scroll { scroll = top }
            if selEnd >= scroll + bodyHeight { scroll = selEnd - bodyHeight + 1 }
            scroll = max(0, min(scroll, rows.count - bodyHeight))

            let layout = rowLayout(inner: inner, now: now)
            for row in rows.dropFirst(scroll).prefix(bodyHeight) {
                lines.append(sp(pad) + line(for: row, inner: inner, layout: layout, now: now))
            }
        }
        while lines.count < H - footerH { lines.append("") }
        if lines.count > H - footerH { lines = Array(lines.prefix(max(0, H - footerH))) }

        // ── footer
        lines.append(sp(pad) + paint(String(repeating: "─", count: inner), Gruv.bg3))
        var cursor: (row: Int, col: Int)?
        switch mode {
        case .normal:
            if let (msg, c) = status { lines.append(sp(pad) + paint(msg.clip(inner), c)) }
            lines += tail.map { sp(pad) + $0 }
        case .confirmDelete(let r):
            let name = r.title ?? ""
            lines.append(sp(pad) + paint("Delete “\(name.clip(inner - 20))”? ", Gruv.red, Style.bold)
                         + paint("y", Gruv.yellow) + paint("/", Gruv.gray) + paint("n", Gruv.yellow))
            lines.append("")
        case .input:
            guard var ed = editor else { break }
            let kind = ed.kind
            let titleLabel = kind == .add ? "New    › " : "Edit   › "
            let notesLabel = "Notes  › "
            let fieldW = max(1, inner - titleLabel.count - 1)

            /// Draw one field; keeps the cursor inside the visible window.
            func draw(_ f: inout Field, label: String, focused: Bool, placeholder: String) -> String {
                if f.cursor < f.scroll { f.scroll = f.cursor }
                if f.cursor > f.scroll + fieldW - 1 { f.scroll = f.cursor - fieldW + 1 }
                f.scroll = max(0, min(f.scroll, max(0, f.text.count - fieldW + 1)))
                let shown = String(f.text.dropFirst(f.scroll).prefix(fieldW).map { $0 == "\n" ? "↵" : $0 })
                let labelStyled = focused ? paint(label, Gruv.orange, Style.bold) : paint(label, Gruv.gray)
                let body = f.text.isEmpty && !focused ? paint(placeholder, Gruv.bg3, Style.italic)
                                                      : paint(shown, focused ? Gruv.fg : Gruv.fg4)
                if focused { cursor = (lines.count + 1, pad + label.count + (f.cursor - f.scroll) + 1) }
                return sp(pad) + labelStyled + body
            }
            /// Draw the notes field soft-wrapped over several rows; `scroll` is the first visible line.
            func drawNotes(_ f: inout Field, label: String, focused: Bool, placeholder: String) -> [String] {
                let labelStyled = focused ? paint(label, Gruv.orange, Style.bold) : paint(label, Gruv.gray)
                if f.text.isEmpty && !focused {
                    return [sp(pad) + labelStyled + paint(placeholder, Gruv.bg3, Style.italic)]
                }
                let vis = wrapRanges(f.text, width: fieldW)
                let rowsShown = min(App.maxNoteFieldRows, vis.count)
                let cl = lineIndex(of: f.cursor, in: vis)
                if cl < f.scroll { f.scroll = cl }
                if cl >= f.scroll + rowsShown { f.scroll = cl - rowsShown + 1 }
                f.scroll = max(0, min(f.scroll, vis.count - rowsShown))
                if focused {
                    cursor = (lines.count + 1 + (cl - f.scroll),
                              pad + label.count + (f.cursor - vis[cl].lowerBound) + 1)
                }
                var out: [String] = []
                for li in f.scroll..<(f.scroll + rowsShown) {
                    let head = li == f.scroll ? labelStyled : sp(label.count)
                    let more = li == f.scroll + rowsShown - 1 && li < vis.count - 1
                    out.append(sp(pad) + head + paint(String(f.text[vis[li]]), focused ? Gruv.fg : Gruv.fg4)
                               + (more ? paint(" …", Gruv.bg3) : ""))
                }
                return out
            }
            lines.append(draw(&ed.title, label: titleLabel, focused: ed.focus == .title, placeholder: ""))
            lines += drawNotes(&ed.notes, label: notesLabel, focused: ed.focus == .notes,
                               placeholder: "add notes (tab)")
            // Repeat line: a selector, not a text field (no cursor).
            let repFocused = ed.focus == .repeats
            let choice = ed.repeatChoice
            let repLabel = repFocused ? paint("Repeat › ", Gruv.orange, Style.bold) : paint("Repeat › ", Gruv.gray)
            let repValue = choice.repeats ? "↻ " + choice.label : choice.label
            let repColor = choice.repeats ? Gruv.aqua : (repFocused ? Gruv.fg : Gruv.fg4)
            lines.append(sp(pad) + repLabel
                         + (repFocused ? paint("‹ ", Gruv.gray) : "")
                         + paint(repValue, repColor, repFocused ? Style.bold : "")
                         + (repFocused ? paint(" ›", Gruv.gray) : ""))
            editor = ed

            lines += tail.map { sp(pad) + $0 }
        }

        var frame = "\u{1B}[H"
        for (i, l) in lines.prefix(H).enumerated() {
            frame += l + Style.reset + "\u{1B}[K" + (i < H - 1 ? "\r\n" : "")
        }
        if let cursor { frame += "\u{1B}[\(cursor.row);\(cursor.col)H\u{1B}[?25h" } else { frame += "\u{1B}[?25l" }
        Terminal.out(frame)
    }

    /// One unbreakable chunk of a hint line; `sep` goes before it unless it starts a line.
    struct Hint {
        var sep: String
        var pieces: [(String, RGB)]
        var optional = false   // dropped rather than wrapped onto its own line
        var width: Int { pieces.reduce(0) { $0 + $1.0.count } }
    }

    /// Lay hints out left to right, wrapping whole chunks onto new lines.
    func flow(_ hints: [Hint], width: Int) -> [String] {
        var out: [String] = [], cur = "", used = 0
        for h in hints {
            if used > 0 && used + h.sep.count + h.width > width {
                if h.optional { continue }
                out.append(cur); cur = ""; used = 0
            }
            if used > 0 { cur += h.sep; used += h.sep.count }
            var left = width - used   // a chunk wider than a whole line gets clipped
            for (text, color) in h.pieces where left > 0 {
                let t = text.count > left ? text.clip(left) : text
                cur += paint(t, color); used += t.count; left -= t.count
            }
        }
        if used > 0 { out.append(cur) }
        return out
    }

    /// The editor's due-date preview plus key hints, wrapped to `width`.
    func editorTail(_ ed: Editor, width: Int) -> [String] {
        let p = parseEntry(ed.title.string)
        var hs: [Hint] = []
        if let d = p.date {
            hs.append(Hint(sep: "", pieces: [("due ", Gruv.gray), (describeDue(d, allDay: p.allDay), Gruv.aqua)]))
        } else if ed.kind == .add {
            hs.append(Hint(sep: "", pieces: [("due ", Gruv.gray), ("Today", Gruv.aqua)]))
            hs.append(Hint(sep: "  ", pieces: [("· try “dentist friday 3pm”", Gruv.gray)], optional: true))
        } else {
            hs.append(Hint(sep: "", pieces: [("due date unchanged", Gruv.gray)]))
        }
        if ed.kind == .add, let list = store.defaultCalendarForNewReminders() {
            hs.append(Hint(sep: "  ", pieces: [("in ", Gruv.gray), (list.title, color(for: list))]))
        }
        var keys: [String]
        switch ed.focus {
        case .title: keys = ["tab notes"]
        case .notes: keys = ["⌥↵ newline", "tab repeat"]
        case .repeats: keys = ["space change"]
        }
        keys += ["enter save", "esc cancel"]
        for (i, k) in keys.enumerated() {
            hs.append(Hint(sep: i == 0 ? "   " : " · ", pieces: [(k, Gruv.bg3)]))
        }
        return flow(hs, width: width)
    }

    /// Column widths for item rows. 0 = column hidden.
    struct RowLayout {
        var titleW = 8, dateW = 0, repW = 0, listW = 0
        var shortRepeat = false   // "wkdays" instead of "weekdays"
    }

    /// Fit columns into `inner`, sized to what's actually on screen. The
    /// title keeps at least `minTitle`; the repeat column wins over the list
    /// column, and falls back to short labels, then to a "↻" after the date.
    func rowLayout(inner: Int, now: Date) -> RowLayout {
        let minTitle = 12, gap = 2
        var l = RowLayout()
        l.dateW = items.map { dueText($0, now: now).count }.max() ?? 0
        let dateCol = l.dateW > 0 ? l.dateW + gap : 0
        var room = inner - 4 - dateCol - minTitle   // 4 = marker + check
        let full = items.compactMap { Recur.describe($0.reminder)?.count }.max().map { min(16, $0 + 2) } ?? 0
        let short = items.compactMap { Recur.short($0.reminder)?.count }.max().map { $0 + 2 } ?? 0
        if full > 0 {
            if room >= full + gap + 4 { l.repW = full }   // +4: rather shorten labels than titles
            else if room >= short + gap { l.repW = short; l.shortRepeat = true }
            if l.repW == 0 {   // " ↻" after the date instead
                room -= l.dateW > 0 ? 2 : gap + 1
                l.dateW += l.dateW > 0 ? 2 : 1
            } else {
                room -= l.repW + gap
            }
        }
        let listW = min(18, max(6, items.map { $0.reminder.calendar?.title.count ?? 0 }.max() ?? 0))
        if room >= listW + gap + 6 { l.listW = listW }   // +6: keep the title roomier than the list
        l.titleW = max(8, inner - 4 - (l.dateW > 0 ? l.dateW + gap : 0) - (l.repW > 0 ? l.repW + gap : 0) - (l.listW > 0 ? l.listW + gap : 0))
        return l
    }

    /// "17:04" for today/tomorrow rows, "Nov 13, 07:00" further out.
    func dueText(_ it: Item, now: Date) -> String {
        switch section(for: it.due, now: now, history: it.history).style {
        case .timeOnly: return it.allDay ? "" : Fmt.time.string(from: it.due)
        case .full:
            let d = Fmt.monthDay.string(from: it.due)
            return it.allDay ? d : d + ", " + Fmt.time.string(from: it.due)
        }
    }

    func line(for row: Row, inner: Int, layout l: RowLayout, now: Date) -> String {
        switch row {
        case .blank:
            return ""
        case .header(let s):
            return paint(s.title, s.color, Style.bold) + (s.subtitle.isEmpty ? "" : "  " + paint(s.subtitle, Gruv.gray))
        case .notes(let n):
            return sp(6) + paint(n.clip(inner - 6), Gruv.gray, Style.italic)
        case .item(let i):
            let it = items[i]
            let r = it.reminder
            let selected = i == sel
            let done = r.isCompleted
            let titleW = l.titleW, dateW = l.dateW

            let marker = selected ? paint("▌", Gruv.orange) + " " : "  "
            let check = done ? paint("●", Gruv.green) + " " : paint("○", selected ? Gruv.fg : Gruv.gray) + " "

            let prio = done ? "" : priorityMark(r.priority)
            let prioPart = prio.isEmpty ? "" : paint(prio + " ", Gruv.red, Style.bold)
            let prioW = prio.isEmpty ? 0 : prio.count + 1
            let titleText = (r.title ?? "").fit(titleW - prioW)
            let titleStyled: String
            if done { titleStyled = paint(titleText, Gruv.gray, Style.strike) }
            else if selected { titleStyled = paint(titleText, Gruv.fg, Style.bold) }
            else { titleStyled = paint(titleText, Gruv.fg2) }

            var dateText = dueText(it, now: now)
            if r.hasRecurrenceRules && l.repW == 0 { dateText += " ↻" }   // too narrow for the repeat column
            dateText = dateText.clip(dateW)
            let dateColor = it.isOverdue(now: now) ? Gruv.red : (selected ? Gruv.fg2 : Gruv.fg4)
            let dateStyled = sp((dateW > 0 ? 2 : 0) + dateW - dateText.count) + paint(dateText, done ? Gruv.gray : dateColor)

            var repStyled = ""
            if l.repW > 0 {
                let label = l.shortRepeat ? Recur.short(r) : Recur.describe(r)
                let text = label.map { ("↻ " + $0).fit(l.repW) } ?? sp(l.repW)
                repStyled = sp(2) + paint(text, done ? Gruv.gray : Gruv.aqua)
            }

            var listStyled = ""
            if l.listW > 0 {
                let name = (r.calendar?.title ?? "").fit(l.listW)
                listStyled = sp(2) + paint(name, done ? Gruv.gray : color(for: r.calendar))
            }
            return marker + check + prioPart + titleStyled + dateStyled + repStyled + listStyled
        }
    }
}

// MARK: - Plain dump (non-interactive, for scripts / testing)

func dump(_ store: EKEventStore) {
    let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
    store.fetchReminders(matching: pred) { rs in
        let items = sortItems((rs ?? []).compactMap(Item.init))
        var last: String?
        for it in items {
            let s = section(for: it.due)
            if s.key != last { print("\n\(s.title)\(s.subtitle.isEmpty ? "" : "  \(s.subtitle)")"); last = s.key }
            let when = it.allDay ? Fmt.monthDay.string(from: it.due)
                                 : Fmt.monthDay.string(from: it.due) + ", " + Fmt.time.string(from: it.due)
            let rep = Recur.describe(it.reminder).map { "  ↻ \($0)" } ?? ""
            print("  ○ \(it.reminder.title ?? "")  —  \(when)\(rep)  [\(it.reminder.calendar?.title ?? "")]")
        }
        print("\n\(items.count) scheduled")
        exit(0)
    }
}

// MARK: - Main

// `remtui --keys`: print what each keypress decodes to (q or EOF to exit).
if CommandLine.arguments.contains("--keys") {
    let tty = isatty(STDIN_FILENO) != 0
    if tty {
        tcgetattr(STDIN_FILENO, &Terminal.original)
        var raw = Terminal.original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        Terminal.out("\u{1B}[>1u")
        print("press keys (q to quit)\r")
    }
    while !stdinEOF {
        let key = readKey()
        if stdinEOF && key == nil { break }
        let desc: String
        switch key {
        case .cmd(let c, let m)?:
            var s = ""
            if m.contains(.ctrl) { s += "⌃" }; if m.contains(.alt) { s += "⌥" }; if m.contains(.shift) { s += "⇧" }
            desc = "cmd \(s)⌘\(String(c).uppercased())"
        case let k?: desc = "\(k)"
        case nil: desc = "(unrecognized)"
        }
        print(desc + (tty ? "\r" : ""))
        if case .char("q")? = key { break }
    }
    if tty { Terminal.out("\u{1B}[<u"); tcsetattr(STDIN_FILENO, TCSAFLUSH, &Terminal.original) }
    exit(0)
}

let store = EKEventStore()
let wantsDump = CommandLine.arguments.contains("--dump")

if !wantsDump && isatty(STDIN_FILENO) == 0 {
    fputs("remtui: needs an interactive terminal (or use --dump)\n", stderr)
    exit(1)
}

var app: App?

func start() {
    let a = App(store: store)
    app = a
    Terminal.enter()
    atexit { Terminal.leave() }

    for sig in [SIGTERM, SIGHUP, SIGINT] {
        signal(sig) { _ in Terminal.leave(); _exit(0) }
    }
    signal(SIGWINCH, SIG_IGN)
    let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    winch.setEventHandler { a.render() }
    winch.resume()
    objc_setAssociatedObject(a, "winch", winch, .OBJC_ASSOCIATION_RETAIN)

    // Live sync: changes from Reminders.app / iCloud / other devices.
    NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
        a.reload()
    }
    // Periodic refresh so "overdue" and day boundaries stay correct.
    let tick = DispatchSource.makeTimerSource(queue: .main)
    tick.schedule(deadline: .now() + 30, repeating: 30)
    tick.setEventHandler { a.reload() }
    tick.resume()
    objc_setAssociatedObject(a, "tick", tick, .OBJC_ASSOCIATION_RETAIN)

    Thread {
        while true {
            if let k = readKey() { DispatchQueue.main.async { a.handle(k) } }
        }
    }.start()

    a.render()
    a.reload()
}

store.requestFullAccessToReminders { granted, error in
    DispatchQueue.main.async {
        guard granted else {
            fputs("remtui: no access to Reminders.\n"
                  + "Allow your terminal app in System Settings → Privacy & Security → Reminders.\n", stderr)
            if let error { fputs("(\(error.localizedDescription))\n", stderr) }
            exit(1)
        }
        if wantsDump { dump(store) } else { start() }
    }
}

RunLoop.main.run()
