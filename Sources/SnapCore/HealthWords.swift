import Foundation

/// Every word the Health page shows, in English here and in French in this target's catalogue: the two
/// tables' titles, the lines' labels, the one word at their trailing edge, the readings, and the sentences
/// that say how to put a line right. The lines are built in this target (`HealthReport`), so their words
/// live in its catalogue, not in the app's; the page itself only draws them. The System and Snapping pages
/// take the states they share with it from here too, so a state reads the same words on every page.
///
/// macOS's own names are quoted from its own strings, in the language being written: the Privacy &
/// Security pane's *Device Control and Data Access*, Desktop & Dock's switches, the Notifications pane's
/// *Allow notifications*, Console's *Crash Reports*.
public enum HealthWords {
    // MARK: The two tables

    public static var healthTitle: String { L("Health") }
    public static var informationTitle: String { L("Information") }
    public static var checkAgainButton: String { L("Check Again") }

    // MARK: The vocabulary

    public static var granted: String { L("Granted") }
    public static var denied: String { L("Denied") }
    public static var enabled: String { L("Enabled") }
    public static var disabled: String { L("Disabled") }
    public static var available: String { L("Available") }
    public static var missing: String { L("Missing") }
    public static var invalid: String { L("Invalid") }
    public static var failed: String { L("Failed") }

    // MARK: Permissions

    public static var accessibilityLabel: String { L("Accessibility permission") }

    /// Also the System page's warning under its Accessibility row, while the permission is denied.
    public static var accessibilityFix: String {
        L("In Privacy & Security, turn on SnappySnap under “Device Control and Data Access”. Snapping starts the moment it is on.")
    }

    public static var notificationsLabel: String { L("Notifications permission") }

    /// Never asked: the one button that asks is the welcome window's.
    public static var notificationsNotAskedFix: String {
        L("Only the announcement of a new version needs it. Show Onboarding Again, in Settings › System, offers it.")
    }

    /// Refused once: macOS asks no more, and the switch is in its own pane.
    public static var notificationsDeniedFix: String {
        L("Only the announcement of a new version needs it. In System Settings › Notifications, turn on “Allow notifications” for SnappySnap.")
    }

    // MARK: macOS tiling

    public static var tilingTitle: String { L("macOS tiling") }
    public static var edgeTilingLabel: String { L("macOS edge tiling") }

    /// Also the System page's warning under its tiling rows.
    public static var edgeTilingFix: String {
        L("In Desktop & Dock, turn off “Drag windows to left or right edge of screen to tile” and “Drag windows to menu bar to fill screen”.")
    }

    public static var marginsLabel: String { L("macOS margins for tiled windows") }

    /// Two whole sentences rather than one with the verb spliced in, so each language writes its own.
    /// Also the System page's warning.
    public static func marginsFix(gapOn: Bool) -> String {
        gapOn ? L("In Desktop & Dock, turn on “Tiled windows have margins”.")
              : L("In Desktop & Dock, turn off “Tiled windows have margins”.")
    }

    public static var optionTilingLabel: String { L("macOS tiling while ⌥ Option is held") }

    public static var optionTilingFix: String {
        L("With the halves held under ⌥ Option on, macOS tiles the window too. In Desktop & Dock, turn off “Hold ⌥ key while dragging windows to tile”.")
    }

    // MARK: The drag detection

    public static var dragDetectionLabel: String { L("Drag detection") }

    public static var dragDetectionFix: String {
        L("SnappySnap could not start following your drags. Quit it and open it again.")
    }

    public static var fnDragsLabel: String { L("Drags with fn held") }

    public static var fnDragsFix: String {
        L("A window dragged with fn held is not snapped. Quit SnappySnap and open it again.")
    }

    public static var pausesLabel: String { L("Drag detection pauses") }

    public static func pausesDetail(slow: Int, byMacOS: Int) -> String {
        L("\(slow) for answering too slowly, \(byMacOS) by macOS")
    }

    public static var pausesFix: String {
        L("macOS paused the drag detection because SnappySnap answered too slowly, so a drag may have been missed. If it keeps happening, quit SnappySnap and open it again.")
    }

    public static var spacesLabel: String { L("Space tracking") }

    public static var spacesFix: String {
        L("Snapping does not stand down when you change Space or open Mission Control. Quit SnappySnap and open it again.")
    }

    public static var strandedLabel: String { L("Windows not put back") }

    public static var parkedRecordFix: String {
        L("The windows Snap Assist had moved aside when SnappySnap last quit could not be found again. Look for them in a corner of the screen and drag them back.")
    }

    public static var strandedFix: String {
        L("Snap Assist could not put them back, so they sit in a corner of the screen. Quit SnappySnap and open it again: it puts them back as it starts.")
    }

    public static func crashesLabel(days: Int) -> String { L("Crashes in the last \(days) days") }

    public static func lastCrash(_ stamp: String) -> String { L("Last one \(stamp)") }

    public static var crashesFix: String {
        L("Console shows what happened, under “Crash Reports”.")
    }

    // MARK: Readings

    public static var lastSnapLabel: String { L("Last snap") }
    public static var noneYet: String { L("None yet") }

    /// How long ago something happened, in the one unit that reads best.
    public static func ago(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return L("\(s) s ago") }
        if s < 3_600 { return L("\(s / 60) min ago") }
        if s < 86_400 { return L("\(s / 3_600) h ago") }
        return L("\(s / 86_400) d ago")
    }

    public static var snappedWindowsLabel: String { L("Windows where a snap left them") }

    // MARK: The System page's hidden macOS features

    public static var compatibilityTitle: String { L("Compatibility") }
    public static var hiddenFeaturesLabel: String { L("Use hidden macOS features") }
}
