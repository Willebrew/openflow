import SwiftUI
import AppKit

enum FlowUI {
    static let pageBackground = Color.clear
    static let panel = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.12)
    static let glassHairline = Color.white.opacity(0.18)
    static let mutedFill = Color.white.opacity(0.045)
    static let controlFill = Color.white.opacity(0.07)
    static let warmGlass = Color.white.opacity(0.02)
    static let glassScrim = Color.black.opacity(0.40)
    static let ink = Color(red: 0.945, green: 0.955, blue: 0.965)
    static let moss = Color(red: 0.48, green: 0.82, blue: 0.74)
    static let success = Color(red: 0.25, green: 0.94, blue: 0.58)
    static let coral = Color(red: 0.96, green: 0.42, blue: 0.32)
    static let amber = Color(red: 0.97, green: 0.72, blue: 0.28)
    static let violet = Color(red: 0.60, green: 0.56, blue: 0.92)
    static let accent = Color(red: 0.945, green: 0.955, blue: 0.965)
    static let selectedFill = Color.white.opacity(0.11)
    static let hoverFill = Color.white.opacity(0.055)
    /// Search fields, toolbar Add/Save/Clear, and inset rows share this radius.
    static let controlCornerRadius: CGFloat = 10
    /// Search fields and the toolbar buttons that sit beside them share this height.
    static let controlHeight: CGFloat = 40
    /// Home / History / Dictionary / Phrases / Style page inset. Settings keeps 30.
    static let hubPageHorizontalPadding: CGFloat = 18
    static let hubPageVerticalPadding: CGFloat = 12
    /// 22pt bold title line. Trailing + must not grow this or titles shift across tabs.
    static let hubTitleRowHeight: CGFloat = 26
    /// Extra inset-row trailing space so an overlay NSScroller cannot cover 28pt actions.
    static let overlayScrollerGutter: CGFloat = 12
    /// Flow Hub content size. Max equals design so the dashboard cannot grow past this.
    static let hubWindowWidth: CGFloat = 880
    static let hubWindowHeight: CGFloat = 640
    /// Settings detail pane page title row. General / Permissions / Subscription / Shortcuts / Updates share this.
    static let settingsDetailHeaderInset: CGFloat = 24
    static let settingsDetailHeaderIconSize: CGFloat = 30
    static let settingsDetailHeaderIconFont: CGFloat = 15
    static let settingsDetailHeaderTitleFont: CGFloat = 22
    static let settingsDetailHeaderIconTitleGap: CGFloat = 11
    /// Gap from the page title to the first content container on every Settings pane.
    static let settingsDetailTitleContentGap: CGFloat = 18
}

struct FlowBehindWindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
    }
}

struct FlowWindowBackdrop: View {
    var body: some View {
        ZStack {
            FlowBehindWindowBlur()
            FlowUI.glassScrim
            FlowUI.warmGlass
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(height: 1)
        }
        .ignoresSafeArea()
    }
}

struct FlowLiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = 8
    var tintOpacity: Double = 0.05
    var interactive = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let glass = interactive
            ? Glass.regular.tint(Color.white.opacity(tintOpacity)).interactive()
            : Glass.regular.tint(Color.white.opacity(tintOpacity))
        content
            .background(Color.white.opacity(0.025), in: shape)
            .glassEffect(glass, in: shape)
            .overlay(shape.stroke(FlowUI.glassHairline))
    }
}

extension View {
    func flowLiquidGlass(cornerRadius: CGFloat = 8, tintOpacity: Double = 0.05, interactive: Bool = false) -> some View {
        modifier(FlowLiquidGlass(cornerRadius: cornerRadius, tintOpacity: tintOpacity, interactive: interactive))
    }

    func flowHubPagePadding() -> some View {
        padding(.horizontal, FlowUI.hubPageHorizontalPadding)
            .padding(.vertical, FlowUI.hubPageVerticalPadding)
    }

