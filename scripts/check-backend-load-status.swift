import Foundation

private final class ProbeCounter: @unchecked Sendable {
    var value = 0
}

@main
struct CheckBackendLoadStatus {
    static func main() {
        checkParsing()
        checkReducer()
        checkSchedule()
        checkEndpoint()
        checkSignals()
        print("backend load status checks passed")
    }

    private static func checkParsing() {
        let high = parse(#"{"level":"high","message":"Busy right now","updatedAt":1710000000000}"#)
        expect(high?.level == .high, "high level")
        expect(high?.message == "Busy right now", "server message is kept")
        expect(high?.updatedAt == 1_710_000_000_000.0, "updatedAt number")
        expect(
            BackendLoadNoticePolicy.notice(from: high!) == .high("Busy right now"),
            "high notice uses the server message"
        )

        let highNull = parse(#"{"level":"high","message":null,"updatedAt":1}"#)
        expect(highNull?.message == nil, "null message")
        expect(
            BackendLoadNoticePolicy.notice(from: highNull!) == .high(BackendLoadNoticePolicy.highMessage),
            "high notice falls back to the default copy"
        )

        let elevated = parse(#"{"level":"elevated","message":"   ","updatedAt":1.5}"#)
        expect(elevated?.message == nil, "blank message is dropped")
        expect(elevated?.updatedAt == 1.5, "fractional updatedAt")
        expect(
            BackendLoadNoticePolicy.notice(from: elevated!) == .elevated(BackendLoadNoticePolicy.elevatedMessage),
            "elevated notice uses the softer default"
        )

        let normal = parse(#"{"level":"normal","message":"ignore me","updatedAt":0}"#)
        expect(
            BackendLoadNoticePolicy.notice(from: normal!) == .hidden,
            "normal load hides the notice even when a message is present"
        )

        let wrapped = parse(#"{"level":"elevated","message":"line\none\t two","updatedAt":2}"#)
        expect(wrapped?.message == "line one two", "newlines collapse to spaces")

        let long = String(repeating: "a", count: 180)
        let truncated = parse(#"{"level":"high","message":"\#(long)","updatedAt":3}"#)
        expect(truncated?.message?.count == 160, "long messages are capped")
        expect(truncated?.message?.hasSuffix("...") == true, "truncated messages end with an ellipsis")

        expect(parse(#"{"level":"critical","message":"nope","updatedAt":1}"#) == nil, "unknown level")
        expect(parse(#"{"message":"missing level"}"#) == nil, "missing level")
        expect(parse(#"not-json"#) == nil, "bad json")
        expect(parse(#"[]"#) == nil, "array json")
        expect(parse(#"{"level":"HIGH"}"#) == nil, "level match is exact")

        let stringStamp = parse(#"{"level":"high","updatedAt":"yesterday"}"#)
        expect(stringStamp?.level == .high, "a bad updatedAt does not hide a real level")
        expect(stringStamp?.updatedAt == nil, "non-numeric updatedAt is ignored")
    }

    private static func checkReducer() {
        let current = BackendLoadNotice.high("stay")
        expect(
            BackendLoadReducer.apply(current: current, outcome: .unchanged) == current,
            "ignored fetches keep the current notice"
        )
        expect(
            BackendLoadStatusDecoder.interpret(statusCode: 404, data: Data("nope".utf8), transportFailed: false) == .unchanged,
            "404 is silent"
        )
        expect(
            BackendLoadStatusDecoder.interpret(statusCode: 500, data: Data(), transportFailed: false) == .unchanged,
            "5xx is silent"
        )
        expect(
            BackendLoadStatusDecoder.interpret(statusCode: nil, data: nil, transportFailed: true) == .unchanged,
            "transport errors are silent"
        )
        expect(
            BackendLoadStatusDecoder.interpret(statusCode: 200, data: Data("nope".utf8), transportFailed: false) == .unchanged,
            "bad json is silent"
        )

        let body = Data(#"{"level":"high","message":null,"updatedAt":9}"#.utf8)
        let outcome = BackendLoadStatusDecoder.interpret(statusCode: 200, data: body, transportFailed: false)
        expect(
            BackendLoadReducer.apply(current: .hidden, outcome: outcome) == .high(BackendLoadNoticePolicy.highMessage),
            "a high payload shows the default notice"
        )
        let cleared = BackendLoadStatusDecoder.interpret(
            statusCode: 200,
            data: Data(#"{"level":"normal","message":null,"updatedAt":10}"#.utf8),
            transportFailed: false
        )
        expect(
            BackendLoadReducer.apply(current: current, outcome: cleared) == .hidden,
            "normal clears a previous notice"
        )
        expect(current.accessibilityLabel == "openflow, stay", "accessibility label includes the notice")
        expect(BackendLoadNotice.hidden.accessibilityLabel == "openflow", "hidden label stays the app name")
    }

    private static func checkSchedule() {
        expect(BackendLoadSchedule.pollInterval(idleFor: 0, asleep: false) == 60, "active poll is 60s")
        expect(BackendLoadSchedule.pollInterval(idleFor: 299, asleep: false) == 60, "just under idle stays active")
        expect(BackendLoadSchedule.pollInterval(idleFor: 300, asleep: false) == 300, "idle backs off to 5 min")
        expect(BackendLoadSchedule.pollInterval(idleFor: 0, asleep: true) == nil, "sleep pauses polling")
        expect(BackendLoadSchedule.initialDelay == 3, "first poll waits briefly")
        expect(BackendLoadSchedule.opportunisticCooldown == 20, "opportunistic refreshes are debounced")

        expect(BackendLoadSchedule.shouldProbe(duration: 1, statusCode: nil, transportFailed: true), "transport failure probes")
        expect(BackendLoadSchedule.shouldProbe(duration: 1, statusCode: 429, transportFailed: false), "429 probes")
        expect(BackendLoadSchedule.shouldProbe(duration: 1, statusCode: 503, transportFailed: false), "5xx probes")
        expect(BackendLoadSchedule.shouldProbe(duration: 8, statusCode: 200, transportFailed: false), "slow 200 probes")
        expect(!BackendLoadSchedule.shouldProbe(duration: 7.9, statusCode: 200, transportFailed: false), "fast 200 does not probe")
        expect(!BackendLoadSchedule.shouldProbe(duration: 1, statusCode: 401, transportFailed: false), "fast 401 is not treated as load")
        expect(BackendLoadSchedule.shouldProbe(duration: 30, statusCode: 401, transportFailed: false), "a slow 401 still counts as slow")
        expect(!BackendLoadSchedule.shouldProbe(duration: 1, statusCode: 404, transportFailed: false), "fast 404 is not treated as load")
    }

    private static func checkEndpoint() {
        let base = URL(string: "https://openflow-site-cvx.jottly.ai")!
        let url = BackendLoadEndpoint.url(cloudBase: base)
        expect(url.host == "openflow-site-cvx.jottly.ai", "status host matches the cloud base")
        expect(url.path == "/status/load", "status path is /status/load")

        let trailing = URL(string: "https://openflow-site-cvx.jottly.ai/")!
        expect(
            BackendLoadEndpoint.url(cloudBase: trailing).path == "/status/load",
            "trailing slash still joins /status/load"
        )

        expect(BackendLoadEndpoint.overrideURL(from: nil) == nil, "missing override")
        expect(BackendLoadEndpoint.overrideURL(from: "  ") == nil, "blank override")
        expect(BackendLoadEndpoint.overrideURL(from: "http://openflow-site-cvx.jottly.ai/status/load") == nil, "http override")
        expect(
            BackendLoadEndpoint.overrideURL(from: "https://user:pass@openflow-site-cvx.jottly.ai/status/load") == nil,
            "credentialed override"
        )
        let override = BackendLoadEndpoint.overrideURL(
            from: " https://openflow-site-cvx.jottly.ai/status/load "
        )
        expect(override?.path == "/status/load", "https override is the full request URL")
        expect(override?.host == "openflow-site-cvx.jottly.ai", "https override keeps its host")
    }

    private static func checkSignals() {
        expect(BackendLoadSignals.isCancellation(CancellationError()), "CancellationError")
        expect(BackendLoadSignals.isCancellation(URLError(.cancelled)), "URLError.cancelled")
        expect(!BackendLoadSignals.isCancellation(URLError(.timedOut)), "timeout is not cancellation")

        let counter = ProbeCounter()
        BackendLoadSignals.register {
            counter.value += 1
        }
        BackendLoadSignals.note(duration: 0.1, statusCode: 200, transportFailed: false)
        BackendLoadSignals.note(duration: 0.1, statusCode: 503, transportFailed: false)
        BackendLoadSignals.register(nil)
        BackendLoadSignals.note(duration: 9, statusCode: nil, transportFailed: true)
        expect(counter.value == 1, "only probe-worthy calls notify, and a cleared handler stays quiet")
    }

    private static func parse(_ json: String) -> BackendLoadSnapshot? {
        BackendLoadStatusDecoder.parse(Data(json.utf8))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        if condition() { return }
        FileHandle.standardError.write(Data("backend load status check failed: \(label)\n".utf8))
        exit(1)
    }
}
