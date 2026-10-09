import AppKit

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if arguments.contains("--self-test") {
        Verification.runTests()
    } else if let index = arguments.firstIndex(of: "--verify-menu"), arguments.count > index + 1 {
        Verification.verifyMenu(to: arguments[index + 1])
    } else if arguments.contains("--snapshot") {
        Verification.snapshot()
    } else if arguments.contains("--open-activity-monitor") {
        _ = NSApplication.shared
        Verification.openActivityMonitor()
    } else if let index = arguments.firstIndex(of: "--render-icons"), arguments.count > index + 1 {
        _ = NSApplication.shared
        do { try Verification.renderIcons(to: arguments[index + 1]) }
        catch { fputs("渲染失败：\(error)\n", stderr); exit(1) }
    } else if let index = arguments.firstIndex(of: "--render-panel"), arguments.count > index + 1 {
        _ = NSApplication.shared
        do { try Verification.renderPanel(to: arguments[index + 1]) }
        catch { fputs("面板渲染失败：\(error)\n", stderr); exit(1) }
    } else {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
