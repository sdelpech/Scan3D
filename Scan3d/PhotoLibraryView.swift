#if os(iOS)
import SwiftUI

/// Écran d'accueil sur iPhone : lancer une série de photos et envoyer les
/// séries au Mac pour la reconstruction 3D.
struct PhotoLibraryView: View {
    @State private var scans: [Scan] = []
    @State private var activeScan: Scan?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        startNewScan()
                    } label: {
                        Label("Nouvelle série de photos", systemImage: "camera.viewfinder")
                            .font(.headline)
                    }
                } footer: {
                    Text("Prenez 40 à 80 photos en tournant autour de l'objet, puis envoyez la série sur votre Mac (AirDrop) pour créer le modèle 3D avec cette même app.")
                }

                if !scans.isEmpty {
                    Section("Mes séries") {
                        ForEach(scans) { scan in
                            ScanRow(scan: scan)
                                .swipeActions {
                                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                                        delete(scan)
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Scan3D")
            .onAppear(perform: reload)
            .fullScreenCover(item: $activeScan, onDismiss: reload) { scan in
                PhotoCaptureView(scan: scan) {
                    activeScan = nil
                }
            }
            .alert("Erreur", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func startNewScan() {
        do {
            activeScan = try Scan.makeNew()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        // Les séries sans aucune photo (capture abandonnée) sont supprimées.
        for scan in Scan.loadAll() where scan.imageURLs.isEmpty {
            try? FileManager.default.removeItem(at: scan.folder)
        }
        scans = Scan.loadAll()
    }

    private func delete(_ scan: Scan) {
        try? FileManager.default.removeItem(at: scan.folder)
        reload()
    }
}

private struct ScanRow: View {
    let scan: Scan

    var body: some View {
        let images = scan.imageURLs
        HStack {
            VStack(alignment: .leading) {
                Text(scan.date, format: .dateTime.day().month().year().hour().minute())
                Text("\(images.count) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ShareLink(items: images) {
                Label("Envoyer au Mac", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
        }
    }
}
#endif
