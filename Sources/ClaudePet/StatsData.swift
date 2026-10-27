import AppKit

/// What the statistics window computes from `TokenLedger`'s responses: totals per token type, model,
/// hour, project and day, over a period and a choice of models.

enum TokenKind: Int, CaseIterable {
    case input, output, cacheWrite, cacheRead

    var title: String {
        switch self {
        case .input: return tr("Entrée", "Input")
        case .output: return tr("Sortie", "Output")
        case .cacheWrite: return tr("Écriture cache", "Cache write")
        case .cacheRead: return tr("Lecture cache", "Cache read")
        }
    }

    var detail: String {
        switch self {
        case .input: return tr("Hors cache", "Uncached")
        case .output: return tr("Texte et réflexion", "Text and thinking")
        case .cacheWrite: return tr("Contexte mis en cache", "Context cached")
        case .cacheRead: return tr("Contexte relu", "Context reread")
        }
    }

    var color: NSColor {
        switch self {
        case .input: return PanelTheme.hex(0x6A9BCC)
        case .output: return PanelTheme.hex(0xD97757)
        case .cacheWrite: return PanelTheme.hex(0x9C87C9)
        case .cacheRead: return PanelTheme.hex(0x788C5D)
        }
    }

    func of(_ e: TokenLedger.Entry) -> Int {
        switch self {
        case .input: return e.input
        case .output: return e.output
        case .cacheWrite: return e.cacheWrite
        case .cacheRead: return e.cacheRead
        }
    }
}

enum StatsPeriod: Int, CaseIterable {
    case today, week, month, all

    var title: String {
        switch self {
        case .today: return tr("Aujourd'hui", "Today")
        case .week: return tr("7 jours", "7 days")
        case .month: return tr("30 jours", "30 days")
        case .all: return tr("Tout", "All time")
        }
    }

    var comparison: String {
        switch self {
        case .today: return tr("vs hier à la même heure", "vs yesterday, same time")
        case .week: return tr("vs les 7 jours d'avant", "vs the 7 days before")
        case .month: return tr("vs les 30 jours d'avant", "vs the 30 days before")
        case .all: return ""
        }
    }
}

struct StatsQuery: Equatable {
    var period = StatsPeriod.week
    /// Nil: every model.
    var models: Set<String>?
    var kinds = Set(TokenKind.allCases)
}

struct StatsSummary {
    enum Unit { case hour, sixHours, day, week }

    struct Bucket {
        var start: Date
        var kinds = [Double](repeating: 0, count: TokenKind.allCases.count)
        var models: [String: Double] = [:]
        var messages = 0
    }

    struct ModelShare { var id: String; var tokens: Int; var messages: Int }
    struct Day { var tokens = 0; var messages = 0 }

    var query = StatsQuery()
    var now = Date()
    /// The chart's x axis; buckets stop at `now`.
    var domain = DateInterval(start: Date(), duration: 1)
    var unit = Unit.day
    var buckets: [Bucket] = []
    /// Every type, whichever are selected.
    var kindTotals = [Int](repeating: 0, count: TokenKind.allCases.count)
    var total = 0
    var previousTotal: Int?
    var messages = 0
    var sessions = 0
    var activeDays = 0
    var hours = [Double](repeating: 0, count: 24)
    var peakHour: Int?
    var models: [ModelShare] = []
    var projects: [(name: String, tokens: Int)] = []
    /// Every day with activity, whatever the period (the heatmap), keyed by the start of the day.
    var daily: [Date: Day] = [:]
    var currentStreak = 0
    var longestStreak = 0
    var biggestDay: (date: Date, tokens: Int)?
    var biggestResponse: (model: String, output: Int)?
    var biggestSession: (project: String, tokens: Int)?
    var firstDay: Date?
    var hasData: Bool { messages > 0 }

    func tokens(_ e: TokenLedger.Entry) -> Int {
        query.kinds.reduce(0) { $0 + $1.of(e) }
    }

    init() {}

    init(entries all: [TokenLedger.Entry], query: StatsQuery, now: Date = Date(), calendar: Calendar = .current) {
        self.query = query
        self.now = now
        let pool = query.models.map { models in all.filter { models.contains($0.model) } } ?? all
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }

