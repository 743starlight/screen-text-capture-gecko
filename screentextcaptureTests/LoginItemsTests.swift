import XCTest
import AppKit
import Carbon
import Combine
@testable import screentextcapture

final class LoginItemsTests: XCTestCase {
    func testStartupReadsStatusWithoutRegisteringDefaultOff() {
        let service = FakeLoginItemService()
        let model = AppModel(settings: OCRSettings(), loginItems: LoginItemController(service: service))
        model.refreshLoginItem()
        XCTAssertFalse(model.loginItemState.isRegistered)
        XCTAssertEqual(service.registrations, 0); XCTAssertEqual(service.removals, 0)
        service.state = .enabled; model.refreshLoginItem()
        XCTAssertTrue(model.loginItemState.isRegistered)
        service.state = .requiresApproval; model.refreshLoginItem()
        XCTAssertEqual(model.loginItemState, .requiresApproval)
        XCTAssertEqual(service.registrations, 0)
    }

    func testExplicitToggleRegistersOnceAndUnregisters() {
        let service = FakeLoginItemService()
        let model = AppModel(settings: OCRSettings(), loginItems: LoginItemController(service: service))
        let enabled = expectation(description: "registered")
        var subscription = model.$isUpdatingLoginItem.dropFirst().sink { if !$0 { enabled.fulfill() } }
        model.setLoginEnabled(true); model.setLoginEnabled(true)
        XCTAssertTrue(model.isUpdatingLoginItem)
        wait(for: [enabled], timeout: 2)
        XCTAssertEqual(service.registrations, 1); XCTAssertEqual(model.loginItemState, .enabled)
        subscription.cancel()
        let removed = expectation(description: "unregistered")
        subscription = model.$isUpdatingLoginItem.dropFirst().sink { if !$0 { removed.fulfill() } }
        model.setLoginEnabled(false)
        wait(for: [removed], timeout: 2)
        XCTAssertEqual(service.removals, 1); XCTAssertEqual(model.loginItemState, .notRegistered)
        subscription.cancel()
    }

    func testRegistrationAndRemovalErrorsPreserveActualState() {
        let service = FakeLoginItemService(); service.failRegistration = true
        let model = AppModel(settings: OCRSettings(), loginItems: LoginItemController(service: service))
        let failed = expectation(description: "registration error")
        var subscription = model.$isUpdatingLoginItem.dropFirst().sink { if !$0 { failed.fulfill() } }
        model.setLoginEnabled(true); wait(for: [failed], timeout: 2)
        XCTAssertFalse(model.loginItemState.isRegistered)
        XCTAssertTrue(model.loginItemError?.contains("登録できません") == true)
        subscription.cancel()
        service.state = .enabled; service.failRemoval = true; model.refreshLoginItem()
        let removal = expectation(description: "removal error")
        subscription = model.$isUpdatingLoginItem.dropFirst().sink { if !$0 { removal.fulfill() } }
        model.setLoginEnabled(false); wait(for: [removal], timeout: 2)
        XCTAssertTrue(model.loginItemState.isRegistered)
        XCTAssertTrue(model.loginItemError?.contains("解除できません") == true)
        subscription.cancel()
    }

    func testPendingApprovalIsRegisteredWithoutRepeatedRegistration() throws {
        let service = FakeLoginItemService(); service.state = .requiresApproval
        let controller = LoginItemController(service: service)
        XCTAssertEqual(try controller.setEnabled(true), .requiresApproval)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(try controller.setEnabled(false), .notRegistered)
        XCTAssertEqual(service.removals, 1)
    }

    // ログイン時の自動起動は範囲選択を始めず（.manualだけが始める）、二重起動のときも常駐中のアプリへ伝えない
    func testLoginAppleEventStaysQuietAndDoesNotForwardReopen() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        let login = LaunchContext.from(event: event)
        XCTAssertEqual(login, .loginItem)
        XCTAssertFalse(login.forwardsReopen)
        XCTAssertEqual(LaunchContext.from(event: nil), .manual)
        XCTAssertTrue(LaunchContext.manual.forwardsReopen)
        let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        reopen.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        XCTAssertEqual(LaunchContext.from(event: reopen), .manual)
    }
}

private final class FakeLoginItemService: LoginItemService {
    var state: LoginItemState = .notRegistered
    var registrations = 0
    var removals = 0
    var failRegistration = false
    var failRemoval = false
    func register() throws {
        registrations += 1
        if failRegistration { throw CocoaError(.fileWriteNoPermission) }
        state = .enabled
    }
    func unregister() throws {
        removals += 1
        if failRemoval { throw CocoaError(.fileWriteNoPermission) }
        state = .notRegistered
    }
}
