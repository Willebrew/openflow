import Foundation

struct AgentRunResult {
    var completed: Bool
    var summary: String
    var steps: Int
    var provider = "typesafe"
    var model = "jev-latest"
}

/// Local voice-agent loop. Each step serializes the frontmost app's
/// accessibility tree, asks Jev (via the openflow backend, which holds
/// TYPESAFE_API_KEY) what to do next, executes the chosen action, and repeats
/// until the goal is done, aborted, or the step cap is hit.
@MainActor
final class JevAgentService {
    static let maxSteps = 16
    private static let completionThreshold = 0.75
    private static let confidenceFloor = 0.5
    private static let settleDuration: Duration = .milliseconds(800)

    var onProgress: ((String) -> Void)?

    private let cloud = OpenFlowCloudService()
    private let screen = ScreenStateService()
    private let executor = AgentActionExecutor()
    private var actionLog: [String] = []
    private var lastActionSignature: String?
    private var repeatCount = 0

    func run(instruction: String,
             settings: UserSettings,
             baseURL: URL) async -> AgentRunResult {
        actionLog = []
        lastActionSignature = nil
        repeatCount = 0
        var model = "jev-latest"
        for step in 1...Self.maxSteps {
            guard let state = screen.capture() else {
                return aborted("Accessibility permission is off", steps: step - 1, model: model)
            }
            let answers: [String: AgentAnswer]
            do {
                let response = try await cloud.agentStep(
                    state: statePayload(instruction: instruction, step: step, screen: state),
                    questions: questions(for: state, instruction: instruction),
                    model: model,
                    appName: state.appName,
                    bundleID: state.bundleID,
                    baseURL: baseURL
                )
                if let responseModel = response.model, !responseModel.isEmpty {
                    model = responseModel
                }
                answers = response.answers
            } catch {
                return aborted(error.localizedDescription, steps: step - 1, model: model)
            }

            if (answers["task_complete"]?.noul ?? 0) >= Self.completionThreshold {
                return AgentRunResult(completed: true,
                                      summary: "Goal complete after \(step - 1) actions",
                                      steps: step - 1,
                                      model: model)
            }

            guard let actionChoice = answers["action"],
                  let kind = actionChoice.choice else {
                return aborted("No action chosen", steps: step - 1, model: model)
            }
            if let confidence = actionChoice.confidence, confidence < Self.confidenceFloor {
                return aborted("Jev not confident enough to act (\(Int(confidence * 100))%)",
                               steps: step - 1,
                               model: model)
            }

            switch kind {
            case "done":
                return AgentRunResult(completed: true,
                                      summary: "Finished after \(step - 1) actions",
                                      steps: step - 1,
                                      model: model)
            case "abort":
                return aborted("Jev aborted the task", steps: step - 1, model: model)
            default:
                let signature = actionSignature(kind, answers: answers, state: state)
                if signature == lastActionSignature {
                    repeatCount += 1
                    if repeatCount >= 2 {
                        return aborted("stuck repeating \(kind)", steps: step, model: model)
                    }
                } else {
                    repeatCount = 0
                    lastActionSignature = signature
                }
                let outcome = perform(kind, answers: answers, state: state, instruction: instruction)
                actionLog.append("step \(step): \(kind) -> \(outcome.detail)")
                onProgress?("Step \(step): \(outcome.detail)")
                if !outcome.ok {
                    return aborted(outcome.detail, steps: step, model: model)
                }
            }
            try? await Task.sleep(for: Self.settleDuration)
        }
        return aborted("Reached the \(Self.maxSteps)-step limit", steps: Self.maxSteps, model: model)
    }

    private func aborted(_ reason: String, steps: Int, model: String) -> AgentRunResult {
        AgentRunResult(completed: false, summary: reason, steps: steps, model: model)
    }

    // MARK: - Action dispatch

