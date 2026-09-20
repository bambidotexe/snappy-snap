import Testing
import Foundation
@testable import SystemAdapters

/// `SnapCoreTests`' `LocalizationTests` holds every rule the catalogues keep, for all three targets.
/// What only this target can answer is whether its own bundle actually shipped them.
@Suite struct LocalizationTests {
    /// A target that loses its `resources:` line in `Package.swift` still compiles, and every
    /// sentence then falls back to its English key with nothing said about it.
    @Test func bothLanguagesShipInSystemAdaptersBundle() {
        let shipped = Set(localizationBundle.localizations)
        #expect(shipped.isSuperset(of: ["en", "fr"]), "SystemAdapters' bundle carries \(shipped.sorted())")
    }

    /// The four lines the System page reports, one per thing the private symbols buy, in the English
    /// the window shows. `PrivateFeature.title` is localized and reads French on a French Mac.
    @Test func theFourFeatureLinesAreTranslated() throws {
        let englishPath = try #require(localizationBundle.path(forResource: "en", ofType: "lproj"))
        let frenchPath = try #require(localizationBundle.path(forResource: "fr", ofType: "lproj"))
        let english = try #require(Bundle(path: englishPath))
        let french = try #require(Bundle(path: frenchPath))
        for word in ["Exact window matching", "Pointer over the handles",
                     "Snap bar above other notch apps", "Blur behind the snap bar"] {
            #expect(english.localizedString(forKey: word, value: "", table: nil) == word,
                    "the System page has lost the English line \"\(word)\"")
            let translated = french.localizedString(forKey: word, value: "", table: nil)
            #expect(!translated.isEmpty, "\"\(word)\" has no French")
            #expect(translated != word, "\"\(word)\" is untranslated French")
        }
    }
}
