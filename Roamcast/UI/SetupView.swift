import AVFoundation
import SwiftUI

/// Écran unique de préparation (CDC §4) : objectif < 1 minute avec un preset.
struct SetupView: View {
    @EnvironmentObject var session: SessionManager
    @State private var categoryQuery = ""
    @State private var categoryResults: [TwitchCategory] = []
    @State private var newTag = ""
    @State private var starting = false

    var body: some View {
        HStack(spacing: 0) {
            // Aperçu à gauche : ce que verront les viewers.
            PreviewLayerView(layer: session.engine.pipeline.preview)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()

            Form {
                Section("Preset") {
                    Picker("Preset", selection: presetBinding) {
                        ForEach(LivePreset.defaults) { Text($0.name).tag($0.name) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Twitch") {
                    TwitchSignInRow(auth: session.auth)
                    TextField("Titre", text: $session.preset.title)
                    categoryField
                    Picker("Langue", selection: $session.preset.language) {
                        Text("Français").tag("fr"); Text("English").tag("en"); Text("Español").tag("es")
                    }
                    TagEditor(tags: $session.preset.tags, newTag: $newTag)
                }

                Section("Diffusion") {
                    Toggle(isOn: $session.dryRun) {
                        VStack(alignment: .leading) {
                            Text("Mode essai")
                            Text("Tout fonctionne, rien n'est envoyé sur Twitch. Idéal pour tester le drone.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Qualité", selection: $session.preset.quality) {
                        ForEach(QualityProfile.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Bitrate adaptatif", isOn: $session.preset.adaptiveBitrate)
                    Picker("Localisation publique", selection: $session.preset.locationMode) {
                        ForEach(PublicLocationMode.allCases) { Text($0.label).tag($0) }
                    }
                    PublicLocationRow(location: session.location)
                }

                Section("Audio") {
                    MicSourceRow(audio: session.audio)
                    Toggle("Ducking musique", isOn: $session.preset.ducking.enabled)
                }

                Section {
                    Button {
                        starting = true
                        Task { await session.goLive(); starting = false }
                    } label: {
                        HStack {
                            Spacer()
                            if starting { ProgressView() } else {
                                Label(session.dryRun ? "Lancer l'essai" : "Lancer le live",
                                      systemImage: session.dryRun ? "play.circle" : "record.circle").font(.title3.bold())
                            }
                            Spacer()
                        }.frame(minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent).tint(session.dryRun ? .blue : .red)
                    .disabled(starting || session.preset.title.isEmpty)
                }
            }
            .frame(maxWidth: 460)
        }
    }

    private var presetBinding: Binding<String> {
        Binding(get: { session.preset.name },
                set: { name in if let p = LivePreset.defaults.first(where: { $0.name == name }) { session.preset = p } })
    }

    private var categoryField: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Catégorie")
                Spacer()
                Text(session.preset.category?.name ?? "—").foregroundStyle(.secondary)
            }
            TextField("Rechercher une catégorie…", text: $categoryQuery)
                .textInputAutocapitalization(.never)
                .task(id: categoryQuery) {
                    try? await Task.sleep(nanoseconds: 350_000_000)   // debounce
                    categoryResults = (try? await session.twitch.searchCategories(categoryQuery)) ?? []
                }
            ForEach(categoryResults.prefix(6)) { cat in
                Button(cat.name) {
                    session.preset.category = cat
                    categoryQuery = ""; categoryResults = []
                }
            }
        }
    }
}

struct TagEditor: View {
    @Binding var tags: [String]
    @Binding var newTag: String
    var body: some View {
        VStack(alignment: .leading) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(tags, id: \.self) { tag in
                        Button { tags.removeAll { $0 == tag } } label: {
                            Label(tag, systemImage: "xmark").labelStyle(.titleAndIcon).font(.callout)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            HStack {
                TextField("Ajouter un tag (\(tags.count)/\(TwitchTagRules.maxCount))", text: $newTag)
                    .onSubmit(add)
                Button("Ajouter", action: add).disabled(newTag.isEmpty)
            }
        }
    }
    private func add() { tags = TwitchTagRules.add(newTag, to: tags); newTag = "" }
}

// Sous-vues avec @ObservedObject : SwiftUI ne propage pas les changements
// d'un ObservableObject imbriqué (session.audio, session.location…).
struct PublicLocationRow: View {
    @ObservedObject var location: LocationManager
    var body: some View {
        LabeledContent("Affiché sur le stream", value: location.publicLocation.label ?? "Rien")
    }
}

struct MicSourceRow: View {
    @ObservedObject var audio: AudioEngine
    var body: some View {
        LabeledContent("Micro") {
            Label(audio.input.rawValue, systemImage: audio.input == .builtIn ? "iphone" : "mic.fill")
                .foregroundStyle(audio.input == .djiMic ? .green : .orange)
        }
    }
}

struct TwitchSignInRow: View {
    @EnvironmentObject var session: SessionManager
    @ObservedObject var auth: TwitchAuth
    @Environment(\.openURL) private var openURL

    var body: some View {
        if auth.isSignedIn {
            LabeledContent("Compte", value: session.twitch.me?.display_name ?? "Connecté")
        } else if let code = auth.pendingCode {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sur twitch.tv/activate, saisis :")
                Text(code.user_code).font(.system(.largeTitle, design: .monospaced).bold())
                Button("Ouvrir Twitch") { openURL(URL(string: code.verification_uri)!) }
            }
        } else {
            Button("Se connecter à Twitch") {
                Task {
                    do {
                        let code = try await session.auth.startDeviceFlow()
                        openURL(URL(string: code.verification_uri)!)
                        try await session.auth.waitForAuthorization(code)
                        _ = try await session.twitch.loadMe()
                        let ch = try await session.twitch.channel()
                        session.preset.category = TwitchCategory(id: ch.game_id, name: ch.game_name)
                    } catch {
                        session.lastError = "Connexion Twitch : \(error.localizedDescription)"
                    }
                }
            }
            Text("Pas besoin de compte pour le mode essai.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Affiche la sortie du compositeur (= ce que voit Twitch).
struct PreviewLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> LayerHost { LayerHost(layer: layer) }
    func updateUIView(_ uiView: LayerHost, context: Context) {}

    final class LayerHost: UIView {
        let hosted: CALayer
        init(layer: CALayer) {
            hosted = layer
            super.init(frame: .zero)
            self.layer.addSublayer(layer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
        }
    }
}
