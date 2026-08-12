import SwiftUI
import SlateCore

/// The slate face: white acrylic, ruled fields, red timecode — a real insert
/// slate rather than an app that happens to show timecode.
///
/// **Everything is sized against the height, not the width.** The phone in
/// landscape is roughly 2.17:1, so height is the binding constraint and always
/// runs out first. Sizing type as a fraction of width overflows the bottom
/// long before it overflows the sides, which is exactly how the first draft of
/// this layout went wrong. The `u` unit below is one percent of the available
/// height, and every row is budgeted so the rows sum to 100.
///
/// Contains no animation, for the same reason as `ClapperSticks` — see the
/// comment there. The sync frame must be one frame, not a transition.
struct SlateFace: View {
    @ObservedObject var model: SlateViewModel
    var onTapSticks: () -> Void
    var onJam: () -> Void
    var onNextShot: () -> Void
    var onSettings: () -> Void
    var onDiagnostics: () -> Void

    /// Drives the keyboard's Done button. Without it the return key is the only
    /// way out of a field, which is a poor thing to hunt for with a camera
    /// waiting on you.
    @FocusState private var editing: Bool

    // Row budget, in percent of height. Must sum to 100.
    private let sticksRow: CGFloat = 17
    private let tcRow: CGFloat = 41
    private let takeRow: CGFloat = 25
    private let footRow: CGFloat = 17

