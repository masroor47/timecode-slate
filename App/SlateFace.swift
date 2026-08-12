import SwiftUI
import SlateCore

/// Where the production metadata sits relative to the timecode.
///
/// Both put timecode above scene/shot/take — that ordering is settled. What is
/// not settled is whether the production block reads as a header above the
/// timecode or as a footer below the take line, and that is a judgement about
/// what someone glances at first, not something to reason out in the abstract.
enum SlateLayout: String, CaseIterable, Identifiable {
    case metaTop
    case metaBottom

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .metaTop:    return "Production on top"
        case .metaBottom: return "Timecode on top"
        }
    }
}

/// The slate face: white acrylic, ruled fields, red timecode — a real insert
/// slate rather than an app that happens to show timecode.
///
/// **Everything is sized against the height, not the width.** The phone in
/// landscape is roughly 2.17:1, so height is the binding constraint and always
/// runs out first. Sizing type as a fraction of width overflows the bottom long
/// before it overflows the sides, which is exactly how the first draft of this
/// layout went wrong. The `u` unit below is one percent of the available
/// height, and the row budget sums to 100.
///
/// Contains no animation, for the same reason as `ClapperSticks` — see the
/// comment there. The sync frame must be one frame, not a transition.
struct SlateFace: View {
    @ObservedObject var model: SlateViewModel
    var layout: SlateLayout
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
    //
    // Turning the scene/shot/take labels vertical is what paid for the bigger
    // sticks: a horizontal label costs a line of height in every cell, and
    // three cells' worth of that adds up. Stood on end, the label costs a few
    // percent of *width* — which this face has to spare — and hands the whole
    // cell height back to the value.
    private let sticksRow: CGFloat = 20
    private let metaRow:   CGFloat = 12
    private let tcRow:     CGFloat = 28
    private let takeRow:   CGFloat = 27
    private let footRow:   CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let u = geo.size.height / 100
            let rule = max(1, 0.5 * u)

            VStack(spacing: 0) {
                sticks(u: u)

                if layout == .metaTop {
                    meta(u: u).frame(height: metaRow * u)
                    divider(rule)
                }

                timecode(u: u).frame(height: tcRow * u)
                divider(rule)
                take(u: u).frame(height: takeRow * u)
                divider(rule)

                if layout == .metaBottom {
                    meta(u: u).frame(height: metaRow * u)
                    divider(rule)
                }

                foot(u: u).frame(height: footRow * u)
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

    /// Full-bleed, unlike everything else: on a real slate the sticks run the
    /// whole width of the board, and inset chevrons look like a screenshot of a
    /// slate rather than a slate.
    private func sticks(u: CGFloat) -> some View {
        ClapperSticks(isClosed: !model.isClapPending, barHeight: 6.6 * u)
            .frame(height: sticksRow * u)
            .clipped()
            .padding(.horizontal, -60)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapSticks)
            .animation(nil, value: model.isClapPending)
            .accessibilityLabel(model.isHolding ? "Resume" : "Clap")
            .accessibilityAddTraits(.isButton)
    }