    /// Compact hub lists hide the overlay NSScroller so it cannot sit on 28pt trailing actions.
    /// Trackpad and mouse wheel still scroll. Do not use this on Settings.
    func flowHubListScroll() -> some View {
        scrollIndicators(.hidden)
    }

    /// Inset fill padding. Trailing includes overlayScrollerGutter so trash/pencil/copy stay clear.
    func flowInsetRowPadding() -> some View {
        padding(.leading, 10)
            .padding(.trailing, 10 + FlowUI.overlayScrollerGutter)
            .padding(.vertical, 8)
    }
}

struct FlowPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(FlowUI.ink)
            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Compact section title with an optional count chip, matching hub list headers.
struct FlowSectionCountHeader: View {
    let title: String
    let count: Int
    /// Singular noun for VoiceOver, e.g. `"saved term"`.
    let countNoun: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(FlowUI.ink.opacity(0.74))
                    .padding(.horizontal, 8)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(FlowUI.controlFill, in: Capsule())
                    .overlay(Capsule().stroke(FlowUI.glassHairline))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard count > 0 else { return title }
        let noun = count == 1 ? countNoun : "\(countNoun)s"
        return "\(count) \(noun)"
    }
}

struct FlowCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowLiquidGlass(cornerRadius: 8)
    }
}

struct FlowListRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowLiquidGlass(cornerRadius: 16, tintOpacity: 0.04)
    }
}

struct FlowGlassField<Content: View>: View {
    let content: Content
    @State private var isHovering = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(Color.white.opacity(isHovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovering ? FlowUI.ink.opacity(0.18) : FlowUI.glassHairline)
                .allowsHitTesting(false)
        }
        .onHover { isHovering = $0 }
    }
}

struct FlowFieldRowArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 38)
    }
}

struct FlowSearchField: View {
    let placeholder: String
    @Binding var text: String
    @State private var isHovering = false
    @State private var isFocused = false

    var body: some View {
        ZStack(alignment: .leading) {
            FlowNativeTextField(placeholder: placeholder,
                                text: $text,
                                insets: NSEdgeInsets(top: 0, left: 32, bottom: 0, right: 12),
                                onEditingChanged: { isFocused = $0 })
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .padding(.leading, 13)
                .allowsHitTesting(false)
        }
        .frame(height: FlowUI.controlHeight)
        .background(
            Color.white.opacity(isHovering || isFocused ? 0.09 : 0.05),
            in: RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
                .stroke(isFocused ? FlowUI.ink.opacity(0.18) : isHovering ? FlowUI.ink.opacity(0.18) : FlowUI.glassHairline)
                .allowsHitTesting(false)
        }
        .onHover { isHovering = $0 }
    }
}

struct FlowInputField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    @State private var isFocused = false
    @State private var isHovering = false

    var body: some View {
        FlowNativeTextField(placeholder: placeholder,
                            text: $text,
                            isSecure: isSecure,
                            onEditingChanged: { isFocused = $0 })
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(FlowUI.ink.opacity(isFocused ? 0.052 : isHovering ? 0.045 : 0.035),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(stroke)
                    .allowsHitTesting(false)
            }
            .onHover { isHovering = $0 }
    }

    private var stroke: Color {
        if isFocused { return FlowUI.ink.opacity(0.24) }
        if isHovering { return FlowUI.ink.opacity(0.16) }
        return FlowUI.hairline
    }
}

/// Chrome only. Do not wrap in extra FocusState or animate the field editor;
/// that recreates first responder and fights typing (NQL-206).
struct FlowTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        FlowTextFieldBody(configuration: configuration)
    }
}

private struct FlowTextFieldBody: View {
    let configuration: TextField<FlowTextFieldStyle._Label>
    @State private var isHovering = false

    var body: some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(FlowUI.ink.opacity(isHovering ? 0.045 : 0.035),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7).stroke(isHovering ? FlowUI.ink.opacity(0.16) : FlowUI.hairline)
                    .allowsHitTesting(false)
            }
            .background(FlowCaretFixer())
            .onHover { isHovering = $0 }
    }
}