    private func perform(_ kind: String,
                         answers: [String: AgentAnswer],
                         state: AgentScreenState,
                         instruction: String) -> AgentActionExecutor.Outcome {
        switch kind {
        case "click":
            guard let element = chosenElement(from: answers, state: state) else {
                return .init(ok: false, detail: "click had no target element")
            }
            if AgentActionExecutor.looksDestructive(element),
               !AgentActionExecutor.confirmDestructive(description: "click \(element.title.isEmpty ? element.role : element.title)") {
                return .init(ok: false, detail: "user declined destructive click")
            }
            return executor.execute(.click(elementID: element.id), in: state)
        case "type":
            guard let element = chosenElement(from: answers, state: state) else {
                return .init(ok: false, detail: "type had no target element")
            }
            guard let text = answers["text"]?.choice, !text.isEmpty else {
                return .init(ok: false, detail: "type had no text")
            }
            return executor.execute(.typeText(elementID: element.id, text: text), in: state)
        case "press_key":
            guard let key = answers["key"]?.choice, !key.isEmpty else {
                return .init(ok: false, detail: "press_key had no key")
            }
            if key == "return" || key == "delete",
               let focused = state.elements.first(where: { $0.focused }),
               AgentActionExecutor.looksDestructive(focused),
               !AgentActionExecutor.confirmDestructive(description: "press \(key) on \(focused.title.isEmpty ? focused.role : focused.title)") {
                return .init(ok: false, detail: "user declined \(key)")
            }
            return executor.execute(.pressKey(key), in: state)
        case "scroll":
            let direction = AgentAction.ScrollDirection(rawValue: answers["direction"]?.choice ?? "down") ?? .down
            let elementID = answers["element"]?.choice.flatMap(Int.init)
            return executor.execute(.scroll(elementID: elementID, direction: direction), in: state)
        case "open_app":
            guard let app = answers["app"]?.choice, !app.isEmpty else {
                return .init(ok: false, detail: "open_app had no app")
            }
            // A domain never means an app: "google" from "go to google.com"
            // resolves to the URL in the goal instead.
            if AgentActionExecutor.looksLikeDomain(app) {
                return executor.execute(.openURL(app), in: state)
            }
            if let domain = Self.urlCandidates(in: instruction).first(where: {
                Self.normalizedAppText($0).hasPrefix(Self.normalizedAppText(app))
            }) {
                return executor.execute(.openURL(domain), in: state)
            }
            if Self.wantsAppearancePane(instruction), Self.isSettingsName(app) {
                return executor.execute(
                    .openURL("x-apple.systempreferences:com.apple.Appearance-Settings.extension"),
                    in: state)
            }
            return executor.execute(.openApp(app), in: state)
        case "open_url":
            let raw = answers["url"]?.choice.flatMap { $0 == "none" ? nil : $0 }
                ?? Self.urlCandidates(in: instruction).first
            guard let raw, !raw.isEmpty else {
                return .init(ok: false, detail: "open_url had no URL")
            }
            return executor.execute(.openURL(raw), in: state)
        default:
            return .init(ok: false, detail: "unknown action \(kind)")
        }
    }

    /// Stable identity for a proposed action so the loop can detect Jev
    /// re-issuing the same no-progress step (element ids renumber per capture,
    /// so clicks sign on the element's serialized form, not the id).
    private func actionSignature(_ kind: String,
                                 answers: [String: AgentAnswer],
                                 state: AgentScreenState) -> String {
        switch kind {
        case "click", "type":
            let element = chosenElement(from: answers, state: state)
            return "\(kind)|\(element?.serialized ?? "?")|\(answers["text"]?.choice ?? "")"
        case "press_key":
            return "\(kind)|\(answers["key"]?.choice ?? "")"
        case "scroll":
            return "\(kind)|\(answers["direction"]?.choice ?? "")|\(answers["element"]?.choice ?? "")"
        case "open_app":
            return "\(kind)|\(answers["app"]?.choice ?? "")"
        case "open_url":
            return "\(kind)|\(answers["url"]?.choice ?? "")"
        default:
            return kind
        }
    }

