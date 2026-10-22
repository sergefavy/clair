import Foundation
import ClairCore

@MainActor final class CleanerTests {
    var root: URL!
    var cleaner: Cleaner!
    var app: InstalledApp!
    func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/Clair-test-" + UUID().uuidString)
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Example.app"), withIntermediateDirectories: true)
        cleaner = Cleaner(home: root, applicationRoots: [apps])
        app = InstalledApp(url: apps.appendingPathComponent("Example.app"), name: "Example", bundleID: "org.example.product")
    }
    func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    @discardableResult func file(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        return url
    }
    func testIdentifierBoundary() {
        XCTAssertEqual(cleaner.evidence(for: "org.example.product.plist", app: app), .identifier)
        XCTAssertNil(cleaner.evidence(for: "org.example.productivity.plist", app: app))
        XCTAssertEqual(cleaner.evidence(for: "org.example.product.helper.plist", app: app), .possible)
        XCTAssertEqual(cleaner.evidence(for: "Example", app: app), .possible)
        XCTAssertNil(cleaner.evidence(for: "Examples", app: app))
    }
    func testUUIDPreferences() {
        XCTAssertEqual(cleaner.evidence(for: "org.example.product.11111111-2222-3333-4444-555555555555.plist", app: app), .identifier)
    }
    func testProtectedRootsAndDocuments() throws {
        XCTAssertThrowsError(try cleaner.validatePath(root.appendingPathComponent("Library/Caches"), app: app))
        XCTAssertThrowsError(try cleaner.validatePath(file("Documents/Example"), app: app))
        XCTAssertThrowsError(try cleaner.validatePath(file("Library/Group Containers/org.example.product"), app: app))
        XCTAssertThrowsError(try cleaner.validatePath(URL(fileURLWithPath: "/Library/Caches/org.example.product"), app: app))
    }
    func testAncestorSymlinkRejected() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Library/Caches"), withDestinationURL: outside)
        let target = try file("Library/Caches/org.example.product")
        XCTAssertThrowsError(try cleaner.validatePath(target, app: app))
    }
    func testAppSymlinkRejected() throws {
        let link = root.appendingPathComponent("Applications/Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app.url)
        let linked = InstalledApp(url: link, name: "Link", bundleID: "org.example.link")
        XCTAssertThrowsError(try cleaner.validatePath(link, app: linked))
    }
    func testScanDoesNotDeleteAndDefaultsAreConservative() throws {
        let exact = try file("Library/Caches/org.example.product")
        let uncertain = try file("Library/Application Support/Example")
        let shared = try file("Library/Group Containers/org.example.product")
        let result = cleaner.scan(app)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exact.path))
        XCTAssertTrue(result.candidates.first { $0.url.path == exact.path }!.recommended)
        XCTAssertFalse(result.candidates.first { $0.url.path == uncertain.path }!.recommended)
        XCTAssertFalse(result.candidates.first { $0.url.path == shared.path }!.removable)
        XCTAssertTrue(result.warnings.contains { $0.contains("autre nom") })
    }
    func testReplacedFileRejected() throws {
        let exact = try file("Library/Caches/org.example.product")
        let candidate = cleaner.scan(app).candidates.first { $0.url.path == exact.path }!
        try cleaner.validate(candidate, app: app)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: exact.path)
        XCTAssertThrowsError(try cleaner.validate(candidate, app: app))
    }
    func testAppleApplicationProtected() throws {
        let apple = InstalledApp(url: app.url, name: "Example", bundleID: "com.apple.example")
        XCTAssertThrowsError(try cleaner.validatePath(app.url, app: apple))
        XCTAssertTrue(cleaner.scan(apple).candidates.allSatisfy { !$0.removable })
    }
    func testBoundaryCannotMatchSiblingFolder() {
        XCTAssertFalse(Cleaner.isWithin(root.appendingPathComponent("Library/CachesBackup/Example"), root.appendingPathComponent("Library/Caches")))
    }
    func testPermanentRemovalOfSyntheticFixtureOnly() throws {
        let exact = try file("Library/Caches/org.example.product")
        let unrelated = try file("Library/Caches/org.example.unrelated")
        let chosen = cleaner.scan(app).candidates.filter { $0.url.path == exact.path }
        let outcome = cleaner.execute(chosen, app: app, permanent: true)
        XCTAssertEqual(outcome.0.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exact.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
    }
    func testPreflightFailurePreservesAllFiles() throws {
        let a = try file("Library/Caches/org.example.product")
        let b = try file("Library/Preferences/org.example.product.plist")
        let chosen = cleaner.scan(app).candidates.filter { $0.url.path == a.path || $0.url.path == b.path }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: b.path)
        let outcome = cleaner.execute(chosen, app: app, permanent: true)
        XCTAssertTrue(outcome.0.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }
    func testProductAliasesRemainUnselected() throws {
        let webex = InstalledApp(url: app.url, name: "Webex", bundleID: "com.cisco.webex")
        let alias = try file("Library/Application Support/Cisco Spark")
        let unrelated = try file("Library/Application Support/Cisco")
        let scan = cleaner.scan(webex)
        XCTAssertTrue(scan.candidates.contains { $0.url == alias && !$0.recommended && $0.removable })
        XCTAssertFalse(scan.candidates.contains { $0.url == unrelated })
        let obs = InstalledApp(url: app.url, name: "OBS", bundleID: "com.obsproject.obs-studio")
        XCTAssertEqual(cleaner.evidence(for: "obs-studio", app: obs), .possible)
        XCTAssertNil(cleaner.evidence(for: "ch.protonvpn.mac.WireGuard-Extension", app: obs))
    }
    func testFinalCutAndSystemBoundary() throws {
        let fcp = InstalledApp(url: app.url, name: "Final Cut Pro", bundleID: "com.apple.FinalCut")
        try cleaner.validatePath(fcp.url, app: fcp)
        let system = InstalledApp(url: URL(fileURLWithPath: "/System/Applications/Final Cut Pro.app"), name: fcp.name, bundleID: fcp.bundleID)
        XCTAssertThrowsError(try cleaner.validatePath(system.url, app: system))
    }
    func testPostScanShowsRetainedItems() throws {
        let exact = try file("Library/Caches/org.example.product")
        let retained = try file("Library/Application Support/Example")
        let chosen = cleaner.scan(app).candidates.filter { $0.url == exact }
        let outcome = cleaner.execute(chosen, app: app, permanent: true)
        let after = cleaner.scan(app)
        XCTAssertEqual(outcome.0, Set([exact.path]))
        XCTAssertFalse(after.candidates.contains { $0.url == exact })
        XCTAssertTrue(after.candidates.contains { $0.url == retained })
    }
    func testSizeDoesNotFollowExternalSymlinks() throws {
        let folder = root.appendingPathComponent("measure")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = try file("outside/large")
        try Data(repeating: 1, count: 4096).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertEqual(cleaner.measure(folder).0, 0)
    }
}


