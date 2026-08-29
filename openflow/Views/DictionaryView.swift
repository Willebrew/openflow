import SwiftUI

struct DictionaryView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var term = ""
    @State private var replacement = ""
    @State private var query = ""
    @State private var editingID: UUID?
    @State private var isComposing = false
    @State private var pendingDeletion: DictionaryEntry?

    private var filtered: [DictionaryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return coordinator.settings.personalDictionary }
        return coordinator.settings.personalDictionary.filter {
            $0.term.localizedCaseInsensitiveContains(trimmed) ||
            $0.replacement.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var canSave: Bool {
        !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isAdding: Bool {
        isComposing && editingID == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowCompactPageHeader(
                title: "Dictionary",
                subtitle: "Names and terms openflow should preserve exactly."
            ) {
                headerAddButton
            }

            FlowSearchField(placeholder: "Search dictionary", text: $query)

            ScrollView {
                LazyVStack(spacing: 6) {
                    if isAdding {
                        composerRow
                    }
                    if filtered.isEmpty && !isAdding {
                        emptyState
                    } else {
                        ForEach(filtered) { entry in
                            if editingID == entry.id {
                                composerRow
                            } else {
                                termRow(entry)
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
            pendingDeletion.map { "Delete “\($0.term)”?" } ?? "Delete term?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) {
                remove(entry)
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
            accessibilityLabel: isAdding ? "Cancel add" : "Add term",
            help: isAdding ? "Cancel add" : "Add term"
        ) {
            toggleAddComposer()
        }
    }

    private var emptyState: some View {
        FlowCompactEmptyState(
            title: query.isEmpty ? "No dictionary terms yet" : "No matching terms",
            subtitle: query.isEmpty
                ? "Add names, products, acronyms, or preferred spellings."
                : "Try a different search.",
            symbol: query.isEmpty ? "text.book.closed" : "magnifyingglass"
        )
    }

    private var composerRow: some View {
        FlowInsetRow {
            HStack(spacing: 8) {
                FlowInlineField(
                    placeholder: "word or phrase",
                    text: $term,
                    fontSize: 12,
                    weight: .semibold,
                    onSubmit: saveIfPossible
                )
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(FlowUI.moss)
                    .accessibilityHidden(true)
                FlowInlineField(
                    placeholder: "expands to…",
                    text: $replacement,
                    fontSize: 11,
                    weight: .medium,
                    onSubmit: saveIfPossible
                )
                FlowCircleIconButton(
                    systemImage: "checkmark",
                    moss: canSave,
                    accessibilityLabel: editingID == nil ? "Save term" : "Save changes",
                    help: editingID == nil ? "Save term" : "Save changes"
                ) {
                    saveTerm()
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

    private func termRow(_ entry: DictionaryEntry) -> some View {
        FlowInsetRow {
            HStack(spacing: 10) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowUI.moss)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.term)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(FlowUI.moss)
                        Text(expansionCaption(for: entry))
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
                    accessibilityLabel: "Edit term",
                    help: "Edit term"
                ) {
                    beginEdit(entry)
                }
                FlowCircleIconButton(
                    systemImage: "trash",
                    accessibilityLabel: "Delete term",
                    help: "Delete term"
                ) {
                    pendingDeletion = entry
                }
            }
        }
    }

    private func expansionCaption(for entry: DictionaryEntry) -> String {
        entry.replacement == entry.term ? "Keep this spelling" : entry.replacement
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
        term = ""
        replacement = ""
        isComposing = true
    }

    private func beginEdit(_ entry: DictionaryEntry) {
        editingID = entry.id
        term = entry.term
        replacement = entry.replacement == entry.term ? "" : entry.replacement
        isComposing = true
    }

    private func cancelComposer() {
        isComposing = false
        editingID = nil
        term = ""
        replacement = ""
    }

    private func remove(_ entry: DictionaryEntry) {
        if editingID == entry.id {
            cancelComposer()
        }
        coordinator.settings.personalDictionary.removeAll { $0.id == entry.id }
    }

    private func saveIfPossible() {
        guard canSave else { return }
        saveTerm()
    }

    private func saveTerm() {
        let cleanedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTerm.isEmpty else { return }
        let cleanedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleanedReplacement.isEmpty ? cleanedTerm : cleanedReplacement
        if let editingID,
           let index = coordinator.settings.personalDictionary.firstIndex(where: { $0.id == editingID }) {
            coordinator.settings.personalDictionary[index].term = cleanedTerm
            coordinator.settings.personalDictionary[index].replacement = value
        } else {
            coordinator.settings.personalDictionary.append(
                DictionaryEntry(term: cleanedTerm, replacement: value)
            )
        }
        cancelComposer()
    }
}
