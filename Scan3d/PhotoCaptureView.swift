#if os(iOS)
import SwiftUI

/// Écran de prise de vue : l'utilisateur tourne autour de l'objet. Un cadran indique
/// les angles déjà photographiés ; le mode automatique déclenche dès qu'on vise
/// un angle encore manquant.
struct PhotoCaptureView: View {
    /// Écart d'angle entre deux photos en mode automatique : plus il est petit,
    /// plus la série contient de photos.
    enum Density: Double, CaseIterable, Identifiable {
        case normal = 12
        case dense = 6
        case maximum = 3

        var id: Self { self }

        var title: String {
            switch self {
            case .normal: "Normale (tous les 12°)"
            case .dense: "Dense (tous les 6°)"
            case .maximum: "Maximale (tous les 3°)"
            }
        }
    }

    let scan: Scan
    let onDone: () -> Void

    @State private var camera = CameraModel()
    @State private var coverage = CoverageTracker()
    @State private var isAutoCaptureOn = false
    @State private var density: Density = .dense
    /// Calque de la photo précédente ; le choix est mémorisé d'une séance à l'autre.
    @AppStorage("isGhostVisible") private var isGhostVisible = true
    @State private var showFlash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .unauthorized:
                ContentUnavailableView {
                    Label("Accès à la caméra refusé", systemImage: "camera.fill")
                } description: {
                    Text("Autorisez l'accès à la caméra dans Réglages pour photographier vos objets.")
                } actions: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Ouvrir Réglages", destination: url)
                    }
                    Button("Fermer", action: onDone)
                }
            case .unavailable:
                ContentUnavailableView {
                    Label("Caméra indisponible", systemImage: "camera.badge.ellipsis")
                } actions: {
                    Button("Fermer", action: onDone)
                }
            case .idle, .running:
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                ghostPhoto
                overlay
            }

            if showFlash {
                Color.white
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .sensoryFeedback(.impact(weight: .light), trigger: coverage.totalCovered)
        .task {
            coverage.start()
            await camera.start(savingTo: scan.imagesFolder)
        }
        .task(id: isAutoCaptureOn) {
            // Mode automatique : déclenche dès que l'iPhone a tourné de l'angle choisi
            // depuis la photo précédente. Aucune limite de nombre de photos.
            guard isAutoCaptureOn else { return }
            while !Task.isCancelled {
                if coverage.degreesSinceLastPhoto >= density.rawValue {
                    await shoot()
                }
                try? await Task.sleep(for: .seconds(0.2))
            }
        }
        .onDisappear {
            camera.stop()
            coverage.stop()
        }
    }

    /// Dernière photo en transparence, cadrée comme l'aperçu (remplissage de l'écran),
    /// pour aligner la photo suivante avec un bon recouvrement.
    @ViewBuilder
    private var ghostPhoto: some View {
        if isGhostVisible, let lastPhoto = camera.lastPhoto {
            Color.clear
                .overlay {
                    Image(uiImage: lastPhoto)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .opacity(0.25)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var overlay: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                if coverage.isAvailable {
                    CoverageDial(tracker: coverage)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(coverage.overallProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.title2.bold().monospacedDigit())
                    Text("\(camera.photoCount) photos")
                        .font(.caption.monospacedDigit())
                    Text("Hauteur : \(coverage.currentRing.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(isOn: $isGhostVisible) {
                        Label(isGhostVisible ? "Calque : oui" : "Calque : non",
                              systemImage: isGhostVisible ? "square.on.square.dashed" : "square.dashed")
                            .font(.caption)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .disabled(camera.lastPhoto == nil)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
            }
            .padding(.horizontal)

            Spacer()

            Text(tip)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding()
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
                .padding(.horizontal)

            if let error = camera.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                VStack(spacing: 8) {
                    Button {
                        isAutoCaptureOn.toggle()
                    } label: {
                        Label(isAutoCaptureOn ? "Auto : oui" : "Auto : non",
                              systemImage: isAutoCaptureOn ? "timer.circle.fill" : "timer.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(isAutoCaptureOn ? .yellow : .white)

                    Picker("Densité", selection: $density) {
                        ForEach(Density.allCases) { density in
                            Text(density.title).tag(density)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                    .font(.caption)
                }
                .frame(maxWidth: .infinity)

                Button {
                    Task { await shoot() }
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .background(Circle().fill(.white.opacity(camera.isTakingPhoto ? 0.4 : 0.9)).padding(6))
                        .frame(width: 76, height: 76)
                }
                .accessibilityLabel("Prendre une photo")
                .disabled(isAutoCaptureOn)

                Button("Terminer", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    /// Conseils adaptés à ce qui reste à photographier.
    private var tip: String {
        if camera.photoCount == 0 {
            return "Posez l'objet sur un fond neutre et bien éclairé. Visez-le à mi-hauteur et prenez la première photo."
        }
        if coverage.fraction(of: .middle) < 0.9 {
            return "Tournez autour de l'objet à mi-hauteur pour remplir l'anneau du milieu. Les cases grises restent à photographier."
        }
        if coverage.fraction(of: .high) < 0.75 {
            return "Levez l'iPhone et visez l'objet par-dessus pour remplir l'anneau intérieur."
        }
        if coverage.fraction(of: .low) < 0.75 {
            return "Baissez l'iPhone à hauteur de l'objet pour remplir l'anneau extérieur."
        }
        return "Tous les angles sont couverts ! Continuez pour ajouter des photos, retournez l'objet pour photographier l'autre face, ou touchez « Terminer »."
    }

    private func shoot() async {
        guard !camera.isTakingPhoto else { return }
        guard await camera.takePhoto(gravity: coverage.gravity) else { return }
        coverage.recordPhoto()
        showFlash = true
        withAnimation(.easeOut(duration: 0.25)) {
            showFlash = false
        }
    }
}
#endif