private enum FlowFieldChrome {
    static let ink = NSColor(calibratedRed: 0.945, green: 0.955, blue: 0.965, alpha: 1)
    static let placeholder = NSColor(calibratedWhite: 1, alpha: 0.38)

    static func applyCaret(to field: NSTextField) {
        (field.currentEditor() as? NSTextView)?.insertionPointColor = ink
        if field.currentEditor() == nil {
            DispatchQueue.main.async {
                (field.currentEditor() as? NSTextView)?.insertionPointColor = ink
            }
        }
    }
}

/// Turns off AppKit completions, inline predictions, and Writing Tools so focusing
/// a field does not flash a suggestions dropdown.
private enum FlowFieldAutofill {
    static func disable(on field: NSTextField) {
        field.isAutomaticTextCompletionEnabled = false
        field.allowsCharacterPickerTouchBarItem = false
        field.importsGraphics = false
        field.allowsWritingTools = false
        field.allowsWritingToolsAffordance = false
        disable(on: field.currentEditor() as? NSTextView)
    }

    static func prepareFieldEditor(for field: NSTextField) {
        disable(on: field)
        if let editor = field.window?.fieldEditor(true, for: field) as? NSTextView {
            disable(on: editor)
        }
    }

    static func disable(on textView: NSTextView?) {
        guard let textView else { return }
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.allowsCharacterPickerTouchBarItem = false
        textView.isIncrementalSearchingEnabled = false
        textView.importsGraphics = false
        textView.inlinePredictionType = .no
        textView.mathExpressionCompletionType = .no
        textView.writingToolsBehavior = .none
    }
}

struct FlowNativeTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var isSecure = false
    var fontSize: CGFloat = 14
    var weight: NSFont.Weight = .medium
    var insets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onSubmit: (() -> Void)? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEditingChanged: onEditingChanged, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> FlowFieldHitHost {
        let field: NSTextField = isSecure ? FlowCaretSecureField() : FlowCaretTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        field.textColor = FlowFieldChrome.ink
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.alignment = .left
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        FlowFieldAutofill.disable(on: field)
        applyInsets(field)
        applyPlaceholder(field)
        let host = FlowFieldHitHost(field: field)
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return host
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FlowFieldHitHost, context: Context) -> CGSize? {
        FlowNativeFieldSize.fitting(proposal, fallbackHeight: 38)
    }

    func updateNSView(_ nsView: FlowFieldHitHost, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEditingChanged = onEditingChanged
        context.coordinator.onSubmit = onSubmit
        let field = nsView.field
        field.isEditable = isEnabled
        field.isSelectable = isEnabled
        field.textColor = FlowFieldChrome.ink
        field.alignment = .left
        applyInsets(field)
        applyPlaceholder(field)
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        FlowFieldAutofill.disable(on: field)
        FlowFieldChrome.applyCaret(to: field)
    }

    private func applyInsets(_ field: NSTextField) {
        if let field = field as? FlowCaretTextField {
            field.contentInsets = insets
        }
        if let field = field as? FlowCaretSecureField {
            field.contentInsets = insets
        }
    }

    private func applyPlaceholder(_ field: NSTextField) {
        let style = NSMutableParagraphStyle()
        style.alignment = field.alignment
        style.lineBreakMode = .byTruncatingTail
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: FlowFieldChrome.placeholder,
                .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                .paragraphStyle: style
            ]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onEditingChanged: ((Bool) -> Void)?
        var onSubmit: (() -> Void)?

        init(text: Binding<String>, onEditingChanged: ((Bool) -> Void)?, onSubmit: (() -> Void)?) {
            self.text = text
            self.onEditingChanged = onEditingChanged
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                FlowFieldAutofill.disable(on: field)
                FlowFieldChrome.applyCaret(to: field)
            }
            onEditingChanged?(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            onEditingChanged?(false)
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), onSubmit != nil else {
                return false
            }
            onSubmit?()
            return true
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     completions words: [String],
                     forPartialWordRange charRange: NSRange,
                     indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            index.pointee = -1
            return []
        }
    }
}

