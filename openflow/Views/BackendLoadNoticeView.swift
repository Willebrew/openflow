import SwiftUI

/// Quiet status capsule. It is not a control: it does not take clicks or focus,
/// and it never inserts text.
struct BackendLoadBanner: View {
    let notice: BackendLoadNotice

    var body: some View {
        switch notice {
        case .hidden:
            EmptyView()
        case .elevated(let text):
            capsule(text, emphasized: false)
        case .high(let text):
            capsule(text, emphasized: true)
        }
    }

    private func capsule(_ text: String, emphasized: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "speedometer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FlowUI.amber.opacity(emphasized ? 1 : 0.8))
            Text(text)
                .font(.system(size: 12, weight: emphasized ? .semibold : .medium))
                .foregroundStyle(FlowUI.ink.opacity(emphasized ? 0.92 : 0.72))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            FlowUI.amber.opacity(emphasized ? 0.16 : 0.08),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(FlowUI.amber.opacity(emphasized ? 0.42 : 0.22))
        )
        .frame(maxWidth: 460, alignment: .trailing)
        .layoutPriority(-1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("backend-load-notice")
    }
}
