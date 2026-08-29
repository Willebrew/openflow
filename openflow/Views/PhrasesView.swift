import SwiftUI

struct PhrasesView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var query = ""
    @State private var editingID: UUID?
    @State private var isComposing = false
    @State private var pendingDeletion: PhraseEntry?

    private var filtered: [PhraseEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return coordinator.settings.phrases }
        return coordinator.settings.phrases.filter {
            $0.trigger.localizedCaseInsensitiveContains(trimmed) ||
            $0.expansion.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isAdding: Bool {
        isComposing && editingID == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowCompactPageHeader(
                title: "Phrases",
                subtitle: "Speak a saved trigger and openflow inserts exact text."
            ) {
                headerAddButton
            }

            FlowSearchField(placeholder: "Search phrases", text: $query)

            ScrollView {
                LazyVStack(spacing: 6) {
                    if isAdding {
                        composerRow
                    }
                    if filtered.isEmpty && !isAdding {
                        emptyState
                    } else {
                        ForEach(filtered) { phrase in
                            if editingID == phrase.id {
                                composerRow
                            } else {
                                phraseRow(phrase)
                            }
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
            pendingDeletion.map { "Delete “\($0.trigger)”?" } ?? "Delete phrase?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { phrase in
            Button("Delete", role: .destructive) {
                remove(phrase)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can’t be undone.")
        }
    }

    private var headerAddButton: some View {
        FlowCircleIconButton(
            systemImage: isAdding ? "xmark" : "plus",
            moss: !isAdding,
            accessibilityLabel: isAdding ? "Cancel add" : "Add phrase",
            help: isAdding ? "Cancel add" : "Add phrase"
        ) {
            toggleAddComposer()
        }
    }

    private var emptyState: some View {
        FlowCompactEmptyState(
            title: query.isEmpty ? "No phrases yet" : "No matching phrases",
            subtitle: query.isEmpty
                ? "Add a short trigger, then the exact text openflow should insert."
                : "Try a different search.",
            symbol: query.isEmpty ? "text.quote" : "magnifyingglass"
        )
    }

    private var composerRow: some View {
        FlowInsetRow {
            HStack(spacing: 8) {
                FlowInlineField(
                    placeholder: "when I say…",
                    text: $trigger,
                    fontSize: 12,
                    weight: .semibold,
                    onSubmit: saveIfPossible
                )
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(FlowUI.moss)
                    .accessibilityHidden(true)
                FlowInlineField(
                    placeholder: "insert this…",
                    text: $expansion,
                    fontSize: 11,
                    weight: .medium,
                    onSubmit: saveIfPossible
                )
                FlowCircleIconButton(
                    systemImage: "checkmark",
                    moss: canSave,
                    accessibilityLabel: editingID == nil ? "Save phrase" : "Save changes",
                    help: editingID == nil ? "Save phrase" : "Save changes"
                ) {
                    savePhrase()
                }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.42)
                FlowCircleIconButton(
                    systemImage: "xmark",
                    accessibilityLabel: "Cancel",
                    help: "Cancel"
                ) {
                    cancelComposer()
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
                .stroke(FlowUI.moss.opacity(0.28))
        }
    }

    private func phraseRow(_ phrase: PhraseEntry) -> some View {
        FlowInsetRow {
            HStack(spacing: 10) {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowUI.moss)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(phrase.trigger)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(FlowUI.moss)
                        Text(phrase.expansion)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .layoutPriority(-1)
                Spacer(minLength: 6)
                FlowCircleIconButton(
                    systemImage: "pencil",
                    accessibilityLabel: "Edit phrase",
                    help: "Edit phrase"
                ) {
                    beginEdit(phrase)
                }
                FlowCircleIconButton(
                    systemImage: "trash",
                    accessibilityLabel: "Delete phrase",
                    help: "Delete phrase"
                ) {
                    pendingDeletion = phrase
                }
            }
        }
    }

    private func toggleAddComposer() {
        if isAdding {
            cancelComposer()
        } else {
            beginAdd()
        }
    }

    private func beginAdd() {
        editingID = nil
        trigger = ""
        expansion = ""
        isComposing = true
    }

    private func beginEdit(_ phrase: PhraseEntry) {
        editingID = phrase.id
        trigger = phrase.trigger
        expansion = phrase.expansion
        isComposing = true
    }

    private func cancelComposer() {
        isComposing = false
        editingID = nil
        trigger = ""
        expansion = ""
    }

    private func remove(_ phrase: PhraseEntry) {
        if editingID == phrase.id {
            cancelComposer()
        }
        coordinator.settings.phrases.removeAll { $0.id == phrase.id }
    }

    private func saveIfPossible() {
        guard canSave else { return }
        savePhrase()
    }

    private func savePhrase() {
        let cleanTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanExpansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTrigger.isEmpty, !cleanExpansion.isEmpty else { return }
        if let editingID,
           let index = coordinator.settings.phrases.firstIndex(where: { $0.id == editingID }) {
            coordinator.settings.phrases[index].trigger = cleanTrigger
            coordinator.settings.phrases[index].expansion = cleanExpansion
        } else {
            coordinator.settings.phrases.append(
                PhraseEntry(trigger: cleanTrigger, expansion: cleanExpansion)
            )
        }
        cancelComposer()
    }
}
