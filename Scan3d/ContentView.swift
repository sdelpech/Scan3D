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
