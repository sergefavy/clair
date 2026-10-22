import Foundation

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    public var discoveredNames: Set<String> = []
    public var componentIDs: Set<String> = []
    public var identityNotes: [String] = []
    public init(url: URL, name: String, bundleID: String) {
        self.url = url.standardizedFileURL; self.name = name; self.bundleID = bundleID
    }
    public var protected: Bool { url.path.hasPrefix("/System/") || url.path.hasPrefix("/Library/Apple/") || bundleID == "fr.local.clair" }
}

public enum Evidence: String, Sendable {
    case application = "Application"
    case identifier = "Identifiant exact"
    case possible = "À vérifier"
    case shared = "Dossier partagé · protégé"
    case system = "Composant système · protégé"
}

public struct Stamp: Equatable, Sendable {
    let inode: UInt64
    let device: UInt64
    let modified: Date
    let type: String
    public static func read(_ url: URL) throws -> Stamp {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(inode: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                     device: (a[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                     modified: a[.modificationDate] as? Date ?? .distantPast,
                     type: (a[.type] as? FileAttributeType)?.rawValue ?? "")
    }
}

public struct Candidate: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let category: String
    public let evidence: Evidence
    public let reason: String
    public let bytes: Int64
    public let sizeIncomplete: Bool
    public let stamp: Stamp
    public let removable: Bool
    public var recommended: Bool { removable && (evidence == .application || evidence == .identifier) }
}

public struct ScanResult: Sendable {
    public let app: InstalledApp
    public let candidates: [Candidate]
    public let warnings: [String]
    public let date: Date
}

public enum CleanerError: LocalizedError {
    case unsafe(String), changed(String), permission(String)
    public var errorDescription: String? {
        switch self {
        case .unsafe(let path): return "Chemin protégé ou non autorisé : \(path)"
        case .permission(let path): return "Droits insuffisants : \(path). Pour une application protégée, choisis la Corbeille afin de laisser macOS gérer l’authentification. Si macOS refuse, utilise le Finder ou le désinstalleur de l’éditeur, puis relance l’analyse."
        case .changed(let path): return "Fichier modifié depuis l’analyse. Relance l’analyse : \(path)"
        }
    }
}

public struct RemovalOutcome: Sendable {
    public let removed: Set<String>
    public let log: String
    public let problem: String?
}

public struct Cleaner: Sendable {
    public let home: URL
    public let applicationRoots: [URL]
    private let canRemove: @Sendable (URL) -> Bool
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                applicationRoots: [URL]? = nil,
                canRemove: @escaping @Sendable (URL) -> Bool = { FileManager.default.isDeletableFile(atPath: $0.path) }) {
        self.canRemove = canRemove
        self.home = home.standardizedFileURL
        self.applicationRoots = applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    public static func isWithin(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.path, p = parent.standardizedFileURL.path
        return c.hasPrefix(p + "/")
    }

    public static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    public func applications() -> [InstalledApp] {
        let fm = FileManager.default
        var result: [InstalledApp] = []
        for root in applicationRoots {
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { walk.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "app" {
                    walk.skipDescendants()
                    guard let bundle = Bundle(url: url) else { continue }
                    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    result.append(InstalledApp(url: url, name: name, bundleID: bundle.bundleIdentifier ?? ""))
                } else if walk.level > 3 { walk.skipDescendants() }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var locations: [(String, String)] {
        [("Application Support", "Données"), ("Caches", "Caches"), ("Preferences", "Préférences"),
         ("Containers", "Conteneurs"), ("Group Containers", "Groupes partagés"),
         ("Saved Application State", "État sauvegardé"), ("Logs", "Journaux"),
         ("HTTPStorages", "Stockage HTTP"), ("WebKit", "WebKit"), ("Cookies", "Cookies"),
         ("LaunchAgents", "Démarrage"), ("Application Scripts", "Scripts"),
         ("Autosave Information", "Sauvegardes automatiques")]
    }

    // Only exact identifiers, known suffixes, or UUID-suffixed preference files are high confidence.
    public func evidence(for filename: String, app: InstalledApp) -> Evidence? {
        let f = filename.lowercased(), bid = app.bundleID.lowercased()
        if !bid.isEmpty && bid.contains(".") {
            if [bid, bid + ".plist", bid + ".savedstate", bid + ".binarycookies", bid + ".cookies", bid + ".application-group"].contains(f) { return .identifier }
            if f.hasPrefix(bid + "."), f.hasSuffix(".plist") {
                let suffix = String(f.dropFirst(bid.count + 1).dropLast(6))
                if UUID(uuidString: suffix) != nil { return .identifier }
            }
            if f.hasPrefix(bid + ".") || f.hasPrefix(bid + "-") { return .possible }
        }
        for identifier in app.componentIDs where !identifier.isEmpty {
            let value = identifier.lowercased()
            if f == value || f == value + ".plist" || f == value + ".savedstate" || f.hasPrefix(value + ".") {
                return .possible
            }
        }
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let names = ([app.name, app.url.deletingPathExtension().lastPathComponent] + Array(app.discoveredNames)).map(Self.normalized).filter { $0.count >= 4 }
        if names.contains(Self.normalized(filename)) || names.contains(Self.normalized(stem)) { return .possible }
        return nil
    }

    public func measure(_ url: URL) -> (Int64, Bool) {
        let fm = FileManager.default
        guard let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else { return (0, true) }
        if info.isSymbolicLink == true { return (0, false) }
        if info.isDirectory != true { return (Int64(info.fileSize ?? 0), false) }
        var bytes: Int64 = 0, count = 0, incomplete = false
        guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], errorHandler: { _, _ in incomplete = true; return true }) else { return (0, true) }
        for case let item as URL in walk {
            if Task.isCancelled { incomplete = true; break }
            count += 1
            if count > 150_000 { incomplete = true; break }
            guard let value = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { incomplete = true; continue }
            if value.isSymbolicLink == true { walk.skipDescendants(); continue }
            if value.isRegularFile == true { bytes += Int64(value.fileSize ?? 0) }
        }
        return (bytes, incomplete)
    }

    public func scan(_ selectedApp: InstalledApp) -> ScanResult {
        let app = discoverIdentity(selectedApp)
        let fm = FileManager.default
        var candidates: [Candidate] = [], warnings: [String] = app.identityNotes
        func add(_ url: URL, _ category: String, _ evidence: Evidence, _ reason: String) {
            guard !candidates.contains(where: { $0.url == url }), let stamp = try? Stamp.read(url) else { return }
            let (bytes, incomplete) = measure(url)
            let allowed = !app.protected && evidence != .shared && evidence != .system && (try? validatePath(url, app: app)) != nil
            candidates.append(Candidate(url: url, category: category, evidence: evidence, reason: reason,
                                        bytes: bytes, sizeIncomplete: incomplete, stamp: stamp, removable: allowed))
        }
        add(app.url, "Application", .application, "Paquet de l’application sélectionnée.")
        for (relative, category) in locations {
            if Task.isCancelled { break }
            let root = home.appendingPathComponent("Library/" + relative)
            guard fm.fileExists(atPath: root.path) else { continue }
            do {
                let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
                var visited = 0
                func examine(_ entries: [URL], depth: Int) {
                    for url in entries {
                        if Task.isCancelled { return }
                        visited += 1
                        if visited > 25_000 { return }
                        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        if values?.isSymbolicLink == true { continue }
                        if let match = association(url, app: app) {
                            let evidence = match.0
                            let shared = relative == "Group Containers"
                            add(url, category, shared ? .shared : evidence,
                                shared ? "Peut être utilisé par plusieurs applications : suppression désactivée."
                                : match.1)
                            continue
                        }
                        // Never descend into an unrelated app sandbox or a shared group.
                        if depth < 2 && values?.isDirectory == true && !["Containers", "Group Containers", "Application Scripts"].contains(relative) {
                            if let nested = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                                examine(nested, depth: depth + 1)
                            } else { warnings.append("Sous-dossier inaccessible : \(url.path)") }
                        }
                    }
                }
                examine(children, depth: 0)
                if visited > 25_000 { warnings.append("Analyse limitée à 25 000 entrées dans \(root.path).") }
            } catch { warnings.append("Accès refusé ou lecture impossible : \(root.path)") }
        }
        for relative in ["Application Support", "Caches", "Preferences", "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools", "CoreMediaIO/Plug-Ins/DAL", "Audio/Plug-Ins", "SystemExtensions"] {
            if Task.isCancelled { break }
            let root = URL(fileURLWithPath: "/Library/" + relative)
            guard fm.fileExists(atPath: root.path) else { continue }
            do {
                var queue = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map { ($0, 0) }
                var visited = 0
                while let (url, depth) = queue.popLast() {
                    if Task.isCancelled { break }
                    visited += 1
                    if visited > 25_000 { warnings.append("Analyse limitée à 25 000 entrées dans \(root.path)."); break }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { continue }
                    if let match = association(url, app: app) {
                        add(url, "Système", .system, match.1 + " Composant global : utilise le désinstalleur de l’éditeur. Aucun accès administrateur demandé. Son état d’activation n’est pas vérifié.")
                    } else if depth < 2 && values.isDirectory == true {
                        do { queue += try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).map { ($0, depth + 1) } }
                        catch { warnings.append("Sous-dossier système inaccessible : \(url.path)") }
                    }
                }
            } catch { warnings.append("Dossier système inaccessible : \(root.path)") }
        }
        warnings.append("Analyse ciblée des dossiers usuels, jusqu’à 3 niveaux. Les groupes partagés, composants système, reçus d’installation, trousseaux, documents et données cloud ne sont pas supprimés. Les fichiers portant un autre nom peuvent ne pas être détectés.")
        if Task.isCancelled { warnings.append("Analyse limitée : interrompue à la demande de l’utilisateur.") }
        if app.bundleID.isEmpty { warnings.append("Identifiant absent : seules des correspondances de nom sont disponibles.") }
        if app.protected { warnings.append("Cette application est protégée contre la suppression.") }
        return ScanResult(app: app, candidates: candidates.sorted { $0.url.path < $1.url.path }, warnings: Array(Set(warnings)).sorted(), date: Date())
    }

