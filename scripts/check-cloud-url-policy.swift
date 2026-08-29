import Foundation

@main
struct CheckCloudURLPolicy {
    private static let baseURL = URL(string: "https://openflow-site-cvx.jottly.ai")!
    private static let authBaseURL = URL(string: "https://auth.neuroquestlabs.ai")!

    static func main() {
        expectAllowed("stripe checkout link",
                      "https://checkout.stripe.com/c/pay/cs_test_123",
                      usage: .billing,
                      baseURL: baseURL)
        expectAllowed("backend-hosted billing link",
                      "https://openflow-site-cvx.jottly.ai/billing/portal",
                      usage: .billing,
                      baseURL: baseURL)
        expectAllowed("device verification link",
                      "https://auth.neuroquestlabs.ai/device?user_code=ABCD-1234",
                      usage: .deviceVerification,
                      baseURL: authBaseURL)
        expectAllowed("same-host audio upload url",
                      "https://openflow-site-cvx.jottly.ai/openflow/audio-upload",
                      usage: .audioUpload,
                      baseURL: baseURL)
        expectAllowed("cloudflare STT worker upload url",
                      "https://openflow-stt.jottly.ai/transcribe",
                      usage: .audioUpload,
                      baseURL: baseURL)
        expectAllowedServiceBase("trusted service base",
                                 "https://openflow-site-cvx.jottly.ai")

        expectRejected("http billing link",
                       "http://checkout.stripe.com/c/pay/cs_test_123",
                       usage: .billing,
                       baseURL: baseURL)
        expectRejected("file scheme billing link",
                       "file:///Applications/Calculator.app",
                       usage: .billing,
                       baseURL: baseURL)
        expectRejected("custom scheme billing link",
                       "openflow-evil://run",
                       usage: .billing,
                       baseURL: baseURL)
        expectRejected("attacker host billing link",
                       "https://checkout.stripe.com.evil.example/pay",
                       usage: .billing,
                       baseURL: baseURL)
        expectRejected("embedded credentials billing link",
                       "https://checkout.stripe.com@evil.example/pay",
                       usage: .billing,
                       baseURL: baseURL)
        expectRejected("attacker verification link",
                       "https://evil.example/device?user_code=ABCD-1234",
                       usage: .deviceVerification,
                       baseURL: authBaseURL)
        expectRejected("stripe host is not an upload host",
                       "https://checkout.stripe.com/api/storage/upload",
                       usage: .audioUpload,
                       baseURL: baseURL)
        expectRejected("attacker upload url",
                       "https://evil.example/api/storage/upload",
                       usage: .audioUpload,
                       baseURL: baseURL)
        expectRejected("shared workers.dev upload url",
                       "https://attacker.workers.dev/api/storage/upload",
                       usage: .audioUpload,
                       baseURL: baseURL)
        expectRejected("shared convex.cloud upload url",
                       "https://openflow.convex.cloud/api/storage/upload",
                       usage: .audioUpload,
                       baseURL: baseURL)
        expectRejected("shared convex.site upload url",
                       "https://attacker.convex.site/api/storage/upload",
                       usage: .audioUpload,
                       baseURL: baseURL)
        expectRejectedServiceBase("http service base",
                                 "http://openflow-site-cvx.jottly.ai")
        expectRejectedServiceBase("attacker service base",
                                 "https://openflow-site-cvx.evil.example")
        expectRejectedServiceBase("shared convex.cloud service base",
                                 "https://openflow.convex.cloud")
        expectRejectedServiceBase("shared convex.site service base",
                                 "https://openflow.convex.site")
    }

    private static func expectAllowed(_ label: String,
                                      _ value: String,
                                      usage: CloudURLPolicy.Usage,
                                      baseURL: URL) {
        guard let url = URL(string: value) else {
            fail("\(label): could not parse \(value)")
            return
        }
        do {
            _ = try CloudURLPolicy.validate(url, usage: usage, baseURL: baseURL)
        } catch {
            fail("\(label): expected \(value) to be allowed")
        }
    }

    private static func expectRejected(_ label: String,
                                       _ value: String,
                                       usage: CloudURLPolicy.Usage,
                                       baseURL: URL) {
        guard let url = URL(string: value) else { return }
        if (try? CloudURLPolicy.validate(url, usage: usage, baseURL: baseURL)) != nil {
            fail("\(label): expected \(value) to be rejected")
        }
    }

    private static func expectAllowedServiceBase(_ label: String, _ value: String) {
        guard let url = URL(string: value) else {
            fail("\(label): could not parse \(value)")
            return
        }
        do {
            _ = try CloudURLPolicy.validateServiceBaseURL(url)
        } catch {
            fail("\(label): expected \(value) to be allowed")
        }
    }

    private static func expectRejectedServiceBase(_ label: String, _ value: String) {
        guard let url = URL(string: value) else { return }
        if (try? CloudURLPolicy.validateServiceBaseURL(url)) != nil {
            fail("\(label): expected \(value) to be rejected")
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("cloud url policy check failed: \(message)\n".utf8))
        exit(1)
    }
}
