#if os(macOS)
import Foundation
import Observation
import RealityKit

/// Niveaux de détail proposés pour le modèle généré sur Mac.
enum DetailLevel: String, CaseIterable, Identifiable {
    case preview, reduced, medium, full, raw

    var id: Self { self }

    var title: String {
        switch self {
        case .preview: "Aperçu (rapide)"
        case .reduced: "Réduit (mobile / web)"
        case .medium: "Moyen"
        case .full: "Complet (recommandé pour la CAO)"
        case .raw: "Brut (maillage le plus fin, très lourd)"
        }
    }

    var requestDetail: PhotogrammetrySession.Request.Detail {
        switch self {
        case .preview: .preview
        case .reduced: .reduced
        case .medium: .medium
        case .full: .full
        case .raw: .raw
        }
    }
}

/// Fichiers produits par une reconstruction.
struct ModelFiles {
    /// Dossier « <photos> - <détail> » créé dans Documents/Modeles 3D.
    let folder: URL
    /// Modèle USDZ, pour l'aperçu 3D et la mesure.
    let usdzURL: URL
    /// Sous-dossier contenant l'OBJ, ses matériaux et ses textures, pour la CAO.
    let objFolder: URL

    var objURL: URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: objFolder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension.lowercased() == "obj" && !$0.lastPathComponent.contains("-mm") }
    }
}

/// Transforme un dossier de photos en modèle 3D (USDZ + OBJ) avec `PhotogrammetrySession`.
@Observable
final class ReconstructionManager {
    enum Phase {
        case idle
        case processing
        case finished(ModelFiles)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private var session: PhotogrammetrySession?

    /// Le Mac doit disposer d'un GPU compatible (tous les Mac Apple silicon le sont).
    var isSupported: Bool { PhotogrammetrySession.isSupported }

    func reconstruct(
        imagesFolder: URL,
        detail: DetailLevel,
        isSequential: Bool,
        isHighSensitivity: Bool,
        isObjectMaskingEnabled: Bool
    ) async {
        progress = 0
        phase = .processing

        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = isSequential ? .sequential : .unordered
        configuration.featureSensitivity = isHighSensitivity ? .high : .normal
        configuration.isObjectMaskingEnabled = isObjectMaskingEnabled

        // Les résultats sont rangés dans Documents/Modeles 3D, et non dans le dossier des
        // photos : sinon les textures générées seraient relues comme photos au calcul suivant.
        let folder = URL.documentsDirectory
            .appending(path: "Modeles 3D", directoryHint: .isDirectory)
            .appending(path: "\(imagesFolder.lastPathComponent) - \(detail.rawValue)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        let files = ModelFiles(
            folder: folder,
            usdzURL: folder.appending(path: "modele.usdz"),
            objFolder: folder.appending(path: "OBJ", directoryHint: .isDirectory)
        )

        do {
            try FileManager.default.createDirectory(at: files.objFolder, withIntermediateDirectories: true)
            let session = try PhotogrammetrySession(input: imagesFolder, configuration: configuration)
            self.session = session
            // Une URL de dossier produit un OBJ (+ matériaux et textures), une URL .usdz un USDZ.
            try session.process(requests: [
                .modelFile(url: files.usdzURL, detail: detail.requestDetail),
                .modelFile(url: files.objFolder, detail: detail.requestDetail)
            ])

            var failure: String?
            for try await output in session.outputs {
                switch output {
                case .requestProgress(_, let fractionComplete):
                    progress = fractionComplete
                case .requestError(_, let error):
                    failure = error.localizedDescription
                case .processingComplete:
                    phase = failure.map { .failed($0) } ?? .finished(files)
                case .processingCancelled:
                    phase = .idle
                default:
                    break
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
        session = nil
    }

    func cancel() {
        session?.cancel()
    }

    func reset() {
        phase = .idle
        progress = 0
    }
}
#endif
