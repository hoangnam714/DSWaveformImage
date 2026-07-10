import SwiftUI
import DSWaveformImage
import DSWaveformImageViews

struct ContentView: View {
    var body: some View {
        TabView {
            WaveformGalleryView()
                .tabItem { Label("Static Files", systemImage: "waveform") }

            ProgressShowcase()
                .tabItem { Label("Progress", systemImage: "play.circle.fill") }

            ZoomScrollShowcase()
                .tabItem { Label("Zoom", systemImage: "plus.magnifyingglass") }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
