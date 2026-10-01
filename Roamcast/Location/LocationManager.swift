import Combine
import CoreLocation

/// GPS de la balade (CDC §6). Les coordonnées exactes ne sortent jamais d'ici
/// vers l'overlay : seule `publicLocation` est exposée au stream.
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var current: CLLocation?            // privé : HUD opérateur
    @Published private(set) var track: [CLLocation] = []        // tracé local
    @Published private(set) var distanceMeters: CLLocationDistance = 0
    @Published private(set) var publicLocation: PublicLocation = .hidden
    @Published private(set) var droneTakeoffPoint: CLLocation?
    @Published var mode: PublicLocationMode = .zone { didSet { refreshPublic(force: true) } }

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocode: (date: Date, location: CLLocation)?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    func resetTrack() { track = []; distanceMeters = 0; droneTakeoffPoint = nil }

    func markDroneTakeoff() { droneTakeoffPoint = current }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for loc in locations where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 30 {
                if let last = track.last {
                    let d = loc.distance(from: last)
                    // Filtre le bruit GPS à l'arrêt.
                    if d > max(3, loc.horizontalAccuracy / 2) { distanceMeters += d; track.append(loc) }
                } else {
                    track.append(loc)
                }
                current = loc
            }
            refreshPublic(force: false)
        }
    }

    private func refreshPublic(force: Bool) {
        guard let loc = current else { publicLocation = .hidden; return }
        switch mode {
        case .hidden:
            publicLocation = .hidden
        case .approximate:
            publicLocation = PublicLocation(label: LocationPrivacy.approximateLabel(
                latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude))
        case .zone:
            // Géocodage inverse limité (quota Apple) : toutes les 2 min ou tous les 500 m.
            if !force, let g = lastGeocode,
               Date().timeIntervalSince(g.date) < 120, loc.distance(from: g.location) < 500 { return }
            lastGeocode = (Date(), loc)
            geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
                let p = placemarks?.first
                let label = LocationPrivacy.zoneLabel(areaOfInterest: p?.areasOfInterest?.first,
                                                      locality: p?.locality,
                                                      adminArea: p?.administrativeArea)
                Task { @MainActor in
                    guard let self, self.mode == .zone else { return }
                    self.publicLocation = PublicLocation(label: label)
                }
            }
        }
    }
}
