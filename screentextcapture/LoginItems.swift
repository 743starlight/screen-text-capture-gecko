import AppKit
import Carbon
import ServiceManagement

enum LoginItemState: Equatable {
    case notRegistered, enabled, requiresApproval, notFound
    var isRegistered: Bool { self == .enabled || self == .requiresApproval }
    /// ON/OFFはスイッチで分かるため、利用者の対応が要る状態だけを文で示す
    var note: String? {
        switch self {
        case .notRegistered, .enabled: return nil
        case .requiresApproval: return "macOSのログイン項目で許可すると有効になります。"
        case .notFound: return "登録状態を確認できません。"
        }
    }
}

protocol LoginItemService {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
}

struct SystemLoginItemService: LoginItemService {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

enum LoginItemError: LocalizedError {
    case registration, removal
    var errorDescription: String? {
        switch self {
        case .registration: return "ログイン時起動を登録できませんでした。macOSのログイン項目設定を確認し、再試行してください。"
        case .removal: return "ログイン時起動を解除できませんでした。macOSのログイン項目設定を確認し、再試行してください。"
        }
    }
}

final class LoginItemController {
    private let service: LoginItemService
    init(service: LoginItemService = SystemLoginItemService()) { self.service = service }
    var state: LoginItemState { service.state }

    /// Calling this is restricted to the settings toggle; startup only reads status.
    func setEnabled(_ enabled: Bool) throws -> LoginItemState {
        do {
            if enabled {
                if !state.isRegistered { try service.register() }
            } else if state.isRegistered {
                try service.unregister()
            }
        } catch { throw enabled ? LoginItemError.registration : LoginItemError.removal }
        return state
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum LaunchContext: Equatable {
    case manual, loginItem

    static func from(event: NSAppleEventDescriptor?) -> LaunchContext {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenApplication),
              event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem else {
            return .manual
        }
        return .loginItem
    }

    static var current: LaunchContext { from(event: NSAppleEventManager.shared().currentAppleEvent) }
    var forwardsReopen: Bool { self == .manual }
}
