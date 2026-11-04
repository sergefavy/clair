import Foundation
import ClairCore

// Contrôles du moteur sur des fichiers fictifs, dans un dossier temporaire.
// Aucun fichier réel n'est lu en écriture ni déplacé.

struct Failure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) throws {
    if !condition { throw Failure(description: "ligne \(line) : \(message())") }
}

/// Reçus simulés.
struct FakeReceipts: ReceiptStore {
    var ownersByPath: [String: [String]] = [:]
    var ids: [String] = []
    let forgotten: LockedSet
    func owners(of path: String) -> [String] { ownersByPath[path] ?? [] }
    func packageIDs() -> [String] { ids }
    func exists(_ id: String) -> Bool { ids.contains(id) && !forgotten.contains(id) }
}

final class LockedSet: @unchecked Sendable {
    private let lock = NSLock(); private var values = Set<String>()
    func insert(_ v: String) { lock.lock(); values.insert(v); lock.unlock() }
    func contains(_ v: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains(v) }
}

/// Corbeille simulée : déplace dans `trash/` et enregistre les appels.
actor FakeBackend: RemovalBackend {
    let trashDir: URL
    let forgotten: LockedSet
    var failUserTrash: Set<String> = []
    var cancelAdmin = false
    var calls: [String] = []
    init(trashDir: URL, forgotten: LockedSet) { self.trashDir = trashDir; self.forgotten = forgotten }
    func configure(failUserTrash: Set<String> = [], cancelAdmin: Bool = false) { self.failUserTrash = failUserTrash; self.cancelAdmin = cancelAdmin }
    private func move(_ url: URL) throws {
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
    }
    func trash(_ url: URL) async throws {
        calls.append("trash " + url.lastPathComponent)
        if failUserTrash.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
        try move(url)
    }
    func trashWithFinder(_ urls: [URL]) async throws {
        calls.append("finder " + urls.map(\.lastPathComponent).joined(separator: ","))
        if cancelAdmin { throw CleanerError.cancelled }
        for u in urls { try move(u) }
    }
    func runAsAdmin(_ commands: [[String]]) async throws {
        calls.append("admin " + commands.map { $0.joined(separator: " ") }.joined(separator: " ; "))
        if cancelAdmin { throw CleanerError.cancelled }
        for c in commands where c.count == 3 && c[1] == "--forget" { forgotten.insert(c[2]) }
    }
    func unloadUserService(_ plist: URL) async { calls.append("unload " + plist.lastPathComponent) }
}

