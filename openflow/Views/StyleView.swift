import SwiftUI
import AppKit

private enum StyleComposerPath: Equatable {
    case choose
    case generate
    case manual
}

private enum StylePendingDeletion: Identifiable {
    case custom(CustomStyle)
    case appOverride(AppStyleOverride)

    var id: UUID {
        switch self {
        case .custom(let style):
            return style.id
        case .appOverride(let override):
            return override.id
        }
    }

    var title: String {
        switch self {
        case .custom(let style):
            return "Delete “\(style.name)”?"
        case .appOverride(let override):
            return "Delete style for “\(override.appName)”?"
        }
    }
}

struct StyleView: View {
    /// True to `ContextService.classify` + `DictationCoordinator.styleRef`:
    /// Personal = `.messages`, Work = `.projectManagement` / `.docs` / `.aiChat`, Email = `.email`.
    static let personalContextCaption = "Messages, Slack, Discord, or WhatsApp"
    static let workContextCaption = "Linear, GitHub, Notion, Notes, or AI chat"
    static let emailContextCaption = "Mail or Gmail"

    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var query = ""
    @State private var styleName = ""
    @State private var stylePrompt = ""
    @State private var askRequest = ""
    @State private var editingID: UUID?
    @State private var isComposing = false
    @State private var composerPath: StyleComposerPath = .choose
    @State private var isGenerating = false
    @State private var didGenerate = false
    @State private var generateError = ""
    @State private var isAddingOverride = false
    @Namespace private var styleComposerMorph
    @State private var selectedAppID = ""
    @State private var selectedAppStyle = StyleRef.preset(.auto)
    @State private var appSearch = ""
    @State private var pendingDeletion: StylePendingDeletion?
    @State private var cachedAppChoices: [StyleAppChoice] = []

    private var settings: UserSettings { coordinator.settings }

    private var isAddingStyle: Bool {
        isComposing && editingID == nil
    }

