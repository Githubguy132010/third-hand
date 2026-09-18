import SwiftUI

@main
struct ThirdHandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Third Hand", systemImage: "hand.raised") {
            Button("Run on Current App (⌃Space)") {
                appDelegate.handleHotkey()
            }
            Divider()
            Button("Set API Key…") {
                appDelegate.promptAPIKey()
            }
            Text("Shortcut: ⌃ Space")
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
