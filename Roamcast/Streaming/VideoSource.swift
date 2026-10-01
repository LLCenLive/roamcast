import CoreVideo
import QuartzCore

/// Une source vidéo pousse ses images ici ; le moteur les *tire* à cadence fixe.
///
/// C'est le découplage qui rend la bascule iPhone ↔ drone sans coupure possible :
/// l'encodeur ne dépend jamais du rythme (ni de l'existence) d'une source.
final class LatestFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var timestamp: CFTimeInterval = 0

    func put(_ pb: CVPixelBuffer) {
        lock.lock(); buffer = pb; timestamp = CACurrentMediaTime(); lock.unlock()
    }

    /// Renvoie nil si la dernière image est plus vieille que `maxAge` (source figée ou perdue).
    func latest(maxAge: CFTimeInterval) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer, CACurrentMediaTime() - timestamp <= maxAge else { return nil }
        return buffer
    }

    func clear() { lock.lock(); buffer = nil; lock.unlock() }
}

enum VideoSourceID: String, Equatable {
    case iPhoneCamera
    case drone
}

protocol VideoSource: AnyObject {
    var id: VideoSourceID { get }
    var frames: LatestFrameBox { get }
    func start()
    func stop()
}

/// Ce que le compositeur doit dessiner à l'instant t.
enum SceneKind: Equatable {
    case live(VideoSourceID)
    /// Écran de transition brandé (préparation drone, perte de signal…).
    case slate(message: String)
}
