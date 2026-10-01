import Foundation

/// Tout ce qui sort vers l'overlay Twitch passe par ici (CDC §6.1).
/// La position exacte n'existe QUE dans `LocationManager` et l'UI opérateur.
struct PublicLocation: Equatable {
    var label: String?        // texte affiché sur le stream, nil = rien

    static let hidden = PublicLocation(label: nil)
}

enum LocationPrivacy {
    /// Pas de la grille d'approximation, en degrés (~5,5 km en latitude).
    static let gridStepDegrees = 0.05

    /// Arrondit au centre de la cellule de grille : deux positions proches
    /// dans la même cellule donnent exactement la même valeur publique,
    /// ce qui empêche de retrouver la position par moyennage dans le temps.
    static func snapToGrid(latitude: Double, longitude: Double,
                           step: Double = gridStepDegrees) -> (lat: Double, lon: Double) {
        func snap(_ v: Double) -> Double { (floor(v / step) + 0.5) * step }
        return (snap(latitude), snap(longitude))
    }

    static func approximateLabel(latitude: Double, longitude: Double) -> String {
        let p = snapToGrid(latitude: latitude, longitude: longitude)
        let ns = p.lat >= 0 ? "N" : "S"
        let ew = p.lon >= 0 ? "E" : "O"
        return String(format: "≈ %.2f°%@ %.2f°%@", abs(p.lat), ns, abs(p.lon), ew)
    }

    /// Choisit le libellé de zone le moins précis parmi les infos du géocodeur.
    /// Priorité : point d'intérêt naturel (lac, massif) > commune > département/région.
    static func zoneLabel(areaOfInterest: String?, locality: String?, adminArea: String?) -> String? {
        if let a = areaOfInterest, !a.isEmpty { return a }
        if let l = locality, !l.isEmpty { return l }
        if let r = adminArea, !r.isEmpty { return r }
        return nil
    }
}
