import SwiftUI

@main
struct openflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.coordinator)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About openflow") {
                    NSApp.orderFrontStandardAboutPanel()
                }
            }
        }
    }
}
