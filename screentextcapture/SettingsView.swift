import SwiftUI
import AppKit
import Combine

final class AppModel: ObservableObject {
    @Published var settings: OCRSettings
    @Published var status = "範囲を選択すると、認識した文字をコピーします。"
    @Published private(set) var availabilityState = AvailabilityState()
    /// ショートカットを登録できなかった理由。登録・解除に成功したらnilに戻す
    @Published var shortcutError: String?
    @Published var isBusy = false
    @Published var recording = false
    @Published var permission = ScreenPermission.isGranted
    /// 通知の許可状態。nilは確認中
    @Published var notificationsAllowed: Bool?
    @Published private(set) var loginItemState: LoginItemState = .notRegistered
    @Published private(set) var isUpdatingLoginItem = false
    @Published private(set) var loginItemError: String?
    /// 配布版で、アップデートを確かめられるか（開発版・テストのビルドでは偽）
    @Published var updatesAvailable = false
    /// アップデートを自動で入れ替えるか。値は Sparkle が保存し、ここは表示と切り替えの窓口
    @Published var autoUpdate = false
    /// 設定画面の高さの上限。ウィンドウが載っている画面の使える高さで、超える分はフォームの中でスクロールさせる
    @Published var settingsHeightLimit: CGFloat = (NSScreen.main?.visibleFrame.height ?? 900) - 80
    var saveAction: (() -> Void)?
    var shortcutAction: ((Shortcut?) -> Void)?
    var recordingAction: ((Bool) -> Void)?
    var captureAction: (() -> Void)?
    var cancelAction: (() -> Void)?
    var permissionAction: ((PermissionKind) -> Void)?
    var autoUpdateAction: ((Bool) -> Void)?
    var updateCheckAction: (() -> Void)?
    let checker: AvailabilityChecker
    private let loginItems: LoginItemController
    private var availabilitySubscription: AnyCancellable?

    init(settings: OCRSettings = .load(), checker: AvailabilityChecker = AvailabilityChecker(),
         loginItems: LoginItemController = LoginItemController()) {
        self.settings = settings
        self.checker = checker
        self.loginItems = loginItems
        availabilitySubscription = checker.$state.sink { [weak self] in self?.availabilityState = $0 }
    }

    var isChecking: Bool { availabilityState.isChecking }
    var models: [OCRModel] { availabilityState.discovery?.models ?? [] }
    var supportsFast: Bool { availabilityState.discovery?.fastSupported ?? false }
    /// 確認前は利用状況の行に確認ボタンがあるため、理由は確認後に分かったものだけを返す
    var fastReason: String { availabilityState.discovery?.fastReason ?? "" }

    func checkAvailability() {
        guard !isBusy else { return }
        checker.start(settings: settings)
    }

    func recheckAvailability() {
        checker.cancel(message: "利用可否を確認してください。")
        checkAvailability()
    }

    func setFastMode(_ enabled: Bool) {
        settings.fastMode = enabled
        // A new explicit user toggle applies Fast; loading/checking existing preferences never grants it.
        settings.fastCostConsent = enabled
    }

    func refreshLoginItem() {
        precondition(Thread.isMainThread)
        guard !isUpdatingLoginItem else { return }
        let status = loginItems.state
        if status != loginItemState { loginItemError = nil }
        loginItemState = status
    }

    func setLoginEnabled(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        guard !isUpdatingLoginItem else { return }
        isUpdatingLoginItem = true
        loginItemError = nil
        let controller = loginItems
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try controller.setEnabled(enabled) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isUpdatingLoginItem = false
                self.loginItemState = controller.state
                if case .failure(let error) = result { self.loginItemError = error.localizedDescription }
            }
        }
    }

    var selectedModel: OCRModel? {
        settings.modelChoice.isEmpty ? (models.first(where: \.isDefault) ?? models.first) : models.first { $0.id == settings.modelChoice }
    }
    var canUseFast: Bool { supportsFast && selectedModel?.fastTier != nil }
}

