import SwiftUI
import SnapCore

/// The notch shape: a body with **continuous** bottom corners, and two **concave** quarter circles
/// that flare outside it at the top so it flows out of the screen's edge instead of meeting it square.
///
/// Drawn in panel coordinates, top-left origin, as **one contour**: the union of the body and the two
/// flares. It has to be one, because the same path is filled, clipped to *and stroked* — a stroke
/// traces every edge a path has, and a shape assembled from touching pieces has edges inside it: the
/// contrast outline would run down each flare where it meets the body, and along the screen's edge.
/// Two things keep the union clean. The pieces **overlap** by `overlap` rather than meet on a
/// shared edge, which a boolean operation can leave a sliver along. And every piece starts `lift`
/// above the panel's top edge — which is the screen's — so the contour's whole top side is off screen
/// and the outline runs only where the shape has an edge to show. Lifting the body is also how it
/// comes by continuous corners at the bottom alone. All four numbers animate together.
struct NotchShape: Shape {
    /// The shape's horizontal centre. Constant: the shape grows about the housing.
    var midX: CGFloat
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    /// How far a flare reaches into the body.
    private static let overlap: CGFloat = 2

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(topRadius, bottomRadius)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let left = midX - width / 2, right = midX + width / 2
        // A continuous corner of radius r begins about 1.53 r before the corner; 2 r clears it, and
        // the stroke's own width besides.
        let lift = bottomRadius * 2 + 4
        let body = Path(roundedRect: CGRect(x: left, y: -lift, width: width, height: height + lift),
                        cornerSize: CGSize(width: bottomRadius, height: bottomRadius), style: .continuous)
        return body.union(flare(bodyEdge: left, outward: -1, lift: lift))
                   .union(flare(bodyEdge: right, outward: 1, lift: lift))
    }

    /// One flare: the region between the body's edge, the screen's edge and a quarter circle centred
    /// outside the shape — widest on the screen's edge, gone one radius down. `outward` is -1 for the
    /// left flare and 1 for the right.
    private func flare(bodyEdge: CGFloat, outward: CGFloat, lift: CGFloat) -> Path {
        let tip = bodyEdge + outward * topRadius
        var path = Path()
        path.move(to: CGPoint(x: tip, y: -lift))
        path.addLine(to: CGPoint(x: tip, y: 0))
        path.addArc(center: CGPoint(x: tip, y: topRadius), radius: topRadius,
                    startAngle: .degrees(-90), endAngle: .degrees(outward < 0 ? 0 : 180),
                    clockwise: outward > 0)
        path.addLine(to: CGPoint(x: bodyEdge - outward * Self.overlap, y: topRadius))
        path.addLine(to: CGPoint(x: bodyEdge - outward * Self.overlap, y: -lift))
        path.closeSubpath()
        return path
    }
}

/// The snap bar inside the notch shape: the black shape and its shadow, the cells clipped to it, and
/// the contrast outline. Panel-sized and fixed; only the shape inside it moves.
///
/// `model.expanded` is the one input that animates, and the controller sets it inside
/// `withAnimation` — a spring that overshoots on the way out, an overdamped one on the way in. The
/// cells keep their own short fades on top of that, so they arrive after the shape has room for them
/// and are gone before it has taken it back. The backdrop blur is not here: it is a Core Animation
/// layer under this view (`NotchBackdropView`), because SwiftUI has no unblurred backdrop to give.
struct NotchBarView: View {
    @ObservedObject var model: SnapBarModel

    var body: some View {
        let g = model.geometry
        if let notch = g.notch {
            let open = model.expanded
            let rect = (open ? notch.expanded : notch.collapsed)
                .offsetBy(dx: -g.panelFrame.minX, dy: -g.panelFrame.minY)
            let shape = NotchShape(
                midX: rect.midX, width: rect.width, height: rect.height,
                topRadius: open ? NotchGeometry.expandedTopRadius : NotchGeometry.collapsedTopRadius,
                bottomRadius: open ? NotchGeometry.expandedBottomRadius : NotchGeometry.collapsedBottomRadius)
            ZStack(alignment: .topLeading) {
                shape
                    .fill(.black)
                    .shadow(color: .black.opacity(open ? NotchGeometry.shadowOpacity : 0),
                            radius: NotchGeometry.shadowRadius, x: 0, y: NotchGeometry.shadowOffsetY)
                SnapBarCells(model: model, palette: .notch)
                    .opacity(open ? 1 : 0)
                    .animation(open
                               ? .easeOut(duration: NotchGeometry.cellsFadeIn).delay(NotchGeometry.cellsFadeInDelay)
                               : .easeOut(duration: NotchGeometry.cellsFadeOut), value: open)
                    .clipShape(shape)
                // A 2 pt stroke clipped to the shape is 1 pt inside its edge and nothing outside it.
                shape
                    .stroke(.white.opacity(model.outlineOpacity), lineWidth: 2)
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