    var body: some View {
        GeometryReader { geo in
            let u = geo.size.height / 100      // one percent of height
            let rule = max(1, 0.5 * u)

            VStack(spacing: 0) {
                ClapperSticks(isClosed: !model.isClapPending, barHeight: 7.5 * u)
                    .frame(height: sticksRow * u)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTapSticks)
                    .animation(nil, value: model.isClapPending)
                    .accessibilityLabel(model.isHolding ? "Resume" : "Clap")
                    .accessibilityAddTraits(.isButton)

                timecodeRow(u: u).frame(height: tcRow * u)
                divider(rule)
                takeRow(u: u).frame(height: takeRow * u)
                divider(rule)
                footRow(u: u).frame(height: footRow * u)
            }
            .background(faceColor)
            .foregroundStyle(Self.ink)
        }
        // The white runs edge to edge, but the *content* stays inside the safe
        // area. In landscape the Dynamic Island sits over the leading edge, and
        // ignoring the safe area outright put it straight through the first
        // digit of the timecode and the SCENE label.
        .background(faceColor.ignoresSafeArea())
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }
            }
        }
    }

    // MARK: - Rows

    private func timecodeRow(u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0.8 * u) {
            label(showingUserBits ? "User bits" : "Timecode · \(model.rate.displayName)", u: u)
            Text(showingUserBits ? model.userBitsDisplay : model.displayTimecode)
                .font(.system(size: 25 * u, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(timecodeColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 3 * u)
        .padding(.vertical, 1.5 * u)
    }

    private func takeRow(u: CGFloat) -> some View {
        HStack(spacing: 0) {
            editable("Scene", text: $model.info.scene, u: u)
            vRule(u)
            editable("Shot", text: $model.info.shot, u: u)
            vRule(u)
            // Take is stepped rather than typed: it advances far more often
            // than it is set, and typing a number on set is a waste of a hand.
            VStack(alignment: .leading, spacing: 0.8 * u) {
                label("Take", u: u)
                HStack(spacing: 1.5 * u) {
                    Text("\(model.info.take)")
                        .font(.system(size: 14 * u, weight: .bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    stepper("minus", u: u) { model.info.take = max(1, model.info.take - 1) }
                    stepper("plus", u: u) { model.info.take += 1 }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 3 * u)
        }
    }

    private func footRow(u: CGFloat) -> some View {
        HStack(spacing: 3 * u) {
            VStack(alignment: .leading, spacing: 0.6 * u) {
                label("Production", u: u)
                Text(model.info.production.isEmpty ? "—" : model.info.production)
                    .font(.system(size: 5.5 * u, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0.6 * u) {
                label("Roll", u: u)
                Text(model.info.roll.isEmpty ? "—" : model.info.roll)
                    .font(.system(size: 5.5 * u, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ticks(u: u)

            Spacer(minLength: 0)

            Button(action: onDiagnostics) {
                HStack(spacing: 0.8 * u) {
                    Circle().fill(model.status.color).frame(width: 2.4 * u, height: 2.4 * u)
                    Text(model.status.label)
                        .font(.system(size: 3.2 * u, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(Self.inkSoft)
            }

            Button(action: onJam) {
                Text(model.isArmedForJam ? "CANCEL" : "JAM")
                    .font(.system(size: 3.4 * u, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3 * u)
                    .padding(.vertical, 1.6 * u)
                    .background(RoundedRectangle(cornerRadius: 1.2 * u)
                        .fill(model.isArmedForJam ? Self.amber : Self.blue))
            }

            Button(action: onNextShot) {
                Text("NEXT")
                    .font(.system(size: 3.4 * u, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Self.ink)
                    .padding(.horizontal, 3 * u)
                    .padding(.vertical, 1.6 * u)
                    .background(RoundedRectangle(cornerRadius: 1.2 * u)
                        .stroke(Self.ink, lineWidth: max(1, 0.35 * u)))
            }

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 4 * u))
                    .foregroundStyle(Self.inkSoft)
            }
        }
        .padding(.horizontal, 3 * u)
    }

    // MARK: - Pieces

    private func label(_ text: String, u: CGFloat) -> some View {
        Text(text.uppercased())
            .font(.system(size: 2.9 * u, weight: .semibold))
            .tracking(2.9 * u * 0.16)
            .foregroundStyle(Self.inkFaint)
            .lineLimit(1)
    }

    private func editable(_ title: String, text: Binding<String>, u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0.8 * u) {
            label(title, u: u)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14 * u, weight: .bold))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .lineLimit(1)
                .focused($editing)
                .submitLabel(.done)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 3 * u)
    }

    private func stepper(_ symbol: String, u: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 3.4 * u, weight: .bold))
                .foregroundStyle(Self.ink)
                .frame(width: 8 * u, height: 6 * u)
                .background(RoundedRectangle(cornerRadius: 1 * u)
                    .stroke(Self.ink, lineWidth: max(1, 0.3 * u)))
        }
    }

    private func ticks(u: CGFloat) -> some View {
        HStack(spacing: 2 * u) {
            tick("INT", on: model.info.isInterior, u: u)
            tick("EXT", on: !model.info.isInterior, u: u)
            tick("DAY", on: model.info.isDay, u: u)
            tick("NGT", on: !model.info.isDay, u: u)
            tick("MOS", on: model.info.isMOS, u: u)
        }
    }

    private func tick(_ text: String, on: Bool, u: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 3.2 * u, weight: .semibold))
            // Without this the three-letter ticks break mid-word under
            // pressure — "EXT" became "EX / T".
            .fixedSize()
            .foregroundStyle(on ? Self.ink : Self.inkFaint)
            .overlay(alignment: .bottom) {
                if on {
                    Rectangle().fill(Self.red).frame(height: 0.7 * u).offset(y: 1.2 * u)
                }
            }
    }

    private func divider(_ height: CGFloat) -> some View {
        Rectangle().fill(Self.ink).frame(height: height)
    }

    private func vRule(_ u: CGFloat) -> some View {
        Rectangle().fill(Self.ink).frame(width: max(1, 0.5 * u))
    }

    // MARK: - Colour

    private var showingUserBits: Bool { model.isHolding && model.holdPhase == .userBits }

    /// The sync mark: the whole face goes amber on the collision frame and
    /// stays there for the timecode hold, then shifts again for user bits. A
    /// full-face change is unmissable in a still, which is the entire job.
    private var faceColor: Color {
        if showingUserBits { return Self.cyanWash }
        if model.isHolding { return Self.amberWash }
        return Self.acrylic
    }

    private var timecodeColor: Color { model.isHolding ? Self.ink : Self.red }

    static let acrylic   = Color(red: 0.965, green: 0.969, blue: 0.969)
    static let amberWash = Color(red: 0.949, green: 0.757, blue: 0.306)
    static let cyanWash  = Color(red: 0.612, green: 0.855, blue: 0.882)
    static let ink       = Color(red: 0.082, green: 0.094, blue: 0.110)
    static let inkSoft   = Color(red: 0.294, green: 0.337, blue: 0.361)
    static let inkFaint  = Color(red: 0.416, green: 0.459, blue: 0.482)
    static let red       = Color(red: 0.784, green: 0.063, blue: 0.180)
    static let blue      = Color(red: 0.173, green: 0.431, blue: 0.561)
    static let amber     = Color(red: 0.878, green: 0.639, blue: 0.235)
}
