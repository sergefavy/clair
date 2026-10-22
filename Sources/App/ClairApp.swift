import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClairCore

private typealias ViewState<Value> = SwiftUI.State<Value>

private let accent = Color(red: 0.21, green: 0.70, blue: 0.56)
private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

@MainActor final class Model: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var selected: InstalledApp?
    @Published var result: ScanResult?
    @Published var checked = Set<String>()
    @Published var busy = false
    @Published var status = "Choisis une application pour examiner ses fichiers."
    @Published var search = ""
    @Published var problem: String?
    @Published var journal = ""
    let cleaner = Cleaner()
    var chosen: [Candidate] { result?.candidates.filter { checked.contains($0.id) && $0.removable } ?? [] }
    var bytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }
    var filtered: [InstalledApp] { apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) } }

    func load() async {
        busy = true; status = "Recherche des applications…"
        let cleaner = cleaner
        apps = await Task.detached(priority: .userInitiated) { cleaner.applications() }.value
        busy = false; status = "\(apps.count) applications trouvées · aucune suppression automatique."
    }
    func select(_ app: InstalledApp) {
        guard !busy else { return }
        selected = app; result = nil; checked = []
        status = "Prêt à analyser \(app.name)."
    }
    func scan() async {
        guard let app = selected, !busy else { return }
        busy = true; result = nil; checked = []; status = "Analyse de \(app.name)…"
        let cleaner = cleaner
        let scan = await Task.detached(priority: .userInitiated) { cleaner.scan(app) }.value
        result = scan; checked = Set(scan.candidates.filter(\.recommended).map(\.id))
        busy = false
        let partial = scan.warnings.contains { $0.contains("inaccessible") || $0.contains("Accès refusé") || $0.contains("Analyse limitée") }
        status = "\(partial ? "Analyse partielle" : "Analyse terminée") · \(scan.candidates.count) éléments repérés."
    }
    func running(_ app: InstalledApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            (!app.bundleID.isEmpty && $0.bundleIdentifier == app.bundleID) || $0.bundleURL == app.url ||
            ($0.executableURL.map { Cleaner.isWithin($0, app.url) } ?? false)
        }
    }
    func remove(permanent: Bool) async {
        guard let result, !busy, !chosen.isEmpty else { return }
        guard !running(result.app) else {
            problem = "Quitte \(result.app.name) avant de continuer, puis relance l’analyse. Clair ne ferme pas tes applications de force."; return
        }
        let candidates = chosen, cleaner = cleaner, app = result.app
        busy = true; status = permanent ? "Suppression des éléments confirmés…" : "Déplacement vers la Corbeille…"
        let outcome = await Task.detached(priority: .userInitiated) { () -> (Set<String>, String) in
            cleaner.execute(candidates, app: app, permanent: permanent)
        }.value
        journal += outcome.1 + "\n"
        checked.subtract(outcome.0)
        self.result = nil; checked = []
        if outcome.0.contains(app.url.path) { apps.removeAll { $0.id == app.id }; selected = nil }
        busy = false
        status = "\(outcome.0.count)/\(candidates.count) éléments traités. Consulte le journal pour le détail."
        problem = status + "\n\nLes agents de démarrage déjà actifs peuvent nécessiter une fermeture de session. Une nouvelle analyse est nécessaire avant une autre opération."
    }
    func export(_ text: String, filename: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = filename; panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { problem = error.localizedDescription }
    }
}

