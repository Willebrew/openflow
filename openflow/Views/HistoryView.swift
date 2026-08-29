import AppKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var query = ""
    @State private var copiedID: UUID?
    @State private var pendingDeletion: DictationHistoryItem?
    @State private var pendingClearAll = false

    /// Fits "12:00 PM" / "Aug 22" in tabular 11pt so every row's snippet shares an X.
    private static let timestampColumnWidth: CGFloat = 64
    /// Keeps app names from shifting the timestamp + snippet column.
    private static let appNameColumnWidth: CGFloat = 78

    private var filtered: [DictationHistoryItem] {
        guard !query.isEmpty else { return coordinator.history.items }
        return coordinator.history.items.filter {
            $0.displayText.localizedCaseInsensitiveContains(query) ||
            $0.appName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowCompactPageHeader(
                title: "History",
                subtitle: "Recent dictations stored locally."
            )
            toolbarRow

            ScrollView {
                LazyVStack(spacing: 6) {
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        ForEach(filtered) { item in
                            historyRow(item)
                        }
                    }
                }
                .padding(.bottom, 56)
            }
            .flowHubListScroll()
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(FlowUI.ink)
        .alert(
            pendingDeletion.map(clipDeleteTitle) ?? "Delete this clip?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { item in
            Button("Delete", role: .destructive) {
                coordinator.history.delete(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can’t be undone.")
        }
        .alert(
            "Clear all history?",
            isPresented: $pendingClearAll
        ) {
            Button("Clear", role: .destructive) {
                coordinator.history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 8) {
            FlowSearchField(placeholder: "Search history", text: $query)
            Button("Clear") { pendingClearAll = true }
                .buttonStyle(FlowSecondaryButtonStyle())
                .disabled(coordinator.history.items.isEmpty)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: query.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowUI.moss)
                .frame(width: 16, height: 16)
            Text(query.isEmpty ? "No dictations yet" : "No matching dictations")
                .font(.system(size: 12, weight: .semibold))
            Text(query.isEmpty
                 ? "Hold \(coordinator.settings.pushToTalkHotkey.keycapLabel) to dictate."
                 : "Try a different search.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func historyRow(_ item: DictationHistoryItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            AppIconBadge(appName: item.appName, bundleID: item.bundleID, size: 22)
            Text(item.appName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(width: Self.appNameColumnWidth, alignment: .leading)
                .layoutPriority(1)
            clipMeta(timestamp: item.timestamp, snippet: item.displayText)
                .layoutPriority(-1)
            Spacer(minLength: 6)
            copyButton(for: item)
            deleteButton(for: item)
        }
        .flowInsetRowPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlowUI.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.appName). \(timestampLabel(item.timestamp)). \(item.displayText)")
    }

    /// Time stays in a fixed tabular column; snippet starts after a real gap. No pipe, no mode chip.
    /// Center-aligned with the icon and actions so the transcription is not pushed under the app name.
    private func clipMeta(timestamp: Date, snippet: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(timestampLabel(timestamp))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.timestampColumnWidth, alignment: .leading)
                .lineLimit(1)
            Text(snippet)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func copyButton(for item: DictationHistoryItem) -> some View {
        Button {
            copyClip(item)
        } label: {
            Image(systemName: copiedID == item.id ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.72))
                .frame(width: 28, height: 28)
                .background(FlowUI.moss, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(copyText(for: item) == nil)
        .help("Copy")
        .accessibilityLabel("Copy dictation")
    }

    private func deleteButton(for item: DictationHistoryItem) -> some View {
        Button {
            pendingDeletion = item
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(FlowUI.ink.opacity(0.72))
                .frame(width: 28, height: 28)
                .background(FlowUI.mutedFill, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Delete")
        .accessibilityLabel("Delete dictation")
    }

    private func clipDeleteTitle(_ item: DictationHistoryItem) -> String {
        let text = item.displayText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return "Delete this clip?" }
        if text.count <= 80 { return "Delete “\(text)”?" }
        let preview = String(text.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "Delete “\(preview)…”?"
    }

    private func timestampLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))
    }

    private func copyText(for item: DictationHistoryItem) -> String? {
        let text = item.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func copyClip(_ item: DictationHistoryItem) {
        guard let text = copyText(for: item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == item.id {
                copiedID = nil
            }
        }
    }
}
