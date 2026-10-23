import Foundation

extension Cleaner {
    // Read structured bundle metadata, never execute shell fragments supplied by an app.
    private func propertyList(_ url: URL) -> [String: Any]? {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath(),
              let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return plist as? [String: Any]
    }

    public func discoverIdentity(_ selected: InstalledApp) -> InstalledApp {
        var app = selected // Keep this snapshot after the application bundle has been removed.
        func collect(_ info: [String: Any], source: URL) {
            if let identifier = info["CFBundleIdentifier"] as? String, identifier.contains("."), identifier != app.bundleID {
                app.componentIDs.insert(identifier)
            }
            for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                if let name = info[key] as? String, !name.contains("/"), name.count >= 4 {
                    app.discoveredNames.insert(name)
                }
            }
            app.identityNotes.append("Métadonnées lues : \(source.path). Les composants embarqués peuvent être partagés avec d’autres logiciels.")
        }
        let rootInfo = app.url.appendingPathComponent("Contents/Info.plist")
        if let info = propertyList(rootInfo) { collect(info, source: rootInfo) }
        else if FileManager.default.fileExists(atPath: app.url.path) {
            app.identityNotes.append("Métadonnées inaccessibles : \(rootInfo.path)")
        }
        let roots = ["Contents/PlugIns", "Contents/XPCServices", "Contents/Library", "Contents/Helpers", "Contents/Frameworks"]
        for relative in roots {
            if Task.isCancelled { break }
            let root = app.url.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: root.path), root == root.resolvingSymlinksInPath() else { continue }
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { url, _ in
                app.identityNotes.append("Composant inaccessible : \(url.path)"); return true
            }) else { app.identityNotes.append("Composants inaccessibles : \(root.path)"); continue }
            var count = 0
            for case let url as URL in walk {
                if Task.isCancelled { break }
                count += 1
                if count > 10_000 { app.identityNotes.append("Analyse limitée des composants dans \(root.path)."); break }
                guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
                    app.identityNotes.append("Composant inaccessible : \(url.path)"); walk.skipDescendants(); continue
                }
                if values.isSymbolicLink == true { walk.skipDescendants(); continue }
                if walk.level > 8 { app.identityNotes.append("Analyse limitée des composants à 8 niveaux dans \(root.path)."); walk.skipDescendants(); continue }
                if url.pathExtension == "framework" { walk.skipDescendants(); continue }
                if ["app", "xpc", "appex", "systemextension", "plugin", "bundle"].contains(url.pathExtension) {
                    let infoURL = url.appendingPathComponent("Contents/Info.plist")
                    if let info = propertyList(infoURL) { collect(info, source: infoURL) }
                }
            }
        }
        app.identityNotes = Array(Set(app.identityNotes)).sorted()
        return app
    }

    // Every match carries an explanation. Metadata clues remain opt-in.
    public func association(_ url: URL, app: InstalledApp) -> (Evidence, String)? {
        if let evidence = evidence(for: url.lastPathComponent, app: app) {
            return (evidence, evidence == .identifier
                    ? "Nom correspondant à l’identifiant principal \(app.bundleID)."
                    : "Nom ou identifiant issu de l’application et de ses composants : appartenance exclusive à vérifier.")
        }
        // A launch service may have an unrelated filename. Attribute only its executable,
        // never arbitrary arguments that could mention another app as a document or target.
        if ["LaunchAgents", "LaunchDaemons"].contains(url.deletingLastPathComponent().lastPathComponent),
           url.pathExtension == "plist", let info = propertyList(url) {
            let executable = (info["Program"] as? String) ?? (info["ProgramArguments"] as? [String])?.first
            if let executable, executable.hasPrefix("/") {
                let path = URL(fileURLWithPath: executable).standardizedFileURL
                if Self.isWithin(path, app.url), Self.isWithin(path.resolvingSymlinksInPath(), app.url.resolvingSymlinksInPath()) {
                    return (.possible, "Le service lance un exécutable dans cette application : \(path.path). Vérifier avant sélection.")
                }
            }
        }
        return nil
    }
}