@main struct ClairApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        Window("Clair", id: "main") { MainView(model: model).frame(minWidth: 980, minHeight: 680).tint(accent).preferredColorScheme(.dark) }
            .defaultSize(width: 1160, height: 790)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct MainView: View {
    @ObservedObject var model: Model
    @ViewState<Bool> private var confirmation = false
    @ViewState<Bool> private var showJournal = false
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 30)).foregroundStyle(accent)
                    VStack(alignment: .leading) { Text("Clair").font(.system(size: 27, weight: .bold)); Text("LE NETTOYAGE SOUS CONTRÔLE").font(.system(size: 8, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary) }
                }.padding(.top, 14)
                TextField("Rechercher une application", text: $model.search).textFieldStyle(.roundedBorder)
                HStack { Text("APPLICATIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Text("\(model.filtered.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.filtered) { app in
                            Button { model.select(app) } label: {
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(app.url.path.hasPrefix("/Applications/") ? "Applications" : "Dossier personnel").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if app.protected { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                                }.padding(9).background(model.selected == app ? accent.opacity(0.17) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).disabled(model.busy)
                        }
                    }
                }
                Button { Task { await model.load() } } label: { Label("Actualiser la liste", systemImage: "arrow.clockwise") }.disabled(model.busy)
                Label("Local · sans compte · sans réseau", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(18).navigationSplitViewColumnWidth(min: 245, ideal: 270, max: 340)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Label("EXAMINER AVANT D’EFFACER", systemImage: "checkmark.shield").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(accent)
                    Spacer()
                    Button { showJournal = true } label: { Label("Journal", systemImage: "clock.arrow.circlepath") }.buttonStyle(.borderless)
                }.padding(.horizontal, 28).padding(.vertical, 20)
                Divider()
                if let app = model.selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            HStack(alignment: .center, spacing: 18) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 68, height: 68)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(app.name).font(.system(size: 28, weight: .bold))
                                    Text(app.bundleID.isEmpty ? "Identifiant inconnu" : app.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text(app.url.path).font(.system(size: 10)).foregroundStyle(.tertiary).textSelection(.enabled)
                                }
                                Spacer()
                                Button { Task { await model.scan() } } label: { Label(model.result == nil ? "Analyser" : "Ré-analyser", systemImage: "magnifyingglass").padding(.vertical, 4) }.buttonStyle(.borderedProminent).disabled(model.busy)
                            }
                            if let result = model.result {
                                HStack(spacing: 12) {
                                    Metric(title: "SÉLECTION", value: "\(model.chosen.count)", subtitle: "éléments à examiner")
                                    Metric(title: "TAILLE ESTIMÉE", value: size(model.bytes), subtitle: "taille logique · espace récupéré variable")
                                    Metric(title: "PROTECTION", value: "Active", subtitle: "confirmation pour chaque application")
                                }
                                if result.warnings.contains(where: { $0.contains("inaccessible") || $0.contains("Accès refusé") || $0.contains("Analyse limitée") }) {
                                    Label("Analyse partielle : certains dossiers n’ont pas pu être lus. Consulte le périmètre et les limites ci-dessous.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 9))
                                }
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("Fichiers associés").font(.title3.weight(.semibold))
                                        Spacer()
                                        Button("Tout décocher") { model.checked = [] }.font(.caption)
                                    }
                                    Text("Les données personnelles de cette application peuvent être incluses. Ouvre les dossiers pour vérifier leur contenu.").font(.caption).foregroundStyle(.secondary)
                                    ForEach(result.candidates) { c in CandidateRow(candidate: c, checked: $model.checked).disabled(model.busy) }
                                }
                                DisclosureGroup("Périmètre et limites de l’analyse (\(result.warnings.count))") {
                                    VStack(alignment: .leading, spacing: 10) { ForEach(result.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) } }.padding(.top, 10)
                                }.font(.caption)
                                Button { model.export(model.cleaner.report(result), filename: "Clair-analyse-\(app.name).txt") } label: { Label("Exporter le rapport d’analyse", systemImage: "square.and.arrow.up") }.buttonStyle(.borderless)
                            } else if model.busy {
                                VStack(spacing: 16) { ProgressView(); Text(model.status).foregroundStyle(.secondary); Text("Lecture uniquement. Aucun fichier n’est supprimé.").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 100)
                            } else {
                                VStack(alignment: .leading, spacing: 20) {
                                    Text("Un départ propre, en connaissance de cause.").font(.title2.weight(.semibold))
                                    Feature(icon: "magnifyingglass", title: "1. Repérer", text: "Cherche les données associées dans les dossiers habituels de macOS.")
                                    Feature(icon: "checklist", title: "2. Vérifier", text: "Affiche chaque chemin et la raison de sa présence. Les correspondances incertaines restent décochées.")
                                    Feature(icon: "hand.raised", title: "3. Confirmer", text: "Une seule application à la fois. Corbeille ou suppression définitive avec confirmation explicite.")
                                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                        }.padding(28)
                    }
                } else {
                    VStack(spacing: 22) {
                        Image(systemName: "sparkle.magnifyingglass").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(accent)
                        Text("Fais de la place.\nGarde la main.").font(.system(size: 38, weight: .bold)).multilineTextAlignment(.center)
                        Text("Sélectionne une application à gauche.\nClair repère ses fichiers, puis te laisse décider.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack(spacing: 24) { Label("Analyse locale", systemImage: "desktopcomputer"); Label("Confirmation requise", systemImage: "hand.raised") }.font(.caption).foregroundStyle(accent)
                        if model.busy { ProgressView() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 16) {
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button { confirmation = true } label: { Label("Examiner la suppression…", systemImage: "trash").padding(.vertical, 5) }.buttonStyle(.borderedProminent).disabled(model.chosen.isEmpty || model.busy)
                }.padding(20)
            }.background(Color(red: 0.065, green: 0.085, blue: 0.09))
        }
        .task { await model.load() }
        .sheet(isPresented: $confirmation) { ConfirmationView(model: model) }
        .sheet(isPresented: $showJournal) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Journal des opérations").font(.title2.bold())
                Text("Résultats de cette session. Exporte le journal pour le conserver.").foregroundStyle(.secondary)
                ScrollView { Text(model.journal.isEmpty ? "Aucune suppression effectuée." : model.journal).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Button("Exporter") { model.export(model.journal, filename: "Clair-journal.txt") }.disabled(model.journal.isEmpty); Spacer(); Button("Fermer") { showJournal = false }.keyboardShortcut(.cancelAction) }
            }.padding(26).frame(width: 740, height: 480)
        }
        .alert("Clair", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) { Button("OK") { model.problem = nil } } message: { Text(model.problem ?? "") }
    }
}

