import SwiftUI
import UIKit

private enum PathAheadStyle {
    static let ink = Color(red: 0.08, green: 0.18, blue: 0.18)
    static let muted = Color(red: 0.39, green: 0.46, blue: 0.45)
    static let canvas = Color(red: 0.95, green: 0.96, blue: 0.93)
    static let card = Color.white
    static let green = Color(red: 0.08, green: 0.39, blue: 0.32)
    static let paleGreen = Color(red: 0.88, green: 0.94, blue: 0.90)
    static let amber = Color(red: 0.72, green: 0.36, blue: 0.08)
    static let paleAmber = Color(red: 1.0, green: 0.94, blue: 0.84)
    static let red = Color(red: 0.68, green: 0.20, blue: 0.16)
    static let paleRed = Color(red: 0.99, green: 0.90, blue: 0.87)
}

struct ContentView: View {
    @StateObject private var cane = BluetoothManager()
    @StateObject private var voice = ElevenLabsVoice()
    @Environment(\.scenePhase) private var scenePhase
    @State private var voiceEnabled = false
    @State private var showVoiceSettings = false

    var body: some View {
        ZStack {
            PathAheadStyle.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    header
                    awarenessCard
                    connectionCard
                    detailCards
                    learningCard
                    distanceChart
                    voiceCard
                    eventCard
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 28)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(PathAheadStyle.ink)
        .sheet(isPresented: $showVoiceSettings) {
            VoiceSettingsSheet(voice: voice)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: cane.alert) { _, next in
            switch next {
            case .obstacle:
                if voiceEnabled { voice.speakObstacle() }
            case .unavailable:
                if voiceEnabled { voice.speakUnavailable() }
                else { voice.stop() }
            case .normal, .stale, .idle, .waiting:
                voice.stop()
            }
        }
        .onChange(of: cane.learningVoiceCue) { _, cue in
            guard voiceEnabled, voice.isReady else { return }
            switch cue {
            case .some(.route): voice.speakRouteCue()
            case .some(.gait): voice.speakGaitCue()
            case .none: break
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                cane.pauseForBackground()
                voice.stop()
                voiceEnabled = false
            }
        }
        .onChange(of: voice.isReady) { _, ready in
            if !ready { voiceEnabled = false }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(PathAheadStyle.green)
                Image(systemName: "figure.walk.motion")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 43, height: 43)

            VStack(alignment: .leading, spacing: 2) {
                Text("PATHAHEAD")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.4)
                Text("Walking awareness")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PathAheadStyle.muted)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(modeColor).frame(width: 7, height: 7)
                Text(modeLabel)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.white, in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }

    private var awarenessCard: some View {
        let state = presentation(for: cane.alert)
        return VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("RIGHT NOW")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(PathAheadStyle.muted)
                    Text(state.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.75)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Text(state.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(PathAheadStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: state.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(state.foreground)
                    .frame(width: 52, height: 52)
                    .background(state.background, in: RoundedRectangle(cornerRadius: 17))
            }

            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(distanceText)
                    .font(.system(size: 57, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text("cm")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PathAheadStyle.muted)
                Spacer()
                Text(distanceFootnote)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PathAheadStyle.muted)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)

            Text("One forward ultrasound sensor can miss objects. Keep using your cane and familiar mobility skills.")
                .font(.system(size: 11))
                .foregroundStyle(PathAheadStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(19)
        .background(state.background, in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(state.foreground.opacity(0.11), lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: cane.alert)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: cane.isConnected ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(cane.isConnected ? PathAheadStyle.green : PathAheadStyle.muted)
                    .frame(width: 36, height: 36)
                    .background(PathAheadStyle.canvas, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(cane.isDemo ? "Preview the app" : cane.isConnected ? "ESP32 connected" : "Connect your cane")
                        .font(.system(size: 15, weight: .bold))
                    Text(cane.status)
                        .font(.system(size: 12))
                        .foregroundStyle(PathAheadStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if cane.isDemo {
                HStack(spacing: 9) {
                    Menu {
                        ForEach(DemoScenario.allCases) { scenario in
                            Button(scenario.rawValue) { cane.demoScenario = scenario }
                        }
                    } label: {
                        Label(cane.demoScenario.rawValue, systemImage: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PathAheadStyle.green)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(PathAheadStyle.paleGreen, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button { cane.disconnect() } label: {
                        Text("End preview")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PathAheadStyle.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(PathAheadStyle.canvas, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            } else if cane.isConnected || cane.isConnecting {
                Button { cane.disconnect() } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.bordered)
                .tint(PathAheadStyle.ink)
            } else {
                HStack(spacing: 9) {
                    Button { cane.scan() } label: {
                        Label(cane.isScanning ? "Searching…" : "Connect cane", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PathAheadStyle.green)
                    .disabled(cane.isScanning)

                    Button { cane.startDemo() } label: {
                        Label("Preview", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.bordered)
                    .tint(PathAheadStyle.green)
                }
            }

            if !cane.devices.isEmpty && !cane.isConnected && !cane.isDemo {
                VStack(spacing: 7) {
                    ForEach(cane.devices) { device in
                        Button { cane.connect(device) } label: {
                            HStack {
                                Image(systemName: "cane")
                                Text(device.name).fontWeight(.semibold)
                                Spacer()
                                Text("\(device.rssi) dBm")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(PathAheadStyle.muted)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                            }
                            .font(.system(size: 13))
                            .padding(12)
                            .background(PathAheadStyle.canvas, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if cane.isDemo {
                Label("Simulated readings · not connected to your sensors", systemImage: "sparkles")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PathAheadStyle.amber)
            } else if !cane.isConnected {
                Text("Connect on a physical iPhone after uploading the PathAhead BLE sketch to the ESP32.")
                    .font(.system(size: 11))
                    .foregroundStyle(PathAheadStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).stroke(PathAheadStyle.ink.opacity(0.055), lineWidth: 1))
    }

    private var detailCards: some View {
        HStack(spacing: 8) {
            metricCard(title: "CLOSING", value: closingText, unit: "cm/s",
                       icon: "arrow.down.right", tint: PathAheadStyle.green,
                       footnote: "+ means approaching")
            metricCard(title: "TO 55 CM", value: etaText, unit: "sec",
                       icon: "timer", tint: PathAheadStyle.amber,
                       footnote: "estimate only")
            metricCard(title: "MPU6050", value: accelerationText, unit: "g",
                       icon: "gyroscope", tint: PathAheadStyle.green,
                       footnote: "raw acceleration")
        }
    }

    private var learningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PathAheadStyle.green)
                    .frame(width: 36, height: 36)
                    .background(PathAheadStyle.paleGreen, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Personal learning")
                        .font(.system(size: 15, weight: .bold))
                    Text(cane.gaitStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(PathAheadStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("BETA")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(PathAheadStyle.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(PathAheadStyle.paleAmber, in: Capsule())
            }

            if let cue = cane.latestLearningMessage {
                Label(cue, systemImage: "sparkle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PathAheadStyle.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PathAheadStyle.paleAmber, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("Learns cane-tap rhythm and repeat route cues during a supervised walk. It does not detect falls or certify a route as safe.")
                    .font(.system(size: 10))
                    .foregroundStyle(PathAheadStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(cane.walkControlStatus)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(cane.supportsWalkControls ? PathAheadStyle.green : PathAheadStyle.amber)
                        .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                Button {
                    cane.isWalkActive ? cane.endWalk() : cane.startWalk()
                } label: {
                    Label(cane.isWalkActive ? "End walk" : "Start learning walk",
                          systemImage: cane.isWalkActive ? "stop.fill" : "figure.walk")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 43)
                }
                .buttonStyle(.borderedProminent)
                .tint(cane.isWalkActive ? PathAheadStyle.amber : PathAheadStyle.green)
                .disabled(!cane.isConnected || cane.isDemo || !cane.supportsWalkControls)

                Button { cane.resetGaitBaseline() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 43, height: 43)
                }
                .buttonStyle(.bordered)
                .tint(PathAheadStyle.green)
                .disabled(!cane.isConnected || cane.isWalkActive || !cane.supportsWalkControls)
                .accessibilityLabel("Reset learned walking baseline")
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(PathAheadStyle.ink.opacity(0.055), lineWidth: 1))
    }

    private func metricCard(title: String, value: String, unit: String, icon: String,
                            tint: Color, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(PathAheadStyle.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.65)
                Text(unit)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PathAheadStyle.muted)
            }
            Text(footnote)
                .font(.system(size: 9))
                .foregroundStyle(PathAheadStyle.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 19))
    }

    private var distanceChart: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Distance trend")
                        .font(.system(size: 15, weight: .bold))
                    Text("Recent ultrasound readings · centimetres")
                        .font(.system(size: 11))
                        .foregroundStyle(PathAheadStyle.muted)
                }
                Spacer()
                Circle().fill(PathAheadStyle.amber).frame(width: 7, height: 7)
                Text("warning")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PathAheadStyle.muted)
            }
            DistancePlot(points: cane.history)
                .frame(height: 98)
                .accessibilityLabel("Recent distance readings, chart")
            HStack {
                Text("Recent")
                Spacer()
                Text(cane.history.isEmpty ? "Waiting for readings" : "55 cm reference buffer")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(PathAheadStyle.muted)
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PathAheadStyle.green)
                    .frame(width: 37, height: 37)
                    .background(PathAheadStyle.paleGreen, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text("ElevenLabs voice")
                        .font(.system(size: 15, weight: .bold))
                    Text(voice.status)
                        .font(.system(size: 11))
                        .foregroundStyle(PathAheadStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { showVoiceSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PathAheadStyle.green)
                        .frame(width: 36, height: 36)
                        .background(PathAheadStyle.canvas, in: RoundedRectangle(cornerRadius: 11))
                }
                .accessibilityLabel("ElevenLabs settings")
            }

            HStack(spacing: 9) {
                Button {
                    Task {
                        if !voice.isReady { _ = await voice.prepare() }
                        if voice.isReady { voiceEnabled = true }
                    }
                } label: {
                    Label(voice.isBusy ? "Preparing…" : voice.isReady ? "Voice ready" : "Prepare voice",
                          systemImage: voice.isReady ? "checkmark.circle.fill" : "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(PathAheadStyle.green)
                .disabled(!voice.isConfigured || voice.isBusy || voice.isReady)

                Button {
                    Task { await voice.testVoice() }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .tint(PathAheadStyle.green)
                .disabled(!voice.isConfigured || voice.isBusy)
                .accessibilityLabel("Test ElevenLabs voice")
            }

            if voice.isReady {
                Toggle(isOn: $voiceEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speak alerts")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Plays a prepared clip when warning starts")
                            .font(.system(size: 10))
                            .foregroundStyle(PathAheadStyle.muted)
                    }
                }
                .tint(PathAheadStyle.green)
            }

            Text("Prepares five fixed clips using your ElevenLabs account, including learned route and rhythm cues. Needs internet while preparing; alerts play from the phone. Voice pauses when you leave this screen.")
                .font(.system(size: 10))
                .foregroundStyle(PathAheadStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            Label("Audio plays through this iPhone when headphones are disconnected.", systemImage: "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PathAheadStyle.green)
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private var eventCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Session notes").font(.system(size: 14, weight: .bold))
                Spacer()
                Text("THIS SESSION")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(PathAheadStyle.muted)
            }
            if cane.events.isEmpty {
                Text("Connect the cane to see session events here.")
                    .font(.system(size: 11))
                    .foregroundStyle(PathAheadStyle.muted)
            } else {
                ForEach(cane.events.prefix(4)) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(event.message.localizedCaseInsensitiveContains("warning") ? PathAheadStyle.amber : PathAheadStyle.green)
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                        Text(event.message)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(event.timestamp, style: .time)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(PathAheadStyle.muted)
                    }
                }
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private var footer: some View {
        Text("PathAhead is a supervised prototype, not a replacement for a mobility cane, guide dog, or professional orientation and mobility training.")
            .font(.system(size: 10))
            .foregroundStyle(PathAheadStyle.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
    }

    private var distanceText: String {
        guard let cm = cane.telemetry?.cm else { return "—" }
        return cm.formatted(.number.precision(.fractionLength(0)))
    }

    private var distanceFootnote: String {
        if cane.isDemo { return "simulated" }
        guard let cm = cane.telemetry?.cm else { return "unknown · not safe" }
        return cm < 55 ? "inside 55 cm buffer" : "measured target"
    }

    private var closingText: String {
        guard let speed = cane.telemetry?.closing else { return "—" }
        return abs(speed) < 0.5 ? "0" : speed.formatted(.number.precision(.fractionLength(0)))
    }

    private var etaText: String {
        guard let eta = cane.telemetry?.eta else { return "—" }
        return eta.formatted(.number.precision(.fractionLength(1)))
    }

    private var accelerationText: String {
        guard let magnitude = cane.telemetry?.accelerationG else { return "—" }
        return magnitude.formatted(.number.precision(.fractionLength(2)))
    }

    private var modeLabel: String {
        if cane.isDemo { return "PREVIEW" }
        if cane.isConnected { return "LIVE" }
        if cane.isConnecting || cane.isScanning { return "CONNECTING" }
        return "OFFLINE"
    }

    private var modeColor: Color {
        cane.isDemo ? PathAheadStyle.amber : cane.isConnected ? PathAheadStyle.green : PathAheadStyle.muted
    }

    private func presentation(for alert: AlertState) -> (title: String, subtitle: String, icon: String, foreground: Color, background: Color) {
        switch alert {
        case .obstacle:
            return ("Obstacle ahead", "Slow down and use your usual mobility technique.", "exclamationmark.triangle.fill", PathAheadStyle.red, PathAheadStyle.paleRed)
        case .unavailable:
            return ("Distance unavailable", "No echo has arrived. Treat the space ahead as unknown.", "questionmark.circle.fill", PathAheadStyle.amber, PathAheadStyle.paleAmber)
        case .stale:
            return ("Readings paused", "Connection or sensor data stopped. Reconnect before relying on readings.", "antenna.radiowaves.left.and.right.slash", PathAheadStyle.amber, PathAheadStyle.paleAmber)
        case .normal:
            return ("No threshold alert", "A distance reading is available; this does not mean the path is clear.", "arrow.forward.circle.fill", PathAheadStyle.green, PathAheadStyle.paleGreen)
        case .waiting, .idle:
            return ("Waiting for readings", cane.isDemo ? "Choose a preview scenario below." : "Connect the ESP32 or start preview to begin.", "waveform.path", PathAheadStyle.muted, .white)
        }
    }
}

private struct DistancePlot: View {
    let points: [DistancePoint]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let maxDistance = 300.0
            ZStack {
                Path { path in
                    let y = height * (1 - 55 / maxDistance)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
                .stroke(PathAheadStyle.amber.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                Path { path in
                    var previousSegment: Int?
                    var didMove = false
                    for index in points.indices {
                        let point = points[index]
                        guard let value = point.cm else { previousSegment = nil; didMove = false; continue }
                        let x = xFor(index: index, count: points.count, width: width)
                        let y = yFor(value, height: height, maxDistance: maxDistance)
                        if previousSegment != point.segment || !didMove {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        previousSegment = point.segment
                        didMove = true
                    }
                }
                .stroke(PathAheadStyle.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    if let value = point.cm {
                        Circle()
                            .fill(point.warning ? PathAheadStyle.amber : PathAheadStyle.green)
                            .frame(width: point.warning ? 6 : 4, height: point.warning ? 6 : 4)
                            .position(x: xFor(index: index, count: points.count, width: width),
                                      y: yFor(value, height: height, maxDistance: maxDistance))
                    }
                }
            }
        }
    }

    private func xFor(index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width }
        return width * CGFloat(index) / CGFloat(count - 1)
    }

    private func yFor(_ value: Double, height: CGFloat, maxDistance: Double) -> CGFloat {
        height * (1 - CGFloat(min(max(value, 0), maxDistance) / maxDistance))
    }
}

private struct VoiceSettingsSheet: View {
    @ObservedObject var voice: ElevenLabsVoice
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var voiceID = ""
    @State private var errorText: String?
    @FocusState private var focusedField: Field?

    private enum Field { case key, voice }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("ElevenLabs API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .focused($focusedField, equals: .key)
                    TextField("Voice ID", text: $voiceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.none)
                        .focused($focusedField, equals: .voice)
                    Text("In ElevenLabs, copy your API key from account settings and copy the voice ID from the selected voice's menu. Enter both here.")
                        .font(.system(size: 12))
                        .foregroundStyle(PathAheadStyle.muted)
                } header: {
                    Text("Your ElevenLabs account")
                } footer: {
                    Text("The key is saved in this iPhone's Keychain. It is used only to request the three prepared audio clips. Never send it in chat or put it in the ESP32 code.")
                }

                Section {
                    Button {
                        focusedField = nil
                        do {
                            try voice.configure(apiKey: apiKey, voiceID: voiceID)
                            apiKey = ""
                            voiceID = ""
                            errorText = nil
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    } label: {
                        Text("Save securely on this iPhone")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if voice.isConfigured {
                        Button(role: .destructive) {
                            voice.forgetCredentials()
                            apiKey = ""
                            voiceID = ""
                        } label: {
                            Text("Forget saved credentials and clips")
                        }
                    }
                    if let errorText {
                        Text(errorText).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }

                Section {
                    Label("Prepared audio stays on this phone for the current app session.", systemImage: "iphone.gen3")
                        .font(.system(size: 12))
                        .foregroundStyle(PathAheadStyle.muted)
                    Label("Only fixed alert phrases are sent, including obstacle, route-learning, rhythm-change, unavailable-distance, and test messages. Sensor readings are not sent to ElevenLabs.", systemImage: "text.quote")
                        .font(.system(size: 12))
                        .foregroundStyle(PathAheadStyle.muted)
                }
            }
            .navigationTitle("ElevenLabs setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