    private func chosenElement(from answers: [String: AgentAnswer],
                               state: AgentScreenState) -> AgentElement? {
        guard let choice = answers["element"]?.choice,
              choice != "none",
              let id = Int(choice) else { return nil }
        return state.elements.first { $0.id == id }
    }

    // MARK: - State + questions

    private func statePayload(instruction: String,
                              step: Int,
                              screen: AgentScreenState) -> [String: AnyCodableValue] {
        [
            "goal": AnyCodableValue(instruction),
            "step": AnyCodableValue("\(step) of \(Self.maxSteps)"),
            "previous_actions": AnyCodableValue(actionLog.isEmpty ? ["none yet"] : actionLog),
            "screen": AnyCodableValue(screen.serialized()),
            "running_apps": AnyCodableValue(screen.runningApps)
        ]
    }

    private func questions(for state: AgentScreenState,
                           instruction: String) -> [String: AgentQuestionSpec] {
        let questions: [String: AgentQuestionSpec] = [
            "task_complete": AgentQuestionSpec(
                type: "noul",
                instructions: "Is the user's goal already fully accomplished given the current screen and previous actions?",
                criteria: [
                    "true": AnyCodableValue("The screen state shows the goal is done; no further action is needed"),
                    "false": AnyCodableValue("At least one more action is required to finish the goal")
                ]),
            "action": AgentQuestionSpec(
                type: "choice",
                instructions: "What is the single next action that most advances the user's goal? Choose abort if the goal cannot be completed safely with these elements.",
                criteria: [
                    "done": AnyCodableValue("The goal is complete; stop acting"),
                    "click": AnyCodableValue("Press or click a visible UI element"),
                    "type": AnyCodableValue("Type text into a focused field"),
                    "press_key": AnyCodableValue("Press a keyboard key such as Return, Tab, or Escape"),
                    "scroll": AnyCodableValue("Scroll to reveal more content"),
                    "open_app": AnyCodableValue("Open or switch to a different application"),
                    "open_url": AnyCodableValue("Open a URL or web address from the goal in the default browser"),
                    "abort": AnyCodableValue("Stop; the goal cannot be achieved safely or confidently")
                ]),
            "element": AgentQuestionSpec(
                type: "choice",
                instructions: "If the next action needs a UI element, which element id is the best target? Choose none when no listed element fits.",
                criteria: elementCriteria(for: state)),
            "key": AgentQuestionSpec(
                type: "choice",
                instructions: "If the next action is a key press, which key should be pressed?",
                criteria: [
                    "return": AnyCodableValue("Confirm, submit, or newline"),
                    "tab": AnyCodableValue("Move focus to the next control"),
                    "escape": AnyCodableValue("Dismiss a dialog, menu, or cancel"),
                    "space": AnyCodableValue("Toggle or activate the focused control"),
                    "delete": AnyCodableValue("Delete the character before the caret"),
                    "up": AnyCodableValue("Move selection up"),
                    "down": AnyCodableValue("Move selection down"),
                    "left": AnyCodableValue("Move selection left"),
                    "right": AnyCodableValue("Move selection right")
                ]),
            "direction": AgentQuestionSpec(
                type: "choice",
                instructions: "If the next action is a scroll, which direction reveals the needed content?",
                criteria: [
                    "up": AnyCodableValue("Reveal content above"),
                    "down": AnyCodableValue("Reveal content below"),
                    "left": AnyCodableValue("Reveal content to the left"),
                    "right": AnyCodableValue("Reveal content to the right")
                ]),
            "text": AgentQuestionSpec(
                type: "choice",
                instructions: "If the next action types text, which text should be typed into the field?",
                criteria: textCandidates(from: instruction)),
            "app": AgentQuestionSpec(
                type: "choice",
                instructions: "If the next action opens an app, which application best serves the goal? When the goal names a web address, prefer the open_url action instead.",
                criteria: appCriteria(for: state, instruction: instruction)),
            "url": AgentQuestionSpec(
                type: "choice",
                instructions: "If the next action opens a web address, which URL from the goal should be opened?",
                criteria: urlCriteria(for: instruction))
        ]
        return questions
    }