/// Insets the cell frame so placeholder, typed text, and the field editor all
/// use the same vertically centered rect. Computed locally — do not store an
/// install flag, or AppKit re-entering the cell will trip Swift exclusivity.
private enum FlowCenteredFieldMetrics {
    static func aligned(_ frame: NSRect, font: NSFont?, in controlView: NSView?) -> NSRect {
        let resolved = font ?? NSFont.systemFont(ofSize: 14, weight: .medium)
        let textHeight = ceil(resolved.boundingRectForFont.height)
        let insets = Self.insets(for: controlView)
        let insetY = max(insets.top, insets.bottom, ((frame.height - textHeight) / 2).rounded(.down))
        return NSRect(
            x: frame.minX + insets.left,
            y: frame.minY + insetY,
            width: max(0, frame.width - insets.left - insets.right),
            height: max(0, frame.height - (insetY * 2))
        )
    }

    static func insets(for view: NSView?) -> NSEdgeInsets {
        if let field = view as? FlowCaretTextField { return field.contentInsets }
        if let field = view as? FlowCaretSecureField { return field.contentInsets }
        return NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    }
}

private final class FlowCenteredTextFieldCell: NSTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: FlowCenteredFieldMetrics.aligned(cellFrame, font: font, in: controlView), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        FlowFieldAutofill.disable(on: textObj as? NSTextView)
        super.edit(withFrame: FlowCenteredFieldMetrics.aligned(rect, font: font, in: controlView),
                   in: controlView,
                   editor: textObj,
                   delegate: delegate,
                   event: event)
        FlowFieldAutofill.disable(on: textObj as? NSTextView)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        FlowFieldAutofill.disable(on: textObj as? NSTextView)
        super.select(withFrame: FlowCenteredFieldMetrics.aligned(rect, font: font, in: controlView),
                     in: controlView,
                     editor: textObj,
                     delegate: delegate,
                     start: selStart,
                     length: selLength)
        FlowFieldAutofill.disable(on: textObj as? NSTextView)
    }
}

private final class FlowCenteredSecureTextFieldCell: NSSecureTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: FlowCenteredFieldMetrics.aligned(cellFrame, font: font, in: controlView), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        FlowFieldAutofill.disable(on: textObj as? NSTextView)
        super.edit(withFrame: FlowCenteredFieldMetrics.aligned(rect, font: font, in: controlView),
                   in: controlView,
                   editor: textObj,
                   delegate: delegate,
                   event: event)
        FlowFieldAutofill.disable(on: textObj as? NSTextView)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        FlowFieldAutofill.disable(on: textObj as? NSTextView)
        super.select(withFrame: FlowCenteredFieldMetrics.aligned(rect, font: font, in: controlView),
                     in: controlView,
                     editor: textObj,
                     delegate: delegate,
                     start: selStart,
                     length: selLength)
        FlowFieldAutofill.disable(on: textObj as? NSTextView)
    }
}

private final class FlowCaretTextField: NSTextField {
    var contentInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

    override class var cellClass: AnyClass? {
        get { FlowCenteredTextFieldCell.self }
        set {}
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        FlowFieldAutofill.prepareFieldEditor(for: self)
        let accepted = super.becomeFirstResponder()
        if accepted {
            FlowFieldAutofill.disable(on: currentEditor() as? NSTextView)
            FlowFieldChrome.applyCaret(to: self)
        }
        return accepted
    }
}

private final class FlowCaretSecureField: NSSecureTextField {
    var contentInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

    override class var cellClass: AnyClass? {
        get { FlowCenteredSecureTextFieldCell.self }
        set {}
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        FlowFieldAutofill.prepareFieldEditor(for: self)
        let accepted = super.becomeFirstResponder()
        if accepted {
            FlowFieldAutofill.disable(on: currentEditor() as? NSTextView)
            FlowFieldChrome.applyCaret(to: self)
        }
        return accepted
    }
}

