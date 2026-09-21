import AppKit
import os

// MARK: - What a grant is

/// One case per grant and per optional setup action the onboarding lists. The identity of a row, which
/// must not depend on its title or on its place in a list.
enum GrantID: String, CaseIterable, Sendable {
    case accessibility, notifications, systemTiling, loginItem
}

/// One grant the app depends on, or one optional setup action: what the onboarding lists. The
/// onboarding's words are here; the Settings window words the same states its own way.
struct GrantItem {
    /// Which grant this is, whatever its title and its place in the list.
    let id: GrantID
    /// **Exactly what System Settings calls this grant**, quoted from the system's own strings. The user
    /// has to find it in a list there, so a name of the app's own is a dead end however well it reads.
    /// A setting that is the app's own, or one that spans two system switches, is named here and quotes
    /// the switches in `why`.
    let title: String
    /// One line: what the app can do with it. Not how it works.
    let why: String
    /// Whether the app cannot do its job without it. Drawn with a warning mark, and the page's button
    /// stays "Skip" until every required grant is there.
    let required: Bool
    /// Read live, every time. Never a cached copy: the user can grant and revoke behind the window.
    ///
    /// **A reader, never an ask.** `AXIsProcessTrusted`, `getNotificationSettings`,
    /// `SMAppService…status` — never the call that requests. A request API returns the current state
    /// too, which makes it tempting here, and it also prompts; behind the 2 s poll that would be a
    /// permission dialog every two seconds.
    let granted: () -> Bool
    let buttonTitle: String
    /// Runs the grant flow; calls `done` on the main thread when the state may have changed. A flow that
    /// cannot finish in the app still calls `done`, at once.
    let action: (_ window: NSWindow?, _ done: @escaping () -> Void) -> Void

    /// Whether the flow puts up its own dialog and blocks until it is answered, as an administrator
    /// password dialog does. macOS does not reactivate an accessory app when such a dialog closes, so a
    /// flow that owned one takes activation back when it ends.
    ///
    /// **A flow that hands over to System Settings or to a system permission prompt leaves this false.**
    /// Those report back immediately, while the thing they opened is still coming up, so taking
    /// activation then drops the window on top of the pane it has just opened.
    var returnsFocus: Bool = false

    /// The app this flow can send the user to, if any. **Every macOS grant sets this to System
    /// Settings**, not only the ones whose button opens a pane: a system permission dialog carries its
    /// own button to System Settings, so any such row can be the reason the user ends up there. macOS
    /// gives an ordinary app the front back when the app it handed over to quits, and leaves an
    /// accessory app out of that, so the row waits for that app to quit and does it itself. Nil for a
    /// flow that stays inside SnappySnap.
    var mayOpen: String? = nil

    /// What the row shows once `granted()` is true. "Granted" for a macOS grant; a setting says what it
    /// now reads.
    var doneTitle: String = L("Granted")
    /// A grant the app can undo itself: the button shown once `granted()` is true.
    var removeTitle: String? = nil
    var remove: ((_ window: NSWindow?, _ done: @escaping () -> Void) -> Void)? = nil
}

