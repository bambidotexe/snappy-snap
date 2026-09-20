import SwiftUI
import SnapCore

/// The island's shape: a rectangle with **continuous** corners — a capsule while its radius is half
/// its height — scaled about a point on its vertical axis.
///
/// Drawn in panel coordinates, top-left origin. The scale is part of the path rather than a
/// `scaleEffect`, for two reasons: the same path is filled, clipped to and stroked, and all three must
/// shrink together; and the departure's spring crosses zero, where the path simply ends — a negative
/// `scaleEffect` would draw the shape again, mirrored. Width, height, radius and scale animate
/// together; the anchor does not animate.
struct IslandShape: Shape {
    /// The shape's horizontal centre. Constant: the island grows about the display's centre line.
    var midX: CGFloat
    /// The shape's top edge at full scale. Constant: every state hangs from the same line.
    var top: CGFloat
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var scale: CGFloat
    /// The y, in panel coordinates, of the point the scale is taken about. A constant.
    var anchorY: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(radius, scale)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            radius = newValue.second.first
            scale = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, scale)
        guard s > 0.001 else { return Path() }
        let w = width * s, h = height * s
        let y = anchorY + (top - anchorY) * s
        // Never more than half the smaller side, so a capsule stays one while it narrows to a circle.
        let r = min(radius * s, w / 2, h / 2)
        return Path(roundedRect: CGRect(x: midX - w / 2, y: y, width: w, height: h),
                    cornerSize: CGSize(width: r, height: r), style: .continuous)
    }
}

/// The snap bar inside the island: the black shape, its shadow once grown, the cells clipped to it,
/// and the contrast outline. Panel-sized and fixed; only the shape inside it moves.
///
/// `model.island` is the one input that animates, and the panel sets it inside `withAnimation`, one
/// spring per step of `IslandPresence`. The collapsed island carries no shadow and no outline — the
/// island it sits above has none at rest — and the backdrop blur is not here: it is a Core Animation
/// layer under this view (`NotchBackdropView`).
struct IslandBarView: View {
    @ObservedObject var model: SnapBarModel

    var body: some View {
        let g = model.geometry
        if let island = g.island {
            let state = model.island
            let open = state == .expanded
            let rect = island.rect(for: state).offsetBy(dx: -g.panelFrame.minX, dy: -g.panelFrame.minY)
            // The panel starts at the screen's top edge, so a distance under that edge is a panel y.
            let shape = IslandShape(
                midX: rect.midX, top: rect.minY, width: rect.width, height: rect.height,
                radius: open ? IslandGeometry.expandedRadius : IslandGeometry.collapsedRadius,
                scale: state == .hidden ? 0 : 1,
                anchorY: IslandPresence.scaleAnchorY)
            ZStack(alignment: .topLeading) {
                shape
                    .fill(.black)
                    .shadow(color: .black.opacity(open ? IslandGeometry.shadowOpacity : 0),
                            radius: IslandGeometry.shadowRadius, x: 0, y: IslandGeometry.shadowOffsetY)
                SnapBarCells(model: model, palette: .notch)
                    .opacity(open ? 1 : 0)
                    .animation(open
                               ? .easeOut(duration: IslandPresence.cellsFadeIn).delay(IslandPresence.cellsFadeInDelay)
                               : .easeOut(duration: model.cellsFadeOut), value: open)
                    .clipShape(shape)
                // A 2 pt stroke clipped to the shape is 1 pt inside its edge and nothing outside it.
                // All the way round: no side of the island is the screen's edge.
                shape
                    .stroke(.white.opacity(open ? model.outlineOpacity : 0), lineWidth: 2)
                    .clipShape(shape)
                    .animation(.easeOut(duration: 0.2), value: model.outlineOpacity)
            }
            .frame(width: g.panelFrame.width, height: g.panelFrame.height, alignment: .topLeading)
            // The cells are drawn in `Color.primary`, which has to be white on this shape whatever
            // the system appearance is.
            .environment(\.colorScheme, .dark)
        }
    }
}
