import SwiftUI

/// Écran de live (Balade + Drone). Utilisable à une main : 5 gros boutons max (CDC §17).
struct LiveView: View {
    @EnvironmentObject var session: SessionManager
    @State private var panel: Panel?
    @State private var confirmStop = false

    enum Panel: String, Identifiable { case music, chat, info, source, settings; var id: String { rawValue } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewLayerView(layer: session.engine.pipeline.preview)
                .aspectRatio(16 / 9, contentMode: .fit)

            VStack {
                StatusBar(engine: session.engine, device: session.device, confirmStop: $confirmStop)
                Spacer()
                OperatorStrip()
            }
            .padding(12)

            HStack {
                Spacer()
                ActionColumn(panel: $panel)
            }
            .padding(.trailing, 12)

            if session.state == .dronePreparation {
                DronePrepOverlay()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $panel) { p in
            NavigationStack {
                Group {
                    switch p {
                    case .music: MusicPanel(music: session.music, audio: session.audio)
                    case .chat: ChatPanel(chat: session.chat)
                    case .info: LiveInfoPanel()
                    case .source: SourcePanel(close: { panel = nil })
                    case .settings: SettingsPanel(audio: session.audio)
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { panel = nil } } }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Arrêter le live ?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Terminer la diffusion", role: .destructive) { Task { await session.stop() } }
            Button("Continuer le live", role: .cancel) {}
        }
    }
}

// MARK: - Barre d'état (privée, jamais diffusée)

struct StatusBar: View {
    @EnvironmentObject var session: SessionManager
    @ObservedObject var engine: StreamingEngine
    @ObservedObject var device: DeviceMonitor
    @Binding var confirmStop: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { confirmStop = true } label: {
                Image(systemName: "stop.fill").font(.title2).frame(width: 52, height: 52)
            }
            .buttonStyle(.borderedProminent).tint(.red)

            liveBadge
            if let start = session.liveStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    chip(Format.duration(Date().timeIntervalSince(start)), "clock")
                }
            }
            if let v = session.viewers { chip("\(v)", "eye") }
            chip(Format.bitrate(engine.sentBitrate), "arrow.up")
            chip(device.link.rawValue, device.link == .none ? "wifi.slash" : "antenna.radiowaves.left.and.right")
            if device.batteryLevel >= 0 { chip("\(Int(device.batteryLevel * 100)) %", "battery.75") }
            Spacer()
            ForEach(device.alerts, id: \.self) { a in
                Text(a).font(.caption.bold()).padding(6).background(.orange, in: Capsule())
            }
        }
    }

    @ViewBuilder private var liveBadge: some View {
        switch engine.publisherState {
        case .live: badge("EN DIRECT", .red)
        case .reconnecting(let n): badge("RECONNEXION \(n)…", .orange)
        case .connecting: badge("CONNEXION…", .yellow)
        default: badge("HORS LIGNE", .gray)
        }
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.headline.bold()).padding(.horizontal, 12).padding(.vertical, 8).background(c, in: Capsule())
    }

    private func chip(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon).font(.subheadline.monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Infos opérateur privées : coordonnées précises, télémétrie brute (CDC §9).
struct OperatorStrip: View {
    @EnvironmentObject var session: SessionManager
    var body: some View {
        HStack(spacing: 14) {
            if session.state == .drone {
                let t = session.droneTelemetry
                Text("ALT \(Int(t.altitudeMeters)) m")
                Text("DIST \(Format.distance(t.distanceToHomeMeters))")
                Text("SAT \(t.satelliteCount)")
                if let b = t.batteryPercent {
                    Text("BAT \(b) %").foregroundStyle(b < 25 ? .red : .primary)
                }
            } else {
                LocationStrip(location: session.location)
            }
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LocationStrip: View {
    @ObservedObject var location: LocationManager
    var body: some View {
        if let c = location.current {
            Text(String(format: "%.5f, %.5f", c.coordinate.latitude, c.coordinate.longitude))
            Text("\(Int(c.altitude)) m")
            Text(Format.distance(location.distanceMeters))
            Text("Public : \(location.publicLocation.label ?? "masqué")").foregroundStyle(.secondary)
        } else {
            Text("GPS en attente…")
        }
    }
}

// MARK: - 5 actions (CDC §17)

struct ActionColumn: View {
    @Binding var panel: LiveView.Panel?
    var body: some View {
        VStack(spacing: 14) {
            big("music.note", "Musique", .music)
            big("bubble.left.and.bubble.right.fill", "Chat", .chat)
            big("text.badge.plus", "Infos", .info)
            big("arrow.triangle.swap", "Source", .source)
            big("slider.horizontal.3", "Réglages", .settings)
        }
    }
    private func big(_ icon: String, _ title: String, _ p: LiveView.Panel) -> some View {
        Button { panel = p } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption2.bold())
            }
            .frame(width: 76, height: 64)
        }
        .buttonStyle(.bordered)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
