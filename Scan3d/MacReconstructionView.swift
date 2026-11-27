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
    /// Gravité enregistrée par l'iPhone dans les photos ; désactivée, le dossier est lu
    /// directement comme dans les premières versions. Choix mémorisé.
    @AppStorage("usesGravity") private var usesGravity = true
    @State private var previewURL: URL?
    @State private var measuredFiles: ModelFiles?
    /// Nombre de triangles du modèle affiché, lu dans l'OBJ.
    @State private var triangleCount: Int?
    @State private var targetTriangles = 50_000

    /// Tailles proposées pour la version simplifiée.
    private static let triangleTargets = [100_000, 50_000, 25_000, 10_000, 5_000, 2_000]

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
                Toggle("Utiliser la gravité enregistrée par l'iPhone", isOn: $usesGravity)
            }
            .disabled(isProcessing)

            Section {
                reconstructionSection
            } header: {
                Text("3. Modèle 3D")
            } footer: {
                Text(AppVersion.label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: finishedFolder) {
            await loadTriangleCount()
        }
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
                        isObjectMaskingEnabled: isObjectMaskingEnabled,
                        usesGravity: usesGravity
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(folder == nil || imageCount == 0)

        case .processing:
            ProgressView(value: manager.progress) {
                Text(manager.stage.isEmpty ? "Reconstruction en cours…" : manager.stage)
            } currentValueLabel: {
                HStack {
                    Text(manager.progress, format: .percent.precision(.fractionLength(0)))
                    if !manager.currentOutput.isEmpty {
                        Text("· fichier \(manager.currentOutput) (\(manager.currentOutput == "USDZ" ? 1 : 2)/2)")
                    }
                }
            }
            if let startDate = manager.startDate {
                // Rafraîchi chaque seconde pour faire défiler le temps écoulé.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        Text("Écoulé : \(Self.format(context.date.timeIntervalSince(startDate)))")
                        if let remaining = manager.estimatedRemainingTime {
                            Text("· Restant : environ \(Self.format(remaining))")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            diagnostics
            Button("Annuler", role: .cancel) {
                manager.cancel()
            }

        case .finished(let files):
            Label("Modèle créé (USDZ + OBJ)", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            if let startDate = manager.startDate {
                Text("Durée : \(Self.format(Date.now.timeIntervalSince(startDate)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            diagnostics
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
            if manager.canSimplify {
                simplifyControls
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            diagnostics
            Button("Réessayer") {
                manager.reset()
            }
        }
    }

    /// Recalcule le modèle avec moins de triangles. Le résultat est enregistré à part :
    /// le modèle d'origine est conservé.
    private var simplifyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Alléger le maillage")
                .font(.headline)
            if let triangleCount {
                Text("Modèle actuel : \(triangleCount.formatted()) triangles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Picker("Triangles au maximum", selection: $targetTriangles) {
                    ForEach(Self.triangleTargets, id: \.self) { count in
                        Text(count.formatted()).tag(count)
                    }
                }
                .fixedSize()
                Button("Créer la version allégée", systemImage: "wand.and.sparkles") {
                    Task { await manager.simplify(maximumTriangles: targetTriangles) }
                }
                .disabled(triangleCount.map { $0 <= targetTriangles } ?? false)
            }
            Text("Le maillage et les textures sont recalculés à partir des photos, en réutilisant l'alignement déjà fait. Le modèle d'origine est conservé.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Alertes et photos écartées par le moteur : elles indiquent quoi reprendre à la prise de vue.
    @ViewBuilder
    private var diagnostics: some View {
        ForEach(manager.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        }
        if !manager.rejectedPhotos.isEmpty {
            DisclosureGroup("\(manager.rejectedPhotos.count) photo(s) écartée(s) sur \(imageCount)") {
                ForEach(manager.rejectedPhotos, id: \.self) { photo in
                    Text(photo)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(.orange)
        }
    }

    /// Durée lisible, par exemple « 4 min 12 s ».
    private static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    /// Compte les triangles du modèle terminé (lecture de l'OBJ en arrière-plan).
    private func loadTriangleCount() async {
        triangleCount = nil
        guard case .finished(let files) = manager.phase, let objURL = files.objURL else { return }
        triangleCount = await Task.detached { try? OBJTools.faceCount(of: objURL) }.value
    }

    /// Dossier du modèle terminé, pour relire le nombre de triangles quand il change.
    private var finishedFolder: URL? {
        if case .finished(let files) = manager.phase { files.folder } else { nil }
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
