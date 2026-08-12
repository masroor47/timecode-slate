import SwiftUI

/// The diagonal-striped bar of a clapperboard, drawn rather than shipped.
///
/// Real sticks are painted with stripes slanting one way on the hinged arm and
/// the other way on the fixed bar, so that when they meet the pattern forms
/// chevrons. That is not decoration: the mismatch makes the closed position
/// unmistakable in a single frame, which is exactly what an editor is looking
/// for when scrubbing for the sync point.
struct ClapperBar: View {
    /// Which way the stripes lean. `ClapperSticks` pairs them so the apex
    /// lands on the right.
    var leaning: Leaning = .right
    var stripeWidth: CGFloat = 34

    enum Leaning { case left, right }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(.white))

            // Each stripe is a parallelogram sheared by the bar's height, which
            // gives a 45° lean regardless of how tall the bar ends up.
            let shear = size.height
            var x = -shear
            var dark = true
            while x < size.width + shear {
                if dark {
                    var path = Path()
                    let top = leaning == .right ? x + shear : x
                    let bottom = leaning == .right ? x : x + shear
                    path.move(to: CGPoint(x: top, y: 0))
                    path.addLine(to: CGPoint(x: top + stripeWidth, y: 0))
                    path.addLine(to: CGPoint(x: bottom + stripeWidth, y: size.height))
                    path.addLine(to: CGPoint(x: bottom, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .color(.black))
                }
                x += stripeWidth
                dark.toggle()
            }
        }
    }
}

/// A working clapperboard hinge: a fixed bar with an arm that swings onto it.
///
/// This view carries **no animation of its own**, deliberately. The closing
/// move must be instantaneous: the timecode freezes on the clap, so if the arm
/// took even 100 ms to swing shut, the frozen number would correspond to the
/// start of the swing rather than to the frame where the sticks meet — and the
/// meeting frame is the one an editor syncs to. An animated close would put the
/// number and the visual sync point several frames apart.
///
/// A conditional `.animation(isClosed ? nil : …)` is *not* sufficient here: the
/// modifier resolves against the state of the current render pass, which is the
/// old value, so it animates the very transition it is meant to exempt. The
/// caller drives direction explicitly instead — see `SlateView`.
struct ClapperSticks: View {
    var isClosed: Bool
    var barHeight: CGFloat = 34
    var openAngle: Double = 22

    var body: some View {
        VStack(spacing: 0) {
            // The hinged arm leans left and the fixed bar right, so the stripe
            // is at its *rightmost* where the two meet: the chevrons point
            // right, as they do on a real slate. Swapping these puts the apex
            // on the left, which reads as an arrow aimed the wrong way.
            ClapperBar(leaning: .left)
                .frame(height: barHeight)
                .rotationEffect(.degrees(isClosed ? 0 : -openAngle),
                                anchor: .bottomLeading)

            ClapperBar(leaning: .right)
                .frame(height: barHeight)
        }
    }
}
