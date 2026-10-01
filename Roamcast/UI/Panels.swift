import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MusicPanel: View {
    @ObservedObject var music: MusicManager
    @ObservedObject var audio: AudioEngine
    @State private var importing = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 28) {
                    Spacer()
                    Button(action: music.previous) { Image(systemName: "backward.fill") }
                    Button(action: music.togglePlay) {
                        Image(systemName: music.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 54))
                    }
                    Button(action: music.next) { Image(systemName: "forward.fill") }
                    Spacer()
                }
                .font(.title).buttonStyle(.plain)
                Text(music.current?.title ?? "Aucune piste").frame(maxWidth: .infinity).foregroundStyle(.secondary)
                Toggle("Aléatoire", isOn: $music.shuffle)
                Toggle("Boucle", isOn: $music.loop)
                VStack(alignment: .leading) {
                    Text("Volume musique")
                    Slider(value: $audio.musicVolume, in: 0...1)
                }
            }
            Section("Bibliothèque (\(music.library.count))") {
                ForEach(music.library) { Text($0.title) }
                Button { importing = true } label: { Label("Importer depuis Fichiers", systemImage: "folder.badge.plus") }
            }
        }
        .navigationTitle("Musique")
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.mp3, .mpeg4Audio, .wav, UTType(filenameExtension: "aac") ?? .audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { music.importFiles(urls) }
        }
    }
}

struct ChatPanel: View {
    @ObservedObject var chat: TwitchChat
    var body: some View {
        ScrollViewReader { proxy in
            List(chat.messages) { m in
                (Text(m.author).bold().foregroundColor(Color(hex: m.color) ?? .purple) + Text("  ") + Text(m.text))
                    .font(.title3)
                    .id(m.id)
            }
            .onChange(of: chat.messages.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .overlay { if chat.messages.isEmpty { Text(chat.connected ? "Pas encore de message" : "Chat hors ligne").foregroundStyle(.secondary) } }
        .navigationTitle("Chat")
    }
}

/// Panneau « Live Twitch » (CDC §4.3) – API uniquement, zéro impact sur le RTMP.
struct LiveInfoPanel: View {
    @EnvironmentObject var session: SessionManager
    @State private var newTag = ""
    @State private var saving = false
    @State private var saved = false

    var body: some View {
        Form {
            TextField("Titre", text: $session.preset.title)
            LabeledContent("Catégorie", value: session.preset.category?.name ?? "—")
            if session.state == .drone || session.state == .dronePreparation,
               session.preset.category?.name == "IRL" {
                // Le CDC impose : proposer, jamais changer tout seul.
                Text("Astuce : adapter le titre pour le vol ?").font(.footnote).foregroundStyle(.secondary)
            }
            TagEditor(tags: $session.preset.tags, newTag: $newTag)
            Button {
                saving = true
                Task {
                    do { try await session.applyLiveInfo(); saved = true }
                    catch { session.lastError = "Mise à jour Twitch : \(error.localizedDescription)" }
                    saving = false
                }
            } label: {
                HStack { Spacer(); if saving { ProgressView() } else { Text(saved ? "Mis à jour ✓" : "Mettre à jour sur Twitch").bold() }; Spacer() }
            }
            .disabled(saving)
        }
        .onChange(of: session.preset) { _, _ in saved = false }
        .navigationTitle("Live Twitch")
    }
}

struct SettingsPanel: View {
    @EnvironmentObject var session: SessionManager
    @ObservedObject var audio: AudioEngine

    var body: some View {
        Form {
            Section("Niveaux") {
                MicSourceRow(audio: audio)
                meter
                slider("Micro", $audio.micVolume, 0...2)
                slider("Musique", $audio.musicVolume, 0...1)
                slider("Master", $audio.masterVolume, 0...1.5)
            }
            Section("Ducking") {
                Toggle("Activé", isOn: $session.preset.ducking.enabled)
                Picker("Réduction", selection: $session.preset.ducking.reductionDB) {
                    Text("-6 dB").tag(Float(-6)); Text("-12 dB").tag(Float(-12)); Text("-18 dB").tag(Float(-18))
                }.pickerStyle(.segmented)
                slider("Remontée (s)", $session.preset.ducking.releaseSeconds, 0.3...4)
            }
            Section("Localisation publique") {
                Picker("Mode", selection: $session.preset.locationMode) {
                    ForEach(PublicLocationMode.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                PublicLocationRow(location: session.location)
            }
            Section("Diagnostic") {
                NavigationLink("Journal de l'app") { DiagnosticView(log: AppLog.shared) }
                LabeledContent("Version", value: AppInfo.version)
            }
        }
        .navigationTitle("Réglages")
    }

    private var meter: some View {
        HStack {
            Text("Voix")
            ProgressView(value: Double(max(0, min(1, (audio.micLevelDB + 60) / 60))))
                .tint(audio.duckGainDB < -1 ? .green : .blue)
            Text(audio.duckGainDB < -1 ? "ducking" : "").font(.caption).frame(width: 60)
        }
    }

    private func slider(_ title: String, _ v: Binding<Float>, _ r: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: "%.1f", v.wrappedValue)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: v, in: r)
        }
    }
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Journal interne : le seul moyen de voir ce qui se passe sans Mac.
/// « Copier » → coller dans une conversation pour analyser un problème.
struct DiagnosticView: View {
    @ObservedObject var log: AppLog
    @State private var copied = false

    var body: some View {
        List {
            Section {
                // Avec un compte Apple gratuit, AltStore modifie le bundle ID :
                // c'est CELUI-CI qu'il faut déclarer sur developer.dji.com pour la clé DJI.
                LabeledContent("Bundle ID réel") {
                    Text(AppInfo.bundleID).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Clé DJI", value: AppInfo.hasDJIKey ? "présente" : "ABSENTE")
                LabeledContent("Client ID Twitch", value: AppInfo.hasTwitchClientID ? "présent" : "ABSENT")
            }
            Section("Journal") {
                ForEach(log.entries.reversed()) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.tag).font(.caption.bold()).foregroundStyle(color(e.tag))
                            Spacer()
                            Text(e.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(e.message).font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Diagnostic")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "Copié ✓" : "Copier") {
                    UIPasteboard.general.string = AppInfo.summary + "\n\n" + log.exportText
                    copied = true
                }
                Button("Vider", role: .destructive) { log.clear(); copied = false }
            }
        }
    }

    private func color(_ tag: String) -> Color {
        switch tag {
        case "Erreur": return .red
        case "DJI": return .purple
        case "RTMP", "Réseau": return .orange
        case "Audio": return .green
        default: return .secondary
        }
    }
}
