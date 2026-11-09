import AppKit
import Darwin

/// There is no nib or storyboard to instantiate the application delegate.
/// NSApplicationDelegate.main() only calls NSApplicationMain; it does not install one.
@main
enum ApplicationMain {
    static let reopenNotification = Notification.Name("io.github.743starlight.screentextcapture.reopen")
    static var userIdentifier: String { String(getuid()) }

    static func main() {
        let hostedTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let lease: InstanceLease?
        do {
            lease = hostedTest ? nil : try InstanceLease()
        } catch {
            let alert = NSAlert()
            alert.messageText = "ScreenTextCapture Geckoを起動できませんでした。"
            alert.informativeText = "常駐アプリの起動状態を確認できません。アプリを終了してから開き直してください。"
            alert.runModal()
            return
        }
        if lease?.isPrimary == false {
            // An unavailable GUI session must not leave an additional resident process behind.
            // DMGの中から開いたときは、案内の窓の答えを待つので、時間では終えない
            if !DiskImageLaunch.isInsideReadOnlyImage(Bundle.main.bundleURL) {
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(0) }
            }
            // 起動のApple Eventを受けてから、常駐中のアプリへ「もう一度開いた」（範囲選択を始める）と伝えるかを決める
            // Dockに一瞬出ないよう、補助のプロセスはDockに出さない
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let delegate = SecondaryInstanceDelegate()
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime((delegate, lease)) {
            application.run()
        }
    }
}

private final class SecondaryInstanceDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 別のアプリが常駐中でも案内する。DockのアイコンがDMGの中のアプリを指していると、押すたびにディスクが開き直されるため
        DiskImageLaunch.guideIfNeeded()
        if LaunchContext.current.forwardsReopen {
            // Bounded retry covers simultaneous initial launches before the primary installs its observer.
            for attempt in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 0.25) {
                    DistributedNotificationCenter.default().postNotificationName(ApplicationMain.reopenNotification,
                        object: ApplicationMain.userIdentifier, userInfo: nil, deliverImmediately: true)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
    }
}
