import AppKit
import os
import SnapCore
import SystemAdapters

// MARK: - The pages

/// A capsule on the first page: an SF Symbol and two or three words, in the brand colour.
struct Pill {
    let symbol: String
    let text: String
}

/// One page of the wizard. The order here is the order the user walks.
enum OnboardingPage {
    /// The first page, and any full width page that is a picture and a sentence rather than a list: the
    /// app icon, a headline with one word accented, a short description, optional capsules, one button.
    case hero(title: String, accent: String?, body: String, pills: [Pill], button: String)
    /// A page of rows. `advanceWhen` decides whether its button reads "Continue" or "Skip": on the
    /// permissions page that is every required grant being there; on an optional page, any one row done.
    case list(header: String, intro: String, items: [GrantItem], height: CGFloat,
              advanceWhen: ([GrantItem]) -> Bool)
    /// The last page. Its button finishes and closes the window.
    case final(title: String, body: String, button: String)

    /// The window's height while this page is shown. The window resizes around its top-left corner.
    var height: CGFloat {
        switch self {
        case .hero: Metrics.heroHeight
        case .list(_, _, _, let height, _): height
        case .final: Metrics.finalHeight
        }
    }
}

/// Every required grant is there. The permissions page's rule.
func everyRequiredGrant(_ items: [GrantItem]) -> Bool {
    items.filter(\.required).allSatisfy { $0.granted() }
}

/// Any one row is done. An optional page's rule.
func anyOneDone(_ items: [GrantItem]) -> Bool {
    items.contains { $0.granted() }
}

// MARK: - The window

