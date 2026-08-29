import AppKit
import Foundation

/// Validates URLs that arrive inside backend or auth-server JSON before the app opens
/// them in the user's browser or uploads recorded audio to them.
enum CloudURLPolicy {
    enum Usage {
        case billing
        case deviceVerification
        case audioUpload
        case serviceBase

        var description: String {
            switch self {
            case .billing: "billing"
            case .deviceVerification: "sign-in"
            case .audioUpload: "audio upload"
            case .serviceBase: "service"
            }
        }
    }

    private static let billingDomains = [
        "stripe.com",
        "neuroquestlabs.ai",
        "jottly.ai"
    ]

    /// First-party hosts only. Shared multi-tenant suffixes (workers.dev, convex.cloud,
    /// convex.site) are not trusted: any third party can obtain a subdomain there.
    private static let uploadDomains = [
        "jottly.ai",
        "neuroquestlabs.ai"
    ]

    private static let serviceBaseDomains = [
        "jottly.ai",
        "neuroquestlabs.ai"
    ]

    static func validate(_ url: URL, usage: Usage, baseURL: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              isTrusted(host: host, usage: usage, baseURL: baseURL) else {
            let message = usage == .serviceBase
                ? "The configured openflow service URL is not trusted."
                : "The openflow service returned an untrusted \(usage.description) link."
            throw OpenflowError.cloudProviderUnavailable(message)
        }
        return url
    }

    static func validateServiceBaseURL(_ url: URL) throws -> URL {
        try validate(url, usage: .serviceBase, baseURL: url)
    }

    private static func isTrusted(host: String, usage: Usage, baseURL: URL) -> Bool {
        if usage != .serviceBase,
           let baseHost = baseURL.host?.lowercased(),
           host == baseHost {
            return true
        }
        switch usage {
        case .billing:
            return billingDomains.contains { matches(host: host, domain: $0) }
        case .deviceVerification:
            return matches(host: host, domain: "neuroquestlabs.ai")
        case .audioUpload:
            return uploadDomains.contains { matches(host: host, domain: $0) }
        case .serviceBase:
            return serviceBaseDomains.contains { matches(host: host, domain: $0) }
        }
    }

    /// Opens a backend-provided link, refusing any non-https scheme at the sink so a
    /// `file://` bundle or a custom scheme handler can never reach `NSWorkspace`.
    /// Callers must still validate the host with `validate(_:usage:baseURL:)` first.
    @MainActor
    @discardableResult
    static func openExternal(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func matches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}
