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
        photoCount = Scan.imageURLs(in: folder).count

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
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
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

        // La photogrammétrie profite de la résolution et de la qualité maximales.
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let largest = device.activeFormat.supportedMaxPhotoDimensions
            .max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = largest
        }
        return true
    }

    /// Prend une photo et l'enregistre. Renvoie `true` si elle a bien été sauvegardée.
    @discardableResult
    func takePhoto() async -> Bool {
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

        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // Portrait
        }

        do {
            let data = try await withCheckedThrowingContinuation { continuation in
                let delegate = PhotoCaptureDelegate(continuation: continuation)
                pendingDelegate = delegate
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
            let name = String(format: "IMG_%04d.%@", photoCount + 1, useHEIC ? "heic" : "jpg")
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
nonisolated private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let continuation: CheckedContinuation<Data, Error>

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            continuation.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation.resume(returning: data)
        } else {
            continuation.resume(throwing: CocoaError(.fileWriteUnknown))
        }
    }
}
#endif