extension GrantItem {
    /// Activation back to `window` once a flow that owned a modal dialog has ended, and only then.
    @MainActor func reclaimFocusIfNeeded(_ window: NSWindow?) {
        guard returnsFocus, let window, window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Giving the front back

/// Gives the front back after the user has been sent to another app, the way macOS does for an ordinary
/// app by itself. One of these waits for a named app to quit and then brings its window forward, once.
///
/// macOS hands the front to whatever was in front before the app that quit, and skips `LSUIElement` apps
/// doing so. There is no flag for that. The alternative is becoming `.regular` for as long as the window
/// is up, which means a Dock icon and a main menu this app has never had.
///
/// The wait is bounded: a user who dismisses the prompt and never goes to System Settings would
/// otherwise leave it armed, and an unrelated visit there much later would pull the window forward out
/// of nowhere.
@MainActor
final class FocusReturnWatch {
    private var observer: NSObjectProtocol?
    private weak var target: NSWindow?
    /// How long a wait stays honoured. Long enough to grant a permission, short enough not to linger.
    private static let honoured: TimeInterval = 300

    isolated deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    /// Waits for `bundleID` to quit, then brings `window` to the front. Replaces any earlier wait, and
    /// does nothing if the window has gone away or been closed by then.
    func whenQuit(_ bundleID: String, bringBack window: NSWindow?) {
        stop()
        guard let window else { return }
        target = window
        let deadline = Date().addingTimeInterval(Self.honoured)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // The identifier is read out here and the notification itself never crosses: `userInfo`
            // carries an `NSRunningApplication`, which cannot be sent into the main actor's region.
            let quit = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, quit == bundleID else { return }
                let target = self.target
                self.stop()
                guard Date() < deadline, let target, target.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                target.makeKeyAndOrderFront(nil)
            }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        target = nil
    }
}

// MARK: - The row

/// One row of a list page: what the grant is, why it is wanted, and a trailing control that follows its
/// state. **Built once and updated in place.** Rebuilding the page to show a grant that moved empties the
/// window and draws it again, which reads as a blink and a reload on every press and every poll tick.
///
/// While a flow is running the row keeps the button that started it, disabled, with a spinner beside it,
/// and the poll leaves that loading state alone until the flow reports back. A flow that reports more
/// than once settles the row on the first only.
@MainActor
final class GrantRow {
    let view: NSStackView

    /// What the trailing control is showing. Compared before redrawing, so a refresh that changes
    /// nothing touches no view at all.
    private enum Shown: Equatable { case nothing, granted, notGranted, busy(String) }

    private let item: GrantItem
    private let window: () -> NSWindow?
    private let focusReturn: FocusReturnWatch
    /// Called once a flow has reported back: the page's primary button may have to change with it.
    private let didFinish: () -> Void
    private let trailing = NSView()
    private var shown: Shown = .nothing
    private var busy = false

    init(item: GrantItem, window: @escaping () -> NSWindow?, focusReturn: FocusReturnWatch,
         didFinish: @escaping () -> Void) {
        self.item = item
        self.window = window
        self.focusReturn = focusReturn
        self.didFinish = didFinish

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: Metrics.rowTitle, weight: .semibold)
        let titleRow = NSStackView(views: [title])
        titleRow.spacing = 6
        if item.required {
            let warn = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                  accessibilityDescription: L("Required"))!)
            warn.contentTintColor = .systemOrange
            warn.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            warn.toolTip = L("Required")
            titleRow.addArrangedSubview(warn)
        }
        let why = NSTextField(wrappingLabelWithString: item.why)
        why.font = .systemFont(ofSize: Metrics.rowWhy)
        why.textColor = .secondaryLabelColor
        why.preferredMaxLayoutWidth = Metrics.rowTextWidth
        let text = NSStackView(views: [titleRow, why])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.rowTextWidth).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view = NSStackView(views: [text, spacer, trailing])
        view.alignment = .centerY
        view.spacing = 12
        refresh()
    }

    /// Re-reads the grant and redraws the trailing control only if it should look different. A row whose
    /// flow is still running keeps its loading state: the poll must not take it away.
    func refresh() {
        guard !busy else { return }
        show(item.granted() ? .granted : .notGranted)
    }

    private func show(_ next: Shown) {
        guard next != shown else { return }
        Logger.onboarding.debug("\(self.item.id.rawValue, privacy: .public): row redraws \(String(describing: next), privacy: .public)")
        shown = next
        trailing.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        switch next {
        case .nothing:
            content = NSView()
        case .busy(let title):
            let button = Self.button(title)
            button.isEnabled = false
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            let pair = NSStackView(views: [spinner, button])
            pair.spacing = 8
            content = pair
        case .granted:
            let done = NSTextField(labelWithString: item.doneTitle)
            done.font = .systemFont(ofSize: Metrics.rowTrailing)
            done.textColor = .secondaryLabelColor
            if let remove = item.remove {
                let title = item.removeTitle ?? L("Remove")
                let button = Self.button(title)
                button.actionHandler = { [weak self] in
                    guard let self else { return }
                    self.start(title) { settle in remove(self.window(), settle) }
                }
                let pair = NSStackView(views: [done, button])
                pair.spacing = 8
                content = pair
            } else {
                content = done
            }
        case .notGranted:
            let button = Self.button(item.buttonTitle)
            button.actionHandler = { [weak self] in
                guard let self else { return }
                self.start(self.item.buttonTitle) { settle in self.item.action(self.window(), settle) }
            }
            content = button
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        trailing.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: trailing.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            content.topAnchor.constraint(equalTo: trailing.topAnchor),
            content.bottomAnchor.constraint(equalTo: trailing.bottomAnchor),
        ])
    }

    /// Runs one grant flow with the row in its loading state, reads the grant again when it reports
    /// back, and settles who is in front. The order matters: the row is right before anything is
    /// activated.
    private func start(_ title: String, _ flow: (_ settle: @escaping () -> Void) -> Void) {
        Logger.onboarding.info("\(self.item.id.rawValue, privacy: .public): flow started from \(title, privacy: .public)")
        busy = true
        show(.busy(title))
        var settled = false
        flow { [weak self] in
            guard !settled else { return }
            settled = true
            guard let self else { return }
            self.busy = false
            Logger.onboarding.info("\(self.item.id.rawValue, privacy: .public): flow settled, granted=\(self.item.granted(), privacy: .public)")
            self.refresh()
            self.didFinish()
            self.item.reclaimFocusIfNeeded(self.window())
            if let opened = self.item.mayOpen { self.focusReturn.whenQuit(opened, bringBack: self.window()) }
        }
    }

    private static func button(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        return button
    }
}

