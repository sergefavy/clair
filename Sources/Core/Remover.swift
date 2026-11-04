import Foundation

/// Opérations système fournies par l'application (ou simulées par les tests).
public protocol RemovalBackend: Sendable {
    /// Déplace dans la Corbeille avec les droits de l'utilisateur.
    func trash(_ url: URL) async throws
    /// Déplace dans la Corbeille par le Finder, qui demande le mot de passe si nécessaire
    /// et dispose de la permission « Gestion des apps ». Lance `CleanerError.cancelled` en cas d'annulation.
    func trashWithFinder(_ urls: [URL]) async throws
    /// Exécute des commandes avec les droits administrateur, en une seule demande.
    func runAsAdmin(_ commands: [[String]]) async throws
    /// Arrête un agent launchd dans la session de l'utilisateur (sans droits particuliers).
    func unloadUserService(_ plist: URL) async
}

extension Cleaner {
    // MARK: - Validation

    func validateApp(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        guard url.pathExtension.lowercased() == "app", Paths.real(path) == path,
              !Self.isProtectedPath(path), !url.deletingLastPathComponent().path.lowercased().contains(".app"),
              !applicationRoots.contains(where: { $0.path == path }) else { throw CleanerError.unsafe(path) }
        if let app = InstalledApp(bundleAt: url), app.isProtected { throw CleanerError.unsafe(path) }
    }

    /// Un fichier doit être un enfant direct d'une racine connue (ou un petit-enfant d'une racine
    /// « Éditeur/Application »), sans aucun lien symbolique dans son chemin.
    func validateLocation(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let parentURL = url.deletingLastPathComponent().standardizedFileURL
        let parent = parentURL.path, grandparent = parentURL.deletingLastPathComponent().path
        guard Paths.real(path) == path, !Self.isAppleID(Self.baseName(url.lastPathComponent)),
              roots.contains(where: { !$0.protected && ($0.url.path == parent || ($0.nested && $0.url.path == grandparent)) })
        else { throw CleanerError.unsafe(path) }
    }

    public func validate(_ candidate: Candidate) throws {
        guard candidate.removable else { throw CleanerError.unsafe(candidate.url.path) }
        switch candidate.kind {
        case .app: try validateApp(candidate.url)
        case .file: try validateLocation(candidate.url)
        case .receipt(let id):
            guard !Self.isAppleID(id), !id.contains("/") else { throw CleanerError.unsafe(id) }
            return
        }
        guard let stamp = candidate.stamp, (try? Stamp.read(candidate.url)) == stamp else {
            throw CleanerError.changed(candidate.url.path)
        }
    }

    private func isGone(_ candidate: Candidate) -> Bool {
        if case .receipt(let id) = candidate.kind { return !receipts.exists(id) }
        return !FileManager.default.fileExists(atPath: candidate.url.path)
    }

    // MARK: - Exécution

    /// Déplace la sélection confirmée dans la Corbeille. Rien n'est supprimé définitivement.
    ///
    /// Ordre : 1) l'application, pour que ses données restent intactes si elle ne peut pas être retirée ;
    /// 2) les éléments qui exigent des droits (une seule demande de mot de passe) ;
    /// 3) les éléments de l'utilisateur ; ceux qui échouent sont confiés au Finder.
    public func execute(_ selection: [Candidate], backend: any RemovalBackend) async -> RemovalOutcome {
        var log = ["", "\(Date().formatted()) — Corbeille — \(selection.count) éléments"]
        func outcome(_ failures: [String], cancelled: Bool = false) -> RemovalOutcome {
            let removed = Set(selection.filter(isGone).map(\.id))
            for c in selection { log.append((removed.contains(c.id) ? "CORBEILLE : " : "CONSERVÉ : ") + c.url.path) }
            log += failures.map { "ÉCHEC : " + $0 }
            if cancelled { log.append("ANNULÉ par l’utilisateur.") }
            return RemovalOutcome(removed: removed, failures: failures, cancelled: cancelled, log: log.joined(separator: "\n"))
        }

        // Tout est revalidé avant la première modification.
        do { for c in selection { try validate(c) } }
        catch {
            log.append("Aucune modification : " + (error.localizedDescription))
            return RemovalOutcome(removed: [], failures: [error.localizedDescription], cancelled: false, log: log.joined(separator: "\n"))
        }

        var failures: [String] = []
        let app = selection.first { $0.kind == .app }
        var finderBatch: [Candidate] = []

        // 1. Application.
        if let app {
            if app.requiresAdmin { finderBatch.append(app) }
            else {
                do { try await backend.trash(app.url) }
                catch { finderBatch.append(app) } // Gestion des apps ou fichiers root : le Finder sait faire.
            }
        }

        // 2. Éléments privilégiés : arrêt des services et oubli des reçus, puis Corbeille via le Finder.
        let privileged = selection.filter { $0.kind != .app && $0.requiresAdmin }
        var commands: [[String]] = []
        for c in privileged {
            switch c.kind {
            case .receipt(let id): commands.append(["/usr/sbin/pkgutil", "--forget", id])
            case .file where c.launchDomain == .system: commands.append(["/bin/launchctl", "bootout", "system", c.url.path])
            default: break
            }
        }
        for c in privileged where c.launchDomain == .user { await backend.unloadUserService(c.url) }
        finderBatch += privileged.filter { $0.kind == .file }
        do {
            if !commands.isEmpty { try await backend.runAsAdmin(commands) }
            if !finderBatch.isEmpty { try await backend.trashWithFinder(finderBatch.map(\.url)) }
        } catch CleanerError.cancelled {
            return outcome(failures, cancelled: true)
        } catch {
            failures.append(error.localizedDescription)
        }
        if let app, !isGone(app) {
            failures.append("L’application n’a pas pu être déplacée ; ses données ont été conservées.")
            return outcome(failures)
        }

        // 3. Éléments de l'utilisateur.
        var retry: [Candidate] = []
        for c in selection where c.kind == .file && !c.requiresAdmin {
            if Task.isCancelled { break }
            if c.launchDomain == .user { await backend.unloadUserService(c.url) }
            do { try await backend.trash(c.url) } catch { retry.append(c) }
        }
        if !retry.isEmpty {
            do { try await backend.trashWithFinder(retry.map(\.url)) }
            catch CleanerError.cancelled { return outcome(failures, cancelled: true) }
            catch { failures.append(error.localizedDescription) }
        }
        for c in selection where !isGone(c) && !failures.contains(where: { $0.contains(c.url.path) }) {
            failures.append("Toujours présent : \(c.url.path)")
        }
        return outcome(failures)
    }
}
