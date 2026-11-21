import CoreMIDI
import SwiftUI

@main
struct PianoApp: App {
    var body: some Scene {
        #if os(macOS)
        Window("Piano", id: "instrument") {
            PianoView()
                .frame(minWidth: 560, minHeight: 360)
        }
        .defaultSize(width: 900, height: 650)
        #else
        WindowGroup { PianoView() }
        #endif
    }
}

struct PianoView: View {
    @StateObject private var audio = PianoAudio()
    @Environment(\.scenePhase) private var phase
    @State private var midi = MIDIInput()
    @State private var midiKeys: Set<MIDIKey> = []
    @State private var midiDampers: [MIDIEndpointRef: Int] = [:]
    @State private var midiSoftPedals: Set<MIDIEndpointRef> = []
    @State private var octave = 4
    @State private var velocity = 60.0
    @State private var pedal = 0.0
    @State private var softPedal = false
    @State private var touches: Set<Int> = []
    @State private var accessibilityNotes: [Int: UUID] = [:]
    @State private var info = false
    @State private var showSound = false
    @AppStorage("soundboardBodyPercent") private var bodyPercent = 45
    @AppStorage("roomReverbPercent") private var reverbPercent = 30
    @State private var visibleNotes = 14
    var playsAudio = true

    private let brass = Color(red: 0.94, green: 0.75, blue: 0.47)

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 580
            let compact = proxy.size.height < 450
            VStack(spacing: compact ? 12 : 24) {
                header
                if audio.unavailable {
                    Button("Retry audio", systemImage: "speaker.slash") { audio.start() }
                        .font(.callout)
                }
                controls
                KeyboardView(
                    layout: KeyboardLayout(octave: octave, whiteCount: wide ? 14 : 7),
                    pressed: touches.union(accessibilityNotes.keys).union(midiKeys.map(\.note)),
                    showLabels: !compact,
                    onTouches: updateTouches,
                    onAccessibilityPlay: playAccessibleNote
                )
                .frame(maxHeight: 460)
                .id(KeyWindow(octave: octave, wide: wide))
                damperControl
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, compact ? 8 : 26)
            .onChange(of: wide, initial: true) { _, newValue in
                releaseKeys()
                visibleNotes = newValue ? 14 : 7
                octave = min(octave, maximumOctave)
            }
        }
        .background {
            LinearGradient(colors: [Color(white: 0.13), Color(white: 0.065)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .tint(brass)
        .task {
            guard playsAudio else { return }
            midi.start(receive: receiveMIDI, disconnected: disconnectMIDI)
            if phase == .active { audio.start() }
        }
        .onDisappear {
            midi.stop()
            audio.stop()
        }
        .onChange(of: bodyPercent, initial: true) { _, value in
            audio.setBody(min(100, max(0, value)))
        }
        .onChange(of: reverbPercent, initial: true) { _, value in
            audio.setReverb(min(100, max(0, value)))
        }
        .onChange(of: phase) { _, value in
            if value == .active {
                if playsAudio { audio.start() }
            } else {
                releaseKeys()
                #if os(iOS)
                if value == .background {
                    midiKeys.removeAll()
                    midiDampers.removeAll()
                    midiSoftPedals.removeAll()
                    pedal = 0
                    audio.releaseAll()
                    audio.stop()
                }
                #endif
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)
            .receive(on: RunLoop.main)) { _ in
            guard playsAudio else { return }
            #if os(iOS)
            guard phase == .active else { return }
            #endif
            releaseKeys()
            midiKeys.removeAll()
            audio.releaseAll()
            updateDamper()
            audio.start()
        }
        .alert("Playing the piano", isPresented: $info) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Touch several keys to play a chord. Use the arrows to change octaves and the slider to set hammer velocity. Use the damper slider to control how long released notes ring. Use the soft pedal for a gentler tone on the next notes.")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Physical Modeling")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(brass)
                Text("Piano")
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            HStack(spacing: 0) {
                iconButton("slider.horizontal.3", label: "Sound controls") { showSound.toggle() }
                    .popover(isPresented: $showSound) {
                        soundControls
                        #if os(iOS)
                            .presentationCompactAdaptation(.popover)
                        #endif
                    }
                iconButton("info.circle", label: "Playing the piano") { info = true }
            }
        }
    }

    private var soundControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            soundSlider("Soundboard body", percent: $bodyPercent)
            soundSlider("Room reverb", percent: $reverbPercent)
        }
        .frame(width: 230)
        .padding(16)
    }

    private func soundSlider(_ label: LocalizedStringKey, percent: Binding<Int>) -> some View {
        let amount = Binding(
            get: { Double(min(100, max(0, percent.wrappedValue))) },
            set: { percent.wrappedValue = Int($0.rounded()) }
        )
        let value = amount.wrappedValue.formatted(.percent.scale(1))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.headline)
                Spacer(minLength: 16)
                Text(value).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Slider(value: amount, in: 0...100, step: 1) { Text(label) }
                .accessibilityValue(Text(value))
        }
    }

    private var maximumOctave: Int { visibleNotes == 14 ? 6 : 7 }

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                iconButton("chevron.left", label: "Lower octave") { shift(-1) }
                    .disabled(octave == 0)
                Group {
                    if octave == 0 {
                        Text("Bass")
                    } else if octave == maximumOctave {
                        Text("Treble")
                    } else {
                        Text(verbatim: "C\(octave)")
                    }
                }
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(minWidth: 30)
                    .accessibilityLabel(Text("Octave range"))
                    .accessibilityValue(Text(verbatim: rangeDescription))
                iconButton("chevron.right", label: "Higher octave") { shift(1) }
                    .disabled(octave == maximumOctave)
            }
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.footnote)
                    .foregroundStyle(brass)
                    .accessibilityHidden(true)
                Slider(value: $velocity, in: 5...100, step: 1) {
                    Text("Velocity")
                }
                .accessibilityValue(Text(verbatim: "\(Int((velocity * 1.27).rounded()))"))
            }

            pedalToggle("speaker.wave.1", label: "Soft pedal", isOn: $softPedal)
        }
    }

    private var damperControl: some View {
        let percent = max(pedal, Double(externalDamper) * 100 / 127).formatted(.percent.scale(1).precision(.fractionLength(0)))
        return HStack(spacing: 10) {
            iconButton("waveform.path", label: "Toggle damper pedal") {
                pedal = pedal == 0 ? 100 : 0
            }
            .background(pedal > 0 ? brass.opacity(0.18) : .white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12))
            .accessibilityValue(Text(percent))
            Slider(value: $pedal, in: 0...100, step: 1) {
                Text("Damper pedal")
            }
            .accessibilityValue(Text(percent))
            Text(percent)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .onChange(of: pedal) { _, _ in updateDamper() }
    }

    private func pedalToggle(_ symbol: String, label: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .foregroundStyle(isOn.wrappedValue ? Color.black : brass)
                .background(isOn.wrappedValue ? brass : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private var rangeDescription: String {
        let layout = KeyboardLayout(octave: octave, whiteCount: visibleNotes)
        return "\(noteName(layout.white.first ?? 21)) – \(noteName(layout.white.last ?? 108))"
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(brass)
        .accessibilityLabel(Text(label))
    }

    private func shift(_ direction: Int) {
        releaseKeys()
        octave = min(maximumOctave, max(0, octave + direction))
    }

    private func updateTouches(_ notes: Set<Int>) {
        for note in touches.subtracting(notes) where accessibilityNotes[note] == nil && !hasMIDIKey(note) { audio.noteOff(note) }
        for note in notes.subtracting(touches) { audio.noteOn(note, velocity: Int(velocity), soft: softPedal || !midiSoftPedals.isEmpty) }
        touches = notes
    }

    private func releaseKeys() {
        for note in touches.union(accessibilityNotes.keys) where !hasMIDIKey(note) { audio.noteOff(note) }
        touches = []
        accessibilityNotes = [:]
    }

    private var externalDamper: Int { midiDampers.values.max() ?? 0 }

    private func updateDamper() {
        if Double(externalDamper) * 100 / 127 > pedal {
            audio.midiSustain(externalDamper)
        } else {
            audio.sustain(Int(pedal))
        }
    }

    private func hasMIDIKey(_ note: Int) -> Bool { midiKeys.contains { $0.note == note } }

    private func receiveMIDI(_ source: MIDIEndpointRef, _ event: PianoMIDI) {
        #if os(iOS)
        guard phase != .background else { return }
        #endif
        switch event {
        case let .press(channel, note, velocity):
            midiKeys.insert(MIDIKey(source: source, channel: channel, note: note))
            audio.midiNoteOn(note, velocity: velocity, soft: softPedal || !midiSoftPedals.isEmpty)
        case let .release(channel, note):
            midiKeys.remove(MIDIKey(source: source, channel: channel, note: note))
            releaseMIDINote(note)
        case let .damper(value):
            midiDampers[source] = value
            updateDamper()
        case let .soft(down):
            if down { midiSoftPedals.insert(source) } else { midiSoftPedals.remove(source) }
        case .panic:
            disconnectMIDI(source)
        }
    }

    private func disconnectMIDI(_ source: MIDIEndpointRef) {
        let released = midiKeys.filter { $0.source == source }
        midiKeys.subtract(released)
        for note in Set(released.map(\.note)) { releaseMIDINote(note) }
        midiDampers[source] = nil
        midiSoftPedals.remove(source)
        updateDamper()
    }

    private func releaseMIDINote(_ note: Int) {
        guard !hasMIDIKey(note), !touches.contains(note), accessibilityNotes[note] == nil else { return }
        audio.noteOff(note)
    }

    private func playAccessibleNote(_ note: Int) {
        let token = UUID()
        accessibilityNotes[note] = token
        audio.noteOn(note, velocity: Int(velocity), soft: softPedal || !midiSoftPedals.isEmpty)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(340))
            guard accessibilityNotes[note] == token else { return }
            accessibilityNotes[note] = nil
            if !touches.contains(note) && !hasMIDIKey(note) { audio.noteOff(note) }
        }
    }
}

private struct MIDIKey: Hashable {
    let source: MIDIEndpointRef
    let channel: Int
    let note: Int
}

private struct KeyWindow: Hashable {
    let octave: Int
    let wide: Bool
}

struct PianoView_Previews: PreviewProvider {
    static var previews: some View {
        #if os(macOS)
        PianoView(playsAudio: false).frame(width: 900, height: 650)
        #else
        Group {
            PianoView(playsAudio: false)
                .previewDevice("iPhone SE (3rd generation)")
            PianoView(playsAudio: false)
                .previewDevice("iPhone 16 Pro Max")
        }
        #endif
    }
}