/// Four pages: what SnappySnap does, the permissions page, the two macOS settings it works best with,
/// and "All set".
///
/// **An ordinary window.** The normal level and the default collection behaviour, the same as
/// `SettingsWindow` and `UpdateWindow`. It comes up in front because it is the last window to open, and
/// from then on it takes its turn like any other: a permission dialog and System Settings both open over
/// it and stay there until the user leaves them. It belongs to the Space it opened in and keeps its
/// place there across a Space switch. The app is activated once, when the window opens, and never again
/// from here.
///
/// **Two things bring it back**, both of them a grant flow ending, and nothing else:
/// `GrantItem.returnsFocus` for a flow that owned a modal dialog, and `GrantItem.mayOpen` for a flow
/// that sent the user to another app, through `FocusReturnWatch`.
///
/// **No prompt is ever shown unless the user clicked for it.** Nothing here, and nothing in the app's
/// start-up path, calls a request API; only a row's button does.
///
/// **Nothing tells an app that a grant was made in System Settings**, so a list page re-reads its grants
/// every `Metrics.pollInterval` while the window is up. A page is built only on a change of step: a
/// grant that moves redraws the one row it belongs to.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    /// The red of the snake's eye in the app icon. One word of a headline and the capsules take it.
    private static let brand = NSColor(srgbRed: 0.890, green: 0.149, blue: 0.165, alpha: 1)

    private let pages: [OnboardingPage]
    /// Called when the last page's button is pressed: onboarding is done.
    private let onFinish: () -> Void
    /// Whether another window of the app still needs it active once the wizard goes away. Injected,
    /// never inferred from `NSApp.windows`: an accessory app with no window left is still the active
    /// application, which would send the user's keystrokes nowhere.
    var othersNeedUsActive: @MainActor () -> Bool = { false }

    private var step = 0
    private var observers: [NSObjectProtocol] = []
    /// The rows of the page on screen, by grant. A grant that moves updates its own row and nothing
    /// else: rebuilding the page to show it blanks the window and draws it again.
    private var rows: [GrantID: GrantRow] = [:]
    /// The page's primary button, whose title follows whether the page's rule is met. Weak: the page
    /// that owns it is thrown away on a change of step.
    private weak var primaryButton: NSButton?
    private var poll: Timer?
    /// Brings the wizard back when the app a grant button sent the user to quits.
    private let focusReturn = FocusReturnWatch()

    /// Whether the window is on screen. `SettingsWindow` and `UpdateController` ask, so that closing
    /// either over a still-open wizard does not deactivate the app out from under it.
    var isUp: Bool { window?.isVisible == true }

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        pages = Self.snappySnapPages()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.windowWidth,
                                             height: Metrics.heroHeight),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("Welcome to SnappySnap")
        w.center()
        w.isReleasedWhenClosed = false
        // Nothing else. No `level` and no `collectionBehavior`: `.floating` puts the window above the
        // System Settings pane its own buttons open, and `.moveToActiveSpace` re-inserts it at the back
        // of the new Space's window list, which leaves it behind whatever the user has there.
        w.contentView = NSView()
        super.init(window: w)
        w.delegate = self
        // Coming back from System Settings: re-read the grants. The poll covers a window that is already
        // key and so never sees this edge.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshGrants() }
            })
        // The app coming forward brings the wizard with it, the way any app's window does.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.comeForward() }
            })
        refreshGrants()
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        poll?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startPolling()
    }

    /// The wizard back in front of the app's own windows, and only while it is the app's one window, so
    /// it never lands on top of Settings or the update window. Ordering front, never
    /// `NSApp.activate(ignoringOtherApps:)`: that is what pulls the wizard over the System Settings
    /// window it has just opened.
    private func comeForward() {
        guard let window, window.isVisible, !othersNeedUsActive() else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        focusReturn.stop()
        if !othersNeedUsActive() { NSApp.deactivate() }
    }

    // MARK: The pages themselves

    private static func snappySnapPages() -> [OnboardingPage] {
        [
            .hero(title: L("Drag a window to the edge. It snaps."),
                  accent: L("snaps"),
                  body: L("Drag any window to an edge, a corner or the top of the screen and it takes half, a quarter or the whole display. A bar at the top offers ready made layouts, and a handle between two windows moves the edge they share."),
                  pills: [Pill(symbol: "rectangle.lefthalf.inset.filled", text: L("Halves and quarters")),
                          Pill(symbol: "rectangle.topthird.inset.filled", text: L("Snap bar")),
                          Pill(symbol: "arrow.left.and.line.vertical.and.arrow.right", text: L("Handles"))],
                  button: L("Continue")),
            .list(header: L("Permissions"),
                  intro: L("SnappySnap asks macOS for two things. The one marked with a warning is required: without it SnappySnap cannot move a single window."),
                  items: GrantCatalog.permissions,
                  height: Metrics.shortListHeight,
                  advanceWhen: everyRequiredGrant),
            .list(header: L("Out of the way"),
                  intro: L("Optional. Turn off the tiling macOS does itself, so it stops grabbing the same drags, and have SnappySnap start with your Mac. Both can be changed later in Settings."),
                  items: GrantCatalog.setUp,
                  height: Metrics.shortListHeight,
                  advanceWhen: anyOneDone),
            .final(title: L("All set"),
                   body: L("Look for the SnappySnap mark in your menu bar, at the top right. Drag any window to an edge, a corner or the top of the screen and it snaps."),
                   button: L("Finish")),
        ]
    }

    // MARK: Building a page

    /// Builds the page for `step`. Called on a change of step and nowhere else: a grant that moves, a
    /// flow that starts or ends, and a poll tick all change one row, never the page.
    private func render() {
        guard let window, let content = window.contentView, pages.indices.contains(step) else {
            Logger.onboarding.error("render declined: step \(self.step, privacy: .public), window \(self.window != nil, privacy: .public)")
            return
        }
        rows.removeAll()
        primaryButton = nil
        content.subviews.forEach { $0.removeFromSuperview() }

        let page = pages[step]
        let view: NSView
        switch page {
        case let .hero(title, accent, body, pills, button):
            view = hero(title: title, accent: accent, body: body, pills: pills, button: button)
        case let .list(header, intro, items, _, advanceWhen):
            view = listPage(header: header, intro: intro, items: items, advanceWhen: advanceWhen)
        case let .final(title, body, button):
            view = hero(title: title, accent: nil, body: body, pills: [], button: button)
        }

        // Grow downward from a fixed title bar.
        var frame = window.frame
        let dy = page.height - content.frame.height
        frame.origin.y -= dy
        frame.size.height += dy
        window.setFrame(frame, display: true, animate: window.isVisible)

        Logger.onboarding.info("page \(self.step, privacy: .public) rendered at \(page.height, privacy: .public) pt, content was \(content.frame.height, privacy: .public) pt")
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        reportButtonGeometry("on render")
    }

    private func hero(title: String, accent: String?, body: String, pills: [Pill], button: String) -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.heightAnchor.constraint(equalToConstant: Metrics.heroIcon).isActive = true

        let headline = NSTextField(wrappingLabelWithString: "")
        // A selectable label enters the field editor on a click and loses its attributes.
        headline.isSelectable = false
        headline.allowsEditingTextAttributes = true
        headline.font = .systemFont(ofSize: Metrics.heroTitle, weight: .bold)
        headline.alignment = .center
        headline.attributedStringValue = Self.accented(title, word: accent)
        headline.preferredMaxLayoutWidth = Metrics.heroTextWidth
        headline.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.heroTextWidth).isActive = true

        let description = NSTextField(wrappingLabelWithString: body)
        description.isSelectable = false
        description.font = .systemFont(ofSize: Metrics.heroBody)
        description.alignment = .center
        description.preferredMaxLayoutWidth = Metrics.heroTextWidth
        description.textColor = .secondaryLabelColor

        var extras: [NSView] = []
        if !pills.isEmpty {
            let row = NSStackView()
            row.spacing = 8
            pills.forEach { row.addArrangedSubview(Self.pill($0)) }
            row.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.pillRowWidth).isActive = true
            extras = [row]
        }

        let next = NSButton(title: button, target: nil, action: nil)
        next.bezelStyle = .rounded
        next.keyEquivalent = "\r"
        next.actionHandler = { [weak self] in self?.advance() }

        let stack = NSStackView(views: [icon, headline, description] + extras + [next])
        stack.orientation = .vertical
        stack.spacing = Metrics.heroSpacing
        stack.setCustomSpacing(Metrics.heroTitleToBody, after: headline)
        stack.edgeInsets = Metrics.heroInsets
        return stack
    }

    private func listPage(header: String, intro: String, items: [GrantItem],
                          advanceWhen: @escaping ([GrantItem]) -> Bool) -> NSView {
        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.font = .systemFont(ofSize: Metrics.listTitle, weight: .bold)
        let introLabel = NSTextField(wrappingLabelWithString: intro)
        introLabel.font = .systemFont(ofSize: Metrics.listIntro)
        introLabel.textColor = .secondaryLabelColor
        introLabel.preferredMaxLayoutWidth = Metrics.listIntroWidth

        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = Metrics.listRowSpacing
        list.alignment = .leading
        for (i, item) in items.enumerated() {
            if i > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                list.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            let row = GrantRow(item: item,
                               window: { [weak self] in self?.window },
                               focusReturn: focusReturn,
                               didFinish: { [weak self] in self?.updatePrimaryButton() })
            rows[item.id] = row
            list.addArrangedSubview(row.view)
        }
        list.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }

        let primary = NSButton(title: "", target: nil, action: nil)
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.actionHandler = { [weak self] in self?.advance() }
        primaryButton = primary

        // The footer is a plain view with the button pinned to its trailing edge and to **both** its
        // top and bottom, which is what fixes the footer's height to the button's.
        //
        // It was an `NSStackView` holding an invisible spacer, and that is a trap: a spacer has no
        // intrinsic height, so nothing decided the footer's own height, and the vertical stack handed
        // it every point of slack the page was not using. The moment a row swapped its 26 pt button
        // for an 18 pt "Granted" label — which is what granting a permission does — the list shrank
        // and the footer grew to absorb it: measured at **186 pt tall instead of 24**, with the button
        // floating in the middle of it. The button then sat wherever the slack put it rather than at
        // the bottom of the page, and a press on it did not land.
        let footer = NSView()
        primary.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(primary)
        NSLayoutConstraint.activate([
            primary.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            primary.topAnchor.constraint(equalTo: footer.topAnchor),
            primary.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])

        // The slack goes here, deliberately, and into nothing else: above the footer, so the stepping
        // button stays at the bottom right of the page however tall the rows happen to be.
        let slack = NSView()
        slack.setContentHuggingPriority(.init(1), for: .vertical)
        slack.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let stack = NSStackView(views: [headerLabel, introLabel, list, slack, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.listSpacing
        stack.setCustomSpacing(Metrics.listIntroToList, after: introLabel)
        stack.setCustomSpacing(Metrics.listToFooter, after: list)
        stack.edgeInsets = Metrics.listInsets
        // Width constraints only once every view shares the stack as an ancestor.
        list.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Metrics.listSideInset).isActive = true
        footer.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        updatePrimaryButton()
        return stack
    }

    /// "Continue" once the page's rule is met, "Skip" until then. Set in place, so the page is never
    /// rebuilt for a word.
    private func updatePrimaryButton() {
        guard let primaryButton, pages.indices.contains(step),
              case let .list(_, _, items, _, advanceWhen) = pages[step] else { return }
        let title = advanceWhen(items) ? L("Continue") : L("Skip")
        guard primaryButton.title != title else { return }
        Logger.onboarding.info("stepping button on page \(self.step, privacy: .public) now reads \(title, privacy: .public)")
        primaryButton.title = title
    }

    // MARK: Following the system

    /// Where the stepping button actually is once the page has settled, and whether every view between
    /// it and the window still contains it. A button drawn in one place and hit-tested in another is
    /// what a ballooning footer looked like from the outside, and this is the line that shows it.
    func reportButtonGeometry(_ when: String) {
        guard let primaryButton, let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var chain = ""
        var v: NSView = primaryButton
        while let parent = v.superview {
            chain += " \(type(of: parent))(\(parent.bounds.height)\(parent.bounds.contains(v.frame) ? "" : " DOES NOT CONTAIN"))"
            v = parent
            if parent == content { break }
        }
        let inWindow = primaryButton.convert(primaryButton.bounds, to: nil)
        Logger.onboarding.debug("\(when, privacy: .public): button \(String(describing: inWindow), privacy: .public) chain:\(chain, privacy: .public)")
    }

    /// Re-reads every grant and lets each row redraw itself if its own state moved. Notification
    /// authorization is read asynchronously, so it goes into its cache first and the rows are refreshed
    /// in that callback. A page with no rows has nothing to do here.
    private func refreshGrants() {
        GrantCatalog.refreshNotifications { [weak self] in
            guard let self else { return }
            for row in self.rows.values { row.refresh() }
            self.updatePrimaryButton()
            self.reportButtonGeometry("after a poll tick")
        }
    }

    /// Idempotent.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: Metrics.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGrants() }
        }
    }

    /// Idempotent.
    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    private func advance() {
        Logger.onboarding.info("stepping button pressed on page \(self.step, privacy: .public) of \(self.pages.count, privacy: .public)")
        if step < pages.count - 1 {
            step += 1
            render()
        } else {
            onFinish()
            close()
        }
    }

    // MARK: Drawing

    /// A rounded capsule with an SF Symbol and a short label, in the brand colour.
    private static func pill(_ pill: Pill) -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: pill.symbol, accessibilityDescription: nil)!)
        image.contentTintColor = brand
        image.symbolConfiguration = .init(pointSize: Metrics.pillSymbol, weight: .semibold)
        let label = NSTextField(labelWithString: pill.text)
        label.font = .systemFont(ofSize: Metrics.pillLabel, weight: .medium)
        label.textColor = brand
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, label])
        row.spacing = Metrics.pillSpacing
        row.edgeInsets = Metrics.pillInsets
        row.wantsLayer = true
        row.layer?.backgroundColor = brand.withAlphaComponent(Metrics.pillTint).cgColor
        row.layer?.cornerRadius = Metrics.pillRadius
        return row
    }

    /// The headline, with `word` in the brand colour where it occurs. `word` is localized separately, so
    /// a translation accents its own word and not a fragment of another.
    private static func accented(_ text: String, word: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: Metrics.heroTitle, weight: .bold),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph])
        if let word, let range = text.range(of: word, options: .caseInsensitive) {
            string.addAttribute(.foregroundColor, value: brand, range: NSRange(range, in: text))
        }
        return string
    }
}
