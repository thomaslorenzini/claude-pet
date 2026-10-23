import Foundation

/// Interface language, picked once at launch from the system's preferred languages (which include
/// the per-app choice of System Settings › Language & Region): French, or English for anything else.
/// Strings stay next to their use, as French/English pairs: with two languages, a key catalog would
/// only add indirection.
enum L10n {
    static let isFrench = (Locale.preferredLanguages.first ?? "en").hasPrefix("fr")

    /// "1 session" / "3 sessions": both languages add an "s", and French counts 0 as singular.
    static func plural(_ count: Int, _ word: String) -> String {
        let one = isFrench ? count <= 1 : count == 1
        return "\(count) \(word)\(one ? "" : "s")"
    }
}

/// The French or the English text, following `L10n.isFrench`.
func tr(_ french: String, _ english: String) -> String {
    L10n.isFrench ? french : english
}
