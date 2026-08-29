import Foundation

enum AudioFileFormat {
    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "m4a", "mp4":
            return "audio/mp4"
        default:
            return "application/octet-stream"
        }
    }

    static func uploadFilename(for url: URL) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent
        let extensionName = url.pathExtension.lowercased()
        guard !baseName.isEmpty, !extensionName.isEmpty else {
            return url.lastPathComponent
        }
        return "\(baseName).\(extensionName)"
    }
}
