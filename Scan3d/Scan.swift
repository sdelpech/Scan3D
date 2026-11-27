import Foundation

/// Une série de photos d'un objet, enregistrée dans son propre dossier.
struct Scan: Identifiable, Hashable {
    let folder: URL
    let date: Date

    var id: URL { folder }
    var imagesFolder: URL { folder.appending(path: "Images", directoryHint: .isDirectory) }

    /// Photos de la série, dans l'ordre de prise de vue.
    var imageURLs: [URL] {
        Scan.imageURLs(in: imagesFolder)
    }

    /// Dossier racine contenant toutes les séries (dans Documents).
    static var rootFolder: URL {
        URL.documentsDirectory.appending(path: "Scans", directoryHint: .isDirectory)
    }

    /// Crée un nouveau dossier de série horodaté.
    static func makeNew() throws -> Scan {
        let date = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = rootFolder.appending(path: formatter.string(from: date), directoryHint: .isDirectory)
        let scan = Scan(folder: folder, date: date)
        try FileManager.default.createDirectory(at: scan.imagesFolder, withIntermediateDirectories: true)
        return scan
    }

    /// Charge toutes les séries existantes, de la plus récente à la plus ancienne.
    static func loadAll() -> [Scan] {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: rootFolder, withIntermediateDirectories: true)
        let folders = (try? fileManager.contentsOfDirectory(
            at: rootFolder,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        return folders
            .map { folder in
                let values = try? folder.resourceValues(forKeys: [.creationDateKey])
                return Scan(folder: folder, date: values?.creationDate ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
    }

    /// Liste les images (HEIC, JPEG, PNG) d'un dossier, triées par nom.
    static func imageURLs(in folder: URL) -> [URL] {
        let extensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        return files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Numéro de la prochaine photo « IMG_xxxx » : un de plus que le plus grand existant.
    static func nextImageNumber(in folder: URL) -> Int {
        let numbers = imageURLs(in: folder).compactMap { url -> Int? in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("IMG_") else { return nil }
            return Int(name.dropFirst(4))
        }
        return (numbers.max() ?? 0) + 1
    }
}

/// Vecteur gravité de l'iPhone au moment de la photo, stocké dans le commentaire EXIF
/// (il voyage ainsi avec la photo, y compris par AirDrop).
nonisolated enum GravityMetadata {
    private static let prefix = "Scan3D gravity:"

    static func comment(for gravity: SIMD3<Double>) -> String {
        "\(prefix)\(gravity.x),\(gravity.y),\(gravity.z)"
    }

    static func gravity(fromComment comment: String) -> SIMD3<Double>? {
        guard comment.hasPrefix(prefix) else { return nil }
        let values = comment.dropFirst(prefix.count).split(separator: ",").compactMap { Double($0) }
        guard values.count == 3 else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }
}
