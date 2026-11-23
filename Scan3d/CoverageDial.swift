#if os(iOS)
import SwiftUI

/// Cadran de couverture : 3 anneaux (hauteur basse à l'extérieur, haute au centre)
/// de 24 cases. Vert = photographié, blanc = position actuelle, gris = à faire.
struct CoverageDial: View {
    let tracker: CoverageTracker

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxRadius = min(size.width, size.height) / 2
            let ringWidth = maxRadius / 4.2
            let sectorAngle = 360.0 / Double(CoverageTracker.sectorCount)

            for ring in CoverageTracker.Ring.allCases {
                // Anneau extérieur = basse, intérieur = haute.
                let index = CoverageTracker.Ring.allCases.count - 1 - ring.rawValue
                let radius = maxRadius - ringWidth / 2 - CGFloat(index) * (ringWidth + 3)
                let coveredSectors = tracker.covered[ring, default: []]

                for sector in 0..<CoverageTracker.sectorCount {
                    // Le secteur 0 est en haut, on tourne dans le sens horaire.
                    let start = Angle.degrees(Double(sector) * sectorAngle - 90 + 1)
                    let end = Angle.degrees(Double(sector + 1) * sectorAngle - 90 - 1)
                    var path = Path()
                    path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)

                    let isCurrent = ring == tracker.currentRing && sector == tracker.currentSector
                    let color: Color = if isCurrent {
                        .white
                    } else if coveredSectors.contains(sector) {
                        .green
                    } else {
                        .white.opacity(0.25)
                    }
                    context.stroke(path, with: .color(color), lineWidth: ringWidth)
                }
            }
        }
        .frame(width: 120, height: 120)
        .padding(8)
        .background(.ultraThinMaterial, in: .circle)
        .accessibilityElement()
        .accessibilityLabel("Couverture du scan")
        .accessibilityValue(Text(tracker.overallProgress, format: .percent.precision(.fractionLength(0))))
    }
}
#endif