private enum FlowNativeFieldSize {
    static func fitting(_ proposal: ProposedViewSize, fallbackHeight: CGFloat) -> CGSize {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            width = proposed
        } else {
            width = 120
        }
        let height: CGFloat
        if let proposed = proposal.height, proposed.isFinite, proposed > 0 {
            height = proposed
        } else {
            height = fallbackHeight
        }
        return CGSize(width: width, height: height)
    }
}

final class FlowFieldHitHost: NSView {
    let field: NSTextField
    private var tracking: NSTrackingArea?
    private var pushedIBeam = false

    init(field: NSTextField) {
        self.field = field
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("flow.field.host")
        addSubview(field)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        field.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            popIBeam()
        }
        updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        pushIBeam()
    }

    override func mouseExited(with event: NSEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.popIBeamIfMouseLeft()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        if let editor = field.currentEditor() as? NSView {
            return editor
        }
        return field
    }

    private func popIBeamIfMouseLeft() {
        guard let window else {
            popIBeam()
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.insetBy(dx: -1, dy: -1).contains(point) { return }
        popIBeam()
    }

    private func pushIBeam() {
        guard !pushedIBeam else { return }
        NSCursor.iBeam.push()
        pushedIBeam = true
    }

    private func popIBeam() {
        guard pushedIBeam else { return }
        NSCursor.pop()
        pushedIBeam = false
    }
}

private struct FlowCaretFixer: NSViewRepresentable {
    func makeNSView(context: Context) -> FlowCaretFixView {
        FlowCaretFixView()
    }

    func updateNSView(_ nsView: FlowCaretFixView, context: Context) {
        nsView.apply()
    }
}

private final class FlowCaretFixView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        var current: NSView? = superview
        while let view = current {
            paint(view)
            current = view.superview
        }
    }

    private func paint(_ view: NSView) {
        if let field = view as? NSTextField {
            FlowFieldChrome.applyCaret(to: field)
        }
        if let textView = view as? NSTextView {
            textView.insertionPointColor = FlowFieldChrome.ink
        }
        view.subviews.forEach(paint)
    }
}

struct FlowPrimaryButtonStyle: ButtonStyle {
    var disabled = false

    func makeBody(configuration: Configuration) -> some View {
        FlowPrimaryButtonBody(configuration: configuration, disabled: disabled)
    }
}

private struct FlowPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let disabled: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color(red: 0.02, green: 0.025, blue: 0.03))
            .padding(.horizontal, 14)
            .frame(height: FlowUI.controlHeight)
            .background(background, in: shape)
            .overlay(shape.stroke(.white.opacity(isHovering && !disabled ? 0.22 : 0)))
            .scaleEffect(configuration.isPressed ? 0.965 : isHovering && !disabled ? 1.025 : 1)
            .shadow(color: .black.opacity(isHovering && !disabled ? 0.08 : 0),
                    radius: isHovering ? 5 : 0,
                    x: 0,
                    y: 3)
            .animation(.spring(response: 0.18, dampingFraction: 0.78), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
    }

    private var background: Color {
        if disabled { return Color.white.opacity(0.22) }
        if configuration.isPressed { return FlowUI.ink.opacity(0.78) }
        if isHovering { return Color.white }
        return FlowUI.ink
    }
}

struct FlowSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FlowSecondaryButtonBody(configuration: configuration)
    }
}

private struct FlowSecondaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(FlowUI.ink.opacity(isEnabled ? 1 : 0.38))
            .padding(.horizontal, 14)
            .frame(height: FlowUI.controlHeight)
            .background(background, in: shape)
            .overlay(shape.stroke(stroke))
            .scaleEffect(configuration.isPressed ? 0.965 : isHovering && isEnabled ? 1.025 : 1)
            .shadow(color: .black.opacity(isHovering && isEnabled ? 0.06 : 0),
                    radius: isHovering ? 4 : 0,
                    x: 0,
                    y: 3)
            .animation(.spring(response: 0.18, dampingFraction: 0.78), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
    }

    private var background: Color {
        if !isEnabled { return Color.white.opacity(0.05) }
        if configuration.isPressed { return Color.white.opacity(0.15) }
        if isHovering { return Color.white.opacity(0.13) }
        return FlowUI.controlFill
    }

    private var stroke: Color {
        if configuration.isPressed { return FlowUI.ink.opacity(0.20) }
        if isHovering && isEnabled { return FlowUI.ink.opacity(0.16) }
        return isHovering ? Color.white.opacity(0.62) : FlowUI.glassHairline
    }
}

