#if os(macOS)
import Foundation
import simd

/// Outils de lecture et de mise à l'échelle des fichiers OBJ (texte),
/// pour obtenir des modèles aux dimensions réelles utilisables en CAO.
nonisolated enum OBJTools {
    /// Boîte englobante des sommets d'un OBJ, dans les unités du fichier.
    struct Bounds {
        var min = SIMD3<Double>(repeating: .infinity)
        var max = SIMD3<Double>(repeating: -.infinity)
        var extents: SIMD3<Double> { max - min }
        var largestExtent: Double { Swift.max(extents.x, extents.y, extents.z) }
    }

    static func bounds(of url: URL) throws -> Bounds {
        let text = try String(contentsOf: url, encoding: .utf8)
        var bounds = Bounds()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let vertex = parseVertex(line) else { continue }
            bounds.min = simd_min(bounds.min, vertex)
            bounds.max = simd_max(bounds.max, vertex)
        }
        return bounds
    }

    /// Écrit une copie de l'OBJ dont tous les sommets sont multipliés par `factor`.
    /// Les autres lignes (faces, normales, textures, matériaux) sont conservées telles quelles.
    static func writeScaledCopy(of url: URL, factor: Double, to output: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var result = ""
        result.reserveCapacity(text.utf8.count + text.utf8.count / 10)
        result += "# Mis à l'échelle par Scan3D : unités = millimètres\n"

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let vertex = parseVertex(line) {
                let scaled = vertex * factor
                // Conserve d'éventuelles composantes supplémentaires (couleurs de sommet).
                let extra = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(4)
                result += String(format: "v %.4f %.4f %.4f", scaled.x, scaled.y, scaled.z)
                if !extra.isEmpty {
                    result += " " + extra.joined(separator: " ")
                }
                result += "\n"
            } else {
                result += line
                result += "\n"
            }
        }
        try result.write(to: output, atomically: true, encoding: .utf8)
    }

    /// Lit une ligne de sommet « v x y z ». Renvoie `nil` pour toute autre ligne.
    private static func parseVertex(_ line: Substring) -> SIMD3<Double>? {
        guard line.hasPrefix("v ") else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4,
              let x = Double(parts[1]), let y = Double(parts[2]), let z = Double(parts[3])
        else { return nil }
        return SIMD3(x, y, z)
    }
}
#endif
