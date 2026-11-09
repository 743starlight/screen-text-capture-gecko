import AppKit
import DiskArbitration

/// 配っているDMGの中から開いたときの案内。中のまま使うとディスクを取り出せないので、アプリケーションフォルダから開くよう伝える。
/// 見るのはDMGの中かどうかだけで、/Applicationsにあるかは見ない（外部ディスクなどに置いて使う人もいるため）
enum DiskImageLaunch {
    /// 起動の最初に呼ぶ。DMGの中なら案内を出し、アプリケーションフォルダを開くことを選んだら、このアプリを終える
    @MainActor
    static func guideIfNeeded() {
        guard isInsideReadOnlyImage(Bundle.main.bundleURL) else { return }
        let alert = NSAlert()
        alert.messageText = "アプリケーションフォルダにコピーしてから開いてください"
        alert.informativeText = "ダウンロードしたディスクイメージの中の ScreenTextCapture Gecko を開いています。\nアプリケーションフォルダにコピーしてから、アプリケーションフォルダの ScreenTextCapture Gecko を開いてください。"
        alert.addButton(withTitle: "アプリケーションフォルダを開く")
        // 案内にとどめ、使えなくはしない（試すだけの人もいるため）
        alert.addButton(withTitle: "このまま使う")
        // メニューバーだけで動く作りなので、前に出さないと窓の後ろに隠れる
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        // 開いたままだとディスクを取り出せないうえ、後から開いたアプリケーションフォルダのアプリも、
        // 常駐中のこちらへ合図して終わるだけで入れ替わらないので終える（InstanceLease）
        exit(0)
    }

    /// 読み取り専用のディスクイメージの中にあればtrue。配るDMGは読み取り専用なので、
    /// 自分で作った書き込めるディスクイメージ（暗号化した入れ物など）に置いて使う人には案内しない
    static func isInsideReadOnlyImage(_ url: URL) -> Bool {
        guard let volume = backingVolume(ofPath: url.path), volume.f_flags & UInt32(MNT_RDONLY) != 0,
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, text(volume.f_mntfromname)),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        // ディスクイメージはデバイスのモデルが「Disk Image」になる。外付けのディスクは製品の型番になるので取り違えない
        return description[kDADiskDescriptionDeviceModelKey as String] as? String == "Disk Image"
    }

    private static func backingVolume(ofPath path: String) -> statfs? {
        var volume = statfs()
        guard statfs(path, &volume) == 0 else { return nil }
        // ダウンロードしたものをその場で開くと、macOSがApp Translocationで仮の場所（nullfs）に見せるので、元の場所（mntfromname）をたどる。
        // zipを展開して開いた場合も仮の場所になるので、仮の場所というだけではDMGとみなさない
        return text(volume.f_fstypename) == "nullfs" ? backingVolume(ofPath: text(volume.f_mntfromname)) : volume
    }

    private static func text<Field>(_ field: Field) -> String {
        withUnsafeBytes(of: field) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}