struct FlowMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var width: CGFloat = 180
    var flexible = false
    @State private var isHovering = false
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 10) {
                Text(title(selection))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FlowUI.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: flexible ? .infinity : width, alignment: .leading)
            .frame(width: flexible ? nil : width, height: 38)
            .background(Color.white.opacity(isHovering ? 0.09 : 0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHovering ? FlowUI.ink.opacity(0.20) : FlowUI.glassHairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: flexible ? nil : width, height: 38)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FlowPopoverChoiceList(
                options: options,
                selection: $selection,
                title: title,
                isOpen: $isOpen
            )
        }
    }
}

/// iOS Settings-style row: title on the left, value on the right, one disclosure.
/// Use this instead of a trailing `FlowMenuPicker` pill so the system Menu chevron
/// cannot stack on a custom `chevron.down`.
struct FlowSettingsMenuRow<Value: Hashable>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var selection: Value
    let options: [Value]
    let valueTitle: (Value) -> String

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowUI.ink)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(-1)
                Spacer(minLength: 8)
                Text(valueTitle(selection))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FlowPopoverChoiceList(
                options: options,
                selection: $selection,
                title: valueTitle,
                isOpen: $isOpen
            )
        }
    }
}

/// Choice list for assignment chips. Do not use SwiftUI Menu here: Menu+fixedSize
/// inside a ScrollView measures NSMenu on the main thread and beachballs.
struct FlowPopoverChoiceList<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    @Binding var isOpen: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                        isOpen = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(title(option))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(FlowUI.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if option == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(FlowUI.moss)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .frame(minWidth: 200, maxHeight: 280)
    }
}

struct FlowMenuValueLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

struct FlowMultilineField: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 96
    @State private var isFocused = false
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            FlowNativeTextView(text: $text, onEditingChanged: { isFocused = $0 })
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.72))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .background(FlowUI.ink.opacity(isFocused ? 0.052 : isHovering ? 0.045 : 0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isFocused ? FlowUI.ink.opacity(0.24) :
                        isHovering ? FlowUI.ink.opacity(0.16) : FlowUI.hairline)
                .allowsHitTesting(false)
        }
        .onHover { isHovering = $0 }
    }
}

private struct FlowNativeTextView: NSViewRepresentable {
    @Binding var text: String
    var onEditingChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEditingChanged: onEditingChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = FlowCaretTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        FlowFieldAutofill.disable(on: textView)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = FlowFieldChrome.ink
        textView.insertionPointColor = FlowFieldChrome.ink
        textView.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        scroll.documentView = textView
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        FlowNativeFieldSize.fitting(proposal, fallbackHeight: 96)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEditingChanged = onEditingChanged
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.insertionPointColor = FlowFieldChrome.ink
        textView.textColor = FlowFieldChrome.ink
        if textView.window?.firstResponder !== textView, textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onEditingChanged: ((Bool) -> Void)?

        init(text: Binding<String>, onEditingChanged: ((Bool) -> Void)?) {
            self.text = text
            self.onEditingChanged = onEditingChanged
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                FlowFieldAutofill.disable(on: textView)
                textView.insertionPointColor = FlowFieldChrome.ink
            }
            onEditingChanged?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            onEditingChanged?(false)
        }

        func textView(_ textView: NSTextView,
                      completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            index?.pointee = -1
            return []
        }
    }
}

private final class FlowCaretTextView: NSTextView {
    override func becomeFirstResponder() -> Bool {
        FlowFieldAutofill.disable(on: self)
        let accepted = super.becomeFirstResponder()
        if accepted {
            FlowFieldAutofill.disable(on: self)
            insertionPointColor = FlowFieldChrome.ink
        }
        return accepted
    }
}

