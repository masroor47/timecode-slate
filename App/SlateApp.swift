import SwiftUI

@main
struct SlateApp: App {
    var body: some Scene {
        WindowGroup {
            SlateView()
                .persistentSystemOverlays(.hidden)
        }
    }
}
