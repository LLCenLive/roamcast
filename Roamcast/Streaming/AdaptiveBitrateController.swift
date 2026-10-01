import Foundation

/// Bitrate adaptatif (CDC §11.1) – logique pure.
///
/// Stratégie AIMD « prudente » :
/// - congestion détectée → baisse multiplicative (×0,75) immédiate, plancher = minBitrate ;
/// - réseau sain pendant `stableSecondsBeforeRaise` → hausse additive (+250 kb/s),
///   jamais au-dessus du profil ;
/// - après une baisse, on attend plus longtemps avant de remonter (backoff).
struct AdaptiveBitrateController {
    struct Sample {
        /// Débit réellement envoyé sur la dernière seconde (bit/s).
        var sentBitsPerSecond: Int
        /// Octets en attente dans le buffer d'envoi RTMP.
        var queuedBytes: Int
        /// L'éditeur signale une insuffisance de bande passante.
        var publisherReportedCongestion: Bool
    }

    let minBitrate: Int
    let maxBitrate: Int
    var stepUp = 250_000
    var decreaseFactor = 0.75
    var stableSecondsBeforeRaise: Double = 10
    var queueCongestionBytes = 500_000   // ~1 s de vidéo à 4 Mb/s

    private(set) var target: Int
    private var healthySeconds: Double = 0
    private var backoffMultiplier: Double = 1
    private var consecutiveUnderSend = 0

    init(start: Int, min: Int, max: Int) {
        self.minBitrate = min
        self.maxBitrate = max
        self.target = Swift.min(Swift.max(start, min), max)
    }

    enum Decision: Equatable { case keep, decrease(Int), increase(Int) }

    /// À appeler toutes les secondes.
    mutating func update(_ s: Sample, dt: Double = 1) -> Decision {
        // Sous-émission soutenue : on n'arrive pas à sortir ce qu'on encode.
        if Double(s.sentBitsPerSecond) < Double(target) * 0.7 { consecutiveUnderSend += 1 }
        else { consecutiveUnderSend = 0 }

        let congested = s.publisherReportedCongestion
            || s.queuedBytes > queueCongestionBytes
            || consecutiveUnderSend >= 2

        if congested {
            healthySeconds = 0
            consecutiveUnderSend = 0
            backoffMultiplier = Swift.min(backoffMultiplier * 1.5, 6)
            let newTarget = Swift.max(minBitrate, Int(Double(target) * decreaseFactor))
            guard newTarget != target else { return .keep }
            target = newTarget
            return .decrease(newTarget)
        }

        healthySeconds += dt
        guard healthySeconds >= stableSecondsBeforeRaise * backoffMultiplier else { return .keep }
        healthySeconds = 0
        backoffMultiplier = Swift.max(1, backoffMultiplier * 0.8)
        let newTarget = Swift.min(maxBitrate, target + stepUp)
        guard newTarget != target else { return .keep }
        target = newTarget
        return .increase(newTarget)
    }

    /// Changement de profil pendant le live.
    mutating func reset(start: Int) {
        target = Swift.min(Swift.max(start, minBitrate), maxBitrate)
        healthySeconds = 0
        backoffMultiplier = 1
        consecutiveUnderSend = 0
    }
}
