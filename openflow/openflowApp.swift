import SwiftUI

@main
struct openflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.coordinator)
                .environmentObject(appDelegate.coordinator.settings)
                .environmentObject(appDelegate.coordinator.permissions)
                .environmentObject(appDelegate.coordinator.history)
                .environmentObject(appDelegate.coordinator.credentials)
                .environmentObject(appDelegate.coordinator.cloudAccount)
                .environmentObject(appDelegate.coordinator.audioRoute)
                .environmentObject(appDelegate.coordinator.diagnostics)
                .environmentObject(appDelegate.coordinator.homeStats)
                .environmentObject(appDelegate.coordinator.pillViewModel)
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
