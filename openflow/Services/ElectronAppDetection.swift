import Foundation

/// Detects an Electron app from its bundle layout.
///
/// Bundle identifiers are not enough: Grok Bot ships as `com.anysphere.sand`.
/// The framework is present for every Electron host and absent for Notes,
/// Safari, Terminal, and Maps.
enum ElectronAppDetection {
    static let frameworkComponents = ["Contents", "Frameworks", "Electron Framework.framework"]

    /// Path of `Electron Framework.framework` inside an `.app` bundle.
    static func frameworkPath(bundlePath: String) -> String {
        frameworkComponents.reduce(URL(fileURLWithPath: bundlePath)) { url, component in
            url.appendingPathComponent(component, isDirectory: component != "Electron Framework.framework")
        }.path
    }

    /// Whether this bundle, or an ancestor bundle, contains the Electron framework.
    ///
    /// Helper processes live inside `Contents/Frameworks`. Walking up finds the
    /// host `.app` without treating Notes, Safari, Terminal, or Maps as Electron.
    ///
    /// - Parameters:
    ///   - bundlePath: Absolute path to an `.app` bundle. Empty is not Electron.
    ///   - frameworkExists: Looks up a filesystem path. Tests pass a stub.
    /// - Returns: True only when the framework file is reported present.
    static func isElectronBundle(bundlePath: String,
                                 frameworkExists: (String) -> Bool) -> Bool {
        guard !bundlePath.isEmpty else { return false }
        var url = URL(fileURLWithPath: bundlePath)
        for _ in 0..<6 {
            if frameworkExists(frameworkPath(bundlePath: url.path)) {
                return true
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return false
    }
}
