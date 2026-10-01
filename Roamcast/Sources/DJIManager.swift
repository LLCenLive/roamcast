import Combine
import CoreLocation
import CoreVideo
import UIKit
#if canImport(DJISDK)
import DJISDK
import DJIWidget
#endif

/// Télémétrie drone. La position de l'appareil reste PRIVÉE (interface opérateur uniquement).
struct DroneTelemetry: Equatable {
    var altitudeMeters: Double = 0          // relative au décollage
    var horizontalSpeed: Double = 0         // m/s
    var distanceToHomeMeters: Double = 0
    var batteryPercent: Int?
    var satelliteCount: Int = 0
    var gpsSignalLevel: Int = 0             // 0…5 côté DJI
    var flightTime: TimeInterval = 0
    var isFlying = false
    /// (CLLocationCoordinate2D n'est pas Equatable : on stocke les deux composantes.)
    var aircraftLatitude: Double?
    var aircraftLongitude: Double?
}

/// Étapes de l'écran de préparation drone (CDC §8, étapes 12 → 15).
struct DroneChecklist: Equatable {
    var sdkRegistered = false
    var remoteConnected = false
    var aircraftConnected = false
    var modelName: String?
    var videoReceiving = false
    var batteryOK = false
    var gpsOK = false

    /// Condition pour proposer « Basculer vers le drone ». La décision reste humaine.
    var readyToSwitch: Bool { aircraftConnected && videoReceiving }
    /// Avertissements affichés mais non bloquants (le pilote décide).
    var warnings: [String] {
        var w: [String] = []
        if aircraftConnected && !batteryOK { w.append("Batterie drone < 30 %") }
        if aircraftConnected && !gpsOK { w.append("GPS faible – pas de retour au point fiable") }
        return w
    }

    static func evaluate(battery: Int?, satellites: Int, gpsLevel: Int) -> (battery: Bool, gps: Bool) {
        ((battery ?? 0) >= 30, satellites >= 8 && gpsLevel >= 3)
    }
}

protocol DroneLink: VideoSource {
    var checklistPublisher: AnyPublisher<DroneChecklist, Never> { get }
    var telemetryPublisher: AnyPublisher<DroneTelemetry, Never> { get }
    func prepare()
}

// MARK: - Implémentation DJI Mobile SDK V4

