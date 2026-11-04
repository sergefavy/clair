import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClairCore

// Les Command Line Tools ne fournissent pas le plugin de la macro `@State` :
// l'alias utilise directement le property wrapper et compile partout.
typealias ViewState<Value> = SwiftUI.State<Value>

let accent = Color(red: 0.16, green: 0.66, blue: 0.53)
func formatSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

struct MainView: View {
    @ObservedObject var model: Model
    @ViewState private var showJournal = false
    @ViewState private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            ZStack {
                switch model.mode {
                case .apps: AppDetail(model: model)
                case .leftovers: LeftoversDetail(model: model)
                }
                if let message = model.working {
                    VStack(spacing: 14) { ProgressView(); Text(message).foregroundStyle(.secondary) }
                        .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) { ActionBar(model: model) }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(accent, style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .padding(12).allowsHitTesting(false)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
        .toolbar {
            ToolbarItem {
                Button { showJournal = true } label: { Label("Journal", systemImage: "clock.arrow.circlepath") }
                    .help("Historique des opérations")
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showJournal) { JournalView(model: model) }
        .alert("Mettre \(model.chosen.count) élément\(model.chosen.count > 1 ? "s" : "") à la Corbeille ?", isPresented: $model.confirming) {
            Button("Mettre à la Corbeille", role: .destructive) { model.remove() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("\(formatSize(model.chosenBytes)) au total. Tu pourras tout récupérer tant que la Corbeille n’est pas vidée."
                 + (model.needsAdmin ? "\n\nCertains éléments appartiennent au système : macOS te demandera ton mot de passe administrateur." : ""))
        }
        .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }), presenting: model.notice) { notice in
            if let app = notice.quit {
                Button("Quitter \(app.name)") { model.quit(app) }
            }
            Button("OK", role: .cancel) {}
        } message: { notice in Text(notice.message) }
    }
}

// MARK: - Barre latérale

struct Sidebar: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: Binding(get: { model.mode }, set: { mode in
                if mode == .leftovers, model.orphans == nil { model.findLeftovers() } else { model.mode = mode }
            })) {
                Text("Applications").tag(Model.Mode.apps)
                Text("Restes").tag(Model.Mode.leftovers)
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            .disabled(model.removing)

            switch model.mode {
            case .apps:
                List(model.filteredApps, selection: Binding(get: { model.selected }, set: { if let app = $0 { model.select(app) } })) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 26, height: 26)
                        Text(app.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if app.isProtected { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary) }
                    }
                    .tag(app)
                }
                .searchable(text: $model.search, placement: .sidebar, prompt: "Rechercher")
                .disabled(model.removing)
                Divider()
                Button { model.chooseApplication() } label: { Label("Choisir une application…", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(10).disabled(model.removing)
            case .leftovers:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Fichiers laissés par des applications déjà supprimées.")
                    Text("Clair repère les préférences, caches et données dont l’identifiant ne correspond plus à aucune application installée. Rien n’est coché d’office : vérifie chaque groupe.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button { model.findLeftovers() } label: { Label("Relancer la recherche", systemImage: "arrow.clockwise") }
                        .disabled(model.working != nil)
                    Spacer()
                }
                .padding(14)
            }
        }
    }
}

// MARK: - Détail d'une application

struct AppDetail: View {
    @ObservedObject var model: Model

    var body: some View {
        if let app = model.selected {
            List {
                HStack(spacing: 16) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title2.weight(.semibold))
                        Text(app.bundleID.isEmpty ? "Identifiant inconnu" : app.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button { model.analyse(app) } label: { Label("Réanalyser", systemImage: "arrow.clockwise") }
                        .disabled(model.working != nil)
                }
                .padding(.vertical, 6)

                if app.isProtected {
                    Label("Application système ou protégée : Clair ne la supprime pas.", systemImage: "lock.fill").foregroundStyle(.orange)
                }
                if let scan = model.scan {
                    let strong = scan.candidates.filter { $0.recommended }
                    let review = scan.candidates.filter { $0.removable && !$0.recommended }
                    let locked = scan.candidates.filter { !$0.removable }
                    CandidateSection(title: "Associés à l’application", subtitle: "Cochés par défaut", candidates: strong, model: model)
                    CandidateSection(title: "À vérifier", subtitle: "Correspondance incertaine, non cochés", candidates: review, model: model)
                    CandidateSection(title: "Non supprimables", subtitle: "Gérés par macOS ou protégés", candidates: locked, model: model)
                    if !scan.warnings.isEmpty {
                        Section("Remarques") { ForEach(scan.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) } }
                    }
                }
            }
        } else {
            EmptyState(icon: "sparkle.magnifyingglass", title: "Désinstalle proprement",
                       text: "Choisis une application dans la liste ou glisse-la ici.\nClair retrouve ses fichiers cachés et te laisse décider.")
        }
    }
}

