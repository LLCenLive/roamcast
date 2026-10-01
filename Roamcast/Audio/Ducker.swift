import Foundation

/// Ducking automatique (CDC §7.1) – logique pure, appelée à chaque buffer micro.
///
/// - Détection de voix : RMS du micro au-dessus d'un seuil (avec hystérésis).
/// - Attaque rapide (la musique baisse en ~80 ms), maintien pendant `holdSeconds`
///   pour ne pas « pomper » entre deux mots, puis remontée sur `releaseSeconds`.
struct Ducker {
    var settings: DuckingSettings
    var openThresholdDB: Float = -38     // voix détectée au-dessus
    var closeThresholdDB: Float = -44    // silence en dessous (hystérésis)
    var attackSeconds: Float = 0.08
    var holdSeconds: Float = 0.6

    private(set) var currentGainDB: Float = 0
    private(set) var voiceActive = false
    private var holdRemaining: Float = 0

    init(settings: DuckingSettings) { self.settings = settings }

    /// - Parameters:
    ///   - micLevelDB: niveau RMS du buffer micro en dBFS
    ///   - dt: durée du buffer en secondes
    /// - Returns: gain linéaire à appliquer à la musique (0…1)
    mutating func process(micLevelDB: Float, dt: Float) -> Float {
        guard settings.enabled else {
            currentGainDB = 0
            voiceActive = false
            return 1
        }

        if micLevelDB >= openThresholdDB {
            voiceActive = true
            holdRemaining = holdSeconds
        } else if micLevelDB < closeThresholdDB {
            holdRemaining = max(0, holdRemaining - dt)
            if holdRemaining == 0 { voiceActive = false }
        } // entre les deux seuils : on garde l'état courant

        let target: Float = voiceActive ? settings.reductionDB : 0
        let span = abs(settings.reductionDB)
        if span > 0 {
            if currentGainDB > target {
                // attaque : descendre de `span` dB en attackSeconds
                currentGainDB = max(target, currentGainDB - span * dt / max(attackSeconds, 0.001))
            } else if currentGainDB < target {
                // remontée progressive
                currentGainDB = min(target, currentGainDB + span * dt / max(settings.releaseSeconds, 0.001))
            }
        } else {
            currentGainDB = 0
        }
        return Self.linear(fromDB: currentGainDB)
    }

    static func linear(fromDB db: Float) -> Float { powf(10, db / 20) }

    static func rmsDB(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return -160 }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = sqrtf(sum / Float(count))
        return rms > 0 ? 20 * log10f(rms) : -160
    }
}
