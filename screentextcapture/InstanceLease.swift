import Foundation
import Darwin

/// A per-user advisory lock keeps both Launch Services and direct launches to one resident instance.
/// The empty lock file may remain after a crash; the kernel releases its lock automatically.
final class InstanceLease {
    private let descriptor: Int32
    let isPrimary: Bool

    private static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("ScreenTextCapture", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        return directory.appendingPathComponent("instance.lock")
    }

    init(url: URL? = nil) throws {
        let url = try url ?? Self.defaultURL()
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        descriptor = fd
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            isPrimary = true
        } else if errno == EWOULDBLOCK {
            isPrimary = false
        } else {
            close(fd)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit { close(descriptor) }
}
