import XCTest
@testable import CalendarSyncCore

final class InstanceLockTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstanceLockTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOnlyOneHolderAtATime() throws {
        let url = folder.appendingPathComponent("instance.lock")
        let first = try XCTUnwrap(InstanceLock.acquire(at: url), "nobody holds it yet")
        XCTAssertNil(try InstanceLock.acquire(at: url), "a second copy can't take it while the first runs")
        withExtendedLifetime(first) {}
    }

    func testFreedWhenTheHolderGoesAway() throws {
        let url = folder.appendingPathComponent("instance.lock")
        var first = try InstanceLock.acquire(at: url)
        XCTAssertNotNil(first)
        first = nil
        XCTAssertNotNil(try InstanceLock.acquire(at: url), "a copy started after the first quit runs")
    }

    func testCreatesMissingFolders() throws {
        let url = folder.appendingPathComponent("a/b/instance.lock")
        XCTAssertNotNil(try InstanceLock.acquire(at: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testThrowsWhenTheFileCantBeOpened() throws {
        // A plain file where the lock's folder should be.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appendingPathComponent("not-a-folder")
        try Data().write(to: blocker)
        XCTAssertThrowsError(try InstanceLock.acquire(at: blocker.appendingPathComponent("instance.lock")))
    }
}
