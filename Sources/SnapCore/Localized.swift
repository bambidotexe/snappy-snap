import Foundation

/// The one route every sentence this target shows a person takes to the screen. The English is the
/// key; `Resources/en.lproj` maps it to itself and `Resources/fr.lproj` to the French. See the same
/// helper in `SnappySnap` for the whole of the rule.
///
/// `Foundation` only, like the rest of `SnapCore`: nothing here knows what a window looks like.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

/// The catalogue the sentences above come from. Named so a test can ask which languages actually
/// shipped in the bundle: a target that loses its `resources:` line still compiles, and every
/// sentence then silently falls back to the English key.
let localizationBundle = Bundle.module
