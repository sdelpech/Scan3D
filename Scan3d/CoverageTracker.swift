#if os(iOS)
import CoreMotion
import Foundation
import Observation
import simd

/// Suit, grâce aux capteurs de mouvement, les angles de vue déjà photographiés
/// autour de l'objet : 3 hauteurs × 24 secteurs de 15°.
@Observable
final class CoverageTracker {
    /// Hauteur de prise de vue, déduite de l'inclinaison de l'iPhone.
    enum Ring: Int, CaseIterable {
        case low, middle, high

        var title: String {
            switch self {
            case .low: "basse"
            case .middle: "moyenne"
            case .high: "haute"
            }
        }
    }

    static let sectorCount = 24

    private(set) var covered: [Ring: Set<Int>] = [:]
    private(set) var currentSector = 0
    private(set) var currentRing: Ring = .middle

    private let motion = CMMotionManager()
    private var azimuth: Double = 0
    /// Direction visée par l'objectif (repère du monde) et celle de la dernière photo.
    private var direction = SIMD3<Double>(1, 0, 0)
    private var lastPhotoDirection: SIMD3<Double>?
    /// Direction de la première photo : elle devient le secteur 0.
    private var origin: Double?

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    var isCurrentPositionCovered: Bool {
        covered[currentRing, default: []].contains(currentSector)
    }

    /// Angle (en degrés) dont l'iPhone a tourné depuis la dernière photo.
    var degreesSinceLastPhoto: Double {
        guard let last = lastPhotoDirection else { return .infinity }
        let cosine = max(-1, min(1, simd_dot(direction, last)))
        return acos(cosine) * 180 / .pi
    }

    var totalCovered: Int {
        covered.values.reduce(0) { $0 + $1.count }
    }

    /// Part couverte (0…1) d'une hauteur donnée.
    func fraction(of ring: Ring) -> Double {
        Double(covered[ring, default: []].count) / Double(Self.sectorCount)
    }

    /// Couverture globale : l'anneau du milieu compte double car c'est le plus utile.
    var overallProgress: Double {
        (fraction(of: .middle) * 2 + fraction(of: .low) + fraction(of: .high)) / 4
    }

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
            guard let data else { return }
            // Les mises à jour arrivent sur la file principale.
            MainActor.assumeIsolated {
                self?.update(with: data)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    /// Marque la position actuelle comme photographiée.
    func recordPhoto() {
        if origin == nil {
            origin = azimuth
            currentSector = sector(for: azimuth)
        }
        covered[currentRing, default: []].insert(currentSector)
        lastPhotoDirection = direction
    }

    private func update(with data: CMDeviceMotion) {
        let g = data.gravity
        let m = data.attitude.rotationMatrix

        // Inclinaison de l'objectif arrière : -90° = visée vers le bas, 0° = à l'horizontale.
        let elevation = asin(max(-1, min(1, g.z))) * 180 / .pi
        currentRing = switch elevation {
        case ..<(-50): .high
        case ..<(-20): .middle
        default: .low
        }

        // Axe Z de l'iPhone exprimé dans le repère du monde. On choisit la lecture
        // (lignes ou colonnes de la matrice) cohérente avec la gravité mesurée.
        let rowsMatchGravity = abs(m.m13 + g.x) <= abs(m.m31 + g.x)
        let zx = rowsMatchGravity ? m.m31 : m.m13
        let zy = rowsMatchGravity ? m.m32 : m.m23

        // L'objectif arrière vise selon -Z : on en déduit la direction visée.
        direction = simd_normalize(SIMD3(-zx, -zy, -m.m33))
        azimuth = atan2(-zy, -zx)
        currentSector = sector(for: azimuth)
    }

    private func sector(for angle: Double) -> Int {
        let relative = angle - (origin ?? 0)
        let fullTurn = 2 * Double.pi
        let normalized = (relative.truncatingRemainder(dividingBy: fullTurn) + fullTurn)
            .truncatingRemainder(dividingBy: fullTurn)
        return Int(normalized / fullTurn * Double(Self.sectorCount)) % Self.sectorCount
    }
}
#endif
