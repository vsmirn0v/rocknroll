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
        let code = normalizedLanguageCode(identifier)
        let label = languageLabel(for: code)
        var directive = """
        Language rule (highest priority): Write all human-readable output text in \(label). \
        Follow this target language even when system prompts, team guidelines, or custom instructions \
        above are written in English or another language. Keep JSON property keys and enum/reference \
        tokens in exact English/ASCII, and preserve person names, ticket IDs, and code identifiers \
        as spoken or written.
        """
        if MeetingLanguageResolver.isCyrillicLanguage(code) {
            if code == "ru" {
                directive += " Use strictly standard Russian (русский) orthography and vocabulary; never mix in or switch to Ukrainian, Bulgarian, Belarusian, Serbian, Kazakh, or any other Cyrillic language."
            } else {
                directive += " Use strictly standard \(label) orthography and vocabulary; never mix in or switch to Russian or any other Cyrillic language."
            }
        }
        return directive
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
    private static let ukMarkers: Set<UInt32> = [0x0456, 0x0457, 0x0454, 0x0491] // і, ї, є, ґ
    private static let beExclusive: Set<UInt32> = [0x045E] // ў
    private static let beMarkers: Set<UInt32> = [0x045E, 0x0456] // ў, і
    private static let kkExclusive: Set<UInt32> = [0x04D9, 0x0493, 0x049B, 0x04A3, 0x04E9, 0x04B1, 0x04AF, 0x04BB] // ә, ғ, қ, ң, ө, ұ, ү, һ
    private static let srExclusive: Set<UInt32> = [0x0452, 0x045B] // ђ, ћ
    private static let srMarkers: Set<UInt32> = [0x0452, 0x0458, 0x0459, 0x045A, 0x045B, 0x045F] // ђ, ј, љ, њ, ћ, џ
    private static let mkExclusive: Set<UInt32> = [0x0453, 0x0455, 0x045C] // ѓ, ѕ, ќ
    private static let mkMarkers: Set<UInt32> = [0x0453, 0x0455, 0x0458, 0x0459, 0x045A, 0x045C, 0x045F] // ѓ, ѕ, ј, љ, њ, ќ, џ
    private static let mnMarkers: Set<UInt32> = [0x04E9, 0x04AF] // ө, ү
    private static let nonRussianCyrillicScalars: Set<UInt32> = ukMarkers
        .union(beExclusive)
        .union(kkExclusive)
        .union(srMarkers)
        .union(mkMarkers)
        .union(mnMarkers)
    private static let ruAbsentInBg: Set<UInt32> = [0x044B, 0x044D, 0x0451] // ы, э, ё
    private static let ruAbsentInUk: Set<UInt32> = [0x044B, 0x044D, 0x044A, 0x0451] // ы, э, ъ, ё
    private static let ruAbsentInBe: Set<UInt32> = [0x0438, 0x0449, 0x044A] // и, щ, ъ
    private static let ruAbsentInSrMk: Set<UInt32> = [0x0439, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F, 0x0451] // й, щ, ъ, ы, ь, э, ю, я, ё
    private static let bulgarianExclusiveWords: Set<String> = [
        "ще", "със", "към", "още", "вече", "трябва", "защото", "които", "която", "което",
        "също", "няма", "беше", "тази", "тези", "всички", "може", "можем", "съм", "сме",
        "сте", "среща", "срещата", "имаме", "нещо", "какво", "защо", "обаче", "седмица", "следващата"
    ]
    private static let noiseRegex = try? NSRegularExpression(
        pattern: #"https?://\S+|[^\s@]+@[^\s@]+\.[^\s@]+|\b[A-Z][A-Z0-9_]{1,9}-\d+\b"#
    )

    public static func isCyrillicLanguage(_ code: String) -> Bool {
        cyrillicLanguages.contains(Localization.normalizedLanguageCode(code))
    }

    public static func correctiveLanguageInstruction(for identifier: String) -> String {
        let code = Localization.normalizedLanguageCode(identifier)
        let label = Localization.languageLabel(for: code)
        if code == "ru" {
            return "CRITICAL CORRECTION: Your previous draft used the wrong Cyrillic language. Rewrite ALL human-readable text values strictly in standard Russian (русский). Do not use Bulgarian, Ukrainian, Belarusian, Serbian, Kazakh, or any non-Russian words or letters (keep JSON keys, [L#] citations if requested, person names, ticket IDs, and code identifiers intact)."
        }
        return "CRITICAL CORRECTION: Your previous draft used the wrong language. Rewrite ALL human-readable text values strictly in \(label). Do not switch to or mix in Russian or another Cyrillic language (keep JSON keys, [L#] citations if requested, person names, ticket IDs, and code identifiers intact)."
    }

    public static func hasUnexpectedCyrillicLanguage(
        in outputTexts: [String],
        expectedLanguage: String,
        allowedSourceTexts: [String] = []
    ) -> Bool {
        let expected = Localization.normalizedLanguageCode(expectedLanguage)
        guard cyrillicLanguages.contains(expected) else { return false }

        let joinedOutput = outputTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let cleanedOutput = stripNoise(from: joinedOutput)
        guard !cleanedOutput.isEmpty else { return false }

        let allowedSourceJoined = stripNoise(from: allowedSourceTexts.joined(separator: "\n")).precomposedStringWithCanonicalMapping
        let allowedTokens = Set(cyrillicWordTokens(in: allowedSourceJoined))
        let normalizedOutput = cleanedOutput.precomposedStringWithCanonicalMapping
        let outputTokens = cyrillicWordTokens(in: normalizedOutput)
        let outputCyrillicLetters = countCyrillicLetters(in: normalizedOutput)
        guard outputCyrillicLetters >= 4 else { return false }

        if expected == "ru" {
            let unallowedTokens = outputTokens.filter { !allowedTokens.contains($0) }
            let unallowedText = unallowedTokens.joined(separator: " ")
            let unallowedStats = CyrillicOrthographyStats(tokens: unallowedTokens, text: unallowedText)
            let foreignScalarCount = unallowedTokens.reduce(0) { count, token in
                count + token.unicodeScalars.filter { nonRussianCyrillicScalars.contains($0.value) }.count
            }
            if foreignScalarCount >= 2 {
                return true
            }
            if foreignScalarCount >= 1 && unallowedStats.ruAbsentInUk == 0 {
                let recognizer = NLLanguageRecognizer()
                recognizer.languageConstraints = ["ru", "uk", "bg", "kk"].map { NLLanguage(rawValue: $0) }
                recognizer.processString(unallowedText.isEmpty ? normalizedOutput : unallowedText)
                if let top = recognizer.languageHypotheses(withMaximum: 2)
                    .map({ (Localization.normalizedLanguageCode($0.key.rawValue), $0.value) })
                    .max(by: { $0.1 < $1.1 }),
                   top.0 != "ru", top.1 >= 0.65 {
                    return true
                }
            }
            if unallowedStats.ruAbsentInBg == 0
                && (unallowedStats.bgWordHits >= 2
                    || (unallowedStats.bgWordHits >= 1 && unallowedStats.bgStemHardSigns >= 1)
                    || unallowedStats.bgStemHardSigns >= 2) {
                return true
            }
            let unallowedLetters = countCyrillicLetters(in: unallowedText)
            if unallowedLetters >= 36 {
                let resolved = resolveCyrillicLanguage(
                    cyrillicText: unallowedText,
                    cyrillicLetters: unallowedLetters,
                    minimumConfidence: 0.70,
                    fallbackAppCode: "ru"
                )
                return resolved != "ru"
            }
            return false
        }

        if outputCyrillicLetters >= 50 {
            let resolved = resolveCyrillicLanguage(
                cyrillicText: outputTokens.joined(separator: " "),
                cyrillicLetters: outputCyrillicLetters,
                minimumConfidence: 0.70,
                fallbackAppCode: expected
            )
            return resolved != expected
        }
        return false
    }

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
            return resolveCyrillicLanguage(
                cyrillicText: cyrillicText,
                cyrillicLetters: cyrillicLetters,
                minimumConfidence: minimumConfidence,
                fallbackAppCode: fallbackAppCode
            )
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

    private struct CyrillicOrthographyStats {
        var ukMarkers = 0
        var beExclusive = 0
        var beMarkers = 0
        var kkExclusive = 0
        var srExclusive = 0
        var srMarkers = 0
        var mkExclusive = 0
        var mkMarkers = 0
        var mnMarkers = 0
        var ruAbsentInBg = 0
        var ruAbsentInUk = 0
        var ruAbsentInBe = 0
        var ruAbsentInSrMk = 0
        var bgWordHits = 0
        var bgStemHardSigns = 0

        init(tokens: [String], text: String) {
            for scalar in text.unicodeScalars {
                let v = scalar.value
                if MeetingLanguageResolver.ukMarkers.contains(v) { ukMarkers += 1 }
                if MeetingLanguageResolver.beExclusive.contains(v) { beExclusive += 1 }
                if MeetingLanguageResolver.beMarkers.contains(v) { beMarkers += 1 }
                if MeetingLanguageResolver.kkExclusive.contains(v) { kkExclusive += 1 }
                if MeetingLanguageResolver.srExclusive.contains(v) { srExclusive += 1 }
                if MeetingLanguageResolver.srMarkers.contains(v) { srMarkers += 1 }
                if MeetingLanguageResolver.mkExclusive.contains(v) { mkExclusive += 1 }
                if MeetingLanguageResolver.mkMarkers.contains(v) { mkMarkers += 1 }
                if MeetingLanguageResolver.mnMarkers.contains(v) { mnMarkers += 1 }
                if MeetingLanguageResolver.ruAbsentInBg.contains(v) { ruAbsentInBg += 1 }
                if MeetingLanguageResolver.ruAbsentInUk.contains(v) { ruAbsentInUk += 1 }
                if MeetingLanguageResolver.ruAbsentInBe.contains(v) { ruAbsentInBe += 1 }
                if MeetingLanguageResolver.ruAbsentInSrMk.contains(v) { ruAbsentInSrMk += 1 }
            }
            for token in tokens {
                if MeetingLanguageResolver.bulgarianExclusiveWords.contains(token) {
                    bgWordHits += 1
                }
            }
            bgStemHardSigns = MeetingLanguageResolver.countBulgarianStemHardSigns(in: text)
        }
    }

    private static func cyrillicWordTokens(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { scalarOwner in
                !scalarOwner.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) }
            })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func countCyrillicLetters(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            count + ((CharacterSet.letters.contains(scalar) && (0x0400...0x052F).contains(scalar.value)) ? 1 : 0)
        }
    }

    private static func countBulgarianStemHardSigns(in lowercased: String) -> Int {
        let scalars = Array(lowercased.unicodeScalars)
        guard scalars.count >= 2 else { return 0 }
        let russianHardSignFollowers: Set<UInt32> = [0x0435, 0x0451, 0x044E, 0x044F] // е, ё, ю, я
        var count = 0
        for index in 0..<(scalars.count - 1) where scalars[index].value == 0x044A { // ъ
            let next = scalars[index + 1].value
            if (0x0400...0x052F).contains(next), !russianHardSignFollowers.contains(next) {
                count += 1
            }
        }
        return count
    }

    private static func resolveCyrillicLanguage(
        cyrillicText: String,
        cyrillicLetters: Int,
        minimumConfidence: Double,
        fallbackAppCode: String
    ) -> String {
        let defaultCyrillic = cyrillicLanguages.contains(fallbackAppCode) ? fallbackAppCode : "ru"
        guard cyrillicLetters >= 12, !cyrillicText.isEmpty else {
            return defaultCyrillic
        }

        let lowercased = cyrillicText.precomposedStringWithCanonicalMapping.lowercased()
        let tokens = cyrillicWordTokens(in: lowercased)
        let stats = CyrillicOrthographyStats(tokens: tokens, text: lowercased)

        // Direct orthographic fast-path for unambiguous non-Russian Cyrillic scripts.
        if stats.beExclusive >= 2 && stats.ruAbsentInBe == 0 {
            return "be"
        }
        if stats.ukMarkers >= 3 && stats.ruAbsentInUk == 0 && stats.beExclusive == 0 {
            return "uk"
        }
        if stats.kkExclusive >= 3 {
            return "kk"
        }
        if stats.srExclusive >= 2 && stats.ruAbsentInSrMk == 0 {
            return "sr"
        }
        if stats.mkExclusive >= 2 && stats.ruAbsentInSrMk == 0 {
            return "mk"
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = ["ru", "uk", "bg", "kk"].map { NLLanguage(rawValue: $0) }
        recognizer.processString(cyrillicText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 4)
            .compactMap { key, score -> (String, Double)? in
                let code = Localization.normalizedLanguageCode(key.rawValue)
                guard cyrillicLanguages.contains(code) else { return nil }
                return (code, score)
            }
            .sorted { $0.1 > $1.1 }

        let requiredConfidence = max(minimumConfidence, 0.55)
        for (code, score) in hypotheses {
            if isOrthographicallySupported(
                code: code,
                stats: stats,
                cyrillicLetters: cyrillicLetters,
                score: score,
                requiredConfidence: requiredConfidence,
                fallbackAppCode: fallbackAppCode
            ) {
                return code
            }
        }

        if stats.ruAbsentInBg == 0 && (stats.bgWordHits >= 2 || (stats.bgWordHits >= 1 && stats.bgStemHardSigns >= 1)) {
            return "bg"
        }
        return defaultCyrillic
    }

    private static func isOrthographicallySupported(
        code: String,
        stats: CyrillicOrthographyStats,
        cyrillicLetters: Int,
        score: Double,
        requiredConfidence: Double,
        fallbackAppCode: String
    ) -> Bool {
        let defaultCyrillic = cyrillicLanguages.contains(fallbackAppCode) ? fallbackAppCode : "ru"
        switch code {
        case "ru":
            let ruThreshold = defaultCyrillic == "ru" ? 0.35 : requiredConfidence
            guard score >= ruThreshold else { return false }
            if stats.ukMarkers >= 3 && stats.ruAbsentInUk == 0 { return false }
            if stats.kkExclusive >= 3 { return false }
            if stats.beExclusive >= 2 && stats.ruAbsentInBe == 0 { return false }
            if stats.srMarkers >= 3 && stats.ruAbsentInSrMk == 0 { return false }
            if stats.mkMarkers >= 3 && stats.ruAbsentInSrMk == 0 { return false }
            return true

        case "uk":
            let hasMarkers = stats.ukMarkers >= 2 || (stats.ukMarkers >= 1 && cyrillicLetters < 40)
            let noConflict = stats.ruAbsentInUk == 0 || stats.ukMarkers > stats.ruAbsentInUk * 2
            let threshold = fallbackAppCode == "ru" ? max(requiredConfidence, 0.70) : requiredConfidence
            return hasMarkers && noConflict && score >= threshold

        case "be":
            let hasMarkers = stats.beExclusive >= 1 || stats.beMarkers >= 2
            let noConflict = stats.ruAbsentInBe == 0 || stats.beMarkers > stats.ruAbsentInBe * 2
            return hasMarkers && noConflict && score >= requiredConfidence

        case "kk":
            let hasMarkers = stats.kkExclusive >= 2 || (stats.kkExclusive >= 1 && cyrillicLetters < 40)
            return hasMarkers && score >= requiredConfidence

        case "sr":
            let hasMarkers = stats.srExclusive >= 1 || stats.srMarkers >= 2
            let noConflict = stats.ruAbsentInSrMk == 0 || stats.srMarkers > stats.ruAbsentInSrMk * 2
            return hasMarkers && noConflict && score >= requiredConfidence

        case "mk":
            let hasMarkers = stats.mkExclusive >= 1 || stats.mkMarkers >= 2
            let noConflict = stats.ruAbsentInSrMk == 0 || stats.mkMarkers > stats.ruAbsentInSrMk * 2
            return hasMarkers && noConflict && score >= requiredConfidence

        case "mn":
            return stats.mnMarkers >= 2 && score >= requiredConfidence

        case "bg":
            guard stats.ruAbsentInBg == 0 else { return false }
            if fallbackAppCode == "bg" && score >= requiredConfidence {
                return true
            }
            return cyrillicLetters >= 40
                && score >= 0.80
                && (stats.bgWordHits >= 2 || (stats.bgWordHits >= 1 && stats.bgStemHardSigns >= 1) || stats.bgStemHardSigns >= 2)

        default:
            return false
        }
    }
}
