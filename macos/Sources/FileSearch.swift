// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit
import SwiftUI
import AppKit

final class FileSearchModel: ObservableObject {
    @Published var root = FS.home
    @Published var query = ""
    @Published var kind = ""
    @Published var minimum = 0
    @Published var days = 0
    @Published var sort = "name"
    @Published var fullPath = false
    @Published var hidden = false
    @Published var items: [SearchResult] = []
    @Published var total = 0
    @Published var indexed = 0
    @Published var skipped = 0
    @Published var running = false
    @Published var stopped = false
    let index = FileSearchIndex()
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var serial = 0

    func build() {
        guard root.hasDirectoryPath || (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        running = true; stopped = false; items = []; total = 0
        index.build(root: root, hidden: hidden) { [weak self] in self?.refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    func stop() { index.stop(); refresh() }
    func refresh() {
        let s = index.status; indexed = s.count; skipped = s.skipped; running = s.running; stopped = s.cancelled
        if !running { timer?.invalidate(); timer = nil }
        search()
    }
    func search() {
        pending?.cancel(); serial += 1; let token = serial
        let q = query, k = kind, min = Int64(minimum), path = fullPath, sorting = sort
        let since = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : nil
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let r = self.index.search(query: q, kind: k, minimum: min, since: since, fullPath: path, sort: sorting)
            DispatchQueue.main.async { if self.serial == token { self.items = r.items; self.total = r.total } }
        }
        pending = job; DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.18, execute: job)
    }
    deinit { timer?.invalidate(); pending?.cancel(); index.stop() }
}

struct FileSearchView: View {
    @ObservedObject var model: FileSearchModel
    var body: some View {
        VStack(spacing: 10) {
            PageHeader(title: String(localized: "Recherche de fichiers"), subtitle: String(localized: "Retrouvez fichiers et dossiers par leur nom, comme avec Everything."), icon: "magnifyingglass", color: .blue)
            HStack {
                Button { if let url = FS.chooseFolder(start: model.root) { model.root = url } } label: { Label(FS.displayPath(model.root), systemImage: "folder") }
                Button("Tout l'ordinateur") { model.root = URL(fileURLWithPath: "/", isDirectory: true) }
                Toggle("Inclure les éléments masqués", isOn: $model.hidden)
                Spacer()
                Button("Reconstruire l'index") { model.build() }.disabled(model.running).buttonStyle(.borderedProminent)
                Button("Arrêter") { model.stop() }.disabled(!model.running)
            }.padding(.horizontal, 24)
            Text("La première indexation peut prendre plusieurs minutes. Les dossiers inaccessibles sont ignorés ; les liens ne sont pas parcourus. Les tailles des dossiers ne sont pas calculées.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
            HStack {
                TextField("Nom, plusieurs mots ou *.pdf", text: $model.query)
                Picker("Type", selection: $model.kind) { Text("Fichiers et dossiers").tag(""); Text("Fichiers").tag("files"); Text("Dossiers").tag("folders") }.frame(width: 200)
                Picker("Taille minimale", selection: $model.minimum) { Text("Toutes les tailles").tag(0); Text("Plus de 10 Mo").tag(10_000_000); Text("Plus de 100 Mo").tag(100_000_000); Text("Plus de 1 Go").tag(1_000_000_000) }.frame(width: 200)
            }.padding(.horizontal, 24)
            HStack {
                Toggle("Chercher dans le chemin complet", isOn: $model.fullPath)
                Picker("Date de modification", selection: $model.days) { Text("Toutes les dates").tag(0); Text("Dernières 24 heures").tag(1); Text("7 derniers jours").tag(7); Text("30 derniers jours").tag(30) }.frame(width: 240)
                Picker("Trier", selection: $model.sort) { Text("Nom").tag("name"); Text("Taille").tag("size"); Text("Date de modification").tag("date") }.frame(width: 220)
                Spacer()
            }.padding(.horizontal, 24)
            HStack {
                Text("\(model.indexed) éléments indexés · \(model.skipped) dossiers inaccessibles")
                if model.running { ProgressView().controlSize(.small); Text("Indexation en cours…") }
                else if model.stopped { Text("Indexation arrêtée (résultats partiels)") }
                Spacer()
                Text("\(model.total) résultats · \(model.items.count) affichés")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
            if model.items.isEmpty {
                EmptyState(icon: "magnifyingglass", title: String(localized: "Aucun résultat"), message: String(localized: "Lancez une indexation ou ajustez les filtres."))
            } else {
                List(model.items) { item in
                    HStack {
                        Image(systemName: item.directory ? "folder.fill" : "doc").foregroundStyle(item.directory ? .blue : .secondary)
                        VStack(alignment: .leading) { Text(item.name).bold(); Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        Spacer()
                        Text(item.directory ? "—" : formatBytes(item.size)).monospacedDigit()
                        if let date = item.modified { Text(date, style: .date).font(.caption) }
                        Button("Afficher dans le Finder") { FS.reveal([item.url]) }
                        Button("Copier le chemin") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.path, forType: .string) }
                    }.help(item.url.path)
                }.listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Text("L'index reste en mémoire sur cet appareil. Reconstruisez-le après des modifications.").font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
        }
        .onChange(of: model.query) { model.search() }
        .onChange(of: model.kind) { model.search() }
        .onChange(of: model.minimum) { model.search() }
        .onChange(of: model.days) { model.search() }
        .onChange(of: model.sort) { model.search() }
        .onChange(of: model.fullPath) { model.search() }
    }
}
