import Foundation

/// Environment-derived defaults for the reserved identify trait keys
/// (whisperr-spec `SPEC.md` → "Reserved trait keys"): `timezone` (IANA name,
/// `TimeZone.current.identifier`) and `locale` (`Locale.current`, normalized to
/// a BCP 47 tag). The engine evaluates quiet hours / send timing in `timezone`
/// and picks the message language from `locale`. Only keys the platform can
/// actually provide are returned — never a guess.
enum DeviceTraits {
    static func current(timeZone: TimeZone = .current, locale: Locale = .current) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let zone = timeZone.identifier
        if !zone.isEmpty {
            out["timezone"] = .string(zone)
        }
        if let tag = bcp47(locale.identifier) {
            out["locale"] = .string(tag)
        }
        return out
    }

    /// Normalizes a Foundation locale identifier to a BCP 47 tag:
    /// `de_DE` → `de-DE`, `zh_Hans_CN` → `zh-Hans-CN`,
    /// `en_US@calendar=gregorian` → `en-US`. Returns nil for anything without a
    /// plausible language subtag (empty identifier, `und`).
    static func bcp47(_ identifier: String) -> String? {
        let withoutKeywords = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let parts = withoutKeywords
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map(String.init)
        guard let language = parts.first,
              (2...8).contains(language.count),
              language.allSatisfy({ $0.isLetter }),
              language.lowercased() != "und" else {
            return nil
        }
        return parts.joined(separator: "-")
    }
}