    private var canSaveStyle: Bool {
        !styleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !stylePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredCustom: [CustomStyle] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return settings.customStyles }
        return settings.customStyles.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            $0.prompt.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var filteredPresets: [StylePreset] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return StylePreset.allCases }
        return StylePreset.allCases.filter {
            $0.label.localizedCaseInsensitiveContains(trimmed) ||
            $0.summary.localizedCaseInsensitiveContains(trimmed) ||
            ($0 == .emailLetter && (
                "sign-off".localizedCaseInsensitiveContains(trimmed) ||
                "your name on emails".localizedCaseInsensitiveContains(trimmed)
            ))
        }
    }

    private var sortedOverrides: [AppStyleOverride] {
        settings.appStyleOverrides.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    private var filteredOverrides: [AppStyleOverride] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sortedOverrides }
        return sortedOverrides.filter {
            $0.appName.localizedCaseInsensitiveContains(trimmed) ||
            assignmentStyleTitle(for: $0.style).localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowCompactPageHeader(
                title: "Style",
                subtitle: "Choose how openflow cleans up your words."
            ) {
                FlowCircleIconButton(
                    systemImage: isAddingStyle ? "xmark" : "plus",
                    moss: !isAddingStyle,
                    accessibilityLabel: isAddingStyle ? "Cancel add" : "Add style",
                    help: isAddingStyle ? "Cancel add" : "Add style"
                ) {
                    toggleAddStyle()
                }
            }

            FlowSearchField(placeholder: "Search styles", text: $query)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Group {
                        if isAddingStyle {
                            styleComposer
                        } else {
                            currentStyleHero
                        }
                    }
                    .padding(.bottom, 8)

                    majorSectionTitle("Styles")
                    if !filteredPresets.isEmpty {
                        sectionTitle("Built-in")
                        ForEach(filteredPresets) { preset in
                            VStack(alignment: .leading, spacing: 6) {
                                libraryRow(ref: .preset(preset),
                                           name: preset.label,
                                           summary: preset.summary,
                                           symbol: preset.symbolName)
                                if preset == .emailLetter {
                                    emailLetterSignOffRow
                                }
                            }
                        }
                    }
                    if !filteredCustom.isEmpty || (query.isEmpty && !isAddingStyle) {
                        sectionTitle("Yours")
                    }
                    if filteredCustom.isEmpty && query.isEmpty && !isAddingStyle && editingID == nil {
                        Text("Tap + to generate a style or write one yourself.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else if filteredCustom.isEmpty && !query.isEmpty && filteredPresets.isEmpty {
                        FlowCompactEmptyState(
                            title: "No matching styles",
                            subtitle: "Try a different search.",
                            symbol: "magnifyingglass"
                        )
                    } else {
                        ForEach(filteredCustom) { style in
                            if editingID == style.id {
                                styleComposer
                            } else {
                                customRow(style)
                            }
                        }
                    }

                    if showsExceptionSection || showsAppOverrides {
                        sectionDivider
                        majorSectionTitle("When you're in…")
                        Text("These override the style you selected above, only when openflow can tell the app type.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if showsExceptionSection {
                        if showsContext(title: "Personal", caption: Self.personalContextCaption) {
                            contextAssignmentRow(
                                title: "Personal",
                                caption: Self.personalContextCaption,
                                symbol: "person",
                                selection: $coordinator.settings.stylePreferences.personalMessages
                            )
                        }
                        if showsContext(title: "Work", caption: Self.workContextCaption) {
                            contextAssignmentRow(
                                title: "Work",
                                caption: Self.workContextCaption,
                                symbol: "briefcase",
                                selection: $coordinator.settings.stylePreferences.workMessages
                            )
                        }
                        if showsContext(title: "Email", caption: Self.emailContextCaption) {
                            contextAssignmentRow(
                                title: "Email",
                                caption: Self.emailContextCaption,
                                symbol: "envelope",
                                selection: $coordinator.settings.stylePreferences.email
                            )
                        }
                    }
                    if showsAppOverrides {
                        HStack(spacing: 8) {
                            sectionTitle("Specific apps")
                            Spacer(minLength: 0)
                            FlowCircleIconButton(
                                systemImage: isAddingOverride ? "xmark" : "plus",
                                moss: !isAddingOverride,
                                accessibilityLabel: isAddingOverride ? "Cancel app style" : "Add app style",
                                help: isAddingOverride ? "Cancel app style" : "Add app style"
                            ) {
                                if isAddingOverride {
                                    cancelOverrideComposer()
                                } else {
                                    beginOverrideAdd()
                                }
                            }
                        }
                        if isAddingOverride {
                            overrideComposer
                        }
                        ForEach(filteredOverrides) { override in
                            appOverrideRow(override)
                        }
                    }
                }
                .padding(.bottom, 56)
            }
            .flowHubListScroll()
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(FlowUI.ink)
        .task {
            await coordinator.refreshCloudEntitlement()
        }
        .alert(
            pendingDeletion?.title ?? "Delete?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { item in
            Button("Delete", role: .destructive) {
                confirmDeletion(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can’t be undone.")
        }
    }

    private var currentStyleHero: some View {
        let current = settings.defaultStyle
        return VStack(alignment: .leading, spacing: 6) {
            FlowInsetRow {
                HStack(spacing: 10) {
                    Image(systemName: settings.symbolName(for: current))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowUI.moss)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current style")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(settings.label(for: current))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(settings.summary(for: current))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(FlowUI.moss)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
                    .stroke(FlowUI.moss.opacity(0.28))
            }
            Text("openflow uses this unless an exception below applies.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current style \(settings.label(for: current)). \(settings.summary(for: current))")
    }

    private var showsExceptionSection: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return "when you're in".localizedCaseInsensitiveContains(trimmed) ||
            "different voice in some apps".localizedCaseInsensitiveContains(trimmed) ||
            "exceptions".localizedCaseInsensitiveContains(trimmed) ||
            "personal".localizedCaseInsensitiveContains(trimmed) ||
            "work".localizedCaseInsensitiveContains(trimmed) ||
            "email".localizedCaseInsensitiveContains(trimmed) ||
            showsContext(title: "Personal", caption: Self.personalContextCaption) ||
            showsContext(title: "Work", caption: Self.workContextCaption) ||
            showsContext(title: "Email", caption: Self.emailContextCaption)
    }

    private var showsAppOverrides: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return "specific apps".localizedCaseInsensitiveContains(trimmed) ||
            !filteredOverrides.isEmpty
    }

    private var emailLetterSignOffRow: some View {
        FlowInsetRow {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your name on emails")
                    .font(.system(size: 12, weight: .semibold))
                Text("Optional. Email letter can end with this, e.g. Best, Will.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                FlowInlineField(
                    placeholder: "Your name",
                    text: $coordinator.settings.stylePreferences.emailSignOffName,
                    fontSize: 12,
                    weight: .medium
                )
                .accessibilityLabel("Your name on emails")
            }
        }
    }

    private var styleComposer: some View {
        FlowInsetRow {
            Group {
                switch composerPath {
                case .choose:
                    composerChoiceRow
                case .generate:
                    if didGenerate {
                        namedPromptComposer(geometryID: "generatePath", showFromLine: true)
                    } else {
                        generateAskRow
                    }
                case .manual:
                    namedPromptComposer(geometryID: "manualPath", showFromLine: false)
                }
            }
        }
        .matchedGeometryEffect(id: "styleComposerCard", in: styleComposerMorph)
        .overlay {
            RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
                .stroke(FlowUI.moss.opacity(0.28))
        }
        .animation(.snappy(duration: 0.28), value: composerPath)
        .animation(.snappy(duration: 0.28), value: didGenerate)
    }

    private var composerChoiceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                composerChoiceButton(
                    title: "Generate with openflow",
                    symbol: "text.badge.plus",
                    geometryID: "generatePath",
                    enabled: coordinator.canGenerateStyleWithOpenflow(),
                    help: coordinator.canGenerateStyleWithOpenflow()
                        ? "Generate a style from a short description"
                        : OpenFlowProviderRouting.styleGenerateProRequiredMessage
                ) {
                    chooseGeneratePath()
                }
                composerChoiceButton(
                    title: "Write it myself",
                    symbol: "pencil",
                    geometryID: "manualPath"
                ) {
                    chooseComposerPath(.manual)
                }
            }
            if !generateError.isEmpty {
                Text(generateError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowUI.coral)
            }
        }
    }

    private var generateAskRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FlowInlineField(
                    placeholder: "Describe the style you want",
                    text: $askRequest,
                    fontSize: 12,
                    weight: .medium,
                    onSubmit: generateStyleIfPossible
                )
                .matchedGeometryEffect(id: "generatePath", in: styleComposerMorph)
                .accessibilityLabel("Describe the style you want")
                FlowCircleIconButton(
                    systemImage: isGenerating ? "hourglass" : "text.badge.plus",
                    moss: canGenerateStyle,
                    accessibilityLabel: "Generate style",
                    help: "Generate style"
                ) {
                    generateStyleIfPossible()
                }
                .disabled(!canGenerateStyle)
                .opacity(canGenerateStyle || isGenerating ? 1 : 0.42)
            }
            if !generateError.isEmpty {
                Text(generateError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowUI.coral)
            }
        }
    }

    private func namedPromptComposer(geometryID: String, showFromLine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let trimmedAsk = askRequest.trimmingCharacters(in: .whitespacesAndNewlines)
            if showFromLine, !trimmedAsk.isEmpty {
                Text("From: \(trimmedAsk)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                FlowInlineField(
                    placeholder: "Style title",
                    text: $styleName,
                    fontSize: 12,
                    weight: .semibold,
                    onSubmit: saveStyleIfPossible
                )
                .matchedGeometryEffect(id: geometryID, in: styleComposerMorph)
                .accessibilityLabel("Style title")
                FlowCircleIconButton(
                    systemImage: "checkmark",
                    moss: canSaveStyle,
                    accessibilityLabel: editingID == nil ? "Save style" : "Save changes",
                    help: editingID == nil ? "Save style" : "Save changes"
                ) {
                    saveStyle()
                }
                .disabled(!canSaveStyle)
                .opacity(canSaveStyle ? 1 : 0.42)
                if !isAddingStyle {
                    composerCancelButton
                }
            }
            FlowMultilineField(
                placeholder: "Rewrite dictation as…",
                text: $stylePrompt,
                minHeight: 52
            )
            .accessibilityLabel("Style instructions")
        }
    }

    private func composerChoiceButton(title: String,
                                      symbol: String,
                                      geometryID: String,
                                      enabled: Bool = true,
                                      help: String? = nil,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowUI.moss.opacity(enabled ? 1 : 0.45))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowUI.ink.opacity(enabled ? 1 : 0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                FlowUI.ink.opacity(enabled ? 0.045 : 0.02),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.72)
        .help(help ?? title)
        .matchedGeometryEffect(id: geometryID, in: styleComposerMorph)
        .accessibilityLabel(title)
        .accessibilityHint(enabled ? "" : (help ?? ""))
    }

    private var composerCancelButton: some View {
        FlowCircleIconButton(
            systemImage: "xmark",
            accessibilityLabel: "Cancel",
            help: "Cancel"
        ) {
            cancelStyleComposer()
        }
    }

    private func chooseComposerPath(_ path: StyleComposerPath) {
        withAnimation(.snappy(duration: 0.28)) {
            generateError = ""
            composerPath = path
        }
    }

    private func chooseGeneratePath() {
        guard coordinator.canGenerateStyleWithOpenflow() else { return }
        chooseComposerPath(.generate)
    }

    private var canGenerateStyle: Bool {
        !askRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    private var overrideComposer: some View {
        FlowInsetRow {
            VStack(alignment: .leading, spacing: 8) {
                if let selectedAppChoice {
                    HStack(spacing: 8) {
                        AppIconBadge(appName: selectedAppChoice.appName, bundleID: selectedAppChoice.bundleID, size: 18)
                        Text(selectedAppChoice.appName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        FlowCircleIconButton(
                            systemImage: "xmark",
                            accessibilityLabel: "Clear app",
                            help: "Clear app"
                        ) {
                            selectedAppID = ""
                            appSearch = ""
                        }
                    }
                } else {
                    FlowInlineField(
                        placeholder: "Search Messages, Slack, Cursor…",
                        text: $appSearch,
                        fontSize: 12,
                        weight: .medium
                    )
                }
                if selectedAppChoice == nil, !appSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 2) {
                        ForEach(filteredAppsToAdd.prefix(5)) { choice in
                            Button {
                                selectApp(choice)
                            } label: {
                                HStack(spacing: 8) {
                                    AppIconBadge(appName: choice.appName, bundleID: choice.bundleID, size: 16)
                                    Text(choice.appName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .foregroundStyle(FlowUI.ink)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if filteredAppsToAdd.isEmpty {
                            Text("No matching Mac apps")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(alignment: .center, spacing: 8) {
                    styleAssignmentMenu(selection: $selectedAppStyle)
                    FlowCircleIconButton(
                        systemImage: "checkmark",
                        moss: selectedAppChoice != nil,
                        accessibilityLabel: "Save app style",
                        help: "Save app style"
                    ) {
                        addSelectedAppOverride()
                    }
                    .disabled(selectedAppChoice == nil)
                    .opacity(selectedAppChoice == nil ? 0.42 : 1)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
                .stroke(FlowUI.moss.opacity(0.28))
        }
    }

    private func libraryRow(ref: StyleRef, name: String, summary: String, symbol: String) -> some View {
        StylePickerRow(
            name: name,
            summary: summary,
            symbol: symbol,
            selected: coordinator.settings.defaultStyle == ref
        ) {
            coordinator.settings.setDefaultStyle(ref)
        }
    }

    private func customRow(_ style: CustomStyle) -> some View {
        let ref = StyleRef.custom(style.id)
        return StylePickerRow(
            name: style.name,
            summary: style.prompt,
            symbol: "paintbrush.pointed",
            selected: coordinator.settings.defaultStyle == ref
        ) {
            coordinator.settings.setDefaultStyle(ref)
        } trailing: {
            HStack(spacing: 8) {
                FlowCircleIconButton(
                    systemImage: "pencil",
                    accessibilityLabel: "Edit style",
                    help: "Edit style"
                ) {
                    beginEdit(style)
                }
                FlowCircleIconButton(
                    systemImage: "trash",
                    accessibilityLabel: "Delete style",
                    help: "Delete style"
                ) {
                    pendingDeletion = .custom(style)
                }
            }
        }
    }

    private func contextAssignmentRow(title: String,
                                      caption: String,
                                      symbol: String,
                                      selection: Binding<StyleRef>) -> some View {
        FlowInsetRow {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowUI.moss)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                    Text(caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                styleAssignmentMenu(selection: selection)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(caption). \(assignmentStyleTitle(for: selection.wrappedValue))")
    }

    private func appOverrideRow(_ override: AppStyleOverride) -> some View {
        FlowInsetRow {
            HStack(alignment: .center, spacing: 10) {
                AppIconBadge(appName: override.appName, bundleID: override.bundleID, size: 22)
                Text(override.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                styleAssignmentMenu(selection: binding(for: override))
                FlowCircleIconButton(
                    systemImage: "trash",
                    accessibilityLabel: "Delete app style",
                    help: "Delete app style"
                ) {
                    pendingDeletion = .appOverride(override)
                }
            }
        }
    }

    private func styleAssignmentMenu(selection: Binding<StyleRef>) -> some View {
        StyleAssignmentChip(
            selection: selection,
            choices: settings.styleChoices,
            title: assignmentStyleTitle
        )
    }

    private func assignmentStyleTitle(for ref: StyleRef) -> String {
        guard ref.preset == .auto else { return settings.label(for: ref) }
        let currentName = settings.label(for: settings.defaultStyle)
        if settings.defaultStyle.preset == .auto {
            return "Same as default"
        }
        return "Same as \"\(currentName)\""
    }

    private func majorSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FlowUI.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(FlowUI.hairline)
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private func showsContext(title: String, caption: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(trimmed) ||
            caption.localizedCaseInsensitiveContains(trimmed)
    }

    private func toggleAddStyle() {
        if isAddingStyle {
            cancelStyleComposer()
        } else {
            withAnimation(.snappy(duration: 0.28)) {
                editingID = nil
                styleName = ""
                stylePrompt = ""
                askRequest = ""
                generateError = ""
                didGenerate = false
                composerPath = .choose
                isComposing = true
            }
        }
    }

    private func beginEdit(_ style: CustomStyle) {
        withAnimation(.snappy(duration: 0.28)) {
            editingID = style.id
            styleName = style.name
            stylePrompt = style.prompt
            askRequest = ""
            generateError = ""
            didGenerate = false
            composerPath = .manual
            isComposing = true
        }
    }

    private func cancelStyleComposer() {
        withAnimation(.snappy(duration: 0.28)) {
            isComposing = false
            editingID = nil
            styleName = ""
            stylePrompt = ""
            askRequest = ""
            generateError = ""
            didGenerate = false
            isGenerating = false
            composerPath = .choose
        }
    }

    private func confirmDeletion(_ item: StylePendingDeletion) {
        switch item {
        case .custom(let style):
            removeCustom(style)
        case .appOverride(let override):
            coordinator.settings.appStyleOverrides.removeAll { $0.id == override.id }
        }
    }

    private func removeCustom(_ style: CustomStyle) {
        if editingID == style.id {
            cancelStyleComposer()
        }
        coordinator.settings.removeCustomStyle(style)
    }

    private func saveStyleIfPossible() {
        guard canSaveStyle else { return }
        saveStyle()
    }

    private func saveStyle() {
        let name = styleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = stylePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { return }
        if let editingID,
           let index = coordinator.settings.customStyles.firstIndex(where: { $0.id == editingID }) {
            coordinator.settings.customStyles[index].name = String(name.prefix(60))
            coordinator.settings.customStyles[index].prompt = String(prompt.prefix(1600))
        } else {
            guard coordinator.settings.customStyles.count < 24 else { return }
            let created = CustomStyle(name: String(name.prefix(60)), prompt: String(prompt.prefix(1600)))
            coordinator.settings.customStyles.append(created)
            coordinator.settings.setDefaultStyle(.custom(created.id))
        }
        cancelStyleComposer()
    }

    private func generateStyleIfPossible() {
        let request = askRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isGenerating else { return }
        if !coordinator.canGenerateStyleWithOpenflow() {
            generateError = OpenFlowProviderRouting.styleGenerateProRequiredMessage
            return
        }
        isGenerating = true
        generateError = ""
        Task {
            do {
                let draft = try await CleanupFormattingService().generateStyleDraft(
                    request: request,
                    settings: coordinator.settings
                )
                await MainActor.run {
                    withAnimation(.snappy(duration: 0.28)) {
                        isGenerating = false
                        generateError = ""
                        didGenerate = true
                        styleName = draft.name
                        stylePrompt = draft.prompt
                    }
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    generateError = error.localizedDescription
                }
            }
        }
    }

    private var selectedAppChoice: StyleAppChoice? {
        cachedAppChoices.first { $0.id == selectedAppID }
    }

    private var appsAvailableToAdd: [StyleAppChoice] {
        cachedAppChoices.filter { choice in
            !coordinator.settings.appStyleOverrides.contains { existing in
                matches(existing, choice)
            }
        }
    }

    private var filteredAppsToAdd: [StyleAppChoice] {
        let trimmed = appSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return appsAvailableToAdd }
        return appsAvailableToAdd.filter {
            $0.appName.localizedCaseInsensitiveContains(trimmed) ||
                $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func binding(for override: AppStyleOverride) -> Binding<StyleRef> {
        Binding {
            coordinator.settings.appStyleOverrides.first(where: { $0.id == override.id })?.style ?? override.style
        } set: { value in
            guard let index = coordinator.settings.appStyleOverrides.firstIndex(where: { $0.id == override.id }) else { return }
            coordinator.settings.appStyleOverrides[index].style = value
        }
    }

    private func matches(_ override: AppStyleOverride, _ choice: StyleAppChoice) -> Bool {
        (!override.bundleID.isEmpty && override.bundleID == choice.bundleID) || override.appName == choice.appName
    }

    private func selectApp(_ choice: StyleAppChoice) {
        selectedAppID = choice.id
        appSearch = ""
        if let existing = coordinator.settings.appStyleOverrides.first(where: { matches($0, choice) }) {
            selectedAppStyle = existing.style
        }
    }

    private func beginOverrideAdd() {
        cachedAppChoices = collectAvailableAppChoices()
        isAddingOverride = true
        selectedAppID = ""
        appSearch = ""
        selectedAppStyle = .preset(.auto)
    }

    private func cancelOverrideComposer() {
        isAddingOverride = false
        selectedAppID = ""
        appSearch = ""
        selectedAppStyle = .preset(.auto)
    }

    private func addSelectedAppOverride() {
        guard let choice = selectedAppChoice else { return }
        if let index = coordinator.settings.appStyleOverrides.firstIndex(where: { matches($0, choice) }) {
            coordinator.settings.appStyleOverrides[index].style = selectedAppStyle
        } else {
            coordinator.settings.appStyleOverrides.append(
                AppStyleOverride(appName: choice.appName, bundleID: choice.bundleID, style: selectedAppStyle)
            )
        }
        cancelOverrideComposer()
    }

    private func collectAvailableAppChoices() -> [StyleAppChoice] {
        var choices: [StyleAppChoice] = []
        var indexByBundle = [String: Int]()
        var indexByName = [String: Int]()

        func add(_ appName: String, _ bundleID: String?) {
            let cleanedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedBundleID = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedName.isEmpty else { return }
            guard cleanedBundleID != Bundle.main.bundleIdentifier else { return }
            let nameKey = normalizedAppName(cleanedName)
            if let bundleIndex = indexByBundle[cleanedBundleID], !cleanedBundleID.isEmpty {
                choices[bundleIndex] = bestChoice(existing: choices[bundleIndex],
                                                  candidate: StyleAppChoice(appName: cleanedName, bundleID: cleanedBundleID))
                return
            }
            if let nameIndex = indexByName[nameKey] {
                choices[nameIndex] = bestChoice(existing: choices[nameIndex],
                                                candidate: StyleAppChoice(appName: cleanedName, bundleID: cleanedBundleID))
                if !cleanedBundleID.isEmpty {
                    indexByBundle[cleanedBundleID] = nameIndex
                }
                return
            }
            let choice = StyleAppChoice(appName: cleanedName, bundleID: cleanedBundleID)
            choices.append(choice)
            let newIndex = choices.count - 1
            indexByName[nameKey] = newIndex
            if !cleanedBundleID.isEmpty {
                indexByBundle[cleanedBundleID] = newIndex
            }
        }

        for item in coordinator.history.items {
            add(item.appName, item.bundleID)
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            add(app.localizedName ?? "", app.bundleIdentifier)
        }
        for known in StyleAppChoice.knownApps {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: known.bundleID) != nil
                || known.installedPath.map({ FileManager.default.fileExists(atPath: $0) }) == true {
                add(known.appName, known.bundleID)
            }
        }
        return choices.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    private func normalizedAppName(_ value: String) -> String {
        let normalized = value.lowercased()
            .replacingOccurrences(of: "adobe pho...", with: "adobe photoshop")
            .replacingOccurrences(of: "google chrome", with: "chrome")
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("arc") { return "arc" }
        if normalized.contains("claude") { return "claude" }
        if normalized.contains("chatgpt") { return "chatgpt" }
        if normalized.contains("codex") { return "codex" }
        if normalized.contains("photoshop") || normalized.contains("adobe pho") { return "adobe photoshop" }
        return normalized
    }

    private func bestChoice(existing: StyleAppChoice, candidate: StyleAppChoice) -> StyleAppChoice {
        if existing.bundleID.isEmpty && !candidate.bundleID.isEmpty { return candidate }
        if existing.installedPath == nil && candidate.installedPath != nil { return candidate }
        if existing.appName.contains("...") && !candidate.appName.contains("...") { return candidate }
        return existing
    }
}

/// Button + popover. SwiftUI Menu + fixedSize inside ScrollView measures NSMenu
/// against an unbounded height and beachballs the main thread on scroll.
private struct StyleAssignmentChip: View {
    @Binding var selection: StyleRef
    let choices: [StyleRef]
    let title: (StyleRef) -> String
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            FlowMenuValueLabel(title: title(selection))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(title(selection))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FlowPopoverChoiceList(
                options: choices,
                selection: $selection,
                title: title,
                isOpen: $isOpen
            )
        }
    }
}

private struct StylePickerRow<Trailing: View>: View {
    let name: String
    let summary: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    let trailing: Trailing
    @State private var isHovering = false

    init(name: String,
         summary: String,
         symbol: String,
         selected: Bool,
         action: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing) {
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.selected = selected
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowUI.moss)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(summary)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .layoutPriority(-1)
                    Spacer(minLength: 6)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? FlowUI.moss : FlowUI.ink.opacity(0.28))
                        .accessibilityLabel(selected ? "Selected" : "Not selected")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityHint("Sets the default style")
            trailing
        }
        .flowInsetRowPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected
                ? FlowUI.moss.opacity(isHovering ? 0.22 : 0.16)
                : (isHovering ? FlowUI.hoverFill : FlowUI.controlFill),
            in: RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
                .stroke(selected ? FlowUI.moss.opacity(0.48) : (isHovering ? FlowUI.moss.opacity(0.18) : Color.clear))
        }
        .onHover { isHovering = $0 }
    }
}

extension StylePickerRow where Trailing == EmptyView {
    init(name: String,
         summary: String,
         symbol: String,
         selected: Bool,
         action: @escaping () -> Void) {
        self.init(name: name, summary: summary, symbol: symbol, selected: selected, action: action) {
            EmptyView()
        }
    }
}

private struct StyleAppChoice: Identifiable, Hashable {
    var appName: String
    var bundleID: String
    var installedPath: String? = nil
    var id: String { bundleID.isEmpty ? appName.lowercased() : bundleID }

    static let knownApps: [StyleAppChoice] = [
        StyleAppChoice(appName: "Arc", bundleID: "company.thebrowser.Browser", installedPath: "/Applications/Arc.app"),
        StyleAppChoice(appName: "ChatGPT", bundleID: "com.openai.chat", installedPath: "/Applications/ChatGPT.app"),
        StyleAppChoice(appName: "Claude", bundleID: "com.anthropic.claudefordesktop", installedPath: "/Applications/Claude.app"),
        StyleAppChoice(appName: "Codex", bundleID: "com.openai.codex", installedPath: "/Applications/Codex.app"),
        StyleAppChoice(appName: "Adobe Photoshop", bundleID: "com.adobe.Photoshop", installedPath: "/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app"),
        StyleAppChoice(appName: "Safari", bundleID: "com.apple.Safari"),
        StyleAppChoice(appName: "Google Chrome", bundleID: "com.google.Chrome"),
        StyleAppChoice(appName: "Brave Browser", bundleID: "com.brave.Browser"),
        StyleAppChoice(appName: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        StyleAppChoice(appName: "Ghostty", bundleID: "com.mitchellh.ghostty", installedPath: "/Applications/Ghostty.app"),
        StyleAppChoice(appName: "Terminal", bundleID: "com.apple.Terminal"),
        StyleAppChoice(appName: "iTerm", bundleID: "com.googlecode.iterm2"),
        StyleAppChoice(appName: "Messages", bundleID: "com.apple.MobileSMS"),
        StyleAppChoice(appName: "Mail", bundleID: "com.apple.mail"),
        StyleAppChoice(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
        StyleAppChoice(appName: "Discord", bundleID: "com.hnc.Discord"),
        StyleAppChoice(appName: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        StyleAppChoice(appName: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", installedPath: "/Applications/Cursor.app"),
        StyleAppChoice(appName: "Microsoft Word", bundleID: "com.microsoft.Word")
    ]
}
