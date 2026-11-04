import Foundation

extension Cleaner {
    private func makeCandidate(_ url: URL, kind: CandidateKind = .file, root: SearchRoot?, evidence: Evidence, reason: String) -> Candidate? {
        guard let stamp = try? Stamp.read(url) else { return nil }
        let (bytes, incomplete) = measure(url)
        return Candidate(url: url, kind: kind, category: root?.category ?? "Application", evidence: evidence, reason: reason,
                         bytes: bytes, sizeIncomplete: incomplete, stamp: stamp,
                         requiresAdmin: !canRemove(url),
                         launchDomain: url.pathExtension == "plist" ? root?.launchDomain : nil)
    }

    /// Enfants directs d'une racine, liens symboliques et fichiers cachés exclus.
    private func children(of root: SearchRoot, warnings: inout [String]) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.url.path) else { return [] }
        guard let items = try? fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            warnings.append("Lecture impossible : \(root.url.path)")
            return []
        }
        return items.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
    }

    private func nestedChildren(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        return items.prefix(500).filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
    }

    // MARK: - Analyse d'une application

    public func scan(_ selected: InstalledApp) -> AppScan {
        let app = discoverIdentity(selected)
        var candidates: [String: Candidate] = [:]
        var warnings: [String] = []

        if FileManager.default.fileExists(atPath: app.url.path) {
            let appEvidence: Evidence = app.isProtected ? .protected : .application
            if let c = makeCandidate(app.url, kind: .app, root: nil, evidence: appEvidence,
                                     reason: app.isProtected ? "Application système ou protégée." : "Le paquet de l’application.") {
                candidates[c.id] = c
            }
        }

        for root in roots {
            if Task.isCancelled { break }
            for url in children(of: root, warnings: &warnings) {
                let name = url.lastPathComponent
                var best = root.crashReports ? crashReportEvidence(name, app: app) : evidence(for: name, in: root, app: app)
                if root.launchDomain != nil, let launchd = launchdEvidence(url, app: app), launchd.0.rank > (best?.0.rank ?? -1) {
                    best = launchd
                }
                if best == nil, root.nested, !Self.looksLikeBundleID(name.lowercased()),
                   (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for inner in nestedChildren(of: url) {
                        guard let (level, reason) = nestedEvidence(inner.lastPathComponent, folder: name, in: root, app: app) else { continue }
                        if let c = makeCandidate(inner, root: root, evidence: app.isProtected ? .protected : level, reason: reason) { candidates[c.id] = c }
                    }
                    continue
                }
                guard var (level, reason) = best else { continue }
                if Self.isAppleID(Self.baseName(name)) || app.isProtected { level = .protected }
                if root.shared, level.rank > Evidence.possible.rank { level = .possible }
                if root.protected {
                    level = .protected
                    reason += " Extension gérée par macOS : utilise le désinstalleur de l’éditeur."
                }
                if let c = makeCandidate(url, root: root, evidence: level, reason: reason) { candidates[c.id] = c }
            }
        }

        // Reçus d'installation : ceux qui ont installé ce paquet, puis ceux du même éditeur.
        if !app.isProtected {
            let owners = Set(receipts.owners(of: app.url.path))
            var ids = owners
            if let vendor = app.vendorPrefix {
                ids.formUnion(receipts.packageIDs().filter { $0.lowercased().hasPrefix(vendor + ".") })
            }
            for id in ids.sorted() where !Self.isAppleID(id) {
                let strong = owners.contains(id)
                let c = Candidate(url: URL(fileURLWithPath: "/private/var/db/receipts/\(id).plist"), kind: .receipt(id),
                                  category: "Reçus d’installation", evidence: strong ? .identifier : .possible,
                                  reason: strong ? "Reçu du paquet qui a installé l’application." : "Reçu d’un paquet du même éditeur.",
                                  bytes: 0, sizeIncomplete: false, stamp: nil, requiresAdmin: true, launchDomain: nil)
                candidates[c.id] = c
            }
        }

        if app.bundleID.isEmpty { warnings.append("Identifiant absent : seules des correspondances de nom sont possibles.") }
        if Task.isCancelled { warnings.append("Analyse interrompue.") }
        let sorted = candidates.values.sorted {
            ($0.kind == .app ? 0 : 1, $0.category, $0.url.path) < ($1.kind == .app ? 0 : 1, $1.category, $1.url.path)
        }
        return AppScan(app: app, candidates: sorted, warnings: warnings)
    }

    // MARK: - Restes d'applications supprimées

    /// Identifiant propriétaire d'un élément nommé en notation inversée, ou nil.
    static func orphanOwner(of filename: String) -> String? {
        var base = baseName(filename)
        // Préférences ByHost : « id.UUID ».
        if let dot = base.lastIndex(of: "."), UUID(uuidString: String(base[base.index(after: dot)...])) != nil {
            base = String(base[..<dot])
        }
        guard looksLikeBundleID(base), !isAppleID(base), !base.hasPrefix("group."), base != clairBundleID else { return nil }
        return base
    }

    /// Cherche les éléments dont l'identifiant ne correspond à aucune application installée.
    public func scanOrphans(installed: [InstalledApp]) -> OrphanScan {
        let inventory = installed.map { ($0.bundleID.lowercased(), $0.name) } + installedComponents().map { ($0.id.lowercased(), $0.name) }
        let installedIDs = Set(inventory.map(\.0).filter { !$0.isEmpty })
        var warnings: [String] = []
        var byOwner: [String: [(URL, SearchRoot)]] = [:]
        var verdict: [String: Bool] = [:] // identifiant → installé

        func isInstalledID(_ id: String) -> Bool {
            if let known = verdict[id] { return known }
            let result = installedIDs.contains { $0 == id || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") } || isInstalled(id)
            verdict[id] = result
            return result
        }

        let eligible = roots.filter { !$0.shared && !$0.crashReports && !$0.protected
            && (!$0.system || $0.launchDomain != nil || $0.url.lastPathComponent == "PrivilegedHelperTools") }
        for root in eligible {
            if Task.isCancelled { break }
            for url in children(of: root, warnings: &warnings) {
                guard let owner = Self.orphanOwner(of: url.lastPathComponent), !isInstalledID(owner) else { continue }
                byOwner[owner, default: []].append((url, root))
            }
        }

        // Regroupe « com.foo.bar.helper » sous « com.foo.bar » quand les deux existent.
        let owners = byOwner.keys.sorted { $0.count < $1.count }
        var merged: [String: [(URL, SearchRoot)]] = [:]
        for owner in owners {
            let parent = merged.keys.first { owner.hasPrefix($0 + ".") } ?? owner
            merged[parent, default: []] += byOwner[owner] ?? []
        }

        var groups: [OrphanGroup] = []
        for (owner, items) in merged {
            let candidates = items.compactMap { url, root in
                makeCandidate(url, root: root, evidence: .possible,
                              reason: "Aucune application installée ne porte l’identifiant \(owner).")
            }
            guard !candidates.isEmpty else { continue }
            let vendor = Self.vendor(of: owner)
            let sibling = vendor.flatMap { v in inventory.first { $0.0.hasPrefix(v + ".") }?.1 }
            groups.append(OrphanGroup(bundleID: owner, candidates: candidates.sorted { $0.url.path < $1.url.path }, sameVendorAs: sibling))
        }
        groups.sort { $0.bytes > $1.bytes }
        return OrphanScan(groups: groups, warnings: warnings)
    }
}