final class Fixture {
    let root: URL
    let home: URL
    let system: URL
    let apps: URL
    let forgotten = LockedSet()
    var receipts: FakeReceipts
    init() throws {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/clair-checks")
        root = base.appendingPathComponent(UUID().uuidString)
        home = root.appendingPathComponent("home")
        system = root.appendingPathComponent("SystemLibrary")
        apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        receipts = FakeReceipts(forgotten: forgotten)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    var cleaner: Cleaner {
        let system = system.path
        return Cleaner(home: home, applicationRoots: [apps], systemLibrary: self.system, darwinDirectories: [],
                       receipts: receipts,
                       canRemove: { !$0.path.hasPrefix(system) },
                       isInstalled: { $0 == "com.registered.elsewhere" })
    }
    lazy var backend = FakeBackend(trashDir: root.appendingPathComponent("trash"), forgotten: forgotten)

    @discardableResult func file(_ relative: String, in base: URL? = nil, contents: Data = Data("x".utf8)) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }
    func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
    /// Crée un paquet .app minimal.
    func app(_ name: String, id: String, in folder: URL? = nil) throws -> InstalledApp {
        let url = (folder ?? apps).appendingPathComponent(name + ".app")
        try file("Contents/Info.plist", in: url, contents: plist(["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name]))
        try file("Contents/MacOS/" + name, in: url)
        return InstalledApp(bundleAt: url)!
    }
}

func candidate(_ scan: AppScan, _ suffix: String) -> Candidate? { scan.candidates.first { $0.url.path.hasSuffix(suffix) } }

// MARK: - Contrôles

let checks: [(String, () async throws -> Void)] = [
    ("identifiant exact : coché par défaut", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        try f.file("Library/Preferences/org.example.product.plist")
        try f.file("Library/Caches/org.example.product/data")
        try f.file("Library/Containers/org.example.product/Data/x")
        try f.file("Library/Saved Application State/org.example.product.savedState/x")
        try f.file("Library/Preferences/ByHost/org.example.product.\(UUID().uuidString).plist")
        try f.file("Library/Preferences/org.unrelated.app.plist")
        let scan = f.cleaner.scan(app)
        try expect(candidate(scan, "Example.app")?.evidence == .application, "app")
        for s in ["Preferences/org.example.product.plist", "Caches/org.example.product", "Containers/org.example.product", "org.example.product.savedState"] {
            try expect(candidate(scan, s)?.recommended == true, s)
        }
        try expect(scan.candidates.contains { $0.url.path.contains("ByHost") && $0.evidence == .identifier }, "ByHost")
        try expect(candidate(scan, "org.unrelated.app.plist") == nil, "fichier sans rapport")
    }),
    ("préfixe d’identifiant : à vérifier, non coché", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        try f.file("Library/Preferences/org.example.product.pro.plist")
        let c = candidate(f.cleaner.scan(app), "org.example.product.pro.plist")
        try expect(c?.evidence == .possible && c?.recommended == false, "\(String(describing: c?.evidence))")
    }),
    ("nom de l’application : coché ; nom interne : à vérifier", {
        let f = try Fixture(); var app = try f.app("Example", id: "org.example.product")
        app.discoveredNames = []
        try f.file("Library/Application Support/Example/db")
        try f.file("Library/Application Support/Electron/db")
        let url = app.url.appendingPathComponent("Contents/Frameworks/Example Helper.app")
        try f.file("Contents/Info.plist", in: url, contents: f.plist(["CFBundleIdentifier": "org.example.product.helper", "CFBundleExecutable": "Electron"]))
        let scan = f.cleaner.scan(app)
        try expect(candidate(scan, "Application Support/Example")?.evidence == .name, "nom")
        try expect(candidate(scan, "Application Support/Electron")?.evidence == .possible, "nom interne")
    }),
    ("composants : même éditeur coché, autre éditeur à vérifier", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        try f.file("Contents/Info.plist", in: app.url.appendingPathComponent("Contents/XPCServices/A.xpc"), contents: f.plist(["CFBundleIdentifier": "org.example.agent"]))
        try f.file("Contents/Info.plist", in: app.url.appendingPathComponent("Contents/PlugIns/B.appex"), contents: f.plist(["CFBundleIdentifier": "net.thirdparty.kit"]))
        try f.file("Library/Caches/org.example.agent/x")
        try f.file("Library/Caches/net.thirdparty.kit/x")
        let scan = f.cleaner.scan(app)
        try expect(candidate(scan, "org.example.agent")?.evidence == .component, "même éditeur")
        try expect(candidate(scan, "net.thirdparty.kit")?.evidence == .possible, "autre éditeur")
    }),
    ("services système et outil privilégié : détectés, droits requis", {
        let f = try Fixture(); let app = try f.app("Zoomish", id: "us.zoomish.xos")
        try f.file("Contents/Library/LaunchServices/us.zoomish.Daemon", in: app.url)
        try f.file("LaunchDaemons/us.zoomish.Daemon.plist", in: f.system, contents: f.plist(["Label": "us.zoomish.Daemon", "Program": "/Library/PrivilegedHelperTools/us.zoomish.Daemon"]))
        try f.file("PrivilegedHelperTools/us.zoomish.Daemon", in: f.system)
        try f.file("LaunchAgents/weird-name.plist", in: f.home.appendingPathComponent("Library"), contents: f.plist(["Label": "x", "ProgramArguments": [app.url.path + "/Contents/MacOS/Zoomish"]]))
        try f.file("LaunchAgents/other.plist", in: f.home.appendingPathComponent("Library"), contents: f.plist(["Label": "y", "ProgramArguments": ["/usr/bin/open", app.url.path]]))
        let scan = f.cleaner.scan(app)
        let daemon = candidate(scan, "LaunchDaemons/us.zoomish.Daemon.plist")
        try expect(daemon?.evidence == .component && daemon?.requiresAdmin == true && daemon?.launchDomain == .system, "daemon \(String(describing: daemon))")
        try expect(candidate(scan, "PrivilegedHelperTools/us.zoomish.Daemon")?.recommended == true, "helper")
        try expect(candidate(scan, "weird-name.plist")?.launchDomain == .user, "agent lancé depuis l’app")
        try expect(candidate(scan, "other.plist") == nil, "argument seulement : ignoré")
    }),
    ("groupes partagés et extensions système : jamais cochés", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        try f.file("Library/Group Containers/ABCDE12345.org.example.product/x")
        try f.file("SystemExtensions/org.example.product/x", in: f.system)
        let scan = f.cleaner.scan(app)
        try expect(candidate(scan, "ABCDE12345.org.example.product")?.evidence == .possible, "groupe")
        try expect(candidate(scan, "SystemExtensions/org.example.product")?.removable == false, "extension")
    }),
    ("dossier d’éditeur imbriqué", {
        let f = try Fixture(); let app = try f.app("Kontakt 7", id: "com.native-instruments.Kontakt 7")
        try f.file("Library/Application Support/Native Instruments/Kontakt 7/db")
        try f.file("Library/Application Support/Native Instruments/Massive/db")
        try f.file("Library/Caches/Vendor Inc/Kontakt 7/x")
        try f.file("Application Support/Native Instruments/Kontakt 7/x", in: f.system)
        let cleaner = f.cleaner
        let scan = cleaner.scan(app)
        let mine = candidate(scan, "Native Instruments/Kontakt 7")
        try expect(mine?.evidence == .name && mine?.recommended == true, "éditeur reconnu \(String(describing: mine?.evidence))")
        try expect(candidate(scan, "Massive") == nil, "autre produit ignoré")
        try expect(candidate(scan, "Vendor Inc/Kontakt 7")?.evidence == .possible, "dossier inconnu : à vérifier")
        try expect(scan.candidates.first { $0.url.path.hasPrefix(f.system.path) }?.evidence == .possible, "système : à vérifier")
        try cleaner.validate(mine!)
    }),
    ("rapports de plantage", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        try f.file("Library/Logs/DiagnosticReports/Example-2026-11-03-175846.ips")
        try f.file("Library/Logs/DiagnosticReports/Examplefoo-2026-11-03-175846.ips")
        let scan = f.cleaner.scan(app)
        try expect(candidate(scan, "Example-2026-11-03-175846.ips")?.evidence == .name, "rapport")
        try expect(candidate(scan, "Examplefoo-2026-11-03-175846.ips") == nil, "autre processus")
    }),
    ("reçus d’installation", {
        let f = try Fixture(); let app = try f.app("Zoomish", id: "us.zoomish.xos")
        f.receipts.ownersByPath[app.url.path] = ["us.zoomish.pkg.meeting"]
        f.receipts.ids = ["us.zoomish.pkg.meeting", "us.zoomish.pkg.plugin", "com.apple.pkg.Core", "org.other.pkg"]
        let scan = f.cleaner.scan(app)
        let receipts = scan.candidates.filter { if case .receipt = $0.kind { return true }; return false }
        try expect(Set(receipts.map(\.id)) == ["receipt:us.zoomish.pkg.meeting", "receipt:us.zoomish.pkg.plugin"], "\(receipts.map(\.id))")
        try expect(receipts.first { $0.id.hasSuffix("meeting") }?.recommended == true, "propriétaire coché")
    }),
    ("liens symboliques ignorés et refusés", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        let target = try f.file("outside/keep.txt", in: f.root)
        try FileManager.default.createDirectory(at: f.home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.home.appendingPathComponent("Library/Caches/org.example.product"), withDestinationURL: target.deletingLastPathComponent())
        let scan = f.cleaner.scan(app)
        try expect(candidate(scan, "Caches/org.example.product") == nil, "lien listé")
        try expect(f.cleaner.measure(f.home.appendingPathComponent("Library/Caches/org.example.product")).0 == 0, "lien mesuré")
    }),
    ("applications Apple protégées", {
        let f = try Fixture(); let app = try f.app("Notes", id: "com.apple.Notes")
        try f.file("Library/Preferences/com.apple.Notes.plist")
        let scan = f.cleaner.scan(app)
        try expect(scan.candidates.allSatisfy { !$0.removable }, "protégé")
    }),
    ("exécution : ordre, droits, services, reçus", {
        let f = try Fixture(); let app = try f.app("Zoomish", id: "us.zoomish.xos")
        try f.file("Contents/Library/LaunchServices/us.zoomish.Daemon", in: app.url)
        try f.file("LaunchDaemons/us.zoomish.Daemon.plist", in: f.system, contents: f.plist(["Program": "/Library/PrivilegedHelperTools/us.zoomish.Daemon"]))
        try f.file("Library/Preferences/us.zoomish.xos.plist")
        try f.file("Library/LaunchAgents/us.zoomish.xos.updater.plist")
        let keep = try f.file("Library/Preferences/org.keep.me.plist")
        f.receipts.ownersByPath[app.url.path] = ["us.zoomish.pkg"]; f.receipts.ids = ["us.zoomish.pkg"]
        let cleaner = f.cleaner
        let scan = cleaner.scan(app)
        let chosen = scan.candidates.filter { $0.recommended || $0.url.lastPathComponent.contains("updater") }
        let out = await cleaner.execute(chosen, backend: f.backend)
        let calls = await f.backend.calls
        try expect(out.failures.isEmpty && !out.cancelled, "\(out.failures)")
        try expect(out.removed.count == chosen.count, "\(out.removed.count)/\(chosen.count)")
        try expect(calls.first == "trash Zoomish.app", "app d’abord : \(calls)")
        try expect(calls.contains { $0.hasPrefix("admin") && $0.contains("bootout system") && $0.contains("pkgutil --forget us.zoomish.pkg") }, "admin \(calls)")
        try expect(calls.contains("finder us.zoomish.Daemon.plist"), "finder \(calls)")
        try expect(calls.contains("unload us.zoomish.xos.updater.plist"), "agent arrêté")
        try expect(FileManager.default.fileExists(atPath: keep.path), "fichier sans rapport conservé")
    }),
    ("refus de l’app par l’utilisateur : passage par le Finder", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        try f.file("Library/Preferences/org.example.product.plist")
        await f.backend.configure(failUserTrash: ["Example.app"])
        let cleaner = f.cleaner
        let out = await cleaner.execute(cleaner.scan(app).candidates.filter(\.recommended), backend: f.backend)
        let calls = await f.backend.calls
        try expect(out.removed.count == 2 && out.failures.isEmpty, "\(out.failures)")
        try expect(calls.contains("finder Example.app"), "\(calls)")
    }),
    ("mot de passe annulé : les données restent intactes", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        let pref = try f.file("Library/Preferences/org.example.product.plist")
        await f.backend.configure(failUserTrash: ["Example.app"], cancelAdmin: true)
        let cleaner = f.cleaner
        let out = await cleaner.execute(cleaner.scan(app).candidates.filter(\.recommended), backend: f.backend)
        try expect(out.cancelled && out.removed.isEmpty, "annulé")
        try expect(FileManager.default.fileExists(atPath: pref.path) && FileManager.default.fileExists(atPath: app.url.path), "rien déplacé")
    }),
    ("élément modifié depuis l’analyse : conservé, le reste continue", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        let pref = try f.file("Library/Preferences/org.example.product.plist")
        let cleaner = f.cleaner
        let chosen = cleaner.scan(app).candidates.filter(\.recommended)
        try FileManager.default.removeItem(at: pref); try f.file("Library/Preferences/org.example.product.plist")
        let out = await cleaner.execute(chosen, backend: f.backend)
        try expect(out.removed == [app.url.path] && out.failures.count == 1, "\(out.removed) \(out.failures)")
        try expect(FileManager.default.fileExists(atPath: pref.path), "fichier modifié conservé")
    }),
    ("échec d’un fichier utilisateur : repris par le Finder", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        try f.file("Library/Containers/org.example.product/x")
        await f.backend.configure(failUserTrash: ["org.example.product"])
        let cleaner = f.cleaner
        let out = await cleaner.execute(cleaner.scan(app).candidates.filter(\.recommended), backend: f.backend)
        try expect(out.failures.isEmpty && out.removed.count == 2, "\(out.failures)")
        try expect(await f.backend.calls.contains("finder org.example.product"), "finder")
    }),
    ("dossier atteint par un lien (/var → /private/var) : accepté", {
        let f = try Fixture()
        let realDir = f.root.appendingPathComponent("private/var/folders/C")
        let item = try f.file("org.gone.app/x", in: realDir).deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("var"), withDestinationURL: f.root.appendingPathComponent("private/var"))
        let alias = f.root.appendingPathComponent("var/folders/C")
        let cleaner = Cleaner(home: f.home, applicationRoots: [f.apps], systemLibrary: f.system, darwinDirectories: [alias], receipts: f.receipts)
        // macOS peut présenter l'élément par le chemin du lien.
        let viaAlias = alias.appendingPathComponent("org.gone.app")
        let c = Candidate(url: viaAlias, kind: .file, category: "", evidence: .possible, reason: "", bytes: 0, sizeIncomplete: false,
                          stamp: try Stamp.read(viaAlias), requiresAdmin: false, launchDomain: nil)
        try cleaner.validate(c)
        // Un élément qui est lui-même un lien reste refusé.
        let link = realDir.appendingPathComponent("org.link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: item)
        let l = Candidate(url: link, kind: .file, category: "", evidence: .possible, reason: "", bytes: 0, sizeIncomplete: false,
                          stamp: try Stamp.read(link), requiresAdmin: false, launchDomain: nil)
        var refused = false
        do { try cleaner.validate(l) } catch { refused = true }
        try expect(refused, "lien refusé")
        let out = await cleaner.execute([c, l], backend: f.backend)
        try expect(out.removed == [c.id] && out.failures.count == 1, "un refus n’empêche pas le reste : \(out.removed) \(out.failures)")
    }),
    ("application refusée : rien n’est touché", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        let pref = try f.file("Library/Preferences/org.example.product.plist")
        let cleaner = f.cleaner
        let chosen = cleaner.scan(app).candidates.filter(\.recommended)
        try FileManager.default.removeItem(at: app.url); _ = try f.app("Example", id: "org.example.product")
        let out = await cleaner.execute(chosen, backend: f.backend)
        try expect(out.removed.isEmpty && FileManager.default.fileExists(atPath: pref.path), "données intactes")
        try expect(await f.backend.calls.isEmpty, "aucun appel")
    }),
    ("validation : hors racines, imbriqué, Apple", {
        let f = try Fixture(); let app = try f.app("Example", id: "org.example.product")
        let cleaner = f.cleaner
        let tooDeep = try f.file("Library/Application Support/Vendor/Sub/org.example.product/x").deletingLastPathComponent()
        let nestedPrefs = try f.file("Library/Preferences/Vendor/org.example.product.plist")
        let apple = try f.file("Library/Preferences/com.apple.finder.plist")
        let outside = try f.file("Documents/org.example.product.plist")
        for url in [tooDeep, nestedPrefs, apple, outside] {
            let c = Candidate(url: url, kind: .file, category: "", evidence: .identifier, reason: "", bytes: 0, sizeIncomplete: false,
                              stamp: try Stamp.read(url), requiresAdmin: false, launchDomain: nil)
            var refused = false
            do { try cleaner.validate(c) } catch { refused = true }
            try expect(refused, url.path)
        }
        _ = app
    }),
    ("restes d’apps supprimées", {
        let f = try Fixture()
        _ = try f.app("Installed", id: "com.vendor.installed")
        try f.file("Library/Preferences/org.gone.app.plist")
        try f.file("Library/Caches/org.gone.app/x")
        try f.file("Library/Application Support/org.gone.app.helper/x")
        try f.file("Library/Preferences/com.vendor.installed.plist")
        try f.file("Library/Preferences/com.vendor.installed.helper.plist")
        try f.file("Library/Preferences/com.vendor.other.plist")
        try f.file("Library/Preferences/com.apple.dock.plist")
        try f.file("Library/Preferences/com.registered.elsewhere.plist")
        try f.file("Library/Preferences/loginwindow.plist")
        try f.file("Library/Group Containers/group.org.gone.app/x")
        let cleaner = f.cleaner
        let result = cleaner.scanOrphans(installed: cleaner.applications())
        let ids = Set(result.groups.map(\.bundleID))
        try expect(ids == ["org.gone.app", "com.vendor.other"], "\(ids)")
        try expect(result.groups.first { $0.bundleID == "org.gone.app" }?.candidates.count == 3, "regroupement")
        try expect(result.groups.first { $0.bundleID == "com.vendor.other" }?.sameVendorAs == "Installed", "même éditeur")
        try expect(result.groups.flatMap(\.candidates).allSatisfy { !$0.recommended }, "rien coché par défaut")
    }),
    ("restes : plugins installés reconnus", {
        let f = try Fixture()
        try f.file("Audio/Plug-Ins/Components/Pro-Q 3.component/Contents/Info.plist", in: f.system,
                   contents: f.plist(["CFBundleIdentifier": "com.fabfilter.Pro-Q.AU.3", "CFBundleName": "FabFilter Pro-Q 3"]))
        try f.file("Library/Preferences/com.fabfilter.pro-q.3.plist")
        try f.file("Library/Preferences/com.fabfilter.Pro-Q.AU.3.plist")
        let cleaner = f.cleaner
        let groups = cleaner.scanOrphans(installed: []).groups
        try expect(groups.map(\.bundleID) == ["com.fabfilter.pro-q.3"], "\(groups.map(\.bundleID))")
        try expect(groups.first?.sameVendorAs == "FabFilter Pro-Q 3", "même éditeur qu’un plugin")
    }),
    ("restes : suppression possible", {
        let f = try Fixture()
        let pref = try f.file("Library/Preferences/org.gone.app.plist")
        let cleaner = f.cleaner
        let group = cleaner.scanOrphans(installed: []).groups.first!
        let out = await cleaner.execute(group.candidates, backend: f.backend)
        try expect(out.removed.count == 1 && !FileManager.default.fileExists(atPath: pref.path), "\(out.failures)")
    }),
]

var failures = 0
for (name, run) in checks {
    do { try await run(); print("OK    \(name)") }
    catch { failures += 1; print("ÉCHEC \(name) — \(error)") }
}
print("\(checks.count) contrôles, \(failures) échec(s)")
exit(failures == 0 ? 0 : 1)
