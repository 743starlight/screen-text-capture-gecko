import XCTest
@testable import screentextcapture

/// 判定はmacOSの答え（ディスクのモデル）に頼るので、将来のmacOSで変わったら気づけるよう、本物のディスクイメージで確かめる
final class DiskImageLaunchTests: XCTestCase {
    private var work: URL!
    private var mountPoint: URL { work.appendingPathComponent("mount", isDirectory: true) }
    private var attached = false

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try hdiutil("create", "-size", "4m", "-fs", "HFS+", "-volname", "DiskImageLaunchTest", "-quiet", image.path)
    }

    override func tearDownWithError() throws {
        if attached { try hdiutil("detach", mountPoint.path, "-quiet", "-force") }
        try FileManager.default.removeItem(at: work)
    }

    func testReadOnlyImageIsDetected() throws {
        try attach("-readonly")
        XCTAssertTrue(DiskImageLaunch.isInsideReadOnlyImage(mountPoint))
    }

    func testWritableImageIsNotDetected() throws {
        try attach()
        XCTAssertFalse(DiskImageLaunch.isInsideReadOnlyImage(mountPoint))
    }

    func testOrdinaryLocationsAreNotDetected() {
        XCTAssertFalse(DiskImageLaunch.isInsideReadOnlyImage(work))
        XCTAssertFalse(DiskImageLaunch.isInsideReadOnlyImage(Bundle.main.bundleURL))
        XCTAssertFalse(DiskImageLaunch.isInsideReadOnlyImage(work.appendingPathComponent("missing")))
    }

    private var image: URL { work.appendingPathComponent("test.dmg") }

    private func attach(_ options: String...) throws {
        try hdiutil(["attach", image.path, "-nobrowse", "-noverify", "-noautoopen", "-quiet", "-mountpoint", mountPoint.path] + options)
        attached = true
    }

    private func hdiutil(_ arguments: String...) throws { try hdiutil(arguments) }

    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "hdiutil \(arguments.joined(separator: " "))")
    }
}
