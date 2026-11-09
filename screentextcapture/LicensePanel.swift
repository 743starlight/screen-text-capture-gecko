import AppKit

// 設定の「ライセンスと謝辞」で開く、macOS 標準の「このアプリについて」の窓。
// 専用の画面を作らず、アイコン・名前・版と、Info.plist の NSHumanReadableCopyright（元の作者とこのフォークの著作権）は窓に任せ、
// 謝辞と許諾文だけを渡す
enum LicensePanel {
    private static let upstreamURL = URL(string: "https://github.com/ku/screentextcapture")!
    private static let sparkleURL = URL(string: "https://github.com/sparkle-project/Sparkle")!

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    // 許諾文は scripts/build-release.sh が配る版の Resources に入れる。開発用のビルドには無いので、その場合は謝辞だけを出す
    static func credits(bundle: Bundle = .main) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        func append(_ text: String, link: URL? = nil, color: NSColor = .labelColor, font: NSFont = .systemFont(ofSize: 11), paragraph: NSParagraphStyle = .default) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if let link { attributes[.link] = link }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        append("ku/screentextcapture", link: upstreamURL, paragraph: centered)
        append(" をもとに作り直したフォークです。\n自動アップデートに ", paragraph: centered)
        append("Sparkle", link: sparkleURL, paragraph: centered)
        append(" を使っています。\n", paragraph: centered)
        for (title, resource) in [("ScreenTextCapture Gecko のライセンス", "LICENSE"), ("Sparkle のライセンス", "Sparkle-LICENSE")] {
            guard let url = bundle.url(forResource: resource, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            append("\n\(title)\n", font: .boldSystemFont(ofSize: 11))
            append(text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", color: .secondaryLabelColor, font: .systemFont(ofSize: 10))
        }
        return result
    }
}
