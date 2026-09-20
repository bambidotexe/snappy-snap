import AppKit
import SnapCore
import SwiftUI

/// One Snap Assist area's live contents. A phase gives each area a model and then only ever assigns
/// to `candidates`; the panel keeps its hosting view, so SwiftUI sees a list that shrank rather than a
/// view that was rebuilt — which is the whole of the card removal animation.
@MainActor
final class SnapAssistAreaModel: ObservableObject, Identifiable {
    /// Stable for the life of the area, which is what `SnapAssistSurfacesView`'s `ForEach` needs: an
    /// area that leaves the list must take its own subtree with it and no other.
    let id = UUID()
    /// The cell this area covers. The card arrangement is measured against it every time the list
    /// changes, which is what makes the cards grow as the list shrinks — and every time the cell does:
    /// a window placed elsewhere in the arrangement that needs more than its own cell moves the
    /// dividers, and the areas still open follow them.
    @Published var cellSize: CGSize
    /// The area's cell in CG space, which is also what the controller hit-tests against. Always
    /// assigned together with `cellSize`, by `SnapAssistController` alone.
    @Published var zoneFrame: CGRect
    @Published var candidates: [SnapAssistController.Candidate]
    @Published var hovered: CGWindowID?
    /// Whether this area is on screen. Drives its own fade and scale; the panel no longer has one
    /// per area because there is no longer a panel per area.
    @Published var visible = false

    /// What an **Accessibility** press on one of this area's cards does. Deliberately not a mouse
    /// path: `AXPress` arrives through the Accessibility API and never through the event
    /// tap, so this is a second input *channel* for assistive technology, not a second opinion about
    /// what a click means. `SnapAssistController.handleGlobalMouseDown` is still the only thing that
    /// reads a click, and this lands in the same `pick` behind the same guards.
    var onAccessibilityPress: ((CGWindowID) -> Void)?

    init(cellSize: CGSize, zoneFrame: CGRect, candidates: [SnapAssistController.Candidate]) {
        self.cellSize = cellSize
        self.zoneFrame = zoneFrame
        self.candidates = candidates
    }

    var layout: SnapAssistCardLayout { SnapAssistCardLayout(count: candidates.count, cell: cellSize) }
}

/// Every area of one display's phase, in the one panel that draws them all.
///
/// One panel, because macOS renders true Liquid Glass only in the **key** window: with a panel per
/// area exactly one area — whichever was presented last — got real refractive glass and the rest got
/// a flat fallback of the same material. Measured twice, from screenshots, on two arrangements. One
/// window means one key window and real glass on every card.
@MainActor
final class SnapAssistSurfacesModel: ObservableObject {
    /// What the panel covers, in CG space: the display's visible frame. Each area is placed inside it
    /// by `SnapAssist.areaFrame`, which needs no coordinate conversion — SwiftUI's y increases
    /// downward exactly as CG's does.
    @Published var panelFrame: CGRect = .zero
    @Published var areas: [SnapAssistAreaModel] = []
}

