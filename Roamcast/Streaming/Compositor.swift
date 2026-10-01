import CoreImage
import CoreVideo
import Metal
import UIKit

/// Données publiques affichées sur le stream. Rien de privé ne doit transiter ici
/// (pas de coordonnées précises, pas de diagnostics – CDC §9).
struct OverlayModel: Equatable {
    var brand = "LLCenLive"
    var location: String?
    var elapsed: String?
    var distance: String?
    var droneAltitude: String?
    var droneDistance: String?
    var droneSpeed: String?
    var droneBattery: String?
    var nowPlaying: String?
}

/// Compositeur Core Image (backend Metal).
/// Rend : source active (aspect-fill 16:9) → fondu de transition → overlays.
final class Compositor {
    let width: Int
    let height: Int
    var transitionDuration: CFTimeInterval = 0.45

    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var lastOutput: CIImage?
    private var transitionFrom: CIImage?
    private var transitionStart: CFTimeInterval = 0
    private var currentScene: SceneKind?

    private let overlayLock = NSLock()
    private var overlayImage: CIImage?
    private var overlayModel = OverlayModel()
    private let overlayRenderer: OverlayRenderer
    private var slateCache: [String: CIImage] = [:]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let device = MTLCreateSystemDefaultDevice()
        context = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
            ?? CIContext(options: [.useSoftwareRenderer: false])
        overlayRenderer = OverlayRenderer(size: CGSize(width: width, height: height))
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    /// Appelé hors du thread de rendu (≈1 Hz) – le rendu texte est coûteux, on le cache.
    func updateOverlay(_ model: OverlayModel) {
        overlayLock.lock()
        let unchanged = model == overlayModel
        overlayLock.unlock()
        guard !unchanged else { return }
        let img = overlayRenderer.render(model)
        overlayLock.lock()
        overlayModel = model
        overlayImage = img
        overlayLock.unlock()
    }

    /// Appelé par le FrameClock à chaque tick (30 Hz).
    func compose(scene: SceneKind, source: CVPixelBuffer?, now: CFTimeInterval) -> CVPixelBuffer? {
        if scene != currentScene {
            // Début de transition : on fige la dernière image envoyée.
            transitionFrom = lastOutput
            transitionStart = now
            currentScene = scene
        }

        var base: CIImage
        switch scene {
        case .live:
            if let source {
                base = aspectFill(CIImage(cvPixelBuffer: source))
            } else {
                // Source muette (drone qui décroche, caméra interrompue) :
                // on reste à l'antenne avec un écran brandé, jamais d'image noire figée.
                base = slate("Signal vidéo en cours de rétablissement…")
            }
        case .slate(let message):
            base = slate(message)
        }

        if let from = transitionFrom {
            let t = min(1, (now - transitionStart) / transitionDuration)
            if t >= 1 {
                transitionFrom = nil
            } else {
                let filter = CIFilter(name: "CIDissolveTransition", parameters: [
                    kCIInputImageKey: from,
                    kCIInputTargetImageKey: base,
                    kCIInputTimeKey: easeInOut(t),
                ])
                base = filter?.outputImage ?? base
            }
        }

        lastOutput = base
        var out = base
        overlayLock.lock()
        let overlay = overlayImage
        overlayLock.unlock()
        if let overlay { out = overlay.composited(over: out) }

        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        context.render(out, to: pb, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pb
    }

    // MARK: - Helpers

    private func aspectFill(_ img: CIImage) -> CIImage {
        let e = img.extent
        let scale = max(CGFloat(width) / e.width, CGFloat(height) / e.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - CGFloat(width)) / 2 + scaled.extent.minX
        let dy = (scaled.extent.height - CGFloat(height)) / 2 + scaled.extent.minY
        return scaled
            .transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func slate(_ message: String) -> CIImage {
        if let cached = slateCache[message] { return cached }
        let img = overlayRenderer.renderSlate(message: message, brand: overlayModel.brand)
        slateCache[message] = img
        return img
    }

    private func easeInOut(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
}

/// Dessin des overlays en CoreGraphics → CIImage (mis en cache).
final class OverlayRenderer {
    let size: CGSize
    private var scale: CGFloat { size.height / 1080 }   // tout est pensé en 1080p

    init(size: CGSize) { self.size = size }

    func render(_ m: OverlayModel) -> CIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let s = scale
            // Bandeau haut-gauche : marque + lieu
            var left: [String] = [m.brand]
            if let loc = m.location { left.append("📍 \(loc)") }
            drawPill(left.joined(separator: "  ·  "), at: CGPoint(x: 40 * s, y: 36 * s), fontSize: 30 * s)

            // Haut-droite : durée / distance marchée
            let right = [m.elapsed, m.distance].compactMap { $0 }
            if !right.isEmpty {
                drawPill(right.joined(separator: "  ·  "), at: CGPoint(x: size.width - 40 * s, y: 36 * s),
                         fontSize: 30 * s, alignRight: true)
            }

            // Bas-gauche : télémétrie drone (discrète, CDC §9)
            let telemetry = [
                m.droneAltitude.map { "ALT \($0)" },
                m.droneDistance.map { "DIST \($0)" },
                m.droneSpeed.map { "VIT \($0)" },
                m.droneBattery.map { "BAT \($0)" },
            ].compactMap { $0 }
            if !telemetry.isEmpty {
                drawPill(telemetry.joined(separator: "   "),
                         at: CGPoint(x: 40 * s, y: size.height - 96 * s), fontSize: 32 * s, mono: true)
            }

            if let track = m.nowPlaying {
                drawPill("♪ \(track)", at: CGPoint(x: size.width - 40 * s, y: size.height - 96 * s),
                         fontSize: 24 * s, alignRight: true)
            }
        }
        return CIImage(image: image)
    }

    func renderSlate(message: String, brand: String) -> CIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [UIColor(red: 0.07, green: 0.09, blue: 0.16, alpha: 1).cgColor,
                          UIColor(red: 0.20, green: 0.10, blue: 0.35, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                             end: CGPoint(x: size.width, y: size.height), options: [])
            let s = scale
            draw(brand, font: .systemFont(ofSize: 96 * s, weight: .heavy), color: .white,
                 centerY: size.height / 2 - 50 * s)
            draw(message, font: .systemFont(ofSize: 40 * s, weight: .medium),
                 color: UIColor.white.withAlphaComponent(0.8), centerY: size.height / 2 + 60 * s)
        }
        return CIImage(image: image) ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
    }

    private func draw(_ text: String, font: UIFont, color: UIColor, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: (size.width - sz.width) / 2, y: centerY - sz.height / 2),
                                withAttributes: attrs)
    }

    private func drawPill(_ text: String, at p: CGPoint, fontSize: CGFloat,
                          alignRight: Bool = false, mono: Bool = false) {
        let font = mono ? UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
                        : UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let sz = (text as NSString).size(withAttributes: attrs)
        let padX = fontSize * 0.6, padY = fontSize * 0.3
        let x = alignRight ? p.x - sz.width - padX * 2 : p.x
        let rect = CGRect(x: x, y: p.y, width: sz.width + padX * 2, height: sz.height + padY * 2)
        UIColor.black.withAlphaComponent(0.45).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + padX, y: rect.minY + padY), withAttributes: attrs)
    }
}
