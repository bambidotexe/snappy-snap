import Testing
import Foundation
@testable import SnapCore

/// The rules every catalogue keeps, for all three targets at once.
///
/// The app target has no test target of its own, so its catalogue is checked here from the source
/// tree rather than from a bundle: the files are the authority, and a sentence that never reaches a
/// catalogue is a sentence that stays English on a French Mac with nothing to say so.
@Suite struct LocalizationTests {
    /// Every target that shows a person a sentence, and the two languages each one carries.
    static let targets = ["SnapCore", "SystemAdapters", "SnappySnap"]
    static let languages = ["en", "fr"]

    /// A key is its symbol and then its name, in either language.
    static let keyboardKeys: [(word: String, symbol: Character)] = [
        ("Option", "⌥"), ("Command", "⌘"), ("Commande", "⌘"),
        ("Control", "⌃"), ("Contrôle", "⌃"), ("Shift", "⇧"), ("Maj", "⇧"),
    ]

    /// None of these may appear in a sentence a person reads. The keyboard's own hyphen is not here.
    static let longDashes: Set<Character> = ["—", "–", "‒", "―", "‐", "‑", "−"]

    /// Names macOS gives something, quoted so the user can find it, in either language, that happen to
    /// hold a key's name: the Accessibility grant's row in Privacy & Security, and Mission Control. The
    /// word is the system's, not the key's, so a mention inside one of these is exempt from the
    /// keyboard-key rule, and from nothing else.
    static let quotedSystemNames = ["Device Control and Data Access", "Contrôle de l’appareil et accès aux données",
                                    "Mission Control"]

    static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func catalogueURL(_ target: String, _ language: String) -> URL {
        repoRoot.appending(path: "Sources/\(target)/Resources/\(language).lproj/Localizable.strings")
    }

    /// A `.strings` file is an old-style property list, so Foundation parses it rather than a regular
    /// expression: a file this cannot read is a file the build cannot read either.
    static func catalogue(_ target: String, _ language: String) throws -> [String: String] {
        let data = try Data(contentsOf: catalogueURL(target, language))
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(parsed as? [String: String],
                            "\(target)/\(language).lproj/Localizable.strings is not a catalogue")
    }

    /// `%@`, `%lld` and the rest, in the order they are written.
    static func placeholders(_ text: String) -> [String] {
        text.ranges(of: /%(?:\d+\$)?(?:lld|ld|@|d|f)/).map { String(text[$0]) }
    }