struct Metric: View {
    let title: String, value: String, subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary); Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(accent); Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }.frame(maxWidth: .infinity, minHeight: 82, alignment: .leading).padding(16).background(.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 12)) }
}
struct Feature: View {
    let icon: String, title: String, text: String
    var body: some View { HStack(alignment: .top, spacing: 15) { Image(systemName: icon).font(.title3).foregroundStyle(accent).frame(width: 26); VStack(alignment: .leading, spacing: 5) { Text(title).fontWeight(.semibold); Text(text).font(.callout).foregroundStyle(.secondary) } } }
}
struct CandidateRow: View {
    let candidate: Candidate
    @Binding var checked: Set<String>
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Sélectionner \(candidate.url.lastPathComponent)", isOn: Binding(get: { checked.contains(candidate.id) }, set: { if $0 { checked.insert(candidate.id) } else { checked.remove(candidate.id) } })).labelsHidden().toggleStyle(.checkbox).disabled(!candidate.removable).padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(candidate.url.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1); Spacer(); Text((candidate.sizeIncomplete ? "≥ " : "") + size(candidate.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Text(candidate.url.path).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 8) { Text(candidate.category); Text("·"); Text(candidate.evidence.rawValue).foregroundStyle(candidate.removable ? (candidate.evidence == .possible ? Color.orange : accent) : Color.orange) }.font(.system(size: 10))
                Text(candidate.reason).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Afficher dans le Finder")
        }.padding(13).background(.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct ConfirmationView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @ViewState<Bool> private var permanent = false
    @ViewState<String> private var typed = ""
    @ViewState<Bool> private var acknowledged = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Confirmer pour \(model.selected?.name ?? "")", systemImage: "hand.raised.fill").font(.title2.bold())
            Text("\(model.chosen.count) éléments · \(size(model.bytes)) estimés. Seuls les chemins ci-dessous seront traités.").foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 7) { ForEach(model.chosen) { Text($0.url.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } } }.frame(height: 170).padding(12).background(.black.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 10))
            Picker("Méthode", selection: $permanent) { Text("Déplacer dans la Corbeille").tag(false); Text("Supprimer définitivement").tag(true) }.pickerStyle(.segmented)
            Text(permanent ? "Cette action est irréversible. Les données, réglages et sessions sélectionnés seront effacés." : "Les éléments seront déplacés dans la Corbeille. Clair ne vide jamais la Corbeille.").font(.callout).foregroundStyle(permanent ? Color.orange : Color.secondary)
            Toggle("J’ai vérifié la liste et sauvegardé les données à conserver.", isOn: $acknowledged)
            if permanent {
                Text("Saisis exactement « \(model.selected?.name ?? "") » pour autoriser la suppression définitive.").font(.caption)
                TextField("Nom de l’application", text: $typed).textFieldStyle(.roundedBorder)
            }
            HStack { Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button(permanent ? "Supprimer définitivement" : "Déplacer dans la Corbeille", role: .destructive) { let mode = permanent; dismiss(); Task { await model.remove(permanent: mode) } }.disabled(!acknowledged || (permanent && typed != model.selected?.name)).buttonStyle(.borderedProminent).tint(permanent ? .red : accent) }
        }.padding(28).frame(width: 690)
    }
}