        // Every day, for the heatmap and the streaks.
        for e in pool {
            let d = calendar.startOfDay(for: e.time)
            daily[d, default: Day()].tokens += tokens(e)
            daily[d, default: Day()].messages += 1
        }
        firstDay = all.first.map { calendar.startOfDay(for: $0.time) }
        var streak = 0
        var cursor = daily[today] == nil ? day(-1) : today
        while daily[cursor] != nil {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        currentStreak = streak
        var run = 0, previous: Date?
        for d in daily.keys.sorted() {
            if let p = previous, calendar.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            longestStreak = max(longestStreak, run)
            previous = d
        }

        // The period, and the same span just before it.
        let start: Date, end: Date, step: DateComponents
        switch query.period {
        case .today:
            start = today; end = day(1); unit = .hour; step = DateComponents(hour: 1)
        case .week:
            start = day(-6); end = day(1); unit = .sixHours; step = DateComponents(hour: 6)
        case .month:
            start = day(-29); end = day(1); unit = .day; step = DateComponents(day: 1)
        case .all:
            let first = firstDay ?? today
            let days = calendar.dateComponents([.day], from: first, to: today).day ?? 0
            if days > 120 {
                unit = .week; step = DateComponents(day: 7)
                start = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? first
            } else {
                unit = .day; step = DateComponents(day: 1)
                // At least two weeks, so a young history still draws a curve.
                start = min(first, day(-13))
            }
            end = day(1)
        }
        domain = DateInterval(start: start, end: end)
        var cursorBucket = start
        while cursorBucket < min(end, now) {
            buckets.append(Bucket(start: cursorBucket))
            cursorBucket = calendar.date(byAdding: step, to: cursorBucket)!
        }

        if query.period != .all {
            // Up to the same moment: today until now against yesterday until this time.
            let length = end.timeIntervalSince(start)
            let previousStart = start.addingTimeInterval(-length), previousEnd = now.addingTimeInterval(-length)
            previousTotal = pool.lazy.filter { $0.time >= previousStart && $0.time < previousEnd }.reduce(0) { $0 + tokens($1) }
        }

        var sessionSet = Set<String>(), days = Set<Date>()
        var perModel: [String: ModelShare] = [:], perProject: [String: Int] = [:], perSession: [String: (String, Int)] = [:]
        var bucketIndex = 0
        for e in pool where e.time >= start && e.time < end {
            let t = tokens(e)
            for kind in TokenKind.allCases { kindTotals[kind.rawValue] += kind.of(e) }
            total += t
            messages += 1
            sessionSet.insert(e.session)
            days.insert(calendar.startOfDay(for: e.time))
            hours[calendar.component(.hour, from: e.time)] += Double(t)
            perModel[e.model, default: ModelShare(id: e.model, tokens: 0, messages: 0)].tokens += t
            perModel[e.model]!.messages += 1
            if !e.project.isEmpty { perProject[e.project, default: 0] += t }
            perSession[e.session, default: (e.project, 0)].1 += t
            if e.output > (biggestResponse?.output ?? 0) { biggestResponse = (e.model, e.output) }
            // Entries are sorted by time: the bucket only moves forward.
            while bucketIndex + 1 < buckets.count, buckets[bucketIndex + 1].start <= e.time { bucketIndex += 1 }
            guard bucketIndex < buckets.count else { continue }
            // Every type, so a type left out still draws its own sparkline.
            for kind in TokenKind.allCases { buckets[bucketIndex].kinds[kind.rawValue] += Double(kind.of(e)) }
            buckets[bucketIndex].models[e.model, default: 0] += Double(t)
            buckets[bucketIndex].messages += 1
        }
        sessions = sessionSet.subtracting([""]).count
        activeDays = days.count
        peakHour = hours.max().flatMap { $0 > 0 ? hours.firstIndex(of: $0) : nil }
        models = perModel.values.sorted { $0.tokens > $1.tokens }
        projects = perProject.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
        biggestSession = perSession.values.max { $0.1 < $1.1 }.map { (project: $0.0, tokens: $0.1) }
        biggestDay = daily.filter { $0.key >= start && $0.key < end }.max { $0.value.tokens < $1.value.tokens }
            .map { (date: $0.key, tokens: $0.value.tokens) }
    }
}

// MARK: - Formatting

enum StatsFormat {
    static let locale = Locale(identifier: L10n.isFrench ? "fr_FR" : "en_US")

    /// "1,84 Md" / "1.84B": three significant digits.
    static func compact(_ value: Double) -> String {
        let units = L10n.isFrench ? ["", " k", " M", " Md", " T"] : ["", "K", "M", "B", "T"]
        var v = abs(value), i = 0
        while v >= 999.5, i < units.count - 1 { v /= 1000; i += 1 }
        let digits = i == 0 || v >= 100 ? 0 : v >= 10 ? 1 : 2
        let f = NumberFormatter()
        f.locale = locale
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = digits
        return (value < 0 ? "-" : "") + (f.string(from: NSNumber(value: v)) ?? "\(v)") + units[i]
    }

    static func full(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func percent(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .percent
        f.maximumFractionDigits = value > 0 && value < 0.1 ? 1 : 0
        return f.string(from: NSNumber(value: value)) ?? ""
    }

    static func date(_ date: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    static func hour(_ hour: Int) -> String {
        if L10n.isFrench { return "\(hour) h" }
        return hour == 0 ? "12 AM" : hour < 12 ? "\(hour) AM" : hour == 12 ? "12 PM" : "\(hour - 12) PM"
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-3-5-sonnet-20241022" → "Sonnet 3.5".
    static func model(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init).filter { $0 != "claude" && !($0.count == 8 && Int($0) != nil) }
        let family = parts.first { Int($0) == nil }
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        guard let family else { return id }
        return ([family.prefix(1).uppercased() + family.dropFirst()] + (version.isEmpty ? [] : [version])).joined(separator: " ")
    }

    /// A stable color per model, by its rank over all time: filtering never repaints them.
    static let modelPalette: [UInt32] = [0xD97757, 0x6A9BCC, 0x788C5D, 0xC46686, 0xD4A27F, 0x9C87C9, 0x5FA8A0, 0x8F8D85]
}
