import Foundation

extension Evidence {
    var rank: Int {
        switch self {
        case .application: 5
        case .identifier: 4
        case .component: 3
        case .name: 2
        case .possible: 1
        case .protected: 0
        }
    }
}

extension Cleaner {
    /// Lit un plist de taille raisonnable sans suivre de lien symbolique. Rien n'est exécuté.
    static func propertyList(_ url: URL) -> [String: Any]? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? .max) <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return plist as? [String: Any]
    }

    static func looksLikeBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let first = parts.first, (2...6).contains(first.count),
              first.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    /// Complète l'application avec les noms et identifiants de ses composants embarqués.
    public func discoverIdentity(_ selected: InstalledApp) -> InstalledApp {
        var app = selected
        let ownID = app.bundleID.lowercased()
        func collect(_ info: [String: Any]) {
            if let identifier = info["CFBundleIdentifier"] as? String, identifier.contains("."), identifier.lowercased() != ownID {
                app.componentIDs.insert(identifier)
            }
            for key in ["CFBundleName", "CFBundleExecutable"] {
                if let name = info[key] as? String, !name.contains("/"), name.count >= 4 { app.discoveredNames.insert(name) }
            }
        }
        if let info = Self.propertyList(app.url.appendingPathComponent("Contents/Info.plist")) { collect(info) }
        let fm = FileManager.default

        // Helpers SMJobBless : exécutables nommés par leur identifiant.
        let launchServices = app.url.appendingPathComponent("Contents/Library/LaunchServices")
        for url in (try? fm.contentsOfDirectory(at: launchServices, includingPropertiesForKeys: nil)) ?? []
        where Self.looksLikeBundleID(url.lastPathComponent.lowercased()) {
            app.componentIDs.insert(url.lastPathComponent)
        }
        // Services SMAppService : plists embarqués.
        for folder in ["Contents/Library/LaunchDaemons", "Contents/Library/LaunchAgents"] {
            for url in (try? fm.contentsOfDirectory(at: app.url.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? [] {
                if let label = Self.propertyList(url)?["Label"] as? String, label.contains(".") { app.componentIDs.insert(label) }
            }
        }
        // Bundles embarqués (XPC, extensions, apps auxiliaires). Les frameworks sont ignorés :
        // ils sont souvent partagés entre éditeurs (Sparkle…).
        for relative in ["Contents/PlugIns", "Contents/XPCServices", "Contents/Library", "Contents/Helpers", "Contents/Frameworks", "Contents/MacOS"] {
            let root = app.url.appendingPathComponent(relative)
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { continue }
            var count = 0
            for case let url as URL in walk {
                count += 1
                if count > 10_000 || Task.isCancelled { break }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                if walk.level > 8 || url.pathExtension == "framework" { walk.skipDescendants(); continue }
                if ["app", "xpc", "appex", "systemextension", "plugin", "bundle", "saver", "prefPane"].contains(url.pathExtension),
                   let info = Self.propertyList(url.appendingPathComponent("Contents/Info.plist")) {
                    collect(info)
                }
            }
        }
        app.componentIDs = app.componentIDs.filter { !Self.isAppleID($0) }
        return app
    }

    /// Nom de fichier sans casse ni extension de préférences.
    static func baseName(_ filename: String) -> String {
        var f = filename.lowercased()
        for suffix in [".plist", ".savedstate", ".binarycookies", ".cookies"] where f.hasSuffix(suffix) {
            f.removeLast(suffix.count); break
        }
        return f
    }

    /// Correspondance d'un nom de fichier avec l'application, avec une explication.
    func evidence(for filename: String, in root: SearchRoot, app: InstalledApp) -> (Evidence, String)? {
        let base = Self.baseName(filename)
        let bid = app.bundleID.lowercased()
        let hasBID = bid.split(separator: ".").count >= 2

        if hasBID {
            if base == bid { return (.identifier, "Porte l’identifiant de l’application (\(app.bundleID)).") }
            if base.hasPrefix(bid + "."), UUID(uuidString: String(base.dropFirst(bid.count + 1))) != nil {
                return (.identifier, "Préférences par machine de \(app.bundleID).")
            }
            if root.shared, base == "group." + bid || base.hasSuffix("." + bid) {
                return (.possible, "Groupe d’applications lié à \(app.bundleID), peut être partagé avec d’autres apps du même éditeur.")
            }
        }
        let vendor = app.vendorPrefix
        for component in app.componentIDs {
            let c = component.lowercased()
            if base == c || base.hasPrefix(c + ".") {
                if let vendor, c.hasPrefix(vendor + ".") {
                    return (.component, "Identifiant d’un composant embarqué dans l’application (\(component)).")
                }
                return (.possible, "Identifiant d’un composant embarqué d’un autre éditeur (\(component)) : peut être partagé.")
            }
        }
        if hasBID, base.hasPrefix(bid + ".") || base.hasPrefix(bid + "-") {
            return (.possible, "Commence par l’identifiant \(app.bundleID) : peut appartenir à une variante de l’application.")
        }
        if root.vendorMatching, let vendor, base.hasPrefix(vendor + ".") {
            return (.possible, "Même éditeur que l’application (\(vendor)) : peut servir à d’autres logiciels.")
        }
        let candidates = Self.nameForms(filename)
        if candidates.contains(where: Self.primaryNames(app).contains) {
            return root.system || root.shared
                ? (.possible, "Même nom que l’application, dans un dossier partagé par tous les utilisateurs.")
                : (.name, "Même nom que l’application.")
        }
        let secondary = app.discoveredNames.map(Self.normalized).filter { $0.count >= 4 }
        if candidates.contains(where: secondary.contains) {
            return (.possible, "Même nom qu’un composant interne de l’application.")
        }
        return nil
    }

    static func nameForms(_ filename: String) -> [String] {
        [normalized(filename), normalized(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent)]
    }

    /// Nom affiché et nom du paquet, normalisés (au moins 4 caractères).
    static func primaryNames(_ app: InstalledApp) -> [String] {
        [app.name, app.url.deletingPathExtension().lastPathComponent].map(normalized).filter { $0.count >= 4 }
    }

    /// Élément « Éditeur/Application » : seul l'identifiant exact ou le nom de l'application compte.
    /// Coché par défaut seulement si le dossier parent correspond à l'éditeur de l'identifiant.
    func nestedEvidence(_ filename: String, folder: String, in root: SearchRoot, app: InstalledApp) -> (Evidence, String)? {
        let bid = app.bundleID.lowercased()
        let isID = bid.contains(".") && Self.baseName(filename) == bid
        guard isID || Self.nameForms(filename).contains(where: Self.primaryNames(app).contains) else { return nil }
        let f = Self.normalized(folder)
        let vendorFolder = f.count >= 4 && (Self.normalized(app.bundleID).contains(f) || Self.primaryNames(app).contains { $0.hasPrefix(f) })
        return vendorFolder && !root.system
            ? (.name, "Dans le dossier de l’éditeur « \(folder) ».")
            : (.possible, "Dans le dossier « \(folder) » : appartenance à vérifier.")
    }

    /// Un service launchd est attribué par l'exécutable qu'il lance, jamais par ses arguments.
    func launchdEvidence(_ url: URL, app: InstalledApp) -> (Evidence, String)? {
        guard url.pathExtension == "plist", let info = Self.propertyList(url) else { return nil }
        let program = (info["Program"] as? String) ?? (info["ProgramArguments"] as? [String])?.first
        guard let program, program.hasPrefix("/") else { return nil }
        let path = URL(fileURLWithPath: program).standardizedFileURL.path
        if Self.isWithin(path, app.url.path) {
            return (.component, "Service qui lance un programme de l’application : \(path).")
        }
        let tool = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if path.hasPrefix("/Library/PrivilegedHelperTools/") || path.contains("/PrivilegedHelperTools/"),
           tool == app.bundleID.lowercased() || app.componentIDs.contains(where: { $0.lowercased() == tool }) {
            return (.component, "Service qui lance l’outil privilégié de l’application : \(path).")
        }
        return nil
    }

    /// Rapports nommés « Processus-AAAA-MM-JJ-….ips » ou « Processus_UUID.plist ».
    func crashReportEvidence(_ filename: String, app: InstalledApp) -> (Evidence, String)? {
        let f = filename.lowercased()
        func matches(_ name: String) -> Bool {
            let n = name.lowercased()
            return n.count >= 3 && (f.hasPrefix(n + "-") || f.hasPrefix(n + "_") || f.hasPrefix(n + "."))
        }
        if matches(app.name) || matches(app.url.deletingPathExtension().lastPathComponent) {
            return (.name, "Rapport de plantage de l’application.")
        }
        if app.discoveredNames.contains(where: matches) {
            return (.possible, "Rapport de plantage d’un processus portant le nom d’un composant.")
        }
        return nil
    }
}
