import Combine
import Foundation
import Network
import UIKit

/// Réseau + santé de l'iPhone (CDC §17 : batterie, température).
@MainActor
final class DeviceMonitor: ObservableObject {
    enum Link: String { case cellular = "4G/5G", wifi = "Wi-Fi", none = "Hors ligne", other = "Réseau" }

    @Published private(set) var link: Link = .none
    @Published private(set) var isExpensive = false
    @Published private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var batteryLevel: Float = UIDevice.current.batteryLevel
    @Published private(set) var isCharging = false

    private let monitor = NWPathMonitor()

    var alerts: [String] {
        var a: [String] = []
        if link == .none { a.append("Plus de réseau") }
        if thermal == .serious { a.append("iPhone chaud – qualité réduite conseillée") }
        if thermal == .critical { a.append("iPhone TRÈS chaud – passer en Éco") }
        if batteryLevel >= 0 && batteryLevel < 0.15 && !isCharging { a.append("Batterie iPhone < 15 %") }
        return a
    }

    /// Recommandation automatique de profil en cas de surchauffe.
    var suggestedMaxProfile: QualityProfile? {
        switch thermal {
        case .critical: return .eco
        case .serious: return .normal
        default: return nil
        }
    }

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        monitor.pathUpdateHandler = { [weak self] path in
            let link: Link = path.status != .satisfied ? .none
                : path.usesInterfaceType(.cellular) ? .cellular
                : path.usesInterfaceType(.wifi) ? .wifi : .other
            Task { @MainActor in
                self?.link = link
                self?.isExpensive = path.isExpensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "roamcast.net"))

        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermal = ProcessInfo.processInfo.thermalState }
        }
        NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        }
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        }
        refreshBattery()
    }

    private func refreshBattery() {
        batteryLevel = UIDevice.current.batteryLevel
        isCharging = [.charging, .full].contains(UIDevice.current.batteryState)
    }
}
