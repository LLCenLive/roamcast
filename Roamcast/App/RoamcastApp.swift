import SwiftUI

@main
struct RoamcastApp: App {
    @StateObject private var session = SessionManager(
        twitchClientID: Bundle.main.object(forInfoDictionaryKey: "TwitchClientID") as? String ?? ""
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var session: SessionManager

    var body: some View {
        Group {
            switch session.state {
            case .idle:
                HomeView()
            case .preparing:
                SetupView()
            case .walking, .dronePreparation, .drone:
                LiveView()
            case .ending, .finished:
                EndView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.state)
        .alert("Oups", isPresented: Binding(get: { session.lastError != nil },
                                            set: { if !$0 { session.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(session.lastError ?? "") }
    }
}

struct HomeView: View {
    @EnvironmentObject var session: SessionManager
    @State private var showLog = false
    var body: some View {
        VStack(spacing: 24) {
            Text("Roamcast").font(.system(size: 56, weight: .heavy))
            Text("Balade · Drone · Direct").foregroundStyle(.secondary)
            Button { session.openSetup() } label: {
                Label("Préparer un live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.title2.bold()).frame(maxWidth: 360, minHeight: 64)
            }
            .buttonStyle(.borderedProminent).tint(.purple)
            Button { showLog = true } label: { Label("Journal de diagnostic", systemImage: "doc.text.magnifyingglass") }
                .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showLog) {
            NavigationStack {
                DiagnosticView(log: AppLog.shared)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { showLog = false } } }
            }
        }
    }
}

struct EndView: View {
    @EnvironmentObject var session: SessionManager
    var body: some View {
        VStack(spacing: 16) {
            if session.state == .ending {
                ProgressView("Fin du live…")
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                Text("Live terminé").font(.largeTitle.bold())
                Text("Distance : \(Format.distance(session.location.distanceMeters))").foregroundStyle(.secondary)
                Button("Retour à l'accueil") { session.reset() }.buttonStyle(.borderedProminent)
            }
        }
    }
}
