import SwiftUI

@main
struct DecksApp: App {
    var body: some Scene {
        WindowGroup("Decks") {
            BoothView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1540, height: 960)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
