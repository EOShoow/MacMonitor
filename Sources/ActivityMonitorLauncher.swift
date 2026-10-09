import AppKit

@MainActor
enum ActivityMonitorLauncher {
    static let bundleIdentifier = "com.apple.ActivityMonitor"
    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
    static var icon: NSImage? {
        let image = applicationURL.flatMap { NSWorkspace.shared.icon(forFile: $0.path).copy() as? NSImage }
            ?? NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "活动监视器")
        image?.size = NSSize(width: 18, height: 18)
        return image
    }
    static func open(completion: @escaping (Result<NSRunningApplication, Error>) -> Void) {
        guard let url = applicationURL else {
            completion(.failure(ReadFailure.message("找不到 macOS 活动监视器")))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)) }
                else if let app, app.bundleIdentifier == bundleIdentifier { completion(.success(app)) }
                else { completion(.failure(ReadFailure.message("活动监视器未正常启动"))) }
            }
        }
    }
}
