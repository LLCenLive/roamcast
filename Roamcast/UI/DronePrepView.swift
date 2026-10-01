import SwiftUI

/// Écran de préparation drone (CDC §8). Le live continue derrière avec l'écran brandé,
/// micro et musique actifs. Rien n'est automatique : c'est le pilote qui bascule.
struct DronePrepOverlay: View {
    @EnvironmentObject var session: SessionManager

    var body: some View {
        let c = session.droneChecklist
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Préparation drone", systemImage: "airplane").font(.title2.bold())
                Spacer()
                Text("Le live continue · écran de transition diffusé").font(.caption).foregroundStyle(.secondary)
            }

            step(done: c.sdkRegistered, "SDK DJI prêt")
            step(done: c.remoteConnected, "Radiocommande RC-N1 branchée en USB-C et allumée")
            step(done: c.aircraftConnected, c.modelName.map { "Drone détecté : \($0)" } ?? "Allumer le Mini 2")
            step(done: c.videoReceiving, "Retour vidéo reçu")
            step(done: c.batteryOK, "Batterie drone ≥ 30 %", optional: true)
            step(done: c.gpsOK, "GPS drone OK (≥ 8 satellites)", optional: true)

            ForEach(c.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Button("Annuler") { session.cancelDrone() }
                    .buttonStyle(.bordered).frame(minHeight: 56)
                Button {
                    session.switchToDrone()
                } label: {
                    Label("Basculer vers le drone", systemImage: "arrow.triangle.swap")
                        .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent).tint(.purple)
                .disabled(!c.readyToSwitch)
            }
        }
        .padding(20)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding()
    }

    private func step(done: Bool, _ text: String, optional: Bool = false) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "circle"))
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            Text(text).foregroundStyle(done ? .primary : .secondary)
            if !done && !optional { ProgressView().scaleEffect(0.7) }
        }
    }
}

struct SourcePanel: View {
    @EnvironmentObject var session: SessionManager
    let close: () -> Void

    var body: some View {
        List {
            switch session.state {
            case .walking:
                Button { session.requestDrone(); close() } label: {
                    Label("Passer au drone", systemImage: "airplane.departure").font(.title3.bold())
                }
            case .drone:
                Button { session.backToWalk(); close() } label: {
                    Label("Revenir à la caméra iPhone", systemImage: "figure.walk").font(.title3.bold())
                }
                Text("Tu pourras ensuite éteindre ou débrancher le drone sans couper le live.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .dronePreparation:
                Text("Préparation du drone en cours…")
            default:
                EmptyView()
            }
        }
        .navigationTitle("Source vidéo")
    }
}
