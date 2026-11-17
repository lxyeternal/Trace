import Foundation
import TraceCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru, zhHans = "zh-Hans"
    var id: String { rawValue }
}

/// In-app localisation. Keys are the English strings; other languages live in
/// `Resources/<code>.lproj/Localizable.strings`. Switching takes effect at once,
/// without relaunching.
enum L10n {
    private(set) static var table: Bundle?
    private(set) static var code = "en"

    static var isChinese: Bool { code.hasPrefix("zh") }
    static var locale: Locale { Locale(identifier: code == "ru" ? "ru_RU" : (isChinese ? "zh_CN" : "en_US")) }

    static func apply(_ language: AppLanguage) {
        switch language {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            switch Locale(identifier: preferred).language.languageCode?.identifier {
            case "ru": code = "ru"
            case "zh": code = "zh-Hans"
            default: code = "en"
            }
        case .en, .ru, .zhHans:
            code = language.rawValue
        }
        table = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}

func L(_ key: String) -> String {
    L10n.table?.localizedString(forKey: key, value: key, table: nil) ?? key
}

enum Fmt {
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            let s = Int(seconds.rounded())
            if L10n.code == "ru" { return "\(s) с" }
            return L10n.isChinese ? "\(s)秒" : "\(s)s"
        }
        let minutes = Int((seconds / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        if L10n.code == "ru" {
            if h == 0 { return "\(m) мин" }
            return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
        }
        if L10n.isChinese {
            if h == 0 { return "\(m)分" }
            return m == 0 ? "\(h)小时" : "\(h)小时\(m)分"
        }
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// A running clock: "23:45", "1:23:45".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Whole hours, for where there is little room: "180h".
    static func hours(_ seconds: TimeInterval) -> String {
        let h = Int((seconds / 3600).rounded())
        if L10n.code == "ru" { return "\(h) ч" }
        return L10n.isChinese ? "\(h)小时" : "\(h)h"
    }

    /// "1 record", "5 records".
    static func records(_ count: Int) -> String {
        if L10n.code == "ru" {
            let label: String
            switch (count % 100, count % 10) {
            case (11...14, _): label = "записей"
            case (_, 1): label = "запись"
            case (_, 2...4): label = "записи"
            default: label = "записей"
            }
            return "\(count) \(label)"
        }
        return count == 1 ? L("1 record") : String(format: L("%d records"), count)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func monthDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    static func month(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f.string(from: date)
    }

    static func year(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("y")
        return f.string(from: date)
    }

    static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date)
    }

    static var shortMonths: [String] {
        let f = DateFormatter()
        f.locale = L10n.locale
        return f.shortStandaloneMonthSymbols ?? (1...12).map(String.init)
    }

    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("MMMd HH:mm")
        return f.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return f.string(from: date)
    }
}

extension Tag {
    /// Preset tags are stored with English names and translated for display.
    var displayName: String { isPreset ? L(name) : name }
}

func tagName(_ tag: Tag?) -> String {
    tag?.displayName ?? L("Untagged")
}

extension RuleField {
    var displayName: String {
        switch self {
        case .app: return L("App")
        case .category: return L("App category")
        case .path: return L("File path")
        case .url: return L("URL")
        case .title: return L("Window title")
        }
    }

    var placeholder: String {
        switch self {
        case .app: return "Xcode"
        case .category: return "developer-tools"
        case .path: return "~/Projects/MyApp"
        case .url: return "github.com"
        case .title: return "Invoice"
        }
    }
}

extension RuleOp {
    var displayName: String {
        switch self {
        case .equals: return L("is")
        case .contains: return L("contains")
        case .hasPrefix: return L("starts with")
        }
    }
}