struct FlowEmptyState: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(FlowUI.mutedFill, in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(.system(size: 16, weight: .bold))
            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

struct AppIconBadge: View {
    let appName: String
    let bundleID: String?
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image = AppIconLookup.image(appName: appName, bundleID: bundleID) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.04)
                    .frame(width: size, height: size)
            } else {
                Text(initials)
                    .font(.system(size: max(10, size * 0.36), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: size * 0.22))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.22).stroke(.white.opacity(0.16), lineWidth: 1))
            }
        }
    }

    private var initials: String {
        let words = appName.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

private enum AppIconLookup {
    private static let lock = NSLock()
    private static var hits = [String: NSImage]()
    private static var misses = Set<String>()

    static func image(appName: String, bundleID: String?) -> NSImage? {
        let key = cacheKey(appName: appName, bundleID: bundleID)
        lock.lock()
        if let cached = hits[key] {
            lock.unlock()
            return cached
        }
        if misses.contains(key) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let resolved = resolve(appName: appName, bundleID: bundleID)
        lock.lock()
        if let resolved {
            hits[key] = resolved
        } else {
            misses.insert(key)
        }
        lock.unlock()
        return resolved
    }

    private static func cacheKey(appName: String, bundleID: String?) -> String {
        if let bundleID, !bundleID.isEmpty { return "id:\(bundleID)" }
        return "name:\(normalized(appName))"
    }

    private static func resolve(appName: String, bundleID: String?) -> NSImage? {
        if let bundleID, !bundleID.isEmpty {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
               let icon = app.icon {
                return icon
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        let normalized = Self.normalized(appName)
        if let app = NSWorkspace.shared.runningApplications.first(where: { Self.normalized($0.localizedName ?? "") == normalized }),
           let icon = app.icon {
            return icon
        }
        if let knownBundleID = Self.knownBundleIDs[normalized],
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: knownBundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let knownPath = Self.knownAppPaths[normalized],
           FileManager.default.fileExists(atPath: knownPath) {
            return NSWorkspace.shared.icon(forFile: knownPath)
        }
        if let knownBundleID = Self.knownBundleIDs.first(where: { normalized.contains($0.key) || $0.key.contains(normalized) })?.value,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: knownBundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let knownPath = Self.knownAppPaths.first(where: { normalized.contains($0.key) || $0.key.contains(normalized) })?.value,
           FileManager.default.fileExists(atPath: knownPath) {
            return NSWorkspace.shared.icon(forFile: knownPath)
        }
        if let discoveredPath = Self.discoverInstalledApp(named: normalized) {
            return NSWorkspace.shared.icon(forFile: discoveredPath)
        }
        return nil
    }

    private static let knownBundleIDs: [String: String] = [
        "arc": "company.thebrowser.Browser",
        "the browser company": "company.thebrowser.Browser",
        "safari": "com.apple.Safari",
        "google chrome": "com.google.Chrome",
        "chrome": "com.google.Chrome",
        "brave browser": "com.brave.Browser",
        "brave": "com.brave.Browser",
        "microsoft edge": "com.microsoft.edgemac",
        "edge": "com.microsoft.edgemac",
        "firefox": "org.mozilla.firefox",
        "ghostty": "com.mitchellh.ghostty",
        "terminal": "com.apple.Terminal",
        "iterm": "com.googlecode.iterm2",
        "iterm2": "com.googlecode.iterm2",
        "visual studio code": "com.microsoft.VSCode",
        "vs code": "com.microsoft.VSCode",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "messages": "com.apple.MobileSMS",
        "mail": "com.apple.mail",
        "slack": "com.tinyspeck.slackmacgap",
        "discord": "com.hnc.Discord",
        "notion": "notion.id",
        "linear": "com.linear",
        "chatgpt": "com.openai.chat",
        "claude": "com.anthropic.claudefordesktop",
        "codex": "com.openai.codex",
        "adobe photoshop": "com.adobe.Photoshop",
        "microsoft word": "com.microsoft.Word"
    ]

    private static let knownAppPaths: [String: String] = [
        "arc": "/Applications/Arc.app",
        "chatgpt": "/Applications/ChatGPT.app",
        "claude": "/Applications/Claude.app",
        "codex": "/Applications/Codex.app",
        "adobe photoshop": "/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app",
        "ghostty": "/Applications/Ghostty.app",
        "cursor": "/Applications/Cursor.app",
        "linear": "/Applications/Linear.app"
    ]

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }

    private static func discoverInstalledApp(named normalizedName: String) -> String? {
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        let fileManager = FileManager.default
        let appName = normalizedName
            .replacingOccurrences(of: "adobe pho", with: "adobe photoshop")
            .replacingOccurrences(of: "google chrome", with: "chrome")
        for root in roots {
            guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
            var checked = 0
            for case let path as String in enumerator {
                checked += 1
                if checked > 450 { break }
                guard path.hasSuffix(".app") else { continue }
                let normalizedPath = normalized(path)
                if normalizedPath.contains(appName) || appName.contains(normalizedPath.replacingOccurrences(of: ".app", with: "")) {
                    return (root as NSString).appendingPathComponent(path)
                }
                enumerator.skipDescendants()
            }
        }
        return nil
    }
}

struct FlowBottomFade: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [
                    FlowUI.glassScrim.opacity(0),
                    FlowUI.glassScrim.opacity(0.7),
                    FlowUI.glassScrim
                ],
                startPoint: .top,
                endPoint: .bottom)
                .frame(height: 42)
                .allowsHitTesting(false)
            }
    }
}

