import Foundation
import ClairCore

actor FixtureRecycler {
    enum Behavior: Sendable { case move, refuse, cancel, missingDestination, sourceRetained, failData }
    let root: URL
    let appURL: URL
    let behavior: Behavior
    var calls: [URL] = []
    init(root: URL, appURL: URL, behavior: Behavior = .move) {
        self.root = root; self.appURL = appURL; self.behavior = behavior
    }
    func recycle(_ url: URL) throws -> URL {
        calls.append(url)
        if behavior == .cancel { throw CancellationError() }
        if behavior == .refuse || (behavior == .failData && url != appURL) { throw CocoaError(.fileWriteNoPermission) }
        let destination = root.appendingPathComponent("simulated-trash/" + url.lastPathComponent)
        if behavior == .missingDestination { return destination }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if behavior == .sourceRetained { try FileManager.default.copyItem(at: url, to: destination) }
        else { try FileManager.default.moveItem(at: url, to: destination) }
        return destination
    }
}

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
        let apple = InstalledApp(url: URL(fileURLWithPath: "/System/Applications/Example.app"), name: "Example", bundleID: "com.apple.example")
        XCTAssertThrowsError(try cleaner.validatePath(app.url, app: apple))
        XCTAssertTrue(cleaner.scan(apple).candidates.allSatisfy { !$0.removable })
    }
    func testBoundaryCannotMatchSiblingFolder() {
        XCTAssertFalse(Cleaner.isWithin(root.appendingPathComponent("Library/CachesBackup/Example"), root.appendingPathComponent("Library/Caches")))
    }
    func testPermanentRemovalOfSyntheticFixtureOnly() async throws {
        let exact = try file("Library/Caches/org.example.product")
        let unrelated = try file("Library/Caches/org.example.unrelated")
        let chosen = cleaner.scan(app).candidates.filter { $0.url.path == exact.path }
        let outcome = await cleaner.execute(chosen, app: app, permanent: true)
        XCTAssertEqual(outcome.removed.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exact.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
    }
    func testPreflightFailurePreservesAllFiles() async throws {
        let a = try file("Library/Caches/org.example.product")
        let b = try file("Library/Preferences/org.example.product.plist")
        let chosen = cleaner.scan(app).candidates.filter { $0.url.path == a.path || $0.url.path == b.path }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: b.path)
        let outcome = await cleaner.execute(chosen, app: app, permanent: true)
        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }
    func testDeniedApplicationPreservesSelection() async throws {
        let data = try file("Library/Caches/org.example.product")
        let appURL = app.url
        let restricted = Cleaner(home: root, applicationRoots: [appURL.deletingLastPathComponent()], canRemove: { $0 != appURL })
        let chosen = restricted.scan(app).candidates.filter { $0.url == appURL || $0.url == data }
        let outcome = await restricted.execute(chosen, app: app, permanent: true)
        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
    }
    func testNativeTrashRefusalAndCancellationPreserveData() async throws {
        let data = try file("Library/Caches/org.example.product")
        let appURL = app.url
        let restricted = Cleaner(home: root, applicationRoots: [appURL.deletingLastPathComponent()], canRemove: { $0 != appURL })
        let chosen = restricted.scan(app).candidates.filter { $0.url == appURL || $0.url == data }
        for behavior in [FixtureRecycler.Behavior.refuse, .cancel] {
            let recycler = FixtureRecycler(root: root, appURL: appURL, behavior: behavior)
            let outcome = await restricted.execute(chosen, app: app, permanent: false, recycle: { try await recycler.recycle($0) })
            XCTAssertTrue(outcome.removed.isEmpty)
            XCTAssertTrue(outcome.problem != nil)
            XCTAssertEqual(await recycler.calls, [appURL])
            XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        }
    }
    func testNativeTrashApplicationBeforeData() async throws {
        let data = try file("Library/Caches/org.example.product")
        let appURL = app.url
        let restricted = Cleaner(home: root, applicationRoots: [appURL.deletingLastPathComponent()], canRemove: { $0 != appURL })
        let chosen = restricted.scan(app).candidates.filter { $0.url == appURL || $0.url == data }
        let recycler = FixtureRecycler(root: root, appURL: appURL)
        let outcome = await restricted.execute(chosen.reversed(), app: app, permanent: false, recycle: { try await recycler.recycle($0) })
        XCTAssertEqual(await recycler.calls, [appURL, data])
        XCTAssertEqual(outcome.removed, Set([appURL.path, data.path]))
        XCTAssertNil(outcome.problem)
        XCTAssertTrue(outcome.log.contains("DESTINATION CORBEILLE"))
    }
    func testDeniedDataPreventsNativeTrash() async throws {
        let data = try file("Library/Caches/org.example.product")
        let restricted = Cleaner(home: root, applicationRoots: [app.url.deletingLastPathComponent()], canRemove: { $0 != data })
        let chosen = restricted.scan(app).candidates.filter { $0.url == app.url || $0.url == data }
        let recycler = FixtureRecycler(root: root, appURL: app.url)
        let outcome = await restricted.execute(chosen, app: app, permanent: false, recycle: { try await recycler.recycle($0) })
        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertEqual(await recycler.calls, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
    }
    func testTrashDestinationAndSourceAreVerified() async throws {
        let data = try file("Library/Caches/org.example.product")
        let chosen = cleaner.scan(app).candidates.filter { $0.url == app.url || $0.url == data }
        for behavior in [FixtureRecycler.Behavior.missingDestination, .sourceRetained] {
            let recycler = FixtureRecycler(root: root, appURL: app.url, behavior: behavior)
            let outcome = await cleaner.execute(chosen, app: app, permanent: false, recycle: { try await recycler.recycle($0) })
            XCTAssertTrue(outcome.removed.isEmpty)
            XCTAssertTrue(outcome.problem != nil)
            XCTAssertEqual(await recycler.calls, [app.url])
            XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
        }
    }
    func testPartialTrashStopsAndReportsFailure() async throws {
        let data = try file("Library/Caches/org.example.product")
        let remaining = try file("Library/Preferences/org.example.product.plist")
        let chosen = cleaner.scan(app).candidates.filter { $0.url == app.url || $0.url == data || $0.url == remaining }
        let recycler = FixtureRecycler(root: root, appURL: app.url, behavior: .failData)
        let outcome = await cleaner.execute(chosen, app: app, permanent: false, recycle: { try await recycler.recycle($0) })
        XCTAssertEqual(outcome.removed, Set([app.url.path]))
        XCTAssertTrue(outcome.problem?.contains("1/3") == true)
        XCTAssertEqual(await recycler.calls, [app.url, data])
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remaining.path))
    }
    func testTrashRevalidatesAfterNativePrompt() async throws {
        let data = try file("Library/Caches/org.example.product")
        let appURL = app.url
        let chosen = cleaner.scan(app).candidates.filter { $0.url == appURL || $0.url == data }
        let recycler = FixtureRecycler(root: root, appURL: appURL)
        let outcome = await cleaner.execute(chosen, app: app, permanent: false, recycle: { url in
            let destination = try await recycler.recycle(url)
            if url == appURL { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: data.path) }
            return destination
        })
        XCTAssertEqual(outcome.removed, Set([appURL.path]))
        XCTAssertTrue(outcome.problem?.contains("Fichier modifié") == true)
        XCTAssertEqual(await recycler.calls, [appURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))
    }
    func plist(_ relative: String, _ values: [String: Any]) throws {
        let url = try file(relative)
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }
    func testProductAliasesRemainUnselected() async throws {
        try plist("Applications/Example.app/Contents/Info.plist", ["CFBundleIdentifier": app.bundleID, "CFBundleExecutable": "LegacyEngine", "CFBundleName": "InternalProduct"])
        try plist("Applications/Example.app/Contents/Library/SystemExtensions/Camera.systemextension/Contents/Info.plist", ["CFBundleIdentifier": "net.vendor.camera", "CFBundleName": "CameraEngine"])
        let alias = try file("Library/Application Support/LegacyEngine")
        let component = try file("Library/Caches/net.vendor.camera")
        let unrelated = try file("Library/Application Support/Vendor")
        let scan = cleaner.scan(app)
        XCTAssertTrue(scan.candidates.contains { $0.url == alias && !$0.recommended && $0.removable })
        XCTAssertTrue(scan.candidates.contains { $0.url == component && !$0.recommended })
        XCTAssertFalse(scan.candidates.contains { $0.url == unrelated })
        XCTAssertNil(cleaner.evidence(for: "ch.protonvpn.mac.WireGuard-Extension", app: scan.app))
        XCTAssertTrue(scan.app.componentIDs.contains("net.vendor.camera"))
        let selected = scan.candidates.filter { $0.url == alias }
        let outcome = await cleaner.execute(selected, app: scan.app, permanent: true)
        XCTAssertEqual(outcome.removed, Set([alias.path]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        // After the app is gone the original identity remains usable for the verification.
        try FileManager.default.removeItem(at: app.url)
        XCTAssertTrue(cleaner.scan(scan.app).candidates.contains { $0.url == component })
    }
    func testLaunchServiceUsesExecutableOnly() throws {
        try plist("Applications/Example.app/Contents/Info.plist", ["CFBundleIdentifier": app.bundleID])
        _ = try file("Applications/Example.app/Contents/MacOS/engine")
        let path = app.url.appendingPathComponent("Contents/MacOS/engine").path
        try plist("Library/LaunchAgents/unrelated-name.plist", ["ProgramArguments": [path, "--start"]])
        try plist("Library/LaunchAgents/unrelated-document.plist", ["ProgramArguments": ["/usr/bin/open", path]])
        let scan = cleaner.scan(app)
        XCTAssertTrue(scan.candidates.contains { $0.url.lastPathComponent == "unrelated-name.plist" && !$0.recommended && $0.removable })
        XCTAssertFalse(scan.candidates.contains { $0.url.lastPathComponent == "unrelated-document.plist" })
    }
    func testFrameworkApplicationsAreDiscoveredConservatively() throws {
        for name in ["Phone", "Chat", "Meeting"] {
            try plist("Applications/Example.app/Contents/Frameworks/\(name).app/Contents/Info.plist",
                      ["CFBundleIdentifier": "net.vendor.\(name.lowercased())", "CFBundleName": "Embedded\(name)"])
        }
        try plist("Applications/Example.app/Contents/Frameworks/ThirdParty.framework/Contents/Info.plist",
                  ["CFBundleIdentifier": "org.thirdparty.runtime", "CFBundleName": "ThirdPartyRuntime"])
        let component = try file("Library/Caches/net.vendor.phone")
        let thirdParty = try file("Library/Caches/org.thirdparty.runtime")
        let scan = cleaner.scan(app)
        for name in ["Phone", "Chat", "Meeting"] {
            XCTAssertTrue(scan.app.componentIDs.contains("net.vendor.\(name.lowercased())"))
            XCTAssertTrue(scan.app.discoveredNames.contains("Embedded\(name)"))
        }
        XCTAssertTrue(scan.candidates.contains { $0.url == component && $0.evidence == .possible && !$0.recommended })
        XCTAssertFalse(scan.app.componentIDs.contains("org.thirdparty.runtime"))
        XCTAssertFalse(scan.app.discoveredNames.contains("ThirdPartyRuntime"))
        XCTAssertFalse(scan.candidates.contains { $0.url == thirdParty })
    }
    func testNestedExactIdentifiersDoNotEstablishOwnership() throws {
        var foreignFiles: [URL] = []
        for location in ["Application Support", "Caches", "Preferences", "Logs", "HTTPStorages", "WebKit"] {
            foreignFiles.append(try file("Library/\(location)/OtherProduct/org.example.product.plist"))
            foreignFiles.append(try file("Library/\(location)/OtherProduct/Settings/org.example.product.plist"))
        }
        let byHost = try file("Library/Preferences/ByHost/org.example.product.11111111-2222-3333-4444-555555555555.plist")
        for name in ["org.example.product.plist", "org.example.product.helper.plist", "Example.plist"] {
            foreignFiles.append(try file("Library/Preferences/ByHost/\(name)"))
        }
        let rootPreference = try file("Library/Preferences/org.example.product.plist")
        let scan = cleaner.scan(app)
        for foreign in foreignFiles {
            XCTAssertThrowsError(try cleaner.validatePath(foreign, app: scan.app))
            XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
            XCTAssertTrue(scan.candidates.contains { $0.url == foreign && !$0.recommended && !$0.removable && $0.evidence == .possible })
        }
        XCTAssertTrue(scan.candidates.contains { $0.url == byHost && $0.recommended })
        XCTAssertTrue(scan.candidates.contains { $0.url == rootPreference && $0.recommended })
        try cleaner.validatePath(byHost, app: scan.app)
    }
    func testIdentityDoesNotFollowSymlinks() throws {
        let outside = root.appendingPathComponent("outside")
        try plist("outside/Contents/Info.plist", ["CFBundleName": "ExternalEngine", "CFBundleIdentifier": "org.external.helper"])
        let plugins = app.url.appendingPathComponent("Contents/PlugIns")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: plugins.appendingPathComponent("Other.app"), withDestinationURL: outside)
        let identity = cleaner.discoverIdentity(app)
        XCTAssertFalse(identity.componentIDs.contains("org.external.helper"))
        XCTAssertFalse(identity.discoveredNames.contains("ExternalEngine"))
    }
    func testApplicationAndSystemBoundary() throws {
        let fcp = InstalledApp(url: app.url, name: "Example", bundleID: "com.apple.example")
        try cleaner.validatePath(fcp.url, app: fcp)
        let system = InstalledApp(url: URL(fileURLWithPath: "/System/Applications/Example.app"), name: fcp.name, bundleID: fcp.bundleID)
        XCTAssertThrowsError(try cleaner.validatePath(system.url, app: system))
    }
    func testPostScanShowsRetainedItems() async throws {
        let exact = try file("Library/Caches/org.example.product")
        let retained = try file("Library/Application Support/Example")
        let chosen = cleaner.scan(app).candidates.filter { $0.url == exact }
        let outcome = await cleaner.execute(chosen, app: app, permanent: true)
        let after = cleaner.scan(app)
        XCTAssertEqual(outcome.removed, Set([exact.path]))
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
let checks: [(String, @MainActor (CleanerTests) async throws -> Void)] = [
    ("native trash refusal and cancellation preserve data", { try await $0.testNativeTrashRefusalAndCancellationPreserveData() }),
    ("native trash application precedes data", { try await $0.testNativeTrashApplicationBeforeData() }),
    ("denied data prevents native trash", { try await $0.testDeniedDataPreventsNativeTrash() }),
    ("trash destination and source verified", { try await $0.testTrashDestinationAndSourceAreVerified() }),
    ("partial trash stops and reports failure", { try await $0.testPartialTrashStopsAndReportsFailure() }),
    ("revalidate data after native prompt", { try await $0.testTrashRevalidatesAfterNativePrompt() }),
    ("denied application preserves entire selection", { try await $0.testDeniedApplicationPreservesSelection() }),
    ("generic bundle identity and post-removal snapshot", { try await $0.testProductAliasesRemainUnselected() }),
    ("launch service executable attribution", { try $0.testLaunchServiceUsesExecutableOnly() }),
    ("framework applications and third-party identity boundary", { try $0.testFrameworkApplicationsAreDiscoveredConservatively() }),
    ("nested identifiers require an ownership boundary", { try $0.testNestedExactIdentifiersDoNotEstablishOwnership() }),
    ("identity excludes symlinked components", { try $0.testIdentityDoesNotFollowSymlinks() }),
    ("application roots and system boundary", { try $0.testApplicationAndSystemBoundary() }),
    ("post scan retains unselected data", { try await $0.testPostScanShowsRetainedItems() }),
    ("identifier boundaries", { $0.testIdentifierBoundary() }),
    ("UUID preferences", { $0.testUUIDPreferences() }),
    ("protected roots and documents", { try $0.testProtectedRootsAndDocuments() }),
    ("ancestor symlinks", { try $0.testAncestorSymlinkRejected() }),
    ("app symlinks", { try $0.testAppSymlinkRejected() }),
    ("read-only scan and conservative selection", { try $0.testScanDoesNotDeleteAndDefaultsAreConservative() }),
    ("changed file rejection", { try $0.testReplacedFileRejected() }),
    ("Apple app protection", { try $0.testAppleApplicationProtected() }),
    ("sibling path boundary", { $0.testBoundaryCannotMatchSiblingFolder() }),
    ("synthetic permanent removal preserves unrelated data", { try await $0.testPermanentRemovalOfSyntheticFixtureOnly() }),
    ("preflight failure preserves all files", { try await $0.testPreflightFailurePreservesAllFiles() }),
    ("size symlink protection", { try $0.testSizeDoesNotFollowExternalSymlinks() })
]
for (name, check) in checks {
    let suite = CleanerTests()
    let before = failures
    do { try suite.setUpWithError(); try await check(suite) } catch { failures += 1; print("FAIL \(name): \(error)") }
    do { try suite.tearDownWithError() } catch { failures += 1; print("Fixture cleanup failed: \(error)") }
    if failures == before { print("PASS \(name)") }
}
print("\(checks.count) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