    private func elementCriteria(for state: AgentScreenState) -> [String: AnyCodableValue] {
        var criteria: [String: AnyCodableValue] = [
            "none": AnyCodableValue("No listed element is the right target")
        ]
        for element in state.elements {
            criteria[String(element.id)] = AnyCodableValue(element.serialized)
        }
        return criteria
    }

    private func urlCriteria(for instruction: String) -> [String: AnyCodableValue] {
        var criteria: [String: AnyCodableValue] = [
            "none": AnyCodableValue("No URL should be opened")
        ]
        for candidate in Self.urlCandidates(in: instruction) {
            criteria[candidate] = AnyCodableValue("The web address spoken in the goal")
        }
        return criteria
    }

    /// URL-like spans in the instruction: full URLs and bare domains such as
    /// google.com or docs.typesafe.ai/introduction. Speech output sometimes
    /// writes "google dot com", which is normalized first.
    private static func urlCandidates(in text: String) -> [String] {
        let normalized = text.replacingOccurrences(
            of: " dot ", with: ".", options: [.caseInsensitive])
        let pattern = #"\b((?:https?://|www\.)[^\s]+|[a-zA-Z0-9][a-zA-Z0-9-]*(?:\.[a-zA-Z0-9-]+)*\.[a-zA-Z]{2,}(?::\d+)?(?:/[^\s]*)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        return regex.matches(in: normalized, range: range).compactMap { match in
            Range(match.range(at: 1), in: normalized).map { String(normalized[$0]) }
        }
    }

    private static func normalizedAppText(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func wantsAppearancePane(_ instruction: String) -> Bool {
        instruction.range(
            of: #"\b(light mode|dark mode|appearance|dark appearance|light appearance)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isSettingsName(_ name: String) -> Bool {
        ["settings", "system settings", "system preferences", "preferences", "prefs"]
            .contains(name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func appCriteria(for state: AgentScreenState, instruction: String) -> [String: AnyCodableValue] {
        var criteria: [String: AnyCodableValue] = [:]
        for name in state.runningApps {
            criteria[name] = AnyCodableValue("Switch to \(name)")
        }
        if let mentioned = Self.appNameMentioned(in: instruction),
           criteria.keys.contains(where: { $0.caseInsensitiveCompare(mentioned) != .orderedSame }) {
            criteria[mentioned] = AnyCodableValue("Launch \(mentioned) (named in the goal, may not be running)")
        }
        return criteria
    }

    private static func appNameMentioned(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:open|launch|start|switch to|go to)\s+([A-Za-z][A-Za-z0-9 ]*?)(?:\s+and\b|\s+to\b|[,.]|$)"#,
            options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Text the agent might legitimately want to type: a quoted span from the
    /// instruction, the text after a typing verb, or the instruction itself.
    /// Criteria keys carry the text itself so `choice` returns it directly;
    /// Jev only decides between candidates, it cannot generate free text.
    private func textCandidates(from instruction: String) -> [String: AnyCodableValue] {
        var candidates: [String: AnyCodableValue] = [:]
        if let quoted = Self.firstQuotedSpan(in: instruction) {
            candidates[quoted] = AnyCodableValue("The text quoted inside the instruction")
        }
        if let afterVerb = Self.textAfterTypingVerb(in: instruction),
           !candidates.keys.contains(afterVerb) {
            candidates[afterVerb] = AnyCodableValue("The text following the typing verb in the instruction")
        }
        if !candidates.keys.contains(instruction) {
            candidates[instruction] = AnyCodableValue("The full instruction verbatim")
        }
        return candidates
    }

    private static func firstQuotedSpan(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[\"'“](.+?)[\"'”]"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func textAfterTypingVerb(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:type|write|enter|input|say|fill in)\b[:\s]+(.+)$"#,
            options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