var failures = 0
@MainActor func XCTAssertTrue(_ condition: @autoclosure () -> Bool, file: String = #file, line: Int = #line) { if !condition() { failures += 1; print("FAIL \(file):\(line)") } }
@MainActor func XCTAssertFalse(_ condition: @autoclosure () -> Bool, file: String = #file, line: Int = #line) { XCTAssertTrue(!condition(), file: file, line: line) }
@MainActor func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: String = #file, line: Int = #line) { XCTAssertTrue(a == b, file: file, line: line) }
@MainActor func XCTAssertNil<T>(_ value: T?, file: String = #file, line: Int = #line) { XCTAssertTrue(value == nil, file: file, line: line) }
@MainActor func XCTAssertThrowsError<T>(_ work: @autoclosure () throws -> T, file: String = #file, line: Int = #line) { do { _ = try work(); XCTAssertTrue(false, file: file, line: line) } catch {} }
let checks: [(String, @MainActor (CleanerTests) throws -> Void)] = [
    ("product aliases and unrelated VPN", { try $0.testProductAliasesRemainUnselected() }),
    ("Final Cut permission and system boundary", { try $0.testFinalCutAndSystemBoundary() }),
    ("post scan retains unselected data", { try $0.testPostScanShowsRetainedItems() }),
    ("identifier boundaries", { $0.testIdentifierBoundary() }),
    ("UUID preferences", { $0.testUUIDPreferences() }),
    ("protected roots and documents", { try $0.testProtectedRootsAndDocuments() }),
    ("ancestor symlinks", { try $0.testAncestorSymlinkRejected() }),
    ("app symlinks", { try $0.testAppSymlinkRejected() }),
    ("read-only scan and conservative selection", { try $0.testScanDoesNotDeleteAndDefaultsAreConservative() }),
    ("changed file rejection", { try $0.testReplacedFileRejected() }),
    ("Apple app protection", { try $0.testAppleApplicationProtected() }),
    ("sibling path boundary", { $0.testBoundaryCannotMatchSiblingFolder() }),
    ("synthetic permanent removal preserves unrelated data", { try $0.testPermanentRemovalOfSyntheticFixtureOnly() }),
    ("preflight failure preserves all files", { try $0.testPreflightFailurePreservesAllFiles() }),
    ("size symlink protection", { try $0.testSizeDoesNotFollowExternalSymlinks() })
]
for (name, check) in checks {
    let suite = CleanerTests()
    let before = failures
    do { try suite.setUpWithError(); try check(suite) } catch { failures += 1; print("FAIL \(name): \(error)") }
    do { try suite.tearDownWithError() } catch { failures += 1; print("Fixture cleanup failed: \(error)") }
    if failures == before { print("PASS \(name)") }
}
print("\(checks.count) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
