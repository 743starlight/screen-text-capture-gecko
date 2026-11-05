import AppKit
import Security
import Sparkle

/// 自動アップデート（Sparkle）。GitHub の最新のリリースに添付した appcast（Info.plist の SUFeedURL）を1日1回読み、
/// 新しい版があれば裏で取ってきて、範囲選択・許可の案内・設定画面のどれもしていないときに入れ替えて開き直す。
/// 取ってきた版は、Sparkle が公開鍵（Info.plist の SUPublicEDKey）で確かめてから入れる。
/// 動かすのは配布版（Developer ID の署名）だけにする。開発版やテストのビルドが配布版に入れ替わると、
/// 署名が変わって画面収録の許可が外れるため。
/// 作るのも呼ぶのも主スレッド（AppDelegate）。Sparkle の型は主スレッド専用のため、触るところでそれを前提にする
/// （型ごと主スレッド専用にすると、呼び出し側の AppDelegate も全体を主スレッド専用に書き換えることになるため）
final class UpdateController {
    /// 配布版で、アップデートを確かめられるか。偽なら設定の項目を出さず、メニューの項目も出さない
    let isAvailable: Bool
    /// 入れ替えて開き直してよいときか（作業の途中で開き直すと途切れるため。AppDelegate が決める）
    var canInstall: () -> Bool = { true }
    /// メニューに出す内容が変わったとき
    var onChange: (() -> Void)?
    /// 自動で取ってこられず、窓も出さずにおいた版（メニューの「〈版〉を入れる…」）。
    /// アプリを書き換えられない場所に置いているなど、裏で入れ替えられないときにだけ入る
    private(set) var pendingVersion: String? { didSet { onChange?() } }

    private var controller: SPUStandardUpdaterController?
    /// 取ってきた版をすぐ入れて開き直す手段（Sparkle から受け取る）
    private var installNow: (() -> Void)?
    private lazy var events = UpdaterEvents(
        downloaded: { [weak self] install in
            self?.installNow = install
            self?.installIfIdle()
        },
        pending: { [weak self] version in self?.pendingVersion = version }
    )

    init() {
        isAvailable = Self.isDeveloperIDSigned()
        guard isAvailable else { return }
        let events = self.events
        MainActor.assumeIsolated {
            self.controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: events, userDriverDelegate: events)
        }
    }

    /// 1日1回確かめて、自動で入れ替えるか（設定の「アップデートを自動で入れ替える」）。値は Sparkle が自分の設定に保存する。
    /// 確かめるだけで入れ替えない組み合わせは作らない（メニューバーのアプリでは、裏で出た知らせに気づきにくいため）
    var automaticallyUpdates: Bool {
        get {
            MainActor.assumeIsolated {
                controller.map { $0.updater.automaticallyChecksForUpdates && $0.updater.automaticallyDownloadsUpdates } ?? false
            }
        }
        set {
            MainActor.assumeIsolated {
                controller?.updater.automaticallyChecksForUpdates = newValue
                controller?.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    /// メニュー・設定の「アップデートを確認」。結果は Sparkle の窓で見せ、新しい版はそこから入れる
    func checkForUpdates() {
        MainActor.assumeIsolated {
            // 普段は前面にいないメニューバーのアプリのため、Sparkle の窓が後ろに隠れないよう前へ出す
            NSApp.activate(ignoringOtherApps: true)
            controller?.checkForUpdates(nil)
        }
    }

    /// 手が空いたときに呼ぶ。取ってきた版があれば、入れ替えて開き直す
    func installIfIdle() {
        guard let install = installNow, canInstall() else { return }
        installNow = nil
        install()
    }

    /// Developer ID Application の証明書で署名されているか（葉の拡張 1.2.840.113635.100.6.1.13 と、中間の Developer ID の CA）。
    /// 配布版だけが真になり、ad-hoc で署名した開発版とテストのビルドは偽
    private static func isDeveloperIDSigned() -> Bool {
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

/// Sparkle の知らせを受ける。delegate は NSObject が要るため、制御の型とは分ける。
/// Sparkle は主スレッドから呼ぶので、その場で（同期で）受ける
private final class UpdaterEvents: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let downloaded: @MainActor (@escaping () -> Void) -> Void
    private let pending: @MainActor (String?) -> Void

    init(downloaded: @escaping @MainActor (@escaping () -> Void) -> Void, pending: @escaping @MainActor (String?) -> Void) {
        self.downloaded = downloaded
        self.pending = pending
    }

    // MARK: SPUUpdaterDelegate

    /// 自動で取ってきた版を、アプリを終えるときに入れる前に呼ばれる。YES を返して、手が空いたらすぐ入れる
    /// （NO だと、アプリを終えるまで入らない。常駐していて終えることが少ないため）
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { downloaded(immediateInstallHandler) }
        return true
    }

    /// 開き直す直前に印を付け、開き直した起動で範囲選択を始めないようにする（Sparkle の窓から入れたときも通る）
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        UpdateRelaunch.mark()
    }

    // MARK: SPUStandardUserDriverDelegate（ゆるい知らせ）

    /// メニューバーのアプリなので、確かめた拍子に窓を前へ出さない。窓を出さなかった版は、メニューで知らせる
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 起動の直後など、窓を前に出してよいときだけ Sparkle に見せさせる
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { pending(version) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pending(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { pending(nil) }
    }
}

/// アップデートで開き直したことの印。開き直しは Dock からの起動と同じ「手動の起動」に見えるため、
/// 印で見分けて範囲選択を始めない。印は一度だけ効かせる
enum UpdateRelaunch {
    static let key = "UpdateRelaunch.pending"

    static func mark(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    /// 印があれば消して真を返す
    static func consume(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: key) else { return false }
        defaults.removeObject(forKey: key)
        return true
    }
}
