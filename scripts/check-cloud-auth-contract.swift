import Foundation

private struct DeviceAuthorizationResponse: Codable {
    var deviceCode: String
    var userCode: String
    var verificationUri: URL
    var verificationUriComplete: URL?
    var expiresIn: TimeInterval
    var interval: TimeInterval
}

private let productionPayload = """
{
  "deviceCode": "device-code",
  "userCode": "USER-CODE",
  "verificationUri": "https://auth.neuroquestlabs.ai/device",
  "expiresIn": 600,
  "interval": 2
}
"""

private let response = try JSONDecoder().decode(
    DeviceAuthorizationResponse.self,
    from: Data(productionPayload.utf8)
)

precondition(response.verificationUriComplete == nil)
precondition(response.verificationUri.absoluteString == "https://auth.neuroquestlabs.ai/device")
print("Cloud auth contract checks passed")
