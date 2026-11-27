import SwiftUI

/// Sur iPhone, l'app sert à photographier l'objet ; sur Mac, à créer le modèle 3D
/// à partir de ces photos (la reconstruction n'est pas possible sur iPhone sans LiDAR).
struct ContentView: View {
    var body: some View {
        #if os(iOS)
        PhotoLibraryView()
        #elseif os(macOS)
        MacReconstructionView()
        #else
        ContentUnavailableView(
            "Non disponible",
            systemImage: "cube.transparent",
            description: Text("Utilisez cette app sur iPhone pour les photos et sur Mac pour créer le modèle 3D.")
        )
        #endif
    }
}

#Preview {
    ContentView()
}

/// Version affichée dans l'app : numéro de version + date de compilation. Celle-ci change
/// à chaque installation depuis Xcode, ce qui permet de vérifier qu'on a la dernière version.
enum AppVersion {
    static let label: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .map { $0.formatted(.dateTime.day(.twoDigits).month(.twoDigits).hour().minute()) }
        return build.map { "Version \(version) · build \($0)" } ?? "Version \(version)"
    }()
}
