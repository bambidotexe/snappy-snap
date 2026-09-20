import Foundation

/// The one route every sentence this target shows a person takes to the screen.
///
/// **The English is the key.** A call site reads `L("Show in menu bar")`, so the sentence is still
/// next to the thing it labels, and `Resources/en.lproj/Localizable.strings` maps each English key to
/// itself while `fr.lproj` maps it to the French. A value inside a sentence is interpolated into the
/// key, `L("Version \(v) is available")`, which is the `%@` the two catalogues carry: the French is
/// then free to put the value wherever its own sentence needs it.
///
/// `Bundle.module` and not `.main`: the strings ship inside this target's resource bundle.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