    private func timecode(u: CGFloat) -> some View {
        VStack(spacing: 0.4 * u) {
            label(showingUserBits ? "User bits" : "Timecode · \(model.rate.displayName)", u: u)
            Text(showingUserBits ? model.userBitsDisplay : model.displayTimecode)
                .font(.system(size: 23 * u, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .foregroundStyle(timecodeColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 3 * u)
        .padding(.vertical, 1 * u)
    }

    private func take(u: CGFloat) -> some View {
        HStack(spacing: 0) {
            cell("Scene", u: u) {
                slateField(text: $model.info.scene, u: u)
            }
            vRule(u)
            cell("Shot", u: u) {
                slateField(text: $model.info.shot, u: u)
            }
            vRule(u)
            // Take is stepped rather than typed: it advances far more often
            // than it is set, and typing a number on set wastes a hand. The
            // steppers run the full height of the cell for the same reason —
            // they are pressed constantly, often without looking.
            cell("Take", u: u) {
                HStack(spacing: 1.5 * u) {
                    Text("\(model.info.take)")
                        .font(.system(size: 20 * u, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    VStack(spacing: 0.8 * u) {
                        stepper("plus", u: u) { model.info.take += 1 }
                        stepper("minus", u: u) { model.info.take = max(1, model.info.take - 1) }
                    }
                    .padding(.vertical, 1.2 * u)
                }
            }
        }
    }

    /// A ruled cell with its label stood on end down the left edge, so the
    /// value gets the cell's full height rather than sharing it with a caption.
    private func cell<Content: View>(_ title: String, u: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 1.5 * u) {
            verticalLabel(title, u: u)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, 2 * u)
    }

    private func verticalLabel(_ text: String, u: CGFloat) -> some View {
        Text(text.uppercased())
            .font(.system(size: 3 * u, weight: .semibold))
            .tracking(3 * u * 0.18)
            .foregroundStyle(Self.inkFaint)
            // Rotation does not change a view's layout size, so the text is
            // fixed at its natural width first and then given a frame with the
            // rotated dimensions.
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: 5 * u)
            .frame(maxHeight: .infinity)
            .padding(.leading, 1.2 * u)
    }

    private func slateField(text: Binding<String>, u: CGFloat) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 20 * u, weight: .bold))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .focused($editing)
            .submitLabel(.done)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func meta(u: CGFloat) -> some View {
        HStack(spacing: 0) {
            readout("Production", model.info.production, u: u)
            vRule(u)
            readout("Director", model.info.director, u: u)
            vRule(u)
            readout("Camera", model.info.cinematographer, u: u)
        }
    }

    private func foot(u: CGFloat) -> some View {
        HStack(spacing: 3 * u) {
            VStack(alignment: .leading, spacing: 0.5 * u) {
                label("Roll", u: u)
                Text(display(model.info.roll))
                    .font(.system(size: 5 * u, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0.5 * u) {
                label("Sound", u: u)
                Text(display(model.info.soundRoll))
                    .font(.system(size: 5 * u, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ticks(u: u)

            Spacer(minLength: 0)

            // Status is an indicator, not a sentence — it truncated as prose,
            // and the detail belongs on the diagnostics sheet behind it anyway.
            Button(action: onDiagnostics) {
                HStack(spacing: 0.9 * u) {
                    Circle().fill(model.status.color).frame(width: 2.4 * u, height: 2.4 * u)
                    Text(model.inputName)
                        .font(.system(size: 3 * u, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(Self.inkSoft)
            }

            Button(action: onJam) {
                Text(model.isArmedForJam ? "CANCEL" : "JAM")
                    .font(.system(size: 3.4 * u, weight: .bold))
                    .tracking(1.2)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2.6 * u)
                    .padding(.vertical, 1.5 * u)
                    .background(RoundedRectangle(cornerRadius: 1.2 * u)
                        .fill(model.isArmedForJam ? Self.amber : Self.blue))
            }

            Button(action: onNextShot) {
                Text("NEXT")
                    .font(.system(size: 3.4 * u, weight: .bold))
                    .tracking(1.2)
                    .fixedSize()
                    .foregroundStyle(Self.ink)
                    .padding(.horizontal, 2.6 * u)
                    .padding(.vertical, 1.5 * u)
                    .background(RoundedRectangle(cornerRadius: 1.2 * u)
                        .stroke(Self.ink, lineWidth: max(1, 0.35 * u)))
            }

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 6 * u))
                    .foregroundStyle(Self.inkSoft)
                    .frame(width: 10 * u, height: 10 * u)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 3 * u)
    }

    // MARK: - Pieces

    private func display(_ s: String) -> String { s.isEmpty ? "—" : s }

    private func label(_ text: String, u: CGFloat) -> some View {
        Text(text.uppercased())
            .font(.system(size: 2.8 * u, weight: .semibold))
            .tracking(2.8 * u * 0.16)
            .foregroundStyle(Self.inkFaint)
            .lineLimit(1)
            .fixedSize()
    }

    private func readout(_ title: String, _ value: String, u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0.5 * u) {
            label(title, u: u)
            Text(display(value))
                .font(.system(size: 5.4 * u, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 3 * u)
    }

    private func stepper(_ symbol: String, u: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 4.2 * u, weight: .bold))
                .foregroundStyle(Self.ink)
                .frame(width: 12 * u)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 1 * u)
                    .stroke(Self.ink, lineWidth: max(1, 0.3 * u)))
        }
    }

    private func ticks(u: CGFloat) -> some View {
        HStack(spacing: 1.8 * u) {
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
