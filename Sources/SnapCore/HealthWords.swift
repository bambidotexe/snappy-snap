import CoreGraphics
import Foundation

/// Every word the Health page shows, in English here and in French in this target's catalogue: the rows'
/// labels, the one word at their trailing edge, the readings, and the sentences that say how to put a row
/// right. The rows are built in this target (`HealthReport`), so their words live in its catalogue, not
/// in the app's; the page itself only draws them.
///
/// macOS's own names are quoted from its own strings, in the language being written: the Privacy &
/// Security pane's *Device Control and Data Access*, Desktop & Dock's four switches, Login Items &
/// Extensions' *Open at Login*, the Notifications pane's *Allow notifications*, Console's *Crash Reports*.
public enum HealthWords {
    // MARK: The overview

    public static var overviewTitle: String { L("Overview") }
    public static var everythingWorks: String { L("Everything works") }

    public static func toLookAt(_ count: Int) -> String {
        count == 1 ? L("1 thing to look at") : L("\(count) things to look at")
    }

    public static func notWorking(problems count: Int) -> String {
        count == 1 ? L("Not working: 1 problem") : L("Not working: \(count) problems")
    }

    /// No ellipsis: a busy word is a participle like any other.
    public static var checking: String { L("Checking") }
    public static var checkAgainButton: String { L("Check Again") }

    // MARK: The vocabulary

    public static var granted: String { L("Granted") }
    public static var denied: String { L("Denied") }
    public static var enabled: String { L("Enabled") }
    public static var disabled: String { L("Disabled") }
    public static var available: String { L("Available") }
    public static var missing: String { L("Missing") }
    public static var valid: String { L("Valid") }
    public static var invalid: String { L("Invalid") }
    public static var failed: String { L("Failed") }

    // MARK: Permissions

    public static var permissionsTitle: String { L("Permissions") }
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

    // MARK: Snapping

    public static var snappingTitle: String { L("Snapping") }
    public static var dragDetectionLabel: String { L("Drag detection") }

    public static var dragDetectionFix: String {
        L("SnappySnap could not start following your drags. Quit it and open it again.")
    }

    public static var fnDragsLabel: String { L("Drags with fn held") }

    public static var fnDragsFix: String {
        L("A window dragged with fn held is not snapped. Quit SnappySnap and open it again.")
    }

    public static var pausesLabel: String { L("Drag detection pauses") }
    public static var never: String { L("Never") }

    public static func pausesDetail(slow: Int, byMacOS: Int) -> String {
        L("\(slow) for answering too slowly, \(byMacOS) by macOS")
    }

    public static var pausesFix: String {
        L("macOS paused the drag detection because SnappySnap answered too slowly, so a drag may have been missed. Copy the report below to send it along.")
    }

    public static var spacesLabel: String { L("Space changes and Mission Control") }

    public static var spacesFix: String {
        L("Snapping does not stand down when you change Space or open Mission Control. Quit SnappySnap and open it again.")
    }

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
    public static var strandedLabel: String { L("Windows not put back") }

    public static var parkedRecordFix: String {
        L("The windows Snap Assist had moved aside when SnappySnap last quit could not be found again. Look for them in a corner of the screen and drag them back.")
    }

    public static var strandedFix: String {
        L("Snap Assist could not put them back, so they sit in a corner of the screen. Quit SnappySnap and open it again: it puts them back as it starts.")
    }

    // MARK: Handles

    public static var handlesTitle: String { L("Handles") }
    public static var handlePlacesLabel: String { L("Handles on offer") }
    public static var windowSizesLabel: String { L("Smallest window sizes") }

    public static func apps(_ count: Int) -> String {
        count == 1 ? L("1 app") : L("\(count) apps")
    }

    public static func windowSizesDetail(builtIn: Int, measured: Int, edited: Int) -> String {
        L("\(builtIn) built in, \(measured) measured, \(edited) edited")
    }

    public static var windowSizesFix: String {
        L("The saved list could not be read, so the built-in one is used and the rest is measured again.")
    }

    // MARK: Custom areas

    public static var customAreasTitle: String { L("Custom areas") }
    public static var customAreasLabel: String { L("Custom areas") }

    public static func areas(_ count: Int) -> String {
        count == 1 ? L("1 area") : L("\(count) areas")
    }

    public static var customAreasFix: String {
        L("No area is offered until the text is fixed. Settings › Custom Areas says what is wrong.")
    }

    // MARK: Compatibility

    public static var compatibilityTitle: String { L("Compatibility") }
    public static var hiddenFeaturesLabel: String { L("Use hidden macOS features") }

    public static var hiddenFeatureFix: String {
        L("This macOS lacks a hidden part SnappySnap uses, so it does without: everything still works, a little less precisely.")
    }

    /// A display's name is its own and never translated; the sentence around it is.
    public static func snapBarOn(display name: String) -> String {
        L("Snap bar on “\(name)”")
    }

    public static func surface(_ surface: SnapBarSurface) -> String {
        switch surface {
        case .notchShape: L("Notch")
        case .island: L("Island")
        case .floatingBar: L("Floating bar")
        }
    }

    public static func displayDetail(size: CGSize, housing: CGSize?) -> String {
        let frame = "\(points(size.width)) × \(points(size.height)) pt"
        guard let housing else { return frame }
        return L("\(frame), camera housing \(points(housing.width)) × \(points(housing.height)) pt")
    }

    private static func points(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }

    // MARK: App

    public static var appTitle: String { L("App") }
    public static var launchAtLoginLabel: String { L("Launch at login") }

    /// The login item was switched off in System Settings while the app still asks for it. Quoted as the
    /// Login Items & Extensions pane names its list.
    public static var loginItemNeedsApprovalFix: String {
        L("In System Settings › General › Login Items & Extensions, turn on SnappySnap under “Open at Login”.")
    }

    public static var runningForLabel: String { L("Running for") }

    /// How long something has run, to the minute, in the two largest units that mean anything.
    public static func duration(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return L("\(days) d \(hours) h") }
        if hours > 0 { return L("\(hours) h \(minutes) min") }
        return minutes > 0 ? L("\(minutes) min") : L("Less than a minute")
    }

    public static var memoryLabel: String { L("Memory used") }

    public static func megabytes(_ count: Int) -> String { L("\(count) MB") }

    public static func crashesLabel(days: Int) -> String { L("Crashes in the last \(days) days") }
    public static var none: String { L("None") }

    public static func lastCrash(_ stamp: String) -> String { L("Last one \(stamp)") }

    public static var crashesFix: String {
        L("Console shows what happened, under “Crash Reports”. Copy the report below to send it along.")
    }

    public static var locationLabel: String { L("Installed in") }

    public static func locationWord(_ location: AppLocation) -> String {
        switch location {
        case .applications: "Applications"
        case .elsewhere(let folder): folder
        case .diskImage: L("Disk image")
        case .temporaryCopy: L("Temporary copy")
        }
    }

    public static var locationFix: String {
        L("Quit SnappySnap, drag it to the Applications folder, and open it from there. Where it runs now, it cannot update itself.")
    }

    // MARK: Report

    public static var reportTitle: String { L("Report") }
    public static var reportHint: String { L("Copies everything on this page as text, to paste into a bug report.") }
    public static var copyReportButton: String { L("Copy Report") }
}
