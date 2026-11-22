import SwiftUI

@main
struct RilievoLiDARApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