/// macOSのシステム設定と同じグループ化フォーム。使う頻度と前提の順に、実行・認識・ショートカット・通知・メニューバーと起動を並べる。
/// 説明文は判断に必要なものだけをセクションの脚注に置き、状態は記号付きの短い文で示す。
struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// フォームの内容の高さ。選択で行が増減するたびに測り直し、ウィンドウをスクロール不要な高さに合わせる
    @State private var contentHeight: CGFloat = 766

    var body: some View {
        Form {
            overview
            Group {
                recognition
                if model.settings.backend != .vision { externalService }
                shortcut
                feedback
                startup
            }
            // 認識中に設定を変えると、実行中の処理と保存内容が食い違うため変更させない
            .disabled(model.isBusy)
        }
        .formStyle(.grouped)
        .modifier(ContentHeightReader(height: $contentHeight))
        // 画面の小さいMacでも使えるよう、画面の高さに達したらそこで止め、フォームの中でスクロールさせる
        .frame(width: 560, height: min(contentHeight, model.settingsHeightLimit))
        .onChange(of: model.settings) { previous, current in
            let leftNotification = previous.copyFeedback == .notification && current.copyFeedback != .notification
            if leftNotification || (previous.notificationPreview && !current.notificationPreview) {
                CopyNotification.cancelPendingDelivery()
            }
            if previous.backend != current.backend || previous.cliPath != current.cliPath || previous.languages != current.languages {
                model.recheckAvailability()
            }
            model.saveAction?()
        }
        .onChange(of: model.recording) { _, value in model.recordingAction?(value) }
    }

    // MARK: - 実行と前提

    // 実行ボタンと直近の結果、実行の前提になる画面収録の許可、使っている版を先頭にまとめる
    private var overview: some View {
        Section {
            HStack(spacing: 12) {
                // Finder・通知・権限の説明と同じアプリアイコンを置き、このアプリの設定だとひと目で分かるようにする
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ScreenTextCapture Gecko").font(.headline)
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("captureStatus")
                }
                Spacer(minLength: 12)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Button("キャンセル") { model.cancelAction?() }
                } else {
                    Button("範囲を選択してコピー") { model.captureAction?() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.recording)
                        .help(model.settings.shortcut.map { "\($0.displayLabel)でも開始できます" } ?? "Dockやメニューバーのアイコンからも開始できます")
                }
            }
            .padding(.vertical, 4)
            LabeledContent("画面収録") {
                if model.permission {
                    StatusText("許可済み", systemImage: "checkmark.circle.fill", tint: .green)
                } else {
                    HStack(spacing: 8) {
                        StatusText("許可が必要です", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                        Button("許可の手順…") { model.permissionAction?(.screenCapture) }
                    }
                }
            }
            LabeledContent("バージョン \(appVersion)") {
                if model.updatesAvailable {
                    // 結果は Sparkle の窓で見せ、新しい版はそこから入れる
                    Button("アップデートを確認") { model.updateCheckAction?() }
                } else {
                    Text("配布版でだけ確かめます").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        return (info["CFBundleVersion"] as? String).map { "\(version)（\($0)）" } ?? version
    }

    // MARK: - 文字認識

    private var recognition: some View {
        Section {
            Picker("認識方法", selection: $model.settings.backend) {
                ForEach(OCRBackend.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("認識言語", selection: languageBinding) {
                Text("日本語 + 英語").tag("ja")
                Text("英語").tag("en")
                Text("簡体字中国語 + 英語").tag("zh-Hans")
                Text("繁体字中国語 + 英語").tag("zh-Hant")
                Text("韓国語 + 英語").tag("ko")
            }
            availability
        } header: {
            Text("文字認識")
        } footer: {
            Text(model.settings.backend == .vision
                 ? "画像はMac内で処理し、外部へは送信しません。"
                 : "\(provider)のCLIに、選択範囲の画像を送って認識します。")
        }
    }

    // 確認結果は長くなるため、ラベル列を使わず記号・結果・操作を1行に並べる
    private var availability: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if model.isChecking {
                    ProgressView().controlSize(.small).accessibilityLabel("利用可否を確認中")
                } else if model.availabilityState.phase == .available {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if model.availabilityState.phase == .unavailable {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isBusy ? "認識の終了後に確認できます。" : model.availabilityState.message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("availabilityStatus")
                if model.isChecking {
                    Text("30秒以内に終わらない場合は中止します。").font(.caption).foregroundStyle(.secondary)
                } else if let checkedAt = model.availabilityState.checkedAt {
                    Text(checkedAt.formatted(date: .omitted, time: .shortened) + "に確認")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.isChecking {
                Button("中止") { model.checker.cancel() }
            } else {
                Button(model.availabilityState.checkedAt == nil ? "利用可否を確認" : "再確認") { model.checkAvailability() }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("availabilityCheck")
            }
        }
    }

    // MARK: - 外部CLI

    private var externalService: some View {
        Section {
            TextField("CLIのパス", text: model.settings.backend == .codex ? $model.settings.codexPath : $model.settings.claudePath)
            Toggle("選択範囲の画像を\(provider)へ送信", isOn: $model.settings.cloudConsent)
            Picker("モデル", selection: $model.settings.modelChoice) {
                Text("CLIの既定モデル").tag("")
                if !model.settings.modelChoice.isEmpty && !model.models.contains(where: { $0.id == model.settings.modelChoice }) {
                    Text("保存済み・未確認：" + model.settings.modelChoice).tag(model.settings.modelChoice)
                }
                ForEach(model.models) { Text($0.name).tag($0.id) }
            }
            .disabled(model.models.isEmpty)
            Toggle("Fastモード", isOn: fastBinding)
                .disabled(!model.canUseFast && !model.settings.fastMode)
            Picker("待ち時間の上限", selection: $model.settings.timeout) {
                Text("30秒").tag(30.0)
                Text("90秒").tag(90.0)
                Text("180秒").tag(180.0)
            }
        } header: {
            Text(model.settings.backend.title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !model.settings.cloudConsent {
                    Text("送信を許可するまで、この方法では認識しません。").foregroundStyle(.orange)
                }
                if !model.fastReason.isEmpty { Text(model.fastReason) }
                Text("CLIの既存ログインと契約の利用枠を使います。機密情報を含む範囲にはApple Visionを使ってください。")
            }
        }
    }

    // MARK: - ショートカット

    private var shortcut: some View {
        Section {
            LabeledContent("範囲選択を開始") {
                HStack(spacing: 8) {
                    ShortcutRecorder(recording: $model.recording,
                                     label: model.settings.shortcut?.displayLabel ?? "未設定") { model.shortcutAction?($0) }
                        .frame(width: 120, height: 24)
                    Button(model.recording ? "中止" : "変更") { model.recording.toggle() }
                    Button("解除") { model.recording = false; model.shortcutAction?(nil) }
                        .disabled(model.settings.shortcut == nil && !model.recording)
                }
            }
        } header: {
            Text("ショートカット")
        } footer: {
            if let error = model.shortcutError {
                Text(error).foregroundStyle(.orange)
            } else if model.recording {
                Text("⌘または⌃を含むキーの組み合わせを押してください。Escで中止します。")
            } else if model.settings.shortcut == nil {
                Text("未設定のときは、Dockやメニューバーのアイコンから開始できます。")
            }
        }
    }

    // MARK: - コピー完了の表示

    private var feedback: some View {
        Section {
            Picker("表示方法", selection: segmentSelection(\.copyFeedback)) {
                ForEach(CopyFeedback.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if model.settings.copyFeedback == .notification {
                Toggle("本文をプレビュー", isOn: $model.settings.notificationPreview)
                LabeledContent("通知の許可") {
                    if let allowed = model.notificationsAllowed {
                        if allowed {
                            StatusText("許可済み", systemImage: "checkmark.circle.fill", tint: .green)
                        } else {
                            HStack(spacing: 8) {
                                StatusText("未許可", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                                Button("許可の手順…") { model.permissionAction?(.notifications) }
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        } header: {
            Text("コピー完了の表示")
        } footer: {
            switch model.settings.copyFeedback {
            case .toast:
                Text("本文を含まない小さな表示を、画面の隅に約2.5秒出します。")
            case .notification:
                Text("集中モード中や画面共有・リモート操作中は、macOSがバナーを表示しません。未許可のときはトーストで知らせます。")
            case .none:
                Text("結果はメニューバーのメニューとこの画面の先頭に表示します。")
            }
        }
    }

    // MARK: - メニューバーと起動

    private var startup: some View {
        Section {
            Picker("メニューバーのアイコン", selection: segmentSelection(\.menuBarIcon)) {
                ForEach(MenuBarIcon.allCases, id: \.self) { icon in
                    if let image = icon.image {
                        Image(nsImage: image).accessibilityLabel(icon.title).help(icon.title).tag(icon)
                    }
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("ログイン時に起動", isOn: Binding(get: { model.loginItemState.isRegistered },
                                                   set: { model.setLoginEnabled($0) }))
                    .disabled(model.isUpdatingLoginItem)
                if model.isUpdatingLoginItem { ProgressView().controlSize(.small) }
            }
            if let note = model.loginItemError ?? model.loginItemState.note {
                HStack {
                    Text(note).foregroundStyle(.orange)
                    Spacer()
                    Button("ログイン項目を開く…") { LoginItemController.openSettings() }
                }
            }
            if model.updatesAvailable {
                // 値は Sparkle が保存するため、切り替えたその場で渡す
                Toggle("アップデートを自動で入れ替える", isOn: Binding(get: { model.autoUpdate },
                                                          set: { model.autoUpdate = $0; model.autoUpdateAction?($0) }))
            }
        } header: {
            Text("メニューバーと起動")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dockに追加したアイコンを押す（起動する）と範囲選択を始めます。Dockの起動中の印は、この画面を開いている間だけ出ます。ログイン時は何も始めずに常駐します。")
                if model.updatesAvailable {
                    Text("新しい版は1日1回確かめ、見つかったら裏でダウンロードして、範囲選択や設定をしていないときに入れ替えて開き直します。")
                }
            }
        }
    }

    // MARK: - 補助

    private var provider: String { model.settings.backend == .claude ? "Anthropic" : "OpenAI" }

    // macOSのセグメント表示は描画の更新中に選択を書き戻すため、そのままでは「Publishing changes from within
    // view updates」の実行時警告になる（1.1.0の実機ログで確認）。モデルへの反映は次の実行ループで行う
    private func segmentSelection<Value>(_ keyPath: WritableKeyPath<OCRSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { value in DispatchQueue.main.async { model.settings[keyPath: keyPath] = value } })
    }

    private var fastBinding: Binding<Bool> {
        Binding(get: { model.settings.fastMode }, set: { model.setFastMode($0) })
    }

    private var languageBinding: Binding<String> {
        Binding(get: {
            switch model.settings.languages.first {
            case "ja-JP": return "ja"
            case "zh-Hans": return "zh-Hans"
            case "zh-Hant": return "zh-Hant"
            case "ko-KR": return "ko"
            default: return "en"
            }
        }, set: { value in
            switch value {
            case "ja": model.settings.languages = ["ja-JP", "en-US"]
            case "zh-Hans": model.settings.languages = ["zh-Hans", "en-US"]
            case "zh-Hant": model.settings.languages = ["zh-Hant", "en-US"]
            case "ko": model.settings.languages = ["ko-KR", "en-US"]
            default: model.settings.languages = ["en-US"]
            }
        })
    }
}

// メニューバーと設定の選択肢で同じ画像を使う。どちらもテンプレート画像のため、メニューバーの明暗や前景色に合わせて塗られる
extension MenuBarIcon {
    var image: NSImage? {
        switch self {
        case .symbol:
            return Self.render(symbol: "text.viewfinder", title: title)
        case .gecko:
            // 標準の記号から3本線を除いた枠（viewfinder）にヤモリを入れ、二つの選択肢の枠と大きさをそろえる。
            // 小さい表示で枠の線とヤモリが接すると潰れて見えるため、枠から約1pt離れるよう中央から左下へずらす（実寸で描き比べて決めた配置）
            guard let gecko = NSImage(named: "MenuBarGecko") else { return nil }
            return Self.render(symbol: "viewfinder", title: title) { size in
                let origin = NSPoint(x: (size.width - gecko.size.width) / 2 - 0.8, y: (size.height - gecko.size.height) / 2 - 0.4)
                gecko.draw(in: NSRect(origin: origin, size: gecko.size))
            }
        }
    }

    // 記号のまま渡すと、状態項目は記号用の位置合わせで描くため、重ねた画像と上下に約0.75ptずれて切り替えると枠が動く。
    // 二つとも同じ普通の画像として描き、配置の基準（alignmentRect）を記号からそろえて、どちらもボタンの中央に置く
    private static func render(symbol name: String, title: String, overlay: ((NSSize) -> Void)? = nil) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: title) else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            overlay?(rect.size)
            return true
        }
        image.isTemplate = true
        image.alignmentRect = symbol.alignmentRect
        image.accessibilityDescription = title
        return image
    }
}

/// macOS 15以降はフォームの内容の高さを読めるため、それをウィンドウの高さにして伸び縮みさせる。
/// macOS 14では読めないため初期値（既定のApple Vision構成が収まる高さ）のままにし、増えた分はフォーム内でスクロールさせる
private struct ContentHeightReader: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, newHeight in
                height = newHeight.rounded(.up)
            }
        } else {
            content
        }
    }
}

/// 許可状態などを、色付きの記号と短い文で示す
private struct StatusText: View {
    let title: String
    let systemImage: String
    let tint: Color

    init(_ title: String, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var recording: Bool
    let label: String
    let picked: (Shortcut) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.isEditable = false
        field.isSelectable = false
        field.alignment = .center
        field.bezelStyle = .roundedBezel
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.stringValue = recording ? "キーを入力…" : label
        field.recording = recording
        field.picked = { shortcut in picked(shortcut); recording = false }
        field.cancelled = { recording = false }
        if recording { DispatchQueue.main.async { field.window?.makeFirstResponder(field) } }
    }
}

final class RecorderField: NSTextField {
    var recording = false
    var picked: ((Shortcut) -> Void)?
    var cancelled: (() -> Void)?
    override var acceptsFirstResponder: Bool { recording }
    override func keyDown(with event: NSEvent) {
        guard recording else { return }
        if event.keyCode == 53 { cancelled?(); return }
        if let shortcut = Shortcut.from(event) { picked?(shortcut) } else { NSSound.beep() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}
