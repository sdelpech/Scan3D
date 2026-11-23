#if os(macOS)
import AppKit
import RealityKit
import SwiftUI

/// Outil de mise à l'échelle : l'utilisateur clique deux points du modèle dont il
/// connaît la distance réelle, et l'app exporte un OBJ aux dimensions exactes, en mm.
struct MeasureView: View {
    let files: ModelFiles

    @Environment(\.dismiss) private var dismiss
    @State private var points: [SIMD3<Float>] = []
    @State private var markers = Entity()
    /// Plus grande dimension du modèle affiché (repère de la scène).
    @State private var sceneExtent: Float = 0
    /// Boîte englobante de l'OBJ, dans les unités du fichier.
    @State private var objBounds: OBJTools.Bounds?
    @State private var realLength: Double = 100
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            RealityView { content in
                await loadModel(into: &content)
            }
            .realityViewCameraControls(.orbit)
            .gesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .targetedToAnyEntity()
                    .onEnded { value in
                        // Lance un rayon depuis le point cliqué jusqu'à la surface du maillage.
                        let hit = value.hitTest(point: value.location, in: .local, query: .nearest, mask: .all).first
                        if let position = hit?.position {
                            addPoint(position)
                        }
                    }
            )
            .overlay {
                if isLoading {
                    ProgressView("Chargement du modèle…")
                }
            }
            .frame(minHeight: 420)

            Form {
                Section {
                    Text("Faites glisser pour tourner autour du modèle. Cliquez sur deux points dont vous connaissez l'écart réel : deux repères collés sur la pièce, les graduations d'un mètre posé à côté, ou deux trous de fixation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    LabeledContent("Points sélectionnés", value: "\(points.count) / 2")

                    TextField("Distance réelle entre les 2 points", value: $realLength, format: .number.precision(.fractionLength(0...2)))
                        .overlay(alignment: .trailing) {
                            Text("mm").foregroundStyle(.secondary)
                        }

                    if let dimensions = scaledDimensions {
                        LabeledContent("Dimensions obtenues") {
                            Text(dimensions)
                                .monospacedDigit()
                        }
                    }

                    if let message {
                        Text(message)
                            .font(.callout)
                    }
                }

                HStack {
                    Button("Effacer les points") {
                        clearPoints()
                    }
                    .disabled(points.isEmpty)

                    Spacer()

                    Button("Fermer") {
                        dismiss()
                    }

                    Button("Exporter l'OBJ en millimètres", systemImage: "square.and.arrow.down") {
                        Task { await exportScaledOBJ() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(scaleFactor == nil || isExporting)
                }
            }
            .formStyle(.grouped)
            .frame(height: 300)
        }
        .frame(minWidth: 700, minHeight: 760)
        .task {
            await loadOBJBounds()
        }
    }

    // MARK: - Calculs d'échelle

    /// Facteur à appliquer aux coordonnées de l'OBJ pour obtenir des millimètres.
    private var scaleFactor: Double? {
        guard points.count == 2, realLength > 0, sceneExtent > 0,
              let objBounds, objBounds.largestExtent > 0 else { return nil }
        let sceneDistance = Double(simd_distance(points[0], points[1]))
        guard sceneDistance > 0 else { return nil }
        // Convertit la distance mesurée dans la scène en unités de l'OBJ.
        let objUnitsPerSceneUnit = objBounds.largestExtent / Double(sceneExtent)
        return realLength / (sceneDistance * objUnitsPerSceneUnit)
    }

    private var scaledDimensions: String? {
        guard let scaleFactor, let objBounds else { return nil }
        let size = objBounds.extents * scaleFactor
        return String(format: "%.0f × %.0f × %.0f mm", size.x, size.y, size.z)
    }

    // MARK: - Scène 3D

    private func loadModel(into content: inout RealityViewCameraContent) async {
        defer { isLoading = false }
        guard let model = try? await Entity(contentsOf: files.usdzURL) else {
            message = "Impossible de charger le modèle 3D."
            return
        }

        // Ramène le modèle à environ 1 m et le centre, pour que la caméra orbite autour.
        let bounds = model.visualBounds(relativeTo: nil)
        let largest = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        if largest > 0 {
            model.scale *= 1 / largest
        }
        model.position -= model.visualBounds(relativeTo: nil).center
        let fitted = model.visualBounds(relativeTo: nil).extents
        sceneExtent = max(fitted.x, fitted.y, fitted.z)

        await makeTappable(model)
        content.add(model)
        content.add(markers)
    }

    /// Ajoute des formes de collision fidèles au maillage pour cliquer précisément sur la surface.
    private func makeTappable(_ entity: Entity) async {
        if let model = entity.components[ModelComponent.self],
           let shape = try? await ShapeResource.generateStaticMesh(from: model.mesh) {
            entity.components.set(CollisionComponent(shapes: [shape]))
            entity.components.set(InputTargetComponent())
        }
        for child in entity.children {
            await makeTappable(child)
        }
    }

    private func addPoint(_ point: SIMD3<Float>) {
        if points.count == 2 {
            clearPoints()
        }
        points.append(point)
        message = nil

        let marker = ModelEntity(
            mesh: .generateSphere(radius: max(sceneExtent, 0.1) * 0.006),
            materials: [UnlitMaterial(color: points.count == 1 ? .systemRed : .systemBlue)]
        )
        marker.position = point
        markers.addChild(marker)
    }

    private func clearPoints() {
        points.removeAll()
        for child in Array(markers.children) {
            child.removeFromParent()
        }
    }

    // MARK: - OBJ

    private func loadOBJBounds() async {
        guard let objURL = files.objURL else {
            message = "Fichier OBJ introuvable."
            return
        }
        objBounds = try? await Task.detached { try OBJTools.bounds(of: objURL) }.value
    }

    private func exportScaledOBJ() async {
        guard let objURL = files.objURL, let scaleFactor else { return }
        isExporting = true
        defer { isExporting = false }

        let name = objURL.deletingPathExtension().lastPathComponent
        let output = objURL.deletingLastPathComponent().appending(path: "\(name)-mm.obj")
        do {
            try await Task.detached {
                try OBJTools.writeScaledCopy(of: objURL, factor: scaleFactor, to: output)
            }.value
            message = "OBJ exporté en millimètres : \(output.lastPathComponent). À l'import dans votre logiciel de CAO, choisissez l'unité « mm »."
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            message = "Export impossible : \(error.localizedDescription)"
        }
    }
}
#endif
