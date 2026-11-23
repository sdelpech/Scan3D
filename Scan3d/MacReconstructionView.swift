#if os(macOS)
import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Écran Mac : choisir le dossier de photos venant de l'iPhone et créer le modèle 3D.
struct MacReconstructionView: View {
    @State private var manager = ReconstructionManager()
    @State private var folder: URL?
    @State private var imageCount = 0
    @State private var isImporterPresented = false
    @State private var detail: DetailLevel = .full
    @State private var isSequential = true
    @State private var isHighSensitivity = false
    @State private var isObjectMaskingEnabled = true
    @State private var previewURL: URL?
    @State private var measuredFiles: ModelFiles?

    var body: some View {
        if manager.isSupported {
            form
        } else {
            ContentUnavailableView(
                "Mac non compatible",
                systemImage: "cpu",
                description: Text("La reconstruction 3D nécessite un Mac Apple silicon ou un GPU avec 4 Go de mémoire et le ray tracing.")
            )
        }
    }

    private var form: some View {
        Form {
            Section("1. Photos") {
                HStack {
                    VStack(alignment: .leading) {
                        Text(folder?.lastPathComponent ?? "Aucun dossier sélectionné")
                        if folder != nil {
                            Text("\(imageCount) photos")
                                .font(.caption)
                                .foregroundStyle(imageCount < 20 ? .orange : .secondary)
                        }
                    }
                    Spacer()
                    Button("Choisir un dossier…") {
                        isImporterPresented = true
                    }
                }
                Text("Envoyez la série depuis l'iPhone par AirDrop, rangez les photos dans un dossier, puis sélectionnez-le.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("2. Réglages") {
                Picker("Niveau de détail", selection: $detail) {
                    ForEach(DetailLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                Toggle("Photos prises dans l'ordre (en tournant autour)", isOn: $isSequential)
                Toggle("Détection renforcée (objets peu texturés)", isOn: $isHighSensitivity)
                Toggle("Isoler l'objet du décor", isOn: $isObjectMaskingEnabled)
            }
            .disabled(isProcessing)

            Section("3. Modèle 3D") {
                reconstructionSection
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 480)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                select(url)
            }
        }
        .quickLookPreview($previewURL)
        .sheet(isPresented: Binding(
            get: { measuredFiles != nil },
            set: { if !$0 { measuredFiles = nil } }
        )) {
            if let measuredFiles {
                MeasureView(files: measuredFiles)
            }
        }
    }

    @ViewBuilder
    private var reconstructionSection: some View {
        switch manager.phase {
        case .idle:
            Button("Créer le modèle 3D", systemImage: "cube") {
                guard let folder else { return }
                Task {
                    await manager.reconstruct(
                        imagesFolder: folder,
                        detail: detail,
                        isSequential: isSequential,
                        isHighSensitivity: isHighSensitivity,
                        isObjectMaskingEnabled: isObjectMaskingEnabled
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(folder == nil || imageCount == 0)

        case .processing:
            ProgressView(value: manager.progress) {
                Text("Reconstruction en cours…")
            } currentValueLabel: {
                Text(manager.progress, format: .percent.precision(.fractionLength(0)))
            }
            Button("Annuler", role: .cancel) {
                manager.cancel()
            }

        case .finished(let files):
            Label("Modèle créé (USDZ + OBJ)", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Pour la CAO : mettez le modèle à l'échelle en mesurant une distance connue, puis importez l'OBJ en millimètres.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Mesurer et mettre à l'échelle", systemImage: "ruler") {
                    measuredFiles = files
                }
                .buttonStyle(.borderedProminent)
                Button("Aperçu 3D", systemImage: "eye") {
                    previewURL = files.usdzURL
                }
                Button("Afficher dans le Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([files.folder])
                }
                Button("Nouveau modèle") {
                    manager.reset()
                }
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Réessayer") {
                manager.reset()
            }
        }
    }

    private var isProcessing: Bool {
        if case .processing = manager.phase { true } else { false }
    }

    /// Ouvre l'accès au dossier choisi (sandbox) pour toute la durée d'utilisation.
    private func select(_ url: URL) {
        folder?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        folder = url
        imageCount = Scan.imageURLs(in: url).count
        manager.reset()
    }
}
#endif