    @Test(arguments: targets) func everyCatalogueParses(_ target: String) throws {
        for language in Self.languages {
            #expect(try !Self.catalogue(target, language).isEmpty,
                    "\(target) has no \(language) sentences at all")
        }
    }

    /// The one failure this whole suite exists to catch: a sentence added to the code and to the
    /// English catalogue, and forgotten in the French. `String(localized:)` falls back to the key, so
    /// the app shows English inside a French window and says nothing about it.
    @Test(arguments: targets) func bothLanguagesHoldExactlyTheSameKeys(_ target: String) throws {
        let en = try Self.catalogue(target, "en")
        let fr = try Self.catalogue(target, "fr")
        let untranslated = Set(en.keys).subtracting(fr.keys).sorted()
        let orphaned = Set(fr.keys).subtracting(en.keys).sorted()
        #expect(untranslated.isEmpty, "\(target) has no French for: \(untranslated)")
        #expect(orphaned.isEmpty, "\(target)'s French translates sentences the English does not have: \(orphaned)")
    }

    /// The English is the key, so the English catalogue maps every sentence to itself. It exists so
    /// that `en.lproj` ships and macOS counts the app as English rather than as French only.
    @Test(arguments: targets) func theEnglishCatalogueMapsEverySentenceToItself(_ target: String) throws {
        for (key, value) in try Self.catalogue(target, "en") where key != value {
            Issue.record("\(target) en.lproj rewrites a sentence: \"\(key)\" reads \"\(value)\"")
        }
    }

    /// A translation free to reorder its sentence is not free to drop a value out of it, and a
    /// `%@` where the key has `%lld` crashes the formatter rather than reading oddly.
    @Test(arguments: targets) func everyTranslationKeepsThePlaceholdersOfItsKey(_ target: String) throws {
        for (key, value) in try Self.catalogue(target, "fr") {
            let wanted = Self.placeholders(key).sorted()
            let got = Self.placeholders(value).sorted()
            #expect(wanted == got, "\(target): \"\(key)\" takes \(wanted), its French takes \(got)")
        }
    }

    /// No sentence a person reads carries a dash other than the keyboard's hyphen. French prose
    /// reaches for one constantly, which is why this is pinned rather than trusted.
    @Test(arguments: targets) func noSentenceAPersonReadsCarriesALongDash(_ target: String) throws {
        for language in Self.languages {
            for (key, value) in try Self.catalogue(target, language)
            where !Self.longDashes.isDisjoint(with: value) {
                Issue.record("\(target) \(language): \"\(key)\" reads \"\(value)\"")
            }
        }
    }

    /// A key is written symbol first at every mention, titles included, in both languages.
    ///
    /// A name macOS gives something is exempt wherever it is quoted, and only by being named in
    /// `quotedSystemNames`: the Accessibility grant is called *Device Control and Data Access* in System
    /// Settings, and the rows and the warnings that send the user to find it have to read exactly that.
    @Test(arguments: targets) func everyKeyboardKeyIsWrittenSymbolFirst(_ target: String) throws {
        for language in Self.languages {
            for (key, sentence) in try Self.catalogue(target, language) {
                let value = Self.quotedSystemNames.reduce(sentence) { $0.replacingOccurrences(of: $1, with: "…") }
                for (word, symbol) in Self.keyboardKeys {
                    for range in value.ranges(of: word) {
                        // A word inside a longer one is not a mention: "Optional" is not ⌥ Option.
                        let after = value[range.upperBound...]
                        guard after.first.map({ !$0.isLetter }) ?? true else { continue }
                        let before = value[value.startIndex..<range.lowerBound]
                        guard before.last.map({ !$0.isLetter }) ?? true else { continue }
                        // "⌘ Command", and nothing else: the symbol, one space, the name.
                        guard before.hasSuffix("\(symbol) ") else {
                            Issue.record("""
                                \(target) \(language): "\(key)" writes \(word) without \(symbol) \
                                before it, in "\(value)"
                                """)
                            continue
                        }
                    }
                }
            }
        }
    }

    // MARK: - The call sites

    /// What a `%@` or a `%lld` in a key looks like, for matching a call site that interpolates a value.
    static let placeholderPattern = #"%(?:\d+\$)?(?:lld|ld|@|d|f)"#

    /// Every `L("…")` literal in a target's sources, as its text with each interpolation `\(…)` replaced
    /// by a NUL. A literal on one line is the only kind the code writes; `L(someVariable)` is not a literal
    /// and is not read.
    static func callSites(_ target: String) throws -> [(file: String, text: String)] {
        let folder = repoRoot.appending(path: "Sources/\(target)")
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.flatMap { file in
            literals(in: try String(contentsOf: file, encoding: .utf8)).map { (file.lastPathComponent, $0) }
        }
    }

    static func literals(in source: String) -> [String] {
        let chars = Array(source)
        var found: [String] = []
        var i = 0
        while i + 2 < chars.count {
            let startsCall = chars[i] == "L" && chars[i + 1] == "(" && chars[i + 2] == "\""
            let standsAlone = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_")
            guard startsCall, standsAlone else { i += 1; continue }
            var k = i + 3
            var text = ""
            var closed = false
            scan: while k < chars.count {
                switch chars[k] {
                case "\\":
                    guard k + 1 < chars.count else { break scan }
                    if chars[k + 1] == "(" {
                        // An interpolation: skip to its closing parenthesis, strings inside it included.
                        var depth = 1
                        k += 2
                        while k < chars.count, depth > 0 {
                            if chars[k] == "(" { depth += 1 }
                            if chars[k] == ")" { depth -= 1 }
                            if chars[k] == "\"" {
                                k += 1
                                while k < chars.count, chars[k] != "\"" { k += chars[k] == "\\" ? 2 : 1 }
                            }
                            k += 1
                        }
                        text.append("\u{0}")
                    } else {
                        text.append(chars[k + 1] == "n" ? "\n" : chars[k + 1])
                        k += 2
                    }
                case "\"":
                    closed = true
                    break scan
                case "\n":
                    break scan
                default:
                    text.append(chars[k])
                    k += 1
                }
            }
            if closed { found.append(text) }
            i = k + 1
        }
        return found
    }

    /// The catalogue keys a call site can mean: itself, or, when it interpolates, every key that reads the
    /// same with a placeholder where each value goes.
    static func keys(for text: String, among keys: Set<String>) throws -> [String] {
        guard text.contains("\u{0}") else { return keys.contains(text) ? [text] : [] }
        let pattern = "^" + text.split(separator: "\u{0}", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: placeholderPattern) + "$"
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        return keys.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }

    /// Every sentence the code shows is in its target's catalogue. `String(localized:)` falls back to the
    /// key when it is not, so a sentence added at a call site and never to the catalogue reads English on a
    /// French Mac with nothing to say so, which the catalogue-only rules above cannot see.
    @Test(arguments: targets) func everySentenceTheCodeShowsIsInItsCatalogue(_ target: String) throws {
        let keys = Set(try Self.catalogue(target, "en").keys)
        for site in try Self.callSites(target) where try Self.keys(for: site.text, among: keys).isEmpty {
            Issue.record("\(target)/\(site.file) shows \"\(site.text.replacingOccurrences(of: "\u{0}", with: "\\(…)"))\", which its catalogue does not hold")
        }
    }

    /// And every sentence in a catalogue is still shown somewhere: a sentence the code no longer uses is a
    /// line a translator keeps translating for nothing, and the next reader takes it for a live one.
    @Test(arguments: targets) func everyCatalogueSentenceIsStillShown(_ target: String) throws {
        let keys = Set(try Self.catalogue(target, "en").keys)
        var shown = Set<String>()
        for site in try Self.callSites(target) { shown.formUnion(try Self.keys(for: site.text, among: keys)) }
        for key in keys.subtracting(shown).sorted() {
            Issue.record("\(target)'s catalogue holds \"\(key)\", which no call site shows")
        }
    }

    /// The Health page's words, built in this target so its rules can be tested: every one is in both
    /// catalogues, and the French is written, not copied, except where both languages say the same.
    @Test func theHealthPageIsTranslated() throws {
        let en = try Self.catalogue("SnapCore", "en")
        let fr = try Self.catalogue("SnapCore", "fr")
        let words = [
            "Overview", "Everything works", "1 thing to look at", "%lld things to look at",
            "Not working: 1 problem", "Not working: %lld problems", "Checking", "Check Again",
            "Granted", "Denied", "Enabled", "Disabled", "Available", "Missing", "Valid", "Invalid", "Failed",
            "Permissions", "Accessibility permission", "Notifications permission",
            "macOS tiling", "macOS edge tiling", "macOS margins for tiled windows",
            "macOS tiling while ⌥ Option is held",
            "Snapping", "Drag detection", "Drags with fn held", "Drag detection pauses", "Never",
            "Space changes and Mission Control", "Last snap", "None yet", "Windows where a snap left them",
            "Windows not put back", "Handles", "Handles on offer", "Smallest window sizes", "Custom areas",
            "Compatibility", "Use hidden macOS features", "Notch", "Island", "Floating bar", "App",
            "Launch at login", "Running for", "Memory used", "Crashes in the last %lld days", "None",
            "Installed in", "Disk image", "Temporary copy", "Report", "Copy Report",
            "%lld s ago", "%lld min ago", "%lld h ago", "%lld d ago", "Less than a minute", "%lld MB",
        ]
        let sameInBothLanguages: Set<String> = ["App"]
        for word in words {
            #expect(en[word] == word, "the Health page has lost the English \"\(word)\"")
            #expect(fr[word]?.isEmpty == false, "\"\(word)\" has no French")
            if !sameInBothLanguages.contains(word) {
                #expect(fr[word] != word, "\"\(word)\" is untranslated French")
            }
        }
    }

    /// The words the Settings window shows for the two choices `SnapCore` owns, pinned in English
    /// where they now live. `title` itself is localized, so on this French Mac it reads French and
    /// cannot be compared to an English literal.
    @Test func theChoicesSnapCoreOwnsAreTranslated() throws {
        let en = try Self.catalogue("SnapCore", "en")
        let fr = try Self.catalogue("SnapCore", "fr")
        for word in ["Smooth", "Balanced", "Battery",
                     "Notch or island", "Floating bar", "Notch or floating bar"] {
            #expect(en[word] == word, "the Settings window has lost the English word \"\(word)\"")
            #expect(fr[word]?.isEmpty == false, "\"\(word)\" has no French")
            #expect(fr[word] != word, "\"\(word)\" is untranslated French")
        }
    }

    /// Both languages have to be in the built bundle, not only in the source tree: a target that
    /// loses its `resources:` line in `Package.swift` still compiles and still shows English.
    @Test func bothLanguagesShipInSnapCoresBundle() {
        let shipped = Set(localizationBundle.localizations)
        #expect(shipped.isSuperset(of: Self.languages), "SnapCore's bundle carries \(shipped.sorted())")
    }
}