struct CandidateSection: View {
    let title: String
    let subtitle: String
    let candidates: [Candidate]
    @ObservedObject var model: Model

    var body: some View {
        if !candidates.isEmpty {
            Section {
                ForEach(candidates) { CandidateRow(candidate: $0, model: model) }
            } header: {
                HStack {
                    Text(title)
                    Text("· " + subtitle).foregroundStyle(.secondary).fontWeight(.regular)
                    Spacer()
                    if candidates.contains(where: \.removable) {
                        let all = candidates.filter(\.removable).allSatisfy { model.checked.contains($0.id) }
                        Button(all ? "Tout décocher" : "Tout cocher") { model.setChecked(candidates, !all) }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }
}

struct CandidateRow: View {
    let candidate: Candidate
    @ObservedObject var model: Model

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { model.checked.contains(candidate.id) }, set: { model.setChecked([candidate], $0) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!candidate.removable || model.removing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                    if candidate.requiresAdmin {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Mot de passe administrateur requis")
                    }
                }
                Text(candidate.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("\(candidate.category) · \(candidate.reason)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text((candidate.sizeIncomplete ? "≥ " : "") + formatSize(candidate.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if FileManager.default.fileExists(atPath: candidate.url.path) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Afficher dans le Finder")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Restes

struct LeftoversDetail: View {
    @ObservedObject var model: Model

    var body: some View {
        if let orphans = model.orphans {
            if orphans.groups.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Rien à signaler", text: "Aucun reste d’application supprimée n’a été trouvé.")
            } else {
                let likely = orphans.groups.filter { $0.sameVendorAs == nil }
                let related = orphans.groups.filter { $0.sameVendorAs != nil }
                List {
                    Text("\(likely.count) applications supprimées ont laissé des fichiers (\(formatSize(likely.reduce(0) { $0 + $1.bytes }))). Ouvre un dossier avec la loupe en cas de doute.")
                        .foregroundStyle(.secondary)
                    ForEach(likely) { OrphanSection(group: $0, model: model) }
                    if !related.isEmpty {
                        Section {
                            DisclosureGroup("\(related.count) autres groupes du même éditeur qu’un logiciel installé : probablement encore utilisés") {
                                ForEach(related) { group in
                                    VStack(alignment: .leading, spacing: 4) {
                                        OrphanHeader(group: group, model: model)
                                        ForEach(group.candidates) { CandidateRow(candidate: $0, model: model).padding(.leading, 18) }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }
            }
        } else if model.working == nil {
            EmptyState(icon: "archivebox", title: "Restes d’applications", text: "Lance la recherche depuis la barre latérale.")
        }
    }
}

struct OrphanSection: View {
    let group: OrphanGroup
    @ObservedObject var model: Model
    var body: some View {
        Section {
            ForEach(group.candidates) { CandidateRow(candidate: $0, model: model) }
        } header: { OrphanHeader(group: group, model: model) }
    }
}

struct OrphanHeader: View {
    let group: OrphanGroup
    @ObservedObject var model: Model
    var body: some View {
        let all = group.candidates.allSatisfy { model.checked.contains($0.id) }
        HStack {
            Toggle("", isOn: Binding(get: { all }, set: { model.setChecked(group.candidates, $0) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(model.removing)
            Text(group.bundleID).textSelection(.enabled)
            if let sibling = group.sameVendorAs {
                Text("même éditeur que \(sibling)").font(.caption).foregroundStyle(.orange).fontWeight(.regular)
            }
            Spacer()
            Text(formatSize(group.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Éléments communs

struct ActionBar: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 12) {
            if model.chosen.isEmpty {
                Text("Aucun élément sélectionné").foregroundStyle(.secondary)
            } else {
                Text("\(model.chosen.count) élément\(model.chosen.count > 1 ? "s" : "") · \(formatSize(model.chosenBytes))")
                    .monospacedDigit()
                if model.needsAdmin {
                    Label("mot de passe requis", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.requestRemoval() } label: {
                Label("Mettre à la Corbeille", systemImage: "trash").padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
            .disabled(model.chosen.isEmpty || model.working != nil)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }
}

struct EmptyState: View {
    let icon: String, title: String, text: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 56, weight: .light)).foregroundStyle(accent)
            Text(title).font(.title.weight(.semibold))
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JournalView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Journal des opérations").font(.title2.weight(.semibold))
            ScrollView {
                Text(model.journal.isEmpty ? "Aucune opération pour l’instant." : model.journal)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Afficher le fichier") { model.revealJournal() }.disabled(model.journal.isEmpty)
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 720, height: 460)
    }
}
