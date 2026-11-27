#if os(iOS)
import AVFoundation
import ImageIO
import UIKit
import Observation
import os

private let logger = Logger(subsystem: "com.sylvain.Scan3D", category: "Camera")

/// Pilote la caméra arrière et enregistre les photos en pleine résolution
/// dans le dossier d'une série, pour une reconstruction ultérieure sur Mac.
@Observable
final class CameraModel {
    enum Status {
        case idle
        case running
        case unauthorized
        case unavailable
    }

    let session = AVCaptureSession()
    private(set) var status: Status = .idle
    private(set) var photoCount = 0
    private(set) var isTakingPhoto = false
    /// Miniature de la dernière photo, affichée en transparence pour cadrer la suivante.
    private(set) var lastPhoto: UIImage?
    var errorMessage: String?

    private let photoOutput = AVCapturePhotoOutput()
    private var folder: URL?
    // Le délégué doit rester en mémoire jusqu'à la fin de la prise de vue.
    private var pendingDelegate: PhotoCaptureDelegate?

    func start(savingTo folder: URL) async {
        self.folder = folder
        let existing = Scan.imageURLs(in: folder)
        photoCount = existing.count
        // Série complétée : la dernière photo existante sert de calque pour reprendre le cadrage.
        if lastPhoto == nil, let last = existing.last {
            lastPhoto = await Task.detached {
                (try? Data(contentsOf: last)).flatMap(Self.thumbnail(from:))
            }.value
        }

        logger.info("Démarrage caméra – autorisation : \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            logger.error("Accès caméra refusé")
            status = .unauthorized
            return
        }
        logger.info("Accès caméra accordé, configuration…")
        guard configureSession() else {
            logger.error("Configuration de la caméra impossible")
            status = .unavailable
            return
        }

        // `startRunning()` est bloquant : on l'exécute hors du thread principal.
        let session = session
        logger.info("Configuration OK, démarrage du flux…")
        await Task.detached { session.startRunning() }.value
        logger.info("Flux démarré : isRunning = \(session.isRunning)")
        status = .running
    }

    func stop() {
        let session = session
        Task.detached { session.stopRunning() }
        status = .idle
    }

    private func configureSession() -> Bool {
        guard session.inputs.isEmpty else { return true }
        // La caméra LiDAR fournit une profondeur en mètres : le modèle sort à l'échelle réelle.
        // Sans LiDAR, on garde la caméra grand-angle (sans profondeur).
        guard
            let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            logger.error("Aucune caméra arrière / entrée impossible")
            return false
        }

        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        session.commitConfiguration()

        if device.deviceType == .builtInLiDARDepthCamera {
            enableDepth(on: device)
        }

        // La photogrammétrie profite de la résolution et de la qualité maximales.
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let largest = device.activeFormat.supportedMaxPhotoDimensions
            .max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = largest
        }
        return true
    }

    /// Choisit le format photo le plus défini qui fournit une profondeur (et non une disparité),
    /// puis active la livraison de la profondeur, qui sera intégrée au fichier HEIC.
    private func enableDepth(on device: AVCaptureDevice) {
        let depthTypes: Set<FourCharCode> = [kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DepthFloat16]
        func depthFormats(of format: AVCaptureDevice.Format) -> [AVCaptureDevice.Format] {
            format.supportedDepthDataFormats.filter { depthTypes.contains($0.formatDescription.mediaSubType.rawValue) }
        }
        func photoPixels(of format: AVCaptureDevice.Format) -> Int32 {
            format.supportedMaxPhotoDimensions.map { $0.width * $0.height }.max() ?? 0
        }

        guard
            let format = device.formats
                .filter({ !depthFormats(of: $0).isEmpty })
                .max(by: { photoPixels(of: $0) < photoPixels(of: $1) }),
            let depthFormat = depthFormats(of: format)
                .max(by: { $0.formatDescription.dimensions.width < $1.formatDescription.dimensions.width })
        else {
            logger.error("Aucun format avec profondeur sur la caméra LiDAR")
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeDepthDataFormat = depthFormat
            device.unlockForConfiguration()
        } catch {
            logger.error("Configuration de la profondeur impossible : \(error.localizedDescription)")
            return
        }
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
        logger.info("Profondeur LiDAR : \(self.photoOutput.isDepthDataDeliveryEnabled)")
    }

    /// Prend une photo et l'enregistre. Renvoie `true` si elle a bien été sauvegardée.
    /// - Parameter gravity: vecteur gravité de l'iPhone (repère de l'appareil) au déclenchement,
    ///   enregistré dans les métadonnées pour aider la reconstruction.
    @discardableResult
    func takePhoto(gravity: SIMD3<Double>? = nil) async -> Bool {
        guard status == .running, !isTakingPhoto, let folder else { return false }
        isTakingPhoto = true
        defer {
            isTakingPhoto = false
            pendingDelegate = nil
        }

        let useHEIC = photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let settings = useHEIC
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliveryEnabled

        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // Portrait
        }

        do {
            let data = try await withCheckedThrowingContinuation { continuation in
                let delegate = PhotoCaptureDelegate(gravity: gravity, continuation: continuation)
                pendingDelegate = delegate
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
            // On repart du plus grand numéro existant : une série complétée après suppression
            // d'une photo n'écrase jamais une photo existante.
            let name = String(format: "IMG_%04d.%@", Scan.nextImageNumber(in: folder), useHEIC ? "heic" : "jpg")
            try data.write(to: folder.appending(path: name))
            photoCount += 1
            lastPhoto = await Task.detached { Self.thumbnail(from: data) }.value
            return true
        } catch {
            errorMessage = "Photo non enregistrée : \(error.localizedDescription)"
            return false
        }
    }
}

extension CameraModel {
    /// Décode une version réduite de la photo, orientée correctement (rapide, peu de mémoire).
    nonisolated static func thumbnail(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Reçoit le résultat d'une prise de vue et le transmet à la continuation.
/// La gravité est ajoutée aux métadonnées EXIF ; la profondeur est intégrée automatiquement.
nonisolated private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate,
    AVCapturePhotoFileDataRepresentationCustomizer {
    private let gravity: SIMD3<Double>?
    private let continuation: CheckedContinuation<Data, Error>

    init(gravity: SIMD3<Double>?, continuation: CheckedContinuation<Data, Error>) {
        self.gravity = gravity
        self.continuation = continuation
    }

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        guard let gravity else { return nil }
        var metadata = photo.metadata
        var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifUserComment as String] = GravityMetadata.comment(for: gravity)
        metadata[kCGImagePropertyExifDictionary as String] = exif
        return metadata
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            continuation.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation(with: self) {
            continuation.resume(returning: data)
        } else {
            continuation.resume(throwing: CocoaError(.fileWriteUnknown))
        }
    }
}
#endif
