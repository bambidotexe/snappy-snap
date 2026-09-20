import Combine
import Foundation
import SnapCore

/// Persists `Settings` as one JSON blob in UserDefaults and publishes changes to SwiftUI.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let defaultsKey = "settings.v1"
    /// The custom zones' JSON, as the text the user wrote — its own string key, not part of the blob.
    public static let customZonesKey = "customZones.v1"

    @Published public var settings: Settings {
        didSet { save() }
    }

    /// Stored on every change. Nothing stored yet reads as `CustomZones.defaultConfiguration`; an empty
    /// string that the user left there is stored and read back as empty, and offers no areas.
    @Published public var customZonesJSON: String {
        didSet { defaults.set(customZonesJSON, forKey: Self.customZonesKey) }
    }

    private let defaults: UserDefaults

    /// What is on disk is loaded as it is, and nothing else. **No migration belongs here**: `didSet`
    /// does not fire in `init`, so nothing would record that a migration had run and it would re-run
    /// on every launch, overwriting the choice the user had made through the Settings window. A
    /// persisted value is not a default — changing a default in code reaches nobody who has already
    /// run the app, and the answer to that is a control the user can move, not a rule that moves it
    /// for them.
    ///
    /// **No clamp either.** Every number the user could put out of range is a constant in
    /// `Settings.Fixed`, and what is left in the file is booleans and one enum, all of which
    /// `Settings.init(from:)` already reads tolerantly.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customZonesJSON = defaults.string(forKey: Self.customZonesKey) ?? CustomZones.defaultConfiguration
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        } else {
            settings = Settings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