#if canImport(DJISDK)
/// Gestion du DJI Mini 2 via MSDK iOS V4 (support Mini 2 ajouté en 4.16).
/// ⚠️ Phase 0 du CDC : tout ce fichier est à valider sur le matériel réel avant le reste.
/// Aucune commande de vol n'est envoyée : lecture seule (CDC §17).
final class DJIManager: NSObject, DroneLink, DJISDKManagerDelegate, DJIVideoFeedListener,
                        VideoFrameProcessor, DJIFlightControllerDelegate, DJIBatteryDelegate {
    let id: VideoSourceID = .drone
    let frames = LatestFrameBox()

    private let checklist = CurrentValueSubject<DroneChecklist, Never>(DroneChecklist())
    private let telemetry = CurrentValueSubject<DroneTelemetry, Never>(DroneTelemetry())
    var checklistPublisher: AnyPublisher<DroneChecklist, Never> { checklist.eraseToAnyPublisher() }
    var telemetryPublisher: AnyPublisher<DroneTelemetry, Never> { telemetry.eraseToAnyPublisher() }

    private var lastFrameAt = Date.distantPast
    private var loggedFirstPacket = false
    private var loggedFirstFrame = false
    private var videoWatchdog: Timer?

    func prepare() {
        // Clé DJI lue dans Info.plist (DJISDKAppKey), liée au bundle ID.
        AppLog.log("DJI", "Enregistrement SDK \(DJISDKManager.sdkVersion())…")
        DJISDKManager.registerApp(with: self)
    }

    func start() {
        DJIVideoPreviewer.instance()?.enableHardwareDecode = true
        DJIVideoPreviewer.instance()?.registFrameProcessor(self)
        DJIVideoPreviewer.instance()?.start()
        DJISDKManager.videoFeeder()?.primaryVideoFeed.add(self, with: nil)
        videoWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            var c = self.checklist.value
            c.videoReceiving = Date().timeIntervalSince(self.lastFrameAt) < 1
            if c != self.checklist.value { self.checklist.send(c) }
        }
    }

    func stop() {
        DJISDKManager.videoFeeder()?.primaryVideoFeed.remove(self)
        DJIVideoPreviewer.instance()?.unregistFrameProcessor(self)
        DJIVideoPreviewer.instance()?.close()
        videoWatchdog?.invalidate()
        frames.clear()
    }

    // MARK: DJISDKManagerDelegate

    func appRegisteredWithError(_ error: Error?) {
        var c = checklist.value
        c.sdkRegistered = (error == nil)
        checklist.send(c)
        AppLog.log("DJI", error.map { "Enregistrement ÉCHOUÉ : \($0.localizedDescription)" } ?? "SDK enregistré, recherche du produit…")
        if error == nil { DJISDKManager.startConnectionToProduct() }
    }

    func productConnected(_ product: DJIBaseProduct?) {
        var c = checklist.value
        c.remoteConnected = product != nil
        c.aircraftConnected = (product as? DJIAircraft)?.flightController != nil
        c.modelName = product?.model
        checklist.send(c)
        AppLog.log("DJI", "Produit : \(product?.model ?? "aucun") · appareil connecté : \(c.aircraftConnected)")

        if let aircraft = product as? DJIAircraft {
            aircraft.flightController?.delegate = self
            aircraft.battery?.delegate = self
        }
    }

    func productDisconnected() {
        // Le live continue : la scène drone affichera l'écran de secours
        // et SessionManager propose le retour caméra iPhone.
        checklist.send(DroneChecklist(sdkRegistered: checklist.value.sdkRegistered))
        frames.clear()
        AppLog.log("DJI", "Produit déconnecté")
    }

    func componentConnected(withKey key: String?, andIndex index: Int) {
        // Radiocommande allumée avant le drone : l'appareil apparaît en deux temps.
        productConnected(DJISDKManager.product())
    }
    func componentDisconnected(withKey key: String?, andIndex index: Int) {
        productConnected(DJISDKManager.product())
    }
    func didUpdateDatabaseDownloadProgress(_ progress: Progress) {}

    // MARK: Vidéo

    func videoFeed(_ videoFeed: DJIVideoFeed, didUpdateVideoData videoData: Data) {
        if !loggedFirstPacket { loggedFirstPacket = true; AppLog.log("DJI", "1er paquet vidéo brut reçu (\(videoData.count) octets)") }
        var data = videoData
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            DJIVideoPreviewer.instance()?.push(base, length: Int32(videoData.count))
        }
    }

    func videoProcessorEnabled() -> Bool { true }

    func videoProcessFrame(_ frame: UnsafeMutablePointer<VideoFrameYUV>!) {
        // Décodage matériel : le CVPixelBuffer est exposé via cv_pixelbuffer_fastupload.
        guard let raw = frame?.pointee.cv_pixelbuffer_fastupload else {
            // Paquets reçus mais pas d'image décodée : c'est le symptôme à surveiller en Phase 0.
            if !loggedFirstFrame { AppLog.log("DJI", "Frame décodée SANS CVPixelBuffer (décodage matériel inactif ?)") ; loggedFirstFrame = true }
            return
        }
        let pb = Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeUnretainedValue()
        if !loggedFirstFrame {
            loggedFirstFrame = true
            AppLog.log("DJI", "1re image drone décodée : \(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb))")
        }
        frames.put(pb)
        lastFrameAt = Date()
    }

    // MARK: Télémétrie

    func flightController(_ fc: DJIFlightController, didUpdate state: DJIFlightControllerState) {
        var t = telemetry.value
        t.altitudeMeters = state.altitude
        t.horizontalSpeed = (Double(state.velocityX * state.velocityX + state.velocityY * state.velocityY)).squareRoot()
        t.satelliteCount = Int(state.satelliteCount)
        t.gpsSignalLevel = Int(state.gpsSignalLevel.rawValue)
        t.isFlying = state.isFlying
        t.flightTime = TimeInterval(state.flightTimeInSeconds)
        if let a = state.aircraftLocation {
            t.aircraftLatitude = a.coordinate.latitude
            t.aircraftLongitude = a.coordinate.longitude
            if let h = state.homeLocation { t.distanceToHomeMeters = a.distance(from: h) }
        }
        telemetry.send(t)
        refreshHealth()
    }

    func battery(_ battery: DJIBattery, didUpdate state: DJIBatteryState) {
        var t = telemetry.value
        t.batteryPercent = Int(state.chargeRemainingInPercent)
        telemetry.send(t)
        refreshHealth()
    }

    private func refreshHealth() {
        let t = telemetry.value
        let e = DroneChecklist.evaluate(battery: t.batteryPercent, satellites: t.satelliteCount, gpsLevel: t.gpsSignalLevel)
        var c = checklist.value
        c.batteryOK = e.battery
        c.gpsOK = e.gps
        if c != checklist.value { checklist.send(c) }
    }
}
#endif

