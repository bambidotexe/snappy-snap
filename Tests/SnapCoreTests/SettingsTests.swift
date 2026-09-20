import Testing
import Foundation
@testable import SnapCore

@Suite struct SettingsTests {
    @Test func smoothnessDefaultsToAdaptiveAndSurvivesAFileWrittenBeforeItExisted() throws {
        #expect(Settings().smoothness == .adaptive)
        let old = Data("{\"gap\": 12}".utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: old).smoothness == .adaptive)
        for preset in Smoothness.allCases {
            var s = Settings()
            s.smoothness = preset
            let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
            #expect(round.smoothness == preset)
        }
    }

    /// The Settings window builds its Animation control from `allCases` and labels each segment with
    /// `title`. Both are pinned here so the order the user reads them in — least battery-conscious
    /// first, with the default in the middle — is not an accident of declaration order that a later
    /// edit can silently reshuffle.
    /// `title` is localized, so it reads French on a Mac set to French. The English words themselves
    /// are pinned in `LocalizationTests`, against the catalogue that now holds them.
    @Test func everySmoothnessPresetHasAnOrderedLabel() throws {
        #expect(Smoothness.allCases == [.smooth, .adaptive, .battery])
        let labels = Smoothness.allCases.map(\.title)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == Smoothness.allCases.count)
    }

    /// The snap bar is drawn in the notch, or in an island, unless the user chooses otherwise — and a
    /// settings file that does not say gets that default like any other missing key.
    @Test func theSnapBarAppearanceDefaultsToTheNotchOrIslandAndSurvivesAFileThatDoesNotSay() throws {
        #expect(Settings().snapBarAppearance == .notch)
        let silent = Data("{\"gap\": 12}".utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: silent).snapBarAppearance == .notch)
        for appearance in SnapBarAppearance.allCases {
            var s = Settings()
            s.snapBarAppearance = appearance
            let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
            #expect(round.snapBarAppearance == appearance)
            #expect(round == s)
        }
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{\"snapBarAppearance\": \"notch\"}".utf8))
            .snapBarAppearance == .notch)
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{\"snapBarAppearance\": \"notchOrBar\"}".utf8))
            .snapBarAppearance == .notchOrBar)
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{\"snapBarAppearance\": \"bar\"}".utf8))
            .snapBarAppearance == .bar)
    }

    /// The Settings window builds the Style tiles from `allCases`, default first, titles each with
    /// `title` and puts the selected one's `detail` under the group.
    @Test func everySnapBarAppearanceHasAnOrderedLabelAndAnExplanation() {
        #expect(SnapBarAppearance.allCases == [.notch, .bar, .notchOrBar])
        // `title` is localized; the English words are pinned in `LocalizationTests`.
        let titles = SnapBarAppearance.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == SnapBarAppearance.allCases.count)
        for appearance in SnapBarAppearance.allCases {
            #expect(!appearance.detail.isEmpty, "\(appearance) has no explanation to show")
            #expect(appearance.detail != appearance.title)
        }
        #expect(Set(SnapBarAppearance.allCases.map(\.detail)).count == SnapBarAppearance.allCases.count)
    }

    /// Every stored property here is a control in the Settings window, and this roster is the only
    /// thing that says so. Adding a setting fails this test on purpose: a setting with no control is
    /// one the user can neither see nor change. Launch at login is not here: its state lives in
    /// `SMAppService`, which the user can change without us, so there is nothing here to be the truth of.
    @Test func theSettingsRosterIsExactlyWhatTheSettingsWindowShows() throws {
        let fields = Mirror(reflecting: Settings()).children.compactMap(\.label).sorted()
        let shown = [
            // Snapping
            "sideHalves", "optionHalves", "topFill", "corners", "restoreOnDragAway",
            // Snap bar
            "snapBar", "snapBarAppearance", "snapAssist", "hapticFeedback",
            // Custom areas
            "customAreas",
            // Layout
            "gapEnabled", "correctOversizedWindows",
            // Handles
            "handleBar", "probeMinimumSizes",
            // Motion
            "smoothness",
            // Compatibility
            "usePrivateAPIs",
            // Menu bar
            "showInMenuBar",
        ].sorted()
        #expect(fields == shown, "a new setting needs a control in SettingsView")
    }

    /// The private-API switch is **on** by default, and a settings file written before it existed must
    /// come back on rather than off: a silent default of off would take the app's performance away
    /// from every existing user without anyone choosing that.
    @Test func thePrivateAPISwitchDefaultsToOnAndSurvivesAFileWrittenBeforeItExisted() throws {
        #expect(Settings().usePrivateAPIs == true)
        let old = Data("{\"gap\": 12}".utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: old).usePrivateAPIs == true)
        // Both ways round: a user who turned it off must still find it off after a relaunch, which an
        // `?? true` written over a decoded `false` would quietly undo.
        for chosen in [true, false] {
            var s = Settings()
            s.usePrivateAPIs = chosen
            let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
            #expect(round.usePrivateAPIs == chosen)
            #expect(round == s)
        }
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{\"usePrivateAPIs\": false}".utf8)).usePrivateAPIs == false)
    }

    /// The probe switch is **on** by default, and a settings file written before it existed must come
    /// back on. Defaulting it off would silently take away the measurement that lets a divider stop
    /// where a window really stops, for a user who never asked for that.
    @Test func theProbeSwitchDefaultsToOnAndSurvivesAFileWrittenBeforeItExisted() throws {
        #expect(Settings().probeMinimumSizes == true)
        let old = Data("{\"gap\": 12}".utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: old).probeMinimumSizes == true)
        // And a user who turned it off finds it off after a relaunch, which an `?? true` written over
        // a decoded `false` would quietly undo.
        for chosen in [true, false] {
            var s = Settings()
            s.probeMinimumSizes = chosen
            let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
            #expect(round.probeMinimumSizes == chosen)
        }
    }

    /// The Option switch is **off** by default, and a settings file written before it existed must come
    /// back off. Defaulting it on would give a second modifier a meaning during a drag for a user who
    /// never asked for one, and Option is a key other applications read.
    @Test func theOptionHalvesSwitchDefaultsToOffAndSurvivesAFileWrittenBeforeItExisted() throws {
        #expect(Settings().optionHalves == false)
        let old = Data("{\"gap\": 12}".utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: old).optionHalves == false)
        for chosen in [true, false] {
            var s = Settings()
            s.optionHalves = chosen
            let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
            #expect(round.optionHalves == chosen)
            #expect(round == s)
        }
    }

    /// The haptic switch is **on** by default, and a settings file written before it existed must come
    /// back on. The tap follows the arming dwell, so it can only ever confirm a bar the user held still
    /// to summon; defaulting it off would withhold that from everyone rather than from whoever asked.
    @Test func theHapticSwitchDefaultsToOnAndSurvivesAFileWrittenBeforeItExisted() throws {
        #expect(Settings().hapticFeedback == true)
        let old = Data("{\"gap\": 12}".utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: old).hapticFeedback == true)
        // And a user who turned it off finds it off after a relaunch, which an `?? true` written over a
        // decoded `false` would quietly undo.
        for chosen in [true, false] {
            var s = Settings()
            s.hapticFeedback = chosen
            let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
            #expect(round.hapticFeedback == chosen)
            #expect(round == s)
        }
    }

    /// The menu-bar icon is **shown** by default, and a settings file written before the switch
    /// existed must come back showing it: an app that defaulted to invisible would look like one that
    /// had not launched, and the icon's menu is where Settings and Quit are.
    @Test func theMenuBarSwitchDefaultsToOnAndSurvivesAFileWrittenBeforeItExisted() throws {
        #expect(Settings().showInMenuBar == true)
        let old = Data("{\"gap\": 12}".utf8)
        #expect(try JSONDecoder().decode(Settings.self, from: old).showInMenuBar == true)
        // Both ways round: a user who hid the icon must still find it hidden after a relaunch, which
        // an `?? true` written over a decoded `false` would quietly undo — and putting the icon back
        // unasked is the one failure here nobody would report as a bug.
        for chosen in [true, false] {
            var s = Settings()
            s.showInMenuBar = chosen
            let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
            #expect(round.showInMenuBar == chosen)
            #expect(round == s)
        }
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{\"showInMenuBar\": false}".utf8))
            .showInMenuBar == false)
    }

    @Test func defaultsAreTheShippedOnes() {
        let s = Settings()
        #expect(s.sideHalves && s.corners && s.topFill && s.snapBar && s.snapAssist && s.handleBar)
        #expect(s.hapticFeedback)
        #expect(s.showInMenuBar)
        #expect(s.restoreOnDragAway == false)
        #expect(s.optionHalves == false)
        #expect(s.gapEnabled && s.correctOversizedWindows)
        #expect(s.smoothness == .adaptive)
    }

    /// The constants read through `Settings` are `Settings.Fixed`'s, and the three widths the handle
    /// keeps apart stay apart: what the app leaves between snapped windows, how far apart two windows
    /// may be and still get a handle, and how wide the region that catches the press is.
    @Test func theFixedConstantsReadThroughSettings() {
        let s = Settings()
        #expect(s.cornerBand == 120)
        #expect(s.edgeBand == 24)
        #expect(s.animationDuration == 0.25)
        #expect(s.handleMaxGap == 16)
        #expect(s.handleMinOverlap == 60)
        #expect(s.deckCeiling == 20)
        #expect(s.snapFill)
        #expect(s.gap == 8)
        #expect(HandleBarGeometry.bandThickness == 10)
        #expect(HandleBarGeometry.pillThickness == 4)
    }

    /// The gap is a switch: on is `Fixed.gap`, off is 0, and nothing else is persisted about it.
    @Test func theGapIsASwitch() throws {
        var s = Settings()
        #expect(s.gap == 8)
        s.gapEnabled = false
        #expect(s.gap == 0)
        let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(round.gapEnabled == false)
        #expect(round == s)
    }

    /// A file written when the gap was a number reads as "on unless it was 0".
    @Test func aLegacyNumericGapDecodesAsTheSwitch() throws {
        #expect(try JSONDecoder().decode(Settings.self, from: Data(#"{"gap": 4}"#.utf8)).gapEnabled == true)
        #expect(try JSONDecoder().decode(Settings.self, from: Data(#"{"gap": 0}"#.utf8)).gapEnabled == false)
        #expect(try JSONDecoder().decode(Settings.self, from: Data(#"{"gap": 12}"#.utf8)).gap == 8)
        // A stored switch wins over a legacy number.
        let both = try JSONDecoder().decode(Settings.self, from: Data(#"{"gap": 12, "gapEnabled": false}"#.utf8))
        #expect(both.gapEnabled == false)
    }

    @Test func decodingToleratesMissingKeys() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"corners": false}"#.utf8))
        #expect(s.corners == false)
        #expect(s.cornerBand == 120)
        #expect(s.handleBar == true)
        var expected = Settings()
        expected.corners = false
        #expect(s == expected)
    }

    /// Keys a file may still hold from earlier versions are ignored, not errors.
    @Test func decodingIgnoresUnknownKeys() throws {
        let json = #"{"customGap": 4, "layoutMode": "custom", "paused": true, "cornerBand": 60, "handleRelease": "reveal", "deckCeiling": 5, "sharedDisplayEdges": true}"#
        #expect(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) == Settings())
    }

    @Test func codableRoundTrip() throws {
        var s = Settings()
        s.smoothness = .battery
        s.handleBar = false
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(Settings.self, from: data) == s)
    }

    /// The constants are computed, so they never reach the file.
    @Test func theFixedConstantsAreNotEncoded() throws {
        let json = try #require(String(data: JSONEncoder().encode(Settings()), encoding: .utf8))
        for key in ["cornerBand", "edgeBand", "animationDuration", "handleMaxGap", "handleMinOverlap",
                    "deckCeiling", "snapFill", "\"gap\""] {
            #expect(!json.contains(key), "\(key) was encoded")
        }
    }
}
