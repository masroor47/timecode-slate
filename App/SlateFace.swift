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

/// The two grounds a slate has to work on.
///
/// Night is not an inversion of day. A white slate at 3am is a lamp pointed at
/// everyone's eyes, but simply flipping the colours gives thin white type
/// glowing on black, which blooms on camera and reads worse. Night therefore
/// uses a softer ink and a lighter red than a naive invert would.
struct SlatePalette {
    let face: Color
    let ink: Color
    let inkSoft: Color
    let inkFaint: Color
    let red: Color
    let blue: Color
    let amber: Color
    /// Held after the flash, for the rest of the timecode window.
    let hold: Color
    /// The user-bits half of the hold.
    let userBits: Color
    /// The sync frame itself.
    let flash: Color
    let flashInk: Color

    static let day = SlatePalette(
        face:     Color(red: 0.965, green: 0.969, blue: 0.969),
        ink:      Color(red: 0.082, green: 0.094, blue: 0.110),
        inkSoft:  Color(red: 0.294, green: 0.337, blue: 0.361),
        inkFaint: Color(red: 0.416, green: 0.459, blue: 0.482),
        red:      Color(red: 0.784, green: 0.063, blue: 0.180),
        blue:     Color(red: 0.173, green: 0.431, blue: 0.561),
        amber:    Color(red: 0.878, green: 0.639, blue: 0.235),
        hold:     Color(red: 0.949, green: 0.757, blue: 0.306),
        userBits: Color(red: 0.612, green: 0.855, blue: 0.882),
        flash:    Color(red: 0.055, green: 0.063, blue: 0.075),
        flashInk: Color.white)

    static let night = SlatePalette(
        face:     Color(red: 0.055, green: 0.063, blue: 0.075),
        ink:      Color(red: 0.898, green: 0.914, blue: 0.918),
        inkSoft:  Color(red: 0.612, green: 0.655, blue: 0.678),
        inkFaint: Color(red: 0.447, green: 0.490, blue: 0.514),
        red:      Color(red: 0.937, green: 0.322, blue: 0.400),
        blue:     Color(red: 0.271, green: 0.576, blue: 0.718),
        amber:    Color(red: 0.878, green: 0.678, blue: 0.325),
        hold:     Color(red: 0.514, green: 0.376, blue: 0.106),
        userBits: Color(red: 0.145, green: 0.353, blue: 0.396),
        flash:    Color(red: 0.965, green: 0.969, blue: 0.969),
        flashInk: Color(red: 0.055, green: 0.063, blue: 0.075))
}