extension View {
    func flowBottomFade() -> some View {
        modifier(FlowBottomFade())
    }
}

/// Plan-card features as a real list: a typographic bullet, then 12pt secondary copy.
struct FlowPlanFeatureList: View {
    let detail: String

    private var lines: [String] {
        detail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{2022}")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowUI.ink.opacity(0.52))
                        .accessibilityHidden(true)
                    Text(line)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Compact page title matching Home / History: 22pt name, 12pt subtitle, optional trailing control.
/// Do not put list-length count chips in page headers.
struct FlowCompactPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing
            }
            .frame(height: FlowUI.hubTitleRowHeight, alignment: .center)
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

extension FlowCompactPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Bare field for inline list composers. No pill chrome -- typography matches inset rows.
struct FlowInlineField: View {
    let placeholder: String
    @Binding var text: String
    var fontSize: CGFloat = 12
    var weight: NSFont.Weight = .semibold
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        FlowNativeTextField(
            placeholder: placeholder,
            text: $text,
            fontSize: fontSize,
            weight: weight,
            insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 6),
            onSubmit: onSubmit
        )
        .frame(maxWidth: .infinity)
        .frame(height: 22)
    }
}

struct FlowMossCountChip: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(FlowUI.moss)
            .padding(.horizontal, 8)
            .frame(minWidth: 22, minHeight: 22)
            .background(FlowUI.moss.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(FlowUI.moss.opacity(0.28)))
            .accessibilityHidden(true)
    }
}

/// Last-clip / History row chrome: inset fill, 10pt corners, compact padding.
struct FlowInsetRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .flowInsetRowPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                FlowUI.controlFill,
                in: RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
            )
    }
}

/// Compact glass card matching Home stat cards (pad 12, radius 14).
struct FlowCompactGlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowLiquidGlass(cornerRadius: 14)
    }
}

struct FlowCircleIconButton: View {
    let systemImage: String
    var moss = false
    let accessibilityLabel: String
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(moss ? Color.black.opacity(0.72) : FlowUI.ink.opacity(0.72))
                .frame(width: 28, height: 28)
                .background(moss ? FlowUI.moss : FlowUI.mutedFill, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help ?? accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct FlowCompactEmptyState: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowUI.moss)
                .frame(width: 16, height: 16)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            FlowUI.controlFill,
            in: RoundedRectangle(cornerRadius: FlowUI.controlCornerRadius, style: .continuous)
        )
    }
}