// MARK: - Drone simulé (développement sans matériel / simulateur)

/// Génère une fausse vidéo + télémétrie. Permet de développer et tester la bascule
/// de sources, l'overlay et le HUD sans sortir le Mini 2.
final class SimulatedDrone: NSObject, DroneLink {
    let id: VideoSourceID = .drone
    let frames = LatestFrameBox()
    private let checklist = CurrentValueSubject<DroneChecklist, Never>(DroneChecklist())
    private let telemetry = CurrentValueSubject<DroneTelemetry, Never>(DroneTelemetry())
    var checklistPublisher: AnyPublisher<DroneChecklist, Never> { checklist.eraseToAnyPublisher() }
    var telemetryPublisher: AnyPublisher<DroneTelemetry, Never> { telemetry.eraseToAnyPublisher() }
    private var timer: Timer?
    private var t: Double = 0

    func prepare() {
        // Simule : SDK → radiocommande → drone, une étape par seconde.
        let steps: [(inout DroneChecklist) -> Void] = [
            { $0.sdkRegistered = true },
            { $0.remoteConnected = true },
            { $0.aircraftConnected = true; $0.modelName = "DJI Mini 2 (simulé)" },
        ]
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i + 1)) { [weak self] in
                guard let self else { return }
                var c = self.checklist.value; step(&c); self.checklist.send(c)
            }
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.frame() }
    }

    func stop() { timer?.invalidate(); frames.clear() }

    private func frame() {
        t += 1.0 / 30
        let size = CGSize(width: 1280, height: 720)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // sinon ×3 (écran Retina) : 3840×2160 à 30 i/s
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let hue = CGFloat((t / 20).truncatingRemainder(dividingBy: 1))
            UIColor(hue: hue, saturation: 0.5, brightness: 0.6, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let horizon = size.height / 2 + CGFloat(sin(t) * 40)
            UIColor(white: 0.15, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon))
        }
        if let pb = image.pixelBuffer() { frames.put(pb) }

        var c = checklist.value
        c.videoReceiving = c.aircraftConnected
        c.batteryOK = true; c.gpsOK = true
        if c != checklist.value { checklist.send(c) }

        telemetry.send(DroneTelemetry(altitudeMeters: 40 + sin(t / 5) * 20, horizontalSpeed: 4 + sin(t) * 2,
                                      distanceToHomeMeters: 120 + t, batteryPercent: max(10, 95 - Int(t / 20)),
                                      satelliteCount: 14, gpsSignalLevel: 5, flightTime: t, isFlying: true))
    }
}

extension UIImage {
    func pixelBuffer() -> CVPixelBuffer? {
        guard let cg = cgImage else { return nil }
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA, attrs, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: cg.width, height: cg.height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return pb
    }
}