struct SnapAssistSurfacesView: View {
    @ObservedObject var model: SnapAssistSurfacesModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.areas, id: \.id) { area in
                SnapAssistAreaHost(model: area, panelFrame: model.panelFrame)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One area at its place inside the display-wide panel, with the fade and scale the panel used to do
/// for itself. The scale is about the area's centre, which is `scaleEffect`'s default and what the
/// old panel's `insetBy` did — so the cards stay concentric with the zone the controller hit-tests
/// against, in flight as well as at rest.
private struct SnapAssistAreaHost: View {
    @ObservedObject var model: SnapAssistAreaModel
    let panelFrame: CGRect

    var body: some View {
        let frame = SnapAssist.areaFrame(of: model.zoneFrame, inPanelCovering: panelFrame)
        SnapAssistView(model: model)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(model.visible ? 1 : 1 - SnapAssistPanel.scaleInset * 2)
            .opacity(model.visible ? 1 : 0)
            .offset(x: frame.minX, y: frame.minY)
            .animation(.easeOut(duration: model.visible ? SnapAssistPanel.presentDuration
                                                        : SnapAssistPanel.dismissDuration),
                       value: model.visible)
            // An area that moves travels on the cards' own curve, for the cards' own reason: the
            // controller evaluates that curve to know where a card is drawn while it is moving, and an
            // area moving on another one would carry its cards off the frames the controller computes.
            .animation(SnapAssistView.cardAnimation, value: model.zoneFrame)
    }
}

/// The choosing surface *is* the zone preview, with the offered windows as cards centred inside it, so
/// choosing reads as a continuation of the snap rather than as new UI. The card arrangement —
/// orientation, size, wrap — is decided in `SnapCore` and only drawn here.
///
/// **It has no gestures at all.** What a click on a surface means is decided in one place,
/// `SnapAssistController.handleGlobalMouseDown`, from the event tap: a card picks, anything else
/// cancels. This view draws, and nothing else — with one exception that is not a click at all, the
/// cards' Accessibility press (see `SnapAssistCard`), which reaches the same `pick` from the other
/// end of the app.
///
/// That is not a matter of taste. SwiftUI gestures in these panels never see the click: the app is an
/// accessory that never activates, and in a non-activating panel of an inactive app AppKit hands the
/// first click only to views that take first mouse — controls do, `onTapGesture` does not. Measured:
/// with a tap gesture *every* non-card point did nothing at all, and a `Color.clear` tap layer laid
/// over the whole panel did nothing either, while the cards' buttons kept working. The event tap has
/// no such rule, and it is already watching every click.
///
/// No thumbnail: a live window image would need Screen Recording, which the app never asks for.
struct SnapAssistView: View {
    /// The card picked elsewhere fades and scales away while the rest move up into the places it left.
    ///
    /// Built from `SnapAssistCardReflow`'s own control points rather than written as `.easeOut`, and
    /// that is the whole point of it: `SnapAssistController` evaluates that curve to work out where a
    /// card is drawn when a click arrives mid-reflow. `.easeOut` cannot be evaluated, so naming it
    /// here would leave the controller matching it by eye — one curve, played here and read there.
    static let cardAnimation: Animation = .timingCurve(SnapAssistCardReflow.curve.x1,
                                                       SnapAssistCardReflow.curve.y1,
                                                       SnapAssistCardReflow.curve.x2,
                                                       SnapAssistCardReflow.curve.y2,
                                                       duration: SnapAssistCardReflow.duration)

    @ObservedObject var model: SnapAssistAreaModel

    var body: some View {
        let layout = model.layout
        ZStack {
            ZonePreviewView(padding: 0)
            // `SnapAssistCardGrid` fills the cell and places each card at `cardFrame`, the same
            // function the controller hit-tests a click with — centring the block both horizontally
            // and vertically is `blockOrigin`'s job, on both sides, and not the `ZStack`'s.
            GlassEffectContainer(spacing: 0) {
                SnapAssistCardGrid(layout: layout) {
                    // Identified by window id, and *also* carrying its place in the list as a layout
                    // value — see `CardSlot` for why counting positions in `LayoutSubviews` will not do.
                    ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, candidate in
                        SnapAssistCard(candidate: candidate, side: CGFloat(layout.side),
                                       press: { [model] in model.onAccessibilityPress?(candidate.id) },
                                       isHovered: model.hovered == candidate.id)
                            .layoutValue(key: CardSlot.self, value: index)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                }
                // Keyed on the ids, not on the array: a card is gone when its id is, and that is exactly
                // the change the removal has to animate.
                .animation(Self.cardAnimation, value: model.candidates.map(\.id))
                .animation(Self.cardAnimation, value: model.cellSize)
            }
        }
    }
}

/// A card's place in the list it belongs to, attached to the card so it travels with it.
///
/// The grid cannot simply count positions in `LayoutSubviews`, because a card leaving through its
/// removal transition **stays** in the hierarchy — and in `LayoutSubviews` — for the whole 0.22 s of
/// that transition. Counting positions would place every card after the departing one a slot late for
/// the length of the animation, and they would then jump when the transition ended. Reading each
/// card's own index instead sends the survivors straight to where they are going the moment the pick
/// lands, which is what SwiftUI animates.
///
/// It is also the answer that holds either way: if a build of SwiftUI drops the departing subview
/// from the layout immediately, the indices are the positions and nothing changes.
private struct CardSlot: LayoutValueKey {
    static let defaultValue = 0
}

/// Places the cards on the grid `SnapCore` measured, from one flat list. Flat is the point: rows of
/// stacks would give a card a new identity the moment a removal moved it into another row, and
/// SwiftUI would cross-fade the rows instead of sliding the cards to their new places.
/// Qualified `SwiftUI.Layout`: `SnapCore.Layout` is a cell arrangement, and both are in scope here.
struct SnapAssistCardGrid: SwiftUI.Layout {
    let layout: SnapAssistCardLayout

    /// **Fills**, so that `bounds` is the cell and `cardFrame` can be called with it.
    ///
    /// Returning `contentSize` instead would make SwiftUI centre the block by centring *this view* in
    /// the `ZStack`, and that centring is a second calculation of the number `blockOrigin` already
    /// produces for the hit test. The two would agree only by accident of three unasserted facts (no
    /// padding, no shadow inset, and a scale-in that happens to preserve the centre), and the day one
    /// of them changed, every card's clickable region would move with nothing to notice it. Filling
    /// removes the second calculation: the block is centred by `blockOrigin` here exactly as it is
    /// there.
    ///
    /// Filling also makes the `ZStack`'s alignment irrelevant to the cards, since a child that takes
    /// the whole proposal has nowhere to be aligned to.
    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard layout.perLine > 0 else {
            // The list emptied, so there is no grid left to place anything on — but cards on their
            // way out are still subviews, and a subview a layout never places is drawn at the origin.
            // An empty block is a zero-sized rect at the cell's centre, which is where the last block
            // was centred, so they fade from there rather than from the area's top-left corner.
            for subview in subviews {
                subview.place(at: layout.blockOrigin(in: bounds), anchor: .center, proposal: proposal)
            }
            return
        }
        let side = CGFloat(layout.side)
        // A departing card keeps the index it had, which can be one past the end of the shrunken
        // grid. Clamping puts it in the block's free tail slot instead of on a line `contentSize`
        // does not contain — it is fading and shrinking by then, but it must not be drawn outside
        // the area, because nothing here clips.
        let lastSlot = max(0, layout.perLine * layout.lines - 1)
        for subview in subviews {
            let index = min(max(0, subview[CardSlot.self]), lastSlot)
            // The one arithmetic. The controller hit-tests a click against `cardFrame(index, zone)`;
            // this draws the card at `cardFrame(index, bounds)`. They are the same rectangle because
            // `cardFrame` reads nothing from the rect it is given but its centre, and the panel is
            // concentric with the zone — including while it scales in, since `insetBy` keeps the
            // centre. Both properties are unit-tested in `SnapAssistCardLayoutTests`.
            let frame = layout.cardFrame(index, in: bounds)
            subview.place(at: frame.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: side, height: side))
        }
    }
}

