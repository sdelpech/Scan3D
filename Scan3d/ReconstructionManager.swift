#if os(macOS)
import CoreMotion
import Foundation
import ImageIO
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
    /// Avancement global (0…1) des deux fichiers demandés (USDZ puis OBJ).
    private(set) var progress: Double = 0
    /// Étape en cours, en clair (« Alignement des photos »…).
    private(set) var stage = ""
    /// Fichier en cours de calcul (« USDZ » ou « OBJ »).
    private(set) var currentOutput = ""
    private(set) var startDate: Date?
    private(set) var estimatedRemainingTime: TimeInterval?
    /// Photos écartées par le moteur, avec la raison quand elle est connue.
    private(set) var rejectedPhotos: [String] = []
    /// Alertes sur la qualité du résultat, conservées après la fin du calcul.
    private(set) var warnings: [String] = []
    private var session: PhotogrammetrySession?

    /// Le Mac doit disposer d'un GPU compatible (tous les Mac Apple silicon le sont).
    var isSupported: Bool { PhotogrammetrySession.isSupported }

    /// Photos et réglages du dernier calcul réussi, réutilisés pour simplifier le modèle.
    private var lastRun: (imagesFolder: URL, configuration: PhotogrammetrySession.Configuration, usesGravity: Bool)?

    /// Une version simplifiée peut être calculée à partir du dernier modèle créé.
    var canSimplify: Bool { lastRun != nil }

    func reconstruct(
        imagesFolder: URL,
        detail: DetailLevel,
        isSequential: Bool,
        isHighSensitivity: Bool,
        isObjectMaskingEnabled: Bool,
        usesGravity: Bool
    ) async {
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = isSequential ? .sequential : .unordered
        configuration.featureSensitivity = isHighSensitivity ? .high : .normal
        configuration.isObjectMaskingEnabled = isObjectMaskingEnabled
        // Points de reprise du calcul (alignement, nuage de points…) : une simplification
        // ultérieure peut les réutiliser au lieu de tout recalculer. On repart à neuf à chaque
        // nouvelle reconstruction, car la série a pu changer (photos ajoutées).
        let checkpoint = Self.checkpointFolder(for: imagesFolder)
        try? FileManager.default.removeItem(at: checkpoint)
        try? FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        configuration.checkpointDirectory = checkpoint

        lastRun = nil
        let succeeded = await run(
            imagesFolder: imagesFolder,
            configuration: configuration,
            usesGravity: usesGravity,
            outputName: detail.rawValue,
            detail: detail.requestDetail
        )
        if succeeded {
            lastRun = (imagesFolder, configuration, usesGravity)
        }
    }

    /// Recrée le dernier modèle avec au plus `maximumTriangles` triangles. RealityKit refait
    /// le maillage et ses textures (plus propre qu'une simplification de l'OBJ après coup).
    func simplify(maximumTriangles: Int) async {
        guard let lastRun else { return }
        var configuration = lastRun.configuration
        var specification = PhotogrammetrySession.Configuration.CustomDetailSpecification()
        specification.maximumPolygonCount = UInt(maximumTriangles)
        configuration.customDetailSpecification = specification

        _ = await run(
            imagesFolder: lastRun.imagesFolder,
            configuration: configuration,
            usesGravity: lastRun.usesGravity,
            outputName: "simplifie-\(maximumTriangles / 1000)k",
            detail: .custom
        )
    }

    /// Lance le calcul de l'USDZ et de l'OBJ et suit son avancement. Renvoie `true` en cas de succès.
    private func run(
        imagesFolder: URL,
        configuration: PhotogrammetrySession.Configuration,
        usesGravity: Bool,
        outputName: String,
        detail: PhotogrammetrySession.Request.Detail
    ) async -> Bool {
        resetStatus()
        phase = .processing
        startDate = .now
        stage = "Lecture des photos"

        // Les résultats sont rangés dans Documents/Modeles 3D, et non dans le dossier des
        // photos : sinon les textures générées seraient relues comme photos au calcul suivant.
        let folder = URL.documentsDirectory
            .appending(path: "Modeles 3D", directoryHint: .isDirectory)
            .appending(path: "\(imagesFolder.lastPathComponent) - \(outputName)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        let files = ModelFiles(
            folder: folder,
            usdzURL: folder.appending(path: "modele.usdz"),
            objFolder: folder.appending(path: "OBJ", directoryHint: .isDirectory)
        )
        // Les identifiants des photos correspondent à leur rang dans le dossier trié.
        let photoNames = Scan.imageURLs(in: imagesFolder).map(\.lastPathComponent)
        func photoName(_ id: Int) -> String {
            photoNames.indices.contains(id) ? photoNames[id] : "Photo n°\(id + 1)"
        }
        // Rang du fichier demandé : la barre couvre l'USDZ (0…50 %) puis l'OBJ (50…100 %).
        func outputIndex(of request: PhotogrammetrySession.Request) -> Int {
            if case .modelFile(let url, _, _) = request, url == files.objFolder { 1 } else { 0 }
        }

        do {
            try FileManager.default.createDirectory(at: files.objFolder, withIntermediateDirectories: true)
            let session = try Self.makeSession(
                imagesFolder: imagesFolder,
                configuration: configuration,
                usesGravity: usesGravity
            )
            self.session = session
            // Une URL de dossier produit un OBJ (+ matériaux et textures), une URL .usdz un USDZ.
            try session.process(requests: [
                .modelFile(url: files.usdzURL, detail: detail),
                .modelFile(url: files.objFolder, detail: detail)
            ])

            var failure: String?
            for try await output in session.outputs {
                switch output {
                case .inputComplete:
                    stage = "Photos chargées, début du calcul"
                case .requestProgress(let request, let fractionComplete):
                    let index = outputIndex(of: request)
                    currentOutput = index == 0 ? "USDZ" : "OBJ"
                    progress = (Double(index) + fractionComplete) / 2
                case .requestProgressInfo(_, let info):
                    if let processingStage = info.processingStage {
                        stage = Self.title(of: processingStage)
                    }
                    estimatedRemainingTime = info.estimatedRemainingTime
                case .requestComplete(let request, _):
                    progress = Double(outputIndex(of: request) + 1) / 2
                case .invalidSample(let id, let reason):
                    rejectedPhotos.append("\(photoName(id)) : \(reason)")
                case .skippedSample(let id):
                    rejectedPhotos.append("\(photoName(id)) : inutilisable")
                case .automaticDownsampling:
                    warnings.append("Mémoire insuffisante : les photos ont été réduites, le modèle sera moins détaillé.")
                case .stitchingIncomplete:
                    warnings.append("Toutes les photos n'ont pas pu être assemblées : certaines zones (souvent le dessous) peuvent manquer. Complétez la série autour de ces zones.")
                case .requestError(_, let error):
                    failure = Self.message(for: error)
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
        estimatedRemainingTime = nil
        if case .finished = phase { return true }
        return false
    }

    /// Message compréhensible pour les erreurs du moteur. `processError` (non documentée,
    /// affichée « Error error 6 ») survient surtout quand les photos n'ont pas pu être alignées.
    private static func message(for error: any Error) -> String {
        guard String(describing: error).contains("processError") else {
            return error.localizedDescription
        }
        return """
            Le calcul a échoué : les photos n'ont pas pu être assemblées entre elles. Causes fréquentes : \
            objet tourné sur lui-même devant un décor fixe (tournez plutôt autour de l'objet immobile), \
            pas assez de recouvrement entre photos, objet trop uni ou brillant, main ou objet qui bouge \
            dans l'image. Essayez aussi « Détection renforcée » et désactivez « Photos prises dans l'ordre ».
            """
    }

    /// Dossier des points de reprise d'une série, dans les caches de l'app.
    private static func checkpointFolder(for imagesFolder: URL) -> URL {
        URL.cachesDirectory
            .appending(path: "Checkpoints", directoryHint: .isDirectory)
            .appending(path: imagesFolder.lastPathComponent, directoryHint: .isDirectory)
    }

    private static func title(of stage: PhotogrammetrySession.Output.ProcessingStage) -> String {
        switch stage {
        case .preProcessing: "Préparation des photos"
        case .imageAlignment: "Alignement des photos"
        case .pointCloudGeneration: "Création du nuage de points"
        case .meshGeneration: "Création du maillage"
        case .textureMapping: "Application des textures"
        case .optimization: "Optimisation du modèle"
        @unknown default: "Calcul en cours"
        }
    }

    /// Si les photos contiennent la gravité (prises avec Scan3D), on fournit chaque photo
    /// comme `PhotogrammetrySample` pour y ajouter ce vecteur. Sinon, lecture directe du dossier.
    /// Dans les deux cas, la profondeur intégrée aux HEIC est lue par RealityKit.
    private nonisolated static func makeSession(
        imagesFolder: URL,
        configuration: PhotogrammetrySession.Configuration,
        usesGravity: Bool
    ) throws -> PhotogrammetrySession {
        guard usesGravity else {
            return try PhotogrammetrySession(input: imagesFolder, configuration: configuration)
        }
        let urls = Scan.imageURLs(in: imagesFolder)
        let gravities = urls.map(gravity(in:))
        guard gravities.contains(where: { $0 != nil }) else {
            return try PhotogrammetrySession(input: imagesFolder, configuration: configuration)
        }

        // Séquence paresseuse : chaque photo n'est chargée en mémoire qu'au moment où
        // la session la lit (sur un thread d'arrière-plan).
        let samples = zip(urls, gravities).enumerated().lazy.compactMap { index, element -> PhotogrammetrySample? in
            let (url, gravity) = element
            guard let loaded = try? PhotogrammetrySample(contentsOf: url) else { return nil }
            // Même numérotation qu'en lecture de dossier (le rang de la photo), pour savoir
            // quel fichier le moteur écarte. On recopie ce que contient le fichier.
            var sample = PhotogrammetrySample(id: index, image: loaded.image)
            sample.metadata = loaded.metadata
            sample.depthDataMap = loaded.depthDataMap
            sample.objectMask = loaded.objectMask
            if let gravity {
                sample.gravity = CMAcceleration(x: gravity.x, y: gravity.y, z: gravity.z)
            }
            return sample
        }
        return try PhotogrammetrySession(input: samples, configuration: configuration)
    }

    /// Lit le vecteur gravité enregistré par l'app iPhone dans le commentaire EXIF.
    private nonisolated static func gravity(in url: URL) -> SIMD3<Double>? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let comment = exif[kCGImagePropertyExifUserComment] as? String
        else { return nil }
        return GravityMetadata.gravity(fromComment: comment)
    }

    func cancel() {
        session?.cancel()
    }

    func reset() {
        phase = .idle
        resetStatus()
    }

    private func resetStatus() {
        progress = 0
        stage = ""
        currentOutput = ""
        startDate = nil
        estimatedRemainingTime = nil
        rejectedPhotos = []
        warnings = []
    }
}
#endif
