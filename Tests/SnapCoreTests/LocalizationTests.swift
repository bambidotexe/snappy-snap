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

    /// Keys whose sentence is a name macOS chose, quoted so the user can find it in System Settings.
    /// Exempt from the keyboard-key rule, and from nothing else.
    static let systemNames: Set<String> = ["Device Control and Data Access"]

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
    /// A sentence that quotes a name macOS gives something is exempt, and only by being named here: the
    /// Accessibility grant is called *Device Control and Data Access* in System Settings, and the row
    /// that sends the user to find it has to read exactly that. The word is the system's, not the key's.
    @Test(arguments: targets) func everyKeyboardKeyIsWrittenSymbolFirst(_ target: String) throws {
        for language in Self.languages {
            for (key, value) in try Self.catalogue(target, language) where !Self.systemNames.contains(key) {
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