/// One window: its app icon over its title, on Liquid Glass, over a gradient that keeps the text
/// legible against whatever wallpaper the clear material lets through.
///
/// Not a `Button`, and it reads no pointer of its own: both the click that picks this window and the
/// hover that lights it are recognised by `SnapAssistController` from the event tap, against the same
/// frame `SnapAssistCardLayout` places the card at. A button here would be a second thing deciding
/// what a *click* means, and `.onHover` a second thing deciding where the pointer is.
///
/// The material's own `interactive()` response is not used, and cannot be: it answers a pointer this
/// app never receives, because an accessory that never activates has no window the system treats as
/// frontmost. `isHovered` arrives from the controller instead and tints the glass.
///
/// It is still **operable**, though, and that is not optional in an app whose one permission is
/// Accessibility: the card carries the button role, the label, and a default action that performs
/// the pick, so VoiceOver and Switch Control can both read what is on offer and take it. That costs
/// nothing here, because `AXPress` is delivered through the Accessibility API — it is not a mouse
/// event, it never reaches the event tap, and it cannot be produced by a click. `press` is therefore a
/// second input *channel* into the one `pick`, not a second reader of the one click.
private struct SnapAssistCard: View {
    /// The card's corner, as a fraction of its side. The same number rounds the glass and clips the
    /// gradient, so the two describe one shape.
    static let cornerFraction: CGFloat = 0.14
    /// What a hovered card adds to the glass. White, because the material carries the light: a tint
    /// is the whole of the hover and there is no border or fill under it.
    static let hoverTint: Double = 0.12
    /// How long the hover tint takes to arrive and to leave.
    static let hoverDuration: TimeInterval = 0.12
    /// The readability gradient under the labels: this much black at the card's bottom edge, nothing
    /// at its top. The icon sits in the clear half and the titles in the dark one.
    static let textBackdrop: Double = 0.55

    let candidate: SnapAssistController.Candidate
    let side: CGFloat
    let press: () -> Void
    let isHovered: Bool

    var body: some View {
        VStack(spacing: side * 0.06) {
            Image(nsImage: candidate.icon ?? NSImage(size: NSSize(width: side, height: side)))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: side * 0.44, height: side * 0.44)
            Text(candidate.title)
                .font(.system(size: max(10, min(14, side * 0.085)), weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white)
            // An untitled window falls back to its app's name; showing both would print it twice.
            if candidate.title != candidate.appName {
                Text(candidate.appName)
                    .font(.system(size: max(9, min(12, side * 0.07))))
                    .lineLimit(1)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .padding(side * 0.08)
        .frame(width: side, height: side)
        // Behind the icon and the labels, in front of the glass: the titles have to be readable over
        // whatever wallpaper the clear material lets through, and they sit at the bottom of the card.
        .background(
            LinearGradient(colors: [Color.black.opacity(Self.textBackdrop), Color.black.opacity(0)],
                           startPoint: .bottom, endPoint: .top)
                .clipShape(Self.shape(side))
        )
        // `.clear` and not `.regular`: the regular material draws a defined edge that reads as a
        // border on a card this small, and carries too little of the desktop through.
        .glassEffect(isHovered ? .clear.tint(Color.white.opacity(Self.hoverTint)) : .clear,
                     in: Self.shape(side))
        .animation(.easeOut(duration: Self.hoverDuration), value: isHovered)
        // One element per card rather than a pile of images and labels, carrying the button role and
        // a default action (`AXPress`) so a card is operable and not merely readable: SwiftUI decides
        // nothing about a mouse click here, and that must not take the window away from anyone driving
        // this with assistive technology.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(candidate.title == candidate.appName
                            ? candidate.title : "\(candidate.title), \(candidate.appName)")
        .accessibilityHint(L("Places this window in this area"))
        .accessibilityAction(.default, press)
    }

    /// The card's outline, which the glass is drawn in and the gradient is clipped to. One function,
    /// so the material and the backdrop can never round differently.
    private static func shape(_ side: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: side * cornerFraction, style: .continuous)
    }
}
