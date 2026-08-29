import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("First Run")
                .font(.title2.weight(.semibold))
            permissionRow(title: "Microphone",
                          granted: coordinator.permissions.microphoneGranted,
                          actionTitle: coordinator.permissions.microphoneGranted ? "Granted" : "Request / Open",
                          action: coordinator.permissions.requestMicrophone)
            permissionRow(title: "Accessibility",
                          granted: coordinator.permissions.accessibilityGranted,
                          actionTitle: coordinator.permissions.accessibilityGranted
                            ? "Granted"
                            : (coordinator.permissions.accessibilityPromptIssued ? "Open Settings" : "Request / Open"),
                          action: coordinator.permissions.requestAccessibility)
            permissionRow(title: "Automation for browser URLs",
                          granted: coordinator.permissions.automationLikelyAvailable,
                          actionTitle: "Requested when needed",
                          action: {})
        }
        .onAppear { coordinator.permissions.startPolling() }
        .onDisappear { coordinator.permissions.refresh() }
    }

    private func permissionRow(title: String, granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            Text(title)
            Spacer()
            Button(actionTitle, action: action)
                .disabled(actionTitle == "Requested when needed")
        }
    }
}
