import AppKit

enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Called only from an explicit user button. Never request permission at startup or in tests.
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        NSWorkspace.shared.open(PermissionKind.screenCapture.settingsURL)
    }
}

enum ScreenSelection {
    static func capture(workspace: OCRWorkspace, cancellation: Cancellation) throws {
        guard ScreenPermission.isGranted else { throw OCRError.permissionDenied }
        let child = try CLIProcess(path: "/usr/sbin/screencapture",
                                   arguments: ["-i", "-s", "-x", "-t", "png", workspace.image.path],
                                   workspace: workspace.directory, timeout: 180, cancellation: cancellation)
        defer { child.stop() }
        child.closeInput()
        while try child.nextLine() != nil { }
        let status = try child.finish()
        try cancellation.check()
        let size = (try? FileManager.default.attributesOfItem(atPath: workspace.image.path)[.size] as? Int) ?? 0
        guard status == 0, size > 0 else {
            if !ScreenPermission.isGranted { throw OCRError.permissionDenied }
            throw OCRError.cancelled
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspace.image.path)
    }
}

/// Main-thread coordinator gate; repeated hotkeys cannot create a second selection or overwrite a later job.
final class OperationGate {
    private(set) var active: Cancellation?
    func begin() -> Cancellation? {
        guard active == nil else { return nil }
        let cancellation = Cancellation()
        active = cancellation
        return cancellation
    }
    func cancel() { active?.cancel() }
    func finish() { active = nil }
}