    public func validatePath(_ url: URL, app: InstalledApp) throws {
        let u = url.standardizedFileURL
        guard !app.protected, u.path == url.path,
              u.resolvingSymlinksInPath().path == u.path else { throw CleanerError.unsafe(url.path) }
        if u == app.url {
            guard u.pathExtension == "app", applicationRoots.contains(where: { Self.isWithin(u, $0) }),
                  !applicationRoots.contains(u) else { throw CleanerError.unsafe(u.path) }
            return
        }
        let allowed = locations.filter { $0.0 != "Group Containers" }.map { home.appendingPathComponent("Library/" + $0.0) }
        guard allowed.contains(where: { Self.isWithin(u, $0) }),
              association(u, app: app) != nil else { throw CleanerError.unsafe(u.path) }
    }

    public func validate(_ candidate: Candidate, app: InstalledApp) throws {
        guard candidate.removable else { throw CleanerError.unsafe(candidate.url.path) }
        try validatePath(candidate.url, app: app)
        guard try Stamp.read(candidate.url) == candidate.stamp else { throw CleanerError.changed(candidate.url.path) }
    }

    /// Call only after the UI has obtained confirmation for this exact selection.
    /// A native recycler is supplied by the app; the core never requests elevated privileges itself.
    public func execute(_ candidates: [Candidate], app: InstalledApp, permanent: Bool,
                        recycle: (@Sendable (URL) async throws -> URL)? = nil) async -> RemovalOutcome {
        var removed = Set<String>()
        var lines = ["\n\(Date().formatted()) — \(app.name) — \(permanent ? "Suppression définitive" : "Corbeille")"]
        // Check the complete selection before any mutation. Permission checks are advisory:
        // the filesystem can change afterwards, so every operation must still handle failure.
        do {
            for candidate in candidates {
                try validate(candidate, app: app)
                if !canRemove(candidate.url) && (permanent || recycle == nil || candidate.url != app.url) {
                    throw CleanerError.permission(candidate.url.path)
                }
            }
        } catch {
            let problem = "Opération annulée avant tout déplacement ou suppression. " + error.localizedDescription
            return RemovalOutcome(removed: removed, log: lines.joined(separator: "\n") + "\nANNULÉ : " + problem, problem: problem)
        }
        // Trash the app first: Finder refusal/cancellation must leave its data untouched.
        // Permanent deletion retains the app-last policy after the full permission preflight.
        let ordered = candidates.sorted {
            let lhs = $0.url == app.url ? (permanent ? 1 : -1) : 0
            let rhs = $1.url == app.url ? (permanent ? 1 : -1) : 0
            return lhs == rhs ? $0.url.path < $1.url.path : lhs < rhs
        }
        var problem: String?
        for candidate in ordered {
            do {
                try Task.checkCancellation()
                try validate(candidate, app: app)
                if permanent {
                    guard canRemove(candidate.url) else { throw CleanerError.permission(candidate.url.path) }
                    try FileManager.default.removeItem(at: candidate.url)
                } else {
                    let destination: URL
                    if let recycle { destination = try await recycle(candidate.url) }
                    else {
                        guard canRemove(candidate.url) else { throw CleanerError.permission(candidate.url.path) }
                        var trashed: NSURL?
                        try FileManager.default.trashItem(at: candidate.url, resultingItemURL: &trashed)
                        guard let trashed else { throw CleanerError.unsafe("Destination Corbeille absente pour " + candidate.url.path) }
                        destination = trashed as URL
                    }
                    guard destination.isFileURL, destination.standardizedFileURL != candidate.url,
                          FileManager.default.fileExists(atPath: destination.path) else {
                        throw CleanerError.unsafe("Destination Corbeille non vérifiée pour " + candidate.url.path)
                    }
                    lines.append("DESTINATION CORBEILLE : \(destination.path)")
                }
                guard !FileManager.default.fileExists(atPath: candidate.url.path) else { throw CleanerError.changed(candidate.url.path) }
                removed.insert(candidate.id)
                lines.append("\(permanent ? "SUPPRIMÉ" : "CORBEILLE") : \(candidate.url.path)")
            } catch {
                let count = "\(removed.count)/\(candidates.count) éléments vérifiés comme traités."
                var failure = "Opération interrompue : " + count + "\n" + candidate.url.path + "\n" + error.localizedDescription
                if candidate.url == app.url && !permanent {
                    failure += "\nLes données associées n’ont pas été traitées. Si une authentification est nécessaire, laisse macOS la gérer ; en cas de refus, utilise le Finder ou le désinstalleur de l’éditeur."
                }
                problem = failure
                lines.append("ÉCHEC : \(candidate.url.path) — \(error.localizedDescription)")
                lines.append("ARRÊT : les éléments suivants ne sont pas traités. Relance l’analyse avant toute nouvelle tentative.")
                break
            }
        }
        return RemovalOutcome(removed: removed, log: lines.joined(separator: "\n"), problem: problem)
    }

    public func report(_ result: ScanResult) -> String {
        var lines = ["CLAIR — Rapport d’analyse", "Application : \(result.app.name)", "Identifiant : \(result.app.bundleID)",
                     "Chemin : \(result.app.url.path)", "Date : \(result.date.formatted())", "", "Ce rapport ne constitue pas une preuve de suppression.", ""]
        lines += ["Identifiants de composants : " + result.app.componentIDs.sorted().joined(separator: ", "),
                  "Noms issus du paquet : " + result.app.discoveredNames.sorted().joined(separator: ", "), ""]
        for c in result.candidates {
            lines.append("[\(c.evidence.rawValue)] \(c.url.path) — \(c.bytes) octets\(c.sizeIncomplete ? " (taille partielle)" : "")\n  \(c.reason)")
        }
        lines += ["", "LIMITES ET ACCÈS"] + result.warnings
        return lines.joined(separator: "\n")
    }
}
