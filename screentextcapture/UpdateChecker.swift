import Foundation

/// GitHubのリリースで新しい版が出ていないかを確かめる。見つけたら知らせてリリースのページを開けるようにするだけで、
/// ダウンロードや置き換えはしない（署名の確かめを含め、入れ替えは利用者が行う）。
/// 配信先（owner/repo）はInfo.plistの ScreenTextCaptureUpdateRepository で決め、空のうちは通信しない
enum UpdateCheck {
    static let repositoryKey = "ScreenTextCaptureUpdateRepository"
    /// 自動の確認の間隔。起動時に確かめ、その後は前回から1日たつごとに確かめる
    static let interval: TimeInterval = 24 * 60 * 60

    /// "owner/repo" の形だけを配信先として受け付ける。空や形の違う値は未設定として扱う。
    /// 「.」「..」だけの区切りはAPIのパスを別の場所へずらすため受け付けない（「.github」のような名前は使える）
    static func repository(from value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        return text
    }

    /// "v1.3.0" や "1.3" を数の並びにする。数以外を含むタグは比べられないためnil
    static func versionNumbers(_ text: String) -> [Int]? {
        var version = Substring(text.trimmingCharacters(in: .whitespaces))
        if version.first == "v" || version.first == "V" { version = version.dropFirst() }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        return !parts.isEmpty && numbers.count == parts.count ? numbers : nil
    }

    /// 版を数の並びとして比べる。足りない桁は0とみなす（1.3 と 1.3.0 は同じ）
    static func isNewer(_ candidate: String, than current: String) -> Bool? {
        guard var a = versionNumbers(candidate), var b = versionNumbers(current) else { return nil }
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        return a != b && !a.lexicographicallyPrecedes(b)
    }

    /// releases/latest の応答から、今より新しい版を取り出す。同じか古ければnil
    static func newerRelease(in data: Data, repository: String, currentVersion: String) throws -> UpdateRelease? {
        struct Payload: Decodable { let tag_name: String }
        let tag = try JSONDecoder().decode(Payload.self, from: data).tag_name
        guard let newer = isNewer(tag, than: currentVersion), let numbers = versionNumbers(tag) else { throw UpdateError.unreadable }
        guard newer else { return nil }
        // 応答のURLは使わず、設定した配信先の最新リリースのページを開く
        return UpdateRelease(version: numbers.map(String.init).joined(separator: "."),
                             page: URL(string: "https://github.com/\(repository)/releases/latest")!)
    }
}

struct UpdateRelease: Equatable {
    let version: String
    let page: URL
}

enum UpdateError: Error, Equatable {
    case unconfigured, noRelease, rateLimited, network, unreadable, server(Int)

    /// 設定画面の1行に収まる短い説明
    var message: String {
        switch self {
        case .unconfigured: return "配信先が未設定のため確認しません"
        case .noRelease: return "公開されたリリースはまだありません"
        case .rateLimited: return "しばらくしてから再確認してください"
        case .network: return "確認できませんでした"
        case .unreadable: return "リリースの情報を読み取れませんでした"
        case .server(let code): return "確認できませんでした（\(code)）"
        }
    }
}

enum UpdateState: Equatable {
    case unconfigured, idle, checking
    case upToDate, noRelease
    case available(UpdateRelease)
    case failed(String)
}

final class UpdateChecker {
    let repository: String?
    let currentVersion: String
    private let session: URLSession

    // Cookieやキャッシュを残さない一時的な接続で問い合わせる
    init(repository: String?, currentVersion: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.repository = repository
        self.currentVersion = currentVersion
        self.session = session
    }

    static func forMainBundle() -> UpdateChecker {
        let info = Bundle.main.infoDictionary ?? [:]
        return UpdateChecker(repository: UpdateCheck.repository(from: info[UpdateCheck.repositoryKey]),
                             currentVersion: info["CFBundleShortVersionString"] as? String ?? "0")
    }

    /// 結果はメインスレッドで返す。配信先が未設定なら通信せずに返す
    func check(completion: @escaping (Result<UpdateRelease?, UpdateError>) -> Void) {
        guard let repository else { completion(.failure(.unconfigured)); return }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHubのAPIはUser-Agentを必須とする。送るのはアプリ名と版だけ
        request.setValue("ScreenTextCapture-Gecko/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let current = currentVersion
        session.dataTask(with: request) { data, response, error in
            let result = Self.result(data: data, response: response, error: error, repository: repository, currentVersion: current)
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func result(data: Data?, response: URLResponse?, error: Error?,
                       repository: String, currentVersion: String) -> Result<UpdateRelease?, UpdateError> {
        guard error == nil, let http = response as? HTTPURLResponse else { return .failure(.network) }
        switch http.statusCode {
        case 200:
            do { return .success(try UpdateCheck.newerRelease(in: data ?? Data(), repository: repository, currentVersion: currentVersion)) }
            catch { return .failure(.unreadable) }
        // 公開したリリースがない、またはリポジトリが非公開・未作成のとき
        case 404: return .failure(.noRelease)
        // 認証なしのAPIは1時間あたりの回数に上限がある
        case 403, 429: return .failure(.rateLimited)
        default: return .failure(.server(http.statusCode))
        }
    }
}
