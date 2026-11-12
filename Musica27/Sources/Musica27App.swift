import SwiftUI

@main
struct Musica27App: App {
    @StateObject private var player = PlayerManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
        }
    }
}
