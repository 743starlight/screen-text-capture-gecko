import AppKit
import SwiftUI
import Combine
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private let hotkey = GlobalShortcut()
    private let gate = OperationGate()
    private var item: NSStatusItem?
    private var window: NSWindow?
    private let toast = ToastPresenter()
    private var cancellables = Set<AnyCancellable>()
    private var reopenObserver: NSObjectProtocol?
    private let permissionPrompts = PermissionPromptGate()
    private var permissionAlert: NSAlert?
    private var feedbackGeneration = 0
    private var updates: UpdateController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted tests never register shortcuts, open windows or request OS permissions.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        installMainMenu()
        UNUserNotificationCenter.current().delegate = self
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.autosaveName = "ScreenTextCapture.OCR"
        item?.isVisible = true
        if let button = item?.button {
            button.imagePosition = .imageOnly
            button.title = ""
            button.setAccessibilityLabel("ScreenTextCapture Gecko — 文字認識")
        }
        // 設定で選んだ図柄へその場で切り替える。設定は文字入力のたびにも保存されるため、図柄が変わったときだけ差し替える
        model.$settings.map(\.menuBarIcon).removeDuplicates().sink { [weak self] icon in
            self?.item?.button?.image = icon.image
        }.store(in: &cancellables)
        // 別の場所のアプリを開いたときも、Dockのアイコンを押したときと同じく範囲選択を始める
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: ApplicationMain.reopenNotification,
                                                                             object: ApplicationMain.userIdentifier, queue: .main) { [weak self] _ in
            self?.capture()
        }
        model.saveAction = { [weak self] in
            guard let self else { return }
            self.model.settings.save()
            if self.model.settings.copyFeedback == .none { self.toast.hide() }
        }
        model.shortcutAction = { [weak self] in self?.setShortcut($0) }
        model.recordingAction = { [weak self] in self?.hotkey.suspended = $0 }
        model.captureAction = { [weak self] in self?.capture() }
        model.cancelAction = { [weak self] in self?.cancel() }
        model.permissionAction = { [weak self] kind in self?.permissionHelp(kind) }
        hotkey.action = { [weak self] in self?.capture() }
        setShortcut(model.settings.shortcut)
        // 自動アップデート（配布版だけ）。入れ替えて開き直すのは、手が空いているときに限る
        let updates = UpdateController()
        updates.canInstall = { [weak self] in self?.isIdleForUpdate ?? false }
        updates.onChange = { [weak self] in self?.updateMenu() }
        self.updates = updates
        model.updatesAvailable = updates.isAvailable
        model.autoUpdate = updates.automaticallyUpdates
        model.autoUpdateAction = { [weak self] in self?.updates?.automaticallyUpdates = $0 }
        model.updateCheckAction = { [weak self] in self?.updates?.checkForUpdates() }
        Publishers.CombineLatest(model.$status, model.$isBusy).receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateMenu() }.store(in: &cancellables)
        updateMenu()
        model.refreshLoginItem()
        model.checkAvailability()
        // Dockのアイコンを押して起動したときも、そのまま範囲選択を始める。ログイン時の自動起動では何も始めずに常駐する。
        // アップデートで開き直したときも手動の起動に見えるが、範囲選択は始めない。
        // 範囲選択中は利用可否の確認を受け付けないため、起動時の確認を始めた後に始める
        let relaunchedForUpdate = UpdateRelaunch.consume()
        if LaunchContext.current == .manual && !relaunchedForUpdate { capture() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.checker.cancel()
        if model.isBusy {
            terminating = true
            cancel()
            // Give the worker time to stop the process and delete the screenshot.
            return .terminateLater
        }
        return .terminateNow
    }

    private func updateMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: String(model.status.prefix(70)), action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(.separator())
        let capture = NSMenuItem(title: "範囲を選択してコピー", action: #selector(capture), keyEquivalent: "")
        capture.target = self
        capture.isEnabled = !model.isBusy
        menu.addItem(capture)
        if model.isBusy {
            let cancel = NSMenuItem(title: "キャンセル", action: #selector(cancel), keyEquivalent: "")
            cancel.target = self; menu.addItem(cancel)
        }
        let settings = NSMenuItem(title: "設定…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        if let updates, updates.isAvailable {
            // 窓を出さずにおいた新しい版があれば、それを入れる項目にする（押すと Sparkle の窓で版を見せて入れる）
            let title = updates.pendingVersion.map { "\($0)を入れる…" } ?? "アップデートを確認…"
            let check = NSMenuItem(title: title, action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = self; menu.addItem(check)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item?.menu = menu
        item?.button?.toolTip = "ScreenTextCapture Gecko\n" + model.status
    }

    // 結果は Sparkle の窓で見せる（新しい版はそこから入れる）
    @objc private func checkForUpdates() {
        updates?.checkForUpdates()
    }

    /// 入れ替えて開き直してよいか。範囲選択・認識の途中、許可の案内や設定画面を開いている間は待つ
    private var isIdleForUpdate: Bool {
        !model.isBusy && !model.recording && !permissionPrompts.isPresented && window?.isVisible != true
    }

    private func setShortcut(_ value: Shortcut?) {
        do {
            try hotkey.register(value)
            model.settings.shortcut = value
            model.settings.save()
            model.shortcutError = nil
        } catch {
            model.shortcutError = error.localizedDescription
            // Preserve both the prior live binding and the prior saved value.
            if hotkey.registered != nil { model.settings.shortcut = hotkey.registered }
        }
    }

    // Dockの「起動中」の印は設定画面を開いている間だけ出す（その間はアプリのメニューも使える）。
    // 範囲選択からコピーまでは裏で動き、終わってもDockに起動中と出し続けないよう、普段はメニューバーに
    // 常駐するだけの扱い（Info.plistのLSUIElement）にしておく。Dockに追加したアイコンを押すと再オープンとして届く
    @objc private func showSettings() {
        NSApp.setActivationPolicy(.regular)
        refreshPermissions()
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let settingsWindow = SettingsWindow(contentViewController: controller)
            settingsWindow.title = "ScreenTextCapture Gecko 設定"
            settingsWindow.styleMask = [.titled, .closable, .miniaturizable]
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.delegate = self
            settingsWindow.center()
            window = settingsWindow
        }
        updateSettingsHeightLimit()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    // 画面の小さいMacや、画面をまたいで動かしたとき・解像度を変えたときにも、設定画面が画面からはみ出さず
    // 中でスクロールできるよう、ウィンドウが載っている画面の使える高さを上限として渡す（タイトルバーと上下の余白を除く）
    private func updateSettingsHeightLimit() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        model.settingsHeightLimit = screen.visibleFrame.height - 80
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateSettingsHeightLimit()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        updateSettingsHeightLimit()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissions()
    }

    private func refreshPermissions() {
        model.refreshLoginItem()
        model.permission = ScreenPermission.isGranted
        CopyNotification.permissionStatus { [weak self] status in
            self?.model.notificationsAllowed = status == .authorized || status == .provisional
        }
    }

    // 設定画面が開いていればそのシートとして出す。開いていなければ（Dockやショートカットから始めて許可が足りないとき）、
    // 設定はメニューからだけ開く決まりのため、設定画面を開かずに単独のダイアログとして出す
    private func showPermissionAlert(_ kind: PermissionKind) {
        guard permissionPrompts.begin() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = kind.title
        alert.informativeText = kind.explanation
        alert.addButton(withTitle: "macOSの設定を開く")
        alert.addButton(withTitle: "キャンセル").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: kind.requestTitle)
        permissionAlert = alert
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.permissionAlert = nil
            self.permissionPrompts.finish()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(kind.settingsURL)
            } else if response == .alertThirdButtonReturn {
                // Only this explicit button may ask macOS for a new permission.
                if kind == .screenCapture {
                    self.model.permission = ScreenPermission.request()
                } else {
                    CopyNotification.request { [weak self] granted in
                        self?.model.status = granted ? "通知が許可されました。" : "通知は未許可です。コピーは引き続き利用できます。"
                        self?.refreshPermissions()
                    }
                }
            }
            self.refreshPermissions()
            self.updates?.installIfIdle()
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            respond(alert.runModal())
        }
    }

    private func permissionHelp(_ kind: PermissionKind) {
        model.permission = ScreenPermission.isGranted
        CopyNotification.permissionStatus { [weak self] status in
            guard let self else { return }
            let notifications = status == .authorized || status == .provisional
            if kind.isGranted(screenCapture: self.model.permission, notifications: notifications) {
                self.model.status = kind == .screenCapture ? "画面収録は許可済みです。" : "通知は許可済みです。表示方法はmacOSの通知設定で確認できます。"
                self.refreshPermissions()
            } else {
                self.showPermissionAlert(kind)
            }
        }
    }

    deinit {
        if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
    }

    func windowWillClose(_ notification: Notification) {
        model.recording = false
        hotkey.suspended = false
        // 設定画面を閉じたら、Dockの起動中の印を消してメニューバーの常駐だけに戻す
        NSApp.setActivationPolicy(.accessory)
        // 開いている間に取ってきた版は、閉じた後に入れる（閉じ終わってから確かめる）
        DispatchQueue.main.async { [weak self] in self?.updates?.installIfIdle() }
    }

    // Dockのアイコンを押したら、設定ではなく範囲選択を始める（設定はメニューの「設定…」から開く）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard LaunchContext.current.forwardsReopen else { return false }
        capture()
        return false
    }

    // 設定画面を開いている間は通常のアプリとして画面上部にメニューが出るため、アプリのメニューを置く。
    // 設定画面の入力欄でコピー・ペーストなどのキー操作が効くよう、編集のメニューも置く
    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let settings = item("設定…", #selector(showSettings), ",")
        settings.target = self
        _ = submenu("ScreenTextCapture Gecko", [
            settings, .separator(),
            item("ScreenTextCapture Geckoを隠す", #selector(NSApplication.hide(_:)), "h"),
            item("ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:)), ""), .separator(),
            item("ScreenTextCapture Geckoを終了", #selector(NSApplication.terminate(_:)), "q")
        ])
        _ = submenu("編集", [
            item("取り消す", Selector(("undo:")), "z"), item("やり直す", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("カット", #selector(NSText.cut(_:)), "x"), item("コピー", #selector(NSText.copy(_:)), "c"),
            item("ペースト", #selector(NSText.paste(_:)), "v"), item("すべてを選択", #selector(NSText.selectAll(_:)), "a")
        ])
        NSApp.windowsMenu = submenu("ウインドウ", [
            item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"), item("閉じる", #selector(NSWindow.performClose(_:)), "w")
        ])
        NSApp.mainMenu = main
    }

    @objc private func capture() {
        guard !model.recording, !permissionPrompts.isPresented, gate.active == nil else { return }
        model.permission = ScreenPermission.isGranted
        guard model.permission else {
            model.status = OCRError.permissionDenied.localizedDescription
            showPermissionAlert(.screenCapture)
            return
        }
        guard let cancellation = gate.begin() else { return }
        let settings = model.settings
        guard settings.backend == .vision || settings.cloudConsent else {
            gate.finish()
            model.status = "設定で画像の外部送信を有効にしてから実行してください。"
            showSettings()
            return
        }
        model.isBusy = true
        feedbackGeneration += 1
        model.status = "範囲をドラッグして選択してください。Escで中止できます。"
        // 範囲選択の邪魔にならないよう隠し、選択が終わったら元へ戻す
        if window?.isVisible == true { settingsRestore = NSApp.isActive ? .front : .back }
        window?.orderOut(nil)
        toast.hide()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let result = Result { () throws -> String in
                let workspace = try OCRWorkspace()
                defer { workspace.remove() }
                try ScreenSelection.capture(workspace: workspace, cancellation: cancellation)
                DispatchQueue.main.async {
                    self?.model.status = "文字を認識しています…"
                    self?.restoreSettingsWindow()
                }
                let text = try SubscriptionOCR.recognize(settings: settings, workspace: workspace, cancellation: cancellation)
                try cancellation.check()
                return text
            }
            DispatchQueue.main.async { self?.complete(result, cancellation: cancellation) }
        }
    }

    @objc private func cancel() {
        gate.cancel()
        model.status = "キャンセルしています…"
    }

    private var terminating = false

    /// 範囲選択のあいだ隠した設定画面の戻し方。操作中（アプリが前面）なら前面へ戻し、
    /// 別のアプリで作業中にショートカットで始めたなら、作業中のアプリから前面を奪わないよう後ろへ戻す
    private enum SettingsRestore { case front, back }
    private var settingsRestore: SettingsRestore?

    // 選択が終わった時点で戻す（認識中の表示も設定画面で見える）。選択の中止・失敗のときは完了の処理から戻す。
    // 認識の間に利用者が開き直していたら、そのままにする
    private func restoreSettingsWindow() {
        defer { settingsRestore = nil }
        guard !terminating, let restore = settingsRestore, let window, !window.isVisible else { return }
        switch restore {
        case .front:
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        case .back:
            window.orderBack(nil)
        }
    }

    private func complete(_ result: Result<String, Error>, cancellation: Cancellation) {
        gate.finish()
        model.isBusy = false
        restoreSettingsWindow()
        do {
            try cancellation.check()
            let text = try result.get()
            try OCRResult.copy(text)
            model.status = "コピーしました（\(text.count)文字）。"
            switch model.settings.copyFeedback {
            case .toast:
                // 通知バナーは画面共有中などにOSが黙って抑止するため、自前のトーストで確実に知らせる
                if !terminating { toast.show(.copied()) }
            case .notification:
                let generation = feedbackGeneration
                CopyNotification.deliver(text: text, settings: model.settings) { [weak self] delivery in
                    guard let self, self.feedbackGeneration == generation, !self.terminating else { return }
                    if delivery == .permissionMissing { self.model.notificationsAllowed = false }
                    let enabled = self.model.settings.copyFeedback == .notification
                    if CopyNotification.shouldShowFallback(for: delivery, notificationsEnabled: enabled) {
                        self.toast.show(.copied())
                    }
                }
            case .none:
                break
            }
        } catch {
            model.status = error.localizedDescription
            if error as? OCRError == .permissionDenied {
                showPermissionAlert(.screenCapture)
            } else if error as? OCRError != .cancelled, model.settings.copyFeedback != .none, !terminating {
                toast.show(ToastMessage(title: model.status, symbol: "exclamationmark.circle.fill"))
            }
        }
        model.permission = ScreenPermission.isGranted
        if terminating {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            // 取ってきた版があれば、コピーの完了の表示（トースト・約2.5秒）を見せ終えてから入れる
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.updates?.installIfIdle() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
