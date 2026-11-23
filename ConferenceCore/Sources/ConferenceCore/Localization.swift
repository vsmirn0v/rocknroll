import Foundation
import NaturalLanguage

/// Resolve app-owned copy only; invitations, names and meeting content remain verbatim.
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.text(key, arguments: arguments)
}

public enum Localization {
    private static let cacheLock = NSLock()
    private static var cachedLocales: [String: Locale] = [:]

    public static func text(_ key: String, arguments: [CVarArg] = [],
                            bundle: Bundle = .main, locale: Locale? = nil) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        let formattingLocale = locale ?? self.formattingLocale(
            language: bundle.preferredLocalizations.first ?? "en")
        return String(format: format, locale: formattingLocale, arguments: arguments)
    }

    public static func normalizedLanguageCode(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "en" }
        let language = Locale(identifier: trimmed).language
        guard let code = language.languageCode?.identifier, !code.isEmpty else { return "en" }
        if code == "zh" {
            let lower = trimmed.replacingOccurrences(of: "_", with: "-").lowercased()
            let script = language.script?.identifier
            let region = Locale(identifier: trimmed).region?.identifier
            if script == "Hant" || lower.contains("hant") || region == "TW" || region == "HK" || region == "MO" {
                return "zh-Hant"
            }
            return "zh-Hans"
        }
        return code
    }

    public static func preferredAppLanguageCode(bundle: Bundle = .main) -> String {
        let raw = bundle.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        return normalizedLanguageCode(raw)
    }

    /// The prompt language must be stable regardless of the device's display language.
    public static func englishLanguageName(for identifier: String) -> String {
        let normalized = normalizedLanguageCode(identifier)
        if normalized == "zh-Hant" { return "Traditional Chinese" }
        if normalized == "zh-Hans" { return "Simplified Chinese" }
        let language = Locale(identifier: normalized).language
        guard let code = language.languageCode?.identifier else { return "English" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    public static func nativeLanguageName(for identifier: String) -> String? {
        let normalized = normalizedLanguageCode(identifier)
        if normalized == "en" { return nil }
        if normalized == "zh-Hant" { return "繁體中文" }
        if normalized == "zh-Hans" { return "简体中文" }
        let language = Locale(identifier: normalized).language
        guard let code = language.languageCode?.identifier else { return nil }
        guard let native = Locale(identifier: normalized).localizedString(forLanguageCode: code)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !native.isEmpty else {
            return nil
        }
        let english = englishLanguageName(for: normalized)
        if native.caseInsensitiveCompare(english) == .orderedSame {
            return nil
        }
        return native
    }

    public static func languageLabel(for identifier: String) -> String {
        let english = englishLanguageName(for: identifier)
        if let native = nativeLanguageName(for: identifier) {
            return "\(english) (\(native))"
        }
        return english
    }

    public static func outputLanguageDirective(for identifier: String) -> String {
        let label = languageLabel(for: identifier)
        return """
        Language rule (highest priority): Write all human-readable output text in \(label). \
        Follow this target language even when system prompts, team guidelines, or custom instructions \
        above are written in English or another language. Keep JSON property keys and enum/reference \
        tokens in exact English/ASCII, and preserve person names, ticket IDs, and code identifiers \
        as spoken or written.
        """
    }

    /// App language governs grammatical rules; device region governs formatting.
    public static func formattingLocale(language: String, region: Locale = .current) -> Locale {
        let cacheKey = "\(language)|\(region.identifier)"
        cacheLock.lock()
        if let cached = cachedLocales[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var components = Locale.Components(identifier: region.identifier)
        let selected = Locale.Components(identifier: language)
        components.languageComponents.languageCode = selected.languageComponents.languageCode
        components.languageComponents.script = selected.languageComponents.script
        let resolved = Locale(components: components)

        cacheLock.lock()
        if cachedLocales.count >= 32 {
            cachedLocales.removeAll(keepingCapacity: true)
        }
        cachedLocales[cacheKey] = resolved
        cacheLock.unlock()
        return resolved
    }
}

/// Resolves the output language for meeting artifacts from the meeting's actual speech,
/// chat, notes, and title before falling back to the app UI language.
public enum MeetingLanguageResolver {
    private static let cyrillicLanguages: Set<String> = ["ru", "uk", "bg", "sr", "be", "kk", "mk", "mn"]
    private static let noiseRegex = try? NSRegularExpression(
        pattern: #"https?://\S+|[^\s@]+@[^\s@]+\.[^\s@]+|\b[A-Z][A-Z0-9_]{1,9}-\d+\b"#
    )

    public static func resolve(
        events: [SyncedTranscriptEvent],
        notes: String = "",
        title: String = "",
        appLanguage: String
    ) -> String {
        var speechTexts: [String] = []
        var chatTexts: [String] = []
        for event in events {
            guard !AssistantSpeechLedger.isAssistantSpeaker(event.speaker, role: event.speakerRole) else {
                continue
            }
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if event.kind == "transcript" {
                speechTexts.append(text)
            } else if event.kind == "chat" {
                chatTexts.append(text)
            }
        }
        return resolve(
            speechTexts: speechTexts,
            chatTexts: chatTexts,
            notes: notes,
            title: title,
            appLanguage: appLanguage
        )
    }

    public static func resolve(
        speechTexts: [String],
        chatTexts: [String] = [],
        notes: String = "",
        title: String = "",
        appLanguage: String
    ) -> String {
        let fallbackCode = Localization.normalizedLanguageCode(appLanguage)

        if let detected = detectDominantLanguage(
            in: speechTexts,
            minimumLetters: 8,
            minimumConfidence: 0.55,
            fallbackAppCode: fallbackCode
        ) {
            return detected
        }

        if let detected = detectDominantLanguage(
            in: speechTexts + chatTexts,
            minimumLetters: 8,
            minimumConfidence: 0.55,
            fallbackAppCode: fallbackCode
        ) {
            return detected
        }

        if let detected = detectDominantLanguage(
            in: [notes],
            minimumLetters: 8,
            minimumConfidence: 0.55,
            fallbackAppCode: fallbackCode
        ) {
            return detected
        }

        if let detected = detectDominantLanguage(
            in: [title],
            minimumLetters: 10,
            minimumConfidence: 0.70,
            fallbackAppCode: fallbackCode
        ) {
            return detected
        }

        return fallbackCode
    }

    private static func detectDominantLanguage(
        in texts: [String],
        minimumLetters: Int,
        minimumConfidence: Double,
        fallbackAppCode: String
    ) -> String? {
        let lines = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(120)
            .map { String($0.prefix(200)) }
        guard !lines.isEmpty else { return nil }

        let joined = lines.joined(separator: "\n")
        let cleaned = stripNoise(from: joined)
        guard !cleaned.isEmpty else { return nil }

        var totalLetters = 0
        var cyrillicLetters = 0
        var hanScalars = 0
        var otherNonLatinLetters = 0

        for scalar in cleaned.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            totalLetters += 1
            let value = scalar.value
            if (0x0400...0x052F).contains(value) {
                cyrillicLetters += 1
            } else if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
                hanScalars += 1
            } else if (0x3040...0x30FF).contains(value)
                        || (0xAC00...0xD7AF).contains(value)
                        || (0x0600...0x06FF).contains(value)
                        || (0x0750...0x077F).contains(value)
                        || (0x0900...0x097F).contains(value)
                        || (0x0590...0x05FF).contains(value)
                        || (0x0370...0x03FF).contains(value)
                        || (0x0E00...0x0E7F).contains(value) {
                otherNonLatinLetters += 1
            }
        }

        let nonLatinLetters = cyrillicLetters + hanScalars + otherNonLatinLetters
        guard totalLetters > 0, (totalLetters >= minimumLetters || nonLatinLetters >= 4) else {
            return nil
        }

        if cyrillicLetters >= 4 && Double(cyrillicLetters) / Double(totalLetters) >= 0.22 {
            let cyrillicTokens = cleaned.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .filter { token in
                    token.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) }
                }
            let cyrillicText = cyrillicTokens.joined(separator: " ")
            // NLLanguageRecognizer frequently misclassifies tiny Cyrillic loanwords (e.g. "Синк" -> "kk").
            if cyrillicLetters >= 12, !cyrillicText.isEmpty {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(cyrillicText)
                let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
                if let bestCyrillic = hypotheses
                    .compactMap({ key, score -> (String, Double)? in
                        let code = Localization.normalizedLanguageCode(key.rawValue)
                        guard cyrillicLanguages.contains(code) else { return nil }
                        return (code, score)
                    })
                    .max(by: { $0.1 < $1.1 }),
                   bestCyrillic.1 >= 0.40 {
                    return bestCyrillic.0
                }
            }
            return cyrillicLanguages.contains(fallbackAppCode) ? fallbackAppCode : "ru"
        }

        if hanScalars >= 4 && Double(hanScalars) / Double(totalLetters) >= 0.20 {
            return fallbackAppCode == "zh-Hant" ? "zh-Hant" : "zh-Hans"
        }

        if otherNonLatinLetters >= 4 && Double(otherNonLatinLetters) / Double(totalLetters) >= 0.22 {
            let nonASCIITokens = cleaned.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .filter { token in
                    token.unicodeScalars.contains { scalar in
                        scalar.value > 0x024F && CharacterSet.letters.contains(scalar)
                    }
                }
            let nonASCIIText = nonASCIITokens.joined(separator: " ")
            if !nonASCIIText.isEmpty {
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(nonASCIIText)
                let hypotheses = recognizer.languageHypotheses(withMaximum: 4)
                var scoresByCode: [String: Double] = [:]
                for (lang, score) in hypotheses where lang != .undetermined {
                    let code = Localization.normalizedLanguageCode(lang.rawValue)
                    scoresByCode[code, default: 0] += score
                }
                if let topNonLatin = scoresByCode
                    .filter({ $0.key != "en" })
                    .max(by: { $0.value < $1.value }),
                   topNonLatin.value >= 0.40 {
                    return topNonLatin.key
                }
            }
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(cleaned)
        let rawHypotheses = recognizer.languageHypotheses(withMaximum: 4)
        var scoresByCode: [String: Double] = [:]
        for (lang, score) in rawHypotheses where lang != .undetermined {
            let code = Localization.normalizedLanguageCode(lang.rawValue)
            scoresByCode[code, default: 0] += score
        }

        guard let top = scoresByCode.max(by: { $0.value < $1.value }) else {
            return nil
        }
        if top.value >= minimumConfidence {
            return top.key
        }
        if top.value >= 0.35 {
            if let fallbackScore = scoresByCode[fallbackAppCode], fallbackScore >= 0.25 {
                return fallbackAppCode
            }
            if top.value >= 0.45 && totalLetters >= 24 {
                return top.key
            }
        }
        return nil
    }

    private static func stripNoise(from text: String) -> String {
        guard let noiseRegex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return noiseRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }
}
