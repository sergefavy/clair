import AppKit
import ClairCore

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var quit: InstalledApp?
    var offerFullDiskAccess = false
}

@MainActor final class Model: ObservableObject {
    enum Mode: Hashable { case apps, leftovers }

    @Published var mode: Mode = .apps
    @Published var apps: [InstalledApp] = []
    @Published var search = ""
    @Published var selected: InstalledApp?
    @Published var scan: AppScan?
    @Published var orphans: OrphanScan?
    @Published var checked = Set<String>()
    /// Message de l'opération en cours ; nil quand Clair est disponible.
    @Published var working: String?
    @Published var notice: Notice?
    @Published var confirming = false
    /// Suppression en cours : aucune autre action ne doit l'interrompre.
    @Published var removing = false
    @Published var journal = ""
    @Published var fullDiskAccess = SystemBackend.hasFullDiskAccess()

    let cleaner = Cleaner(isInstalled: Model.isInstalled)
    private var current: Task<Void, Never>?

    private static let journalURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(clairBundleID)/journal.txt")

    init() { journal = (try? String(contentsOf: Self.journalURL, encoding: .utf8)) ?? "" }

    /// Une application est-elle encore connue de macOS (hors Corbeille) ?
    nonisolated static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains {
            !$0.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    // MARK: - Listes

    var filteredApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var visibleCandidates: [Candidate] {
        switch mode {
        case .apps: scan?.candidates ?? []
        case .leftovers: orphans?.groups.flatMap(\.candidates) ?? []
        }
    }

    var chosen: [Candidate] { visibleCandidates.filter { checked.contains($0.id) && $0.removable } }
    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }
    var needsAdmin: Bool { chosen.contains(where: \.requiresAdmin) }

    // MARK: - Actions

    func load() async {
        let cleaner = cleaner
        apps = await Task.detached(priority: .userInitiated) { cleaner.applications() }.value
    }

    func select(_ app: InstalledApp) {
        guard !removing, selected != app || scan == nil else { return }
        mode = .apps
        selected = app
        analyse(app)
    }

    /// Application glissée dans la fenêtre ou choisie avec le sélecteur.
    func open(_ url: URL) {
        guard let app = InstalledApp(bundleAt: url) else {
            notice = Notice(title: "Fichier non reconnu", message: "Choisis une application (.app).")
            return
        }
        if !apps.contains(app) { apps.append(app); apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        select(app)
    }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func analyse(_ app: InstalledApp) {
        current?.cancel()
        scan = nil; checked = []
        working = "Analyse de \(app.name)…"
        let cleaner = cleaner
        current = Task {
            let result = await Task.detached(priority: .userInitiated) { cleaner.scan(app) }.value
            guard !Task.isCancelled, selected == app else { return }
            scan = result
            checked = Set(result.candidates.filter(\.recommended).map(\.id))
            working = nil
        }
    }

    func findLeftovers() {
        guard !removing else { return }
        current?.cancel()
        mode = .leftovers
        fullDiskAccess = SystemBackend.hasFullDiskAccess()
        orphans = nil; checked = []
        working = "Recherche des restes d’applications supprimées…"
        let cleaner = cleaner
        current = Task {
            let installed = apps.isEmpty ? await Task.detached { cleaner.applications() }.value : apps
            let result = await Task.detached(priority: .userInitiated) { cleaner.scanOrphans(installed: installed) }.value
            guard !Task.isCancelled else { return }
            orphans = result
            working = nil
        }
    }

    func setChecked(_ candidates: [Candidate], _ on: Bool) {
        let ids = candidates.filter(\.removable).map(\.id)
        if on { checked.formUnion(ids) } else { checked.subtract(ids) }
    }

    private func runningInstances(_ app: InstalledApp) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            (!app.bundleID.isEmpty && $0.bundleIdentifier == app.bundleID) || $0.bundleURL?.standardizedFileURL == app.url
        }
    }

    func requestRemoval() {
        guard !chosen.isEmpty, working == nil, !removing else { return }
        if let app = scan?.app, mode == .apps, !runningInstances(app).isEmpty {
            notice = Notice(title: "\(app.name) est ouverte",
                            message: "Quitte l’application avant de la déplacer dans la Corbeille.", quit: app)
            return
        }
        confirming = true
    }

    func quit(_ app: InstalledApp) {
        runningInstances(app).forEach { $0.terminate() }
    }

    func remove() {
        let selection = chosen
        guard !selection.isEmpty else { return }
        current?.cancel()
        removing = true
        working = "Déplacement dans la Corbeille…"
        let cleaner = cleaner
        Task {
            let outcome = await cleaner.execute(selection, backend: SystemBackend())
            appendJournal(outcome.log)
            removing = false
            working = nil

            let moved = outcome.removed.count
            var message = "\(moved) élément\(moved > 1 ? "s" : "") sur \(selection.count) dans la Corbeille."
            if outcome.cancelled { message = "Opération annulée. " + message }
            if !outcome.failures.isEmpty { message += "\n\n" + outcome.failures.prefix(5).joined(separator: "\n") }
            let blocked = outcome.needsFullDiskAccess.count
            let hasAccess = SystemBackend.hasFullDiskAccess()
            if blocked > 0 {
                message += "\n\n\(blocked) élément\(blocked > 1 ? "s sont protégés" : " est protégé") par macOS (conteneurs d’applications). "
                message += hasAccess
                    ? "Clair a pourtant l’« Accès complet au disque » : quitte Clair complètement puis relance-le pour que l’autorisation s’applique, et recommence."
                    : "Pour les retirer, active Clair dans Réglages Système › Confidentialité et sécurité › Accès complet au disque, puis quitte et relance Clair, et recommence."
            }
            if moved > 0 { message += "\n\nTu peux les récupérer tant que la Corbeille n’est pas vidée." }
            let title = outcome.failures.isEmpty && !outcome.cancelled && blocked == 0 ? "C’est fait" : "Opération incomplète"

            switch mode {
            case .apps:
                if let app = scan?.app, outcome.removed.contains(app.url.path) {
                    apps.removeAll { $0 == app }
                }
                if let app = selected { analyse(app) }
            case .leftovers:
                findLeftovers()
            }
            notice = Notice(title: title, message: message, offerFullDiskAccess: blocked > 0 && !hasAccess)
        }
    }

    private func appendJournal(_ text: String) {
        journal += text + "\n"
        do {
            try FileManager.default.createDirectory(at: Self.journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try journal.write(to: Self.journalURL, atomically: true, encoding: .utf8)
        } catch {
            journal += "Échec d’enregistrement du journal : \(error.localizedDescription)\n"
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealJournal() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.journalURL])
    }
}