/// The slate face: ruled fields, red timecode — a real insert slate rather than
/// an app that happens to show timecode.
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
    var night: Bool
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
    // Turning the scene/shot/take labels vertical is what paid for the sticks:
    // a horizontal label costs a line of height in every cell, and three cells'
    // worth adds up. Stood on end, a label costs a few percent of *width* —
    // which this face has to spare — and hands the cell height to the value.
    /// Breathing room above the sticks. A clapper's arm does not start at the
    /// very top edge of the board, and butting it against the bezel made the
    /// slate feel like it was overflowing the phone.
    private let topGap:    CGFloat = 3
    private let sticksRow: CGFloat = 22
    private let tcRow:     CGFloat = 23
    private let takeRow:   CGFloat = 30
    private let metaRow:   CGFloat = 10
    private let footRow:   CGFloat = 12

    private var p: SlatePalette { night ? .night : .day }

    var body: some View {
        // Note this reader deliberately stays *inside* the safe area: adding
        // .ignoresSafeArea() to it zeroes geo.safeAreaInsets, and then there is
        // nothing left to tell you where the hardware actually is. Expansion is
        // done with negative padding instead.
        GeometryReader { geo in
            // Both horizontal insets are kept in full. iOS reports them
            // *symmetrically* in landscape, so there is no way to tell from them
            // which edge the Dynamic Island is on — reclaiming the "empty" side
            // is a coin flip, and losing it puts hardware over the take
            // steppers. Height is taken instead, which is reliable.
            let insets = geo.safeAreaInsets
            let growTop    = max(insets.top - 2, 0)
            let growBottom = max(insets.bottom - 2, 0)

            let rule: CGFloat = 2
            // The three rules are laid out *between* the rows, so their height
            // comes out of the budget before it is divided into units. Leaving
            // them out made the rows total more than the screen.
            let u = (geo.size.height + growTop + growBottom - rule * 3) / 100

            VStack(spacing: 0) {
                Color.clear.frame(height: topGap * u)
                sticks(u: u, bleedLeading: insets.leading, bleedTrailing: insets.trailing)

                if layout == .metaTop {
                    meta(u: u).frame(height: metaRow * u)
                    divider(rule)
                }

                timecode(u: u).frame(height: tcRow * u).clipped()
                divider(rule)
                take(u: u).frame(height: takeRow * u).clipped()
                divider(rule)

                if layout == .metaBottom {
                    meta(u: u).frame(height: metaRow * u)
                    divider(rule)
                }

                foot(u: u).frame(height: footRow * u)
            }
            .padding(.top, -growTop)
            .padding(.bottom, -growBottom)
            .foregroundStyle(inkColor)
            // Nothing on this slate may ease, fade or interpolate. SwiftUI will
            // happily cross-fade a colour change over ~250 ms, which at 24 fps
            // smears the sync mark across six frames and lands it visibly after
            // the freeze it is meant to mark.
            //
            // Scoped to the slate itself rather than applied further up: at the
            // top level it also reached the settings and diagnostics sheets, and
            // suppressed the Picker menus they depend on.
            .transaction { $0.animation = nil }
        }
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
    ///
    /// The bars are sized to fill the row rather than to a fixed height — that
    /// was why enlarging the row kept doing nothing visible.
    private func sticks(u: CGFloat, bleedLeading: CGFloat, bleedTrailing: CGFloat) -> some View {
        ClapperSticks(isClosed: !model.isClapPending, barHeight: sticksRow * u / 2)
            .frame(height: sticksRow * u)
            .clipped()
            // Cancel the safe-area inset so the chevrons reach both physical
            // edges of the display.
            .padding(.leading, -bleedLeading)
            .padding(.trailing, -bleedTrailing)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapSticks)
            .animation(nil, value: model.isClapPending)
            .accessibilityLabel(model.isHolding ? "Resume" : "Clap")
            .accessibilityAddTraits(.isButton)
    }

    /// No caption. Eight red digits in a slate's largest cell are not something
    /// anyone needs told are timecode, and the word cost the numbers a fifth of
    /// their height. The rate goes in the corner, where it is available without
    /// being in the way — and doubles as the marker for the user-bits phase,
    /// which is the one time the digits are *not* timecode.
    private func timecode(u: CGFloat) -> some View {
        ZStack {
            fillingText(showingUserBits ? model.userBitsDisplay : model.displayTimecode,
                        size: 25 * u, weight: .bold, monospaced: true)
                .foregroundStyle(timecodeColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Only during user bits. The rate lives in the footer instead — at
            // full size the timecode reaches the trailing edge and ran straight
            // into it, and the digits get priority.
            if showingUserBits {
                HStack {
                    Spacer()
                    Text("USER BITS")
                        .font(.system(size: 2.8 * u, weight: .semibold))
                        .tracking(2.8 * u * 0.16)
                        .foregroundStyle(model.isFlashing ? p.flashInk : p.inkFaint)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 2.5 * u)
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
            // Take is stepped rather than typed: it advances far more often than
            // it is set, and typing a number on set wastes a hand. The steppers
            // run the full height of the cell for the same reason — they are
            // pressed constantly, often without looking.
            cell("Take", u: u) {
                HStack(spacing: 1.5 * u) {
                    fillingText("\(model.info.take)", size: 33 * u, weight: .bold)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    // The steppers sit inside the cell, not against its rules —
                    // borders meeting borders reads as a mistake.
                    // Fixed height, not maxHeight: .infinity. The take number is
                    // deliberately taller than its row — that is what makes it
                    // fill the cell — which inflates this HStack, and anything
                    // stretching to fit then gets clipped flush against the
                    // rules. Padding cannot win against a stretched frame.
                    VStack(spacing: 1.6 * u) {
                        stepper("plus", u: u) { model.info.take += 1 }
                        stepper("minus", u: u) { model.info.take = max(1, model.info.take - 1) }
                    }
                }
            }
        }
    }

    /// Text sized to fill its cell rather than to sit politely inside a line
    /// box. A line box is about 1.2× the font size but the capitals only fill
    /// about 0.72×, so type that "fits" leaves a third of the cell empty above
    /// and below. Taking the natural size and letting the parent clip trims the
    /// leading instead of the letters.
    private func fillingText(_ string: String, size: CGFloat,
                             weight: Font.Weight, monospaced: Bool = false) -> some View {
        Text(string)
            .font(.system(size: size, weight: weight,
                          design: monospaced ? .monospaced : .default))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .fixedSize(horizontal: false, vertical: true)
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
            VStack(alignment: .leading, spacing: 0.4 * u) {
                label("Roll", u: u)
                Text(display(model.info.roll))
                    .font(.system(size: 4.6 * u, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0.4 * u) {
                label("Sound", u: u)
                Text(display(model.info.soundRoll))
                    .font(.system(size: 4.6 * u, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ticks(u: u)

            Spacer(minLength: 0)

            Text("\(model.rate.displayName) FPS")
                .font(.system(size: 2.8 * u, weight: .semibold))
                .tracking(2.8 * u * 0.16)
                .foregroundStyle(p.inkSoft)
                .fixedSize()

            // Status is an indicator, not a sentence — it truncated as prose,
            // and the detail belongs on the diagnostics sheet behind it.
            Button(action: onDiagnostics) {
                HStack(spacing: 0.9 * u) {
                    Circle().fill(model.status.color).frame(width: 2.2 * u, height: 2.2 * u)
                    Text(model.inputName)
                        .font(.system(size: 2.8 * u, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(p.inkSoft)
            }

            Button(action: onJam) {
                Text(model.isArmedForJam ? "CANCEL" : "JAM")
                    .font(.system(size: 3.2 * u, weight: .bold))
                    .tracking(1.2)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2.4 * u)
                    .padding(.vertical, 1.3 * u)
                    .background(RoundedRectangle(cornerRadius: 1.2 * u)
                        .fill(model.isArmedForJam ? p.amber : p.blue))
            }

            Button(action: onNextShot) {
                Text("NEXT")
                    .font(.system(size: 3.2 * u, weight: .bold))
                    .tracking(1.2)
                    .fixedSize()
                    .foregroundStyle(inkColor)
                    .padding(.horizontal, 2.4 * u)
                    .padding(.vertical, 1.3 * u)
                    .background(RoundedRectangle(cornerRadius: 1.2 * u)
                        .stroke(inkColor, lineWidth: max(1, 0.3 * u)))
            }

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 5.5 * u))
                    .foregroundStyle(p.inkSoft)
                    .frame(width: 9 * u, height: 9 * u)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 3 * u)
    }

    // MARK: - Pieces

    private func display(_ s: String) -> String { s.isEmpty ? "—" : s }

    private func label(_ text: String, u: CGFloat) -> some View {
        Text(text.uppercased())
            .font(.system(size: 2.6 * u, weight: .semibold))
            .tracking(2.6 * u * 0.16)
            .foregroundStyle(model.isFlashing ? p.flashInk : p.inkFaint)
            .lineLimit(1)
            .fixedSize()
    }

    private func readout(_ title: String, _ value: String, u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0.3 * u) {
            label(title, u: u)
            Text(display(value))
                .font(.system(size: 5.2 * u, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 3 * u)
    }

    /// A ruled cell with its label stood on end down the left edge, so the value
    /// gets the cell's full height rather than sharing it with a caption.
    private func cell<Content: View>(_ title: String, u: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 1.2 * u) {
            verticalLabel(title, u: u)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, 4 * u)
    }

    /// Letters stacked one above the next, read top to bottom — not a rotated
    /// word. A rotated label makes you tilt your head; a stacked one stays
    /// upright, which is what a slate wants when it is read at a glance from
    /// whatever angle the camera happens to be at.
    private func verticalLabel(_ text: String, u: CGFloat) -> some View {
        let letters = Array(text.uppercased())
        return VStack(spacing: 0.35 * u) {
            // Indices rather than the characters themselves: "SCENE" repeats E,
            // and duplicate ids silently drop rows.
            ForEach(letters.indices, id: \.self) { i in
                Text(String(letters[i]))
                    .font(.system(size: 3 * u, weight: .semibold))
                    .fixedSize()
            }
        }
        .foregroundStyle(model.isFlashing ? p.flashInk : p.inkFaint)
        .frame(maxHeight: .infinity)
        .padding(.leading, 1.2 * u)
    }

    private func slateField(text: Binding<String>, u: CGFloat) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 33 * u, weight: .bold))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .focused($editing)
            .submitLabel(.done)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func stepper(_ symbol: String, u: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 4 * u, weight: .bold))
                .foregroundStyle(inkColor)
                .frame(width: 11 * u, height: 10.5 * u)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 1 * u)
                    .stroke(inkColor, lineWidth: max(1, 0.3 * u)))
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
            .font(.system(size: 3 * u, weight: .semibold))
            // Without this the three-letter ticks break mid-word under
            // pressure — "EXT" became "EX / T".
            .fixedSize()
            .foregroundStyle(on ? inkColor : p.inkFaint)
            .overlay(alignment: .bottom) {
                if on {
                    Rectangle().fill(p.red).frame(height: 0.6 * u).offset(y: 1.1 * u)
                }
            }
    }

    private func divider(_ height: CGFloat) -> some View {
        Rectangle().fill(inkColor).frame(height: height)
    }

    private func vRule(_ u: CGFloat) -> some View {
        Rectangle().fill(inkColor).frame(width: max(1, 0.3 * u))
    }

    // MARK: - Colour

    private var showingUserBits: Bool { model.isHolding && model.holdPhase == .userBits }

    /// The sync mark, in three steps on one timeline:
    ///
    /// 1. **Flash** — the whole face inverts for two frames. Nothing else on the
    ///    slate is ever this colour, so a single frame of it is unambiguous.
    /// 2. **Hold** — settles to amber for the rest of the timecode window.
    /// 3. **User bits** — shifts again, so the two halves of the hold cannot be
    ///    mistaken for one another.
    private var faceColor: Color {
        if model.isFlashing { return p.flash }
        if showingUserBits { return p.userBits }
        if model.isHolding { return p.hold }
        return p.face
    }

    private var inkColor: Color { model.isFlashing ? p.flashInk : p.ink }

    private var timecodeColor: Color {
        if model.isFlashing { return p.flashInk }
        return model.isHolding ? p.ink : p.red
    }
}