// MARK: - The numbers

/// Every size the onboarding window uses, in points. Fitted by eye in the running window. Reproduce
/// them; do not retune one because it reads better in a diff.
enum Metrics {
    static let windowWidth: CGFloat = 540
    /// Page heights, by page. The window resizes around its top-left corner, so the title bar stays put
    /// and the page grows downward. A list page's height is the one its rows need: `listHeight` is the
    /// five row height, `shortListHeight` the two row one, and a page taller than its content leaves the
    /// stepping button floating above a band of nothing.
    static let heroHeight: CGFloat = 440
    static let listHeight: CGFloat = 560
    static let shortListHeight: CGFloat = 440
    static let finalHeight: CGFloat = 400

    static let heroIcon: CGFloat = 104
    static let heroTitle: CGFloat = 26
    static let heroBody: CGFloat = 14
    /// The widest a hero's text gets before it wraps, inside a 540 window.
    static let heroTextWidth: CGFloat = 440
    static let heroSpacing: CGFloat = 18
    static let heroTitleToBody: CGFloat = 10
    static let heroInsets = NSEdgeInsets(top: 32, left: 40, bottom: 36, right: 40)

    static let listTitle: CGFloat = 22
    static let listIntro: CGFloat = 13
    static let listIntroWidth: CGFloat = 460
    static let listSpacing: CGFloat = 14
    static let listIntroToList: CGFloat = 20
    static let listToFooter: CGFloat = 24
    static let listRowSpacing: CGFloat = 12
    static let listInsets = NSEdgeInsets(top: 28, left: 40, bottom: 28, right: 40)
    /// The list is the page's width less both insets.
    static let listSideInset: CGFloat = 80

    static let rowTitle: CGFloat = 14
    static let rowWhy: CGFloat = 12
    static let rowTrailing: CGFloat = 13
    /// The widest a row's title and explanation get, leaving room for the trailing control.
    static let rowTextWidth: CGFloat = 320

    static let pillSymbol: CGFloat = 11
    static let pillLabel: CGFloat = 11.5
    static let pillInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
    static let pillRadius: CGFloat = 13
    static let pillSpacing: CGFloat = 4
    static let pillTint: CGFloat = 0.10
    static let pillRowWidth: CGFloat = 460

    /// How often a list page re-reads its grants while the window is up. Slow enough to be free, fast
    /// enough that coming back from System Settings finds the page already right.
    static let pollInterval: TimeInterval = 2
}
