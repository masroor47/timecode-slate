import SwiftUI
import SlateCore

/// Landscape slate. Deliberately plain — the point of the proof of concept is
/// the timecode path, not the styling.
struct SlateView: View {
    @StateObject private var model = SlateViewModel()
    @State private var showSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {
                // Bound straight to the model, with animation explicitly off.
                // Routing this through an intermediate @State updated in
                // .onChange would cost a second render pass, which could put
                // the sticks a frame behind the colour change — and the whole
                // point is that they are the same frame.
                ClapperSticks(isClosed: model.isHolding)
                    .frame(height: 68)
                    .animation(nil, value: model.isHolding)
                header
                timecodeDisplay
                metadataRow
                controls
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            // Nothing on this slate may ease, fade or interpolate. SwiftUI will
            // happily cross-fade a foregroundStyle change over ~250 ms, which
            // at 24 fps smears the white→yellow sync mark across six frames and
            // lands it visibly after the freeze it is supposed to mark. Killing
            // the transaction outright is more reliable than trying to exempt
            // each value individually.
            .transaction { $0.animation = nil }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear {
            // A slate that blanks itself between takes is worse than no slate.
            UIApplication.shared.isIdleTimerDisabled = true
            // Note we do *not* start listening here. The microphone only runs
            // between arming a jam and getting one.
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.stopListening()
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(model.status.color)
                .frame(width: 12, height: 12)
            Text(model.status.label)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(model.status.color)

            // Tapping the input name opens the diagnostics. The phone has one
            // USB-C port, so when a timecode interface is in it there is no
            // cable left for a debugger — every routing question has to be
            // answerable on the slate's own screen.
            Button {
                model.refreshDiagnostics()
                showDiagnostics = true
            } label: {
                HStack(spacing: 4) {
                    Text(model.inputName)
                        .lineLimit(1)
                    Image(systemName: "info.circle")
                }
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            // Input level meter — confirms signal is arriving before you rely on it.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(model.level > 0.98 ? Color.orange : Color.green)
                        .frame(width: geo.size.width * CGFloat(min(model.level, 1)))
                }
            }
            .frame(height: 6)

            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
            }
            .foregroundStyle(.secondary)
        }
    }

    /// While frozen the slate shows the clap timecode first, then the user
    /// bits. Both halves are static, which is the whole point — a still frame
    /// of either is unambiguous no matter what the camera's shutter is doing.
    private var showingUserBits: Bool {
        model.isHolding && model.holdPhase == .userBits
    }

    /// Three states, three colours, so no frame is ambiguous about which it is.
    ///
    /// White → yellow marks the sync point and nothing else: yellow appears on
    /// the collision frame and lasts exactly the timecode window. Yellow → cyan
    /// then marks the switch to user bits. Previously both halves of the hold
    /// were yellow, which made the sync transition and the user-bits transition
    /// look identical.
    private var displayColor: Color {
        if showingUserBits { return .cyan }
        if model.isHolding { return .yellow }
        return .white
    }

    private var timecodeDisplay: some View {
        VStack(spacing: 2) {
            Text(showingUserBits ? model.userBitsDisplay : model.displayTimecode)
                .font(.system(size: 96, weight: .bold, design: .monospaced))
                .foregroundStyle(displayColor)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .contentTransition(.identity)      // never animate digits
                .animation(nil, value: model.displayTimecode)
                .animation(nil, value: showingUserBits)
                .animation(nil, value: model.isHolding)

            Text(caption)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(model.isHolding ? displayColor : .secondary)
                .animation(nil, value: model.isHolding)
        }
        .frame(maxWidth: .infinity)
    }

    private var caption: String {
        if showingUserBits { return "USER BITS" }
        if model.isHolding { return "SYNC" }
        return model.rate.displayName + " fps"
    }

    private var metadataRow: some View {
        HStack(spacing: 14) {
            field("SCENE", text: $model.info.scene, width: 130)
            field("SHOT", text: $model.info.shot, width: 90)
            takeField
            field("ROLL", text: $model.info.roll, width: 90)
            Spacer()
        }
    }

    private func field(_ label: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .frame(width: width)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
        }
    }

    private var takeField: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("TAKE")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("\(model.info.take)")
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 46)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
                // Sized for a thumb on set, not a cursor. 44pt is Apple's
                // minimum touch target and the old 12pt chevrons were far
                // under it.
                VStack(spacing: 4) {
                    takeStepper("chevron.up") { model.info.take += 1 }
                    takeStepper("chevron.down") {
                        if model.info.take > 1 { model.info.take -= 1 }
                    }
                }
            }
        }
    }

    private func takeStepper(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.14)))
        }
    }

    private var clapButtonTitle: String {
        if model.isHolding { return "RESUME" }
        return model.isClapPending ? "READY…" : "CLAP"
    }

    private var clapButtonColor: Color {
        if model.isHolding { return .yellow }
        return model.isClapPending ? .orange : .red
    }

    private var controls: some View {
        HStack(spacing: 14) {
            // Tapping again while armed cancels, so an unanswered jam is never
            // a dead end that leaves the microphone running.
            Button {
                model.armJam()
            } label: {
                Label(model.isArmedForJam ? "CANCEL JAM" : "JAM",
                      systemImage: model.isArmedForJam ? "xmark" : "bolt.fill")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(model.isArmedForJam ? Color.orange : Color.blue))
                    .foregroundStyle(.white)
            }

            Button { model.advanceShot() } label: {
                Text("NEXT SHOT")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.12)))
                    .foregroundStyle(.white)
            }

            Spacer()

            // Feedback for the press lives on the button alone. Nothing in the
            // timecode display may change before the sync point, or the change
            // itself becomes a false sync mark.
            Button {
                if model.isHolding { model.releaseHold() } else { model.clap() }
            } label: {
                Text(clapButtonTitle)
                    .font(.system(size: 26, weight: .heavy, design: .monospaced))
                    .frame(minWidth: 190)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(clapButtonColor))
                    .foregroundStyle(model.isHolding ? .black : .white)
            }
            .disabled(model.isClapPending)
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Timecode") {
                    Toggle("Auto-detect frame rate", isOn: $model.autoDetectRate)
                    Picker("Frame rate", selection: $model.rate) {
                        ForEach(TimecodeRate.allCases, id: \.self) { r in
                            Text(r.displayName).tag(r)
                        }
                    }
                    .disabled(model.autoDetectRate)
                }
                Section {
                    Toggle("Audible clap", isOn: $model.clapSoundEnabled)
                } header: {
                    Text("Clap")
                } footer: {
                    Text("Plays a transient the sound recorder can pick up. "
                         + "The microphone is off except while jamming, so this "
                         + "never interferes with decoding.")
                }
                Section("Production") {
                    TextField("Production", text: $model.info.production)
                    TextField("Director", text: $model.info.director)
                    TextField("Cinematographer", text: $model.info.cinematographer)
                    TextField("Sound roll", text: $model.info.soundRoll)
                }
                Section("Shot") {
                    Toggle("MOS (no sound)", isOn: $model.info.isMOS)
                    Toggle("Interior", isOn: $model.info.isInterior)
                    Toggle("Day", isOn: $model.info.isDay)
                    Toggle("Pickup", isOn: $model.info.isPickup)
                }
            }
            .navigationTitle("Slate Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                }
            }
        }
    }

    // MARK: - Input diagnostics

    /// What iOS thinks is plugged in, readable on the phone itself.
    ///
    /// The verdict line at the top is the whole point: it separates "iOS never
    /// enumerated the interface", which is a power or class-compliance problem
    /// upstream of this app, from "iOS enumerated it and we failed to select
    /// it", which is ours.
    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let d = model.diagnostics {
                        Text(d.verdict)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(verdictColor(d))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(verdictColor(d).opacity(0.12)))

                        Text(d.report)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if model.diagnosticsProbeRunning {
                        ProgressView("Probing audio session…")
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("No snapshot yet.")
                            .foregroundStyle(.secondary)
                    }

                    Text("Plug the interface in, then Refresh. If it only "
                         + "appears while armed, arm JAM first and refresh again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Input Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Refresh") { model.refreshDiagnostics() }
                        .disabled(model.diagnosticsProbeRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showDiagnostics = false }
                }
            }
        }
    }

    private func verdictColor(_ d: AudioDiagnostics) -> Color {
        if d.probeError != nil { return .red }
        if d.activeInputIsExternal { return .green }
        if d.externalInputs.isEmpty { return .orange }
        return .yellow
    }
}
