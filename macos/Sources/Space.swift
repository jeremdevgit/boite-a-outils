// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct SpaceEntry: Identifiable {
    var id: URL { url }
    let url: URL
    let isFolder: Bool
    var size: Int64?
}

/// Explorateur d'espace disque : taille de chaque dossier, navigation par clic.
final class SpaceModel: ObservableObject {
    @Published var path: [URL] = [FS.home]
    @Published var entries: [SpaceEntry] = []
    @Published var pending = 0

    private var cache: [URL: Int64] = [:]
    private var token = UUID()

    var current: URL { path.last! }
    var maxSize: Int64 { entries.compactMap(\.size).max() ?? 1 }
    var total: Int64 { entries.compactMap(\.size).reduce(0, +) }

    func load() {
        let t = UUID()
        token = t
        let kids = FS.children(current).filter { $0.lastPathComponent != ".DS_Store" }
        entries = kids.map { SpaceEntry(url: $0, isFolder: FS.isDirectory($0) && !FS.isPackage($0), size: cache[$0]) }
        sort()
        let todo = kids.filter { cache[$0] == nil }
        pending = todo.count
        guard !todo.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: todo.count) { i in
                guard self.token == t else { return }
                let s = FS.size(of: todo[i])
                DispatchQueue.main.async {
                    self.cache[todo[i]] = s
                    guard self.token == t else { return }
                    if let idx = self.entries.firstIndex(where: { $0.url == todo[i] }) { self.entries[idx].size = s }
                    self.pending = max(self.pending - 1, 0)
                    if self.pending == 0 { self.sort() }
                }
            }
        }
    }

    func open(_ e: SpaceEntry) {
        guard e.isFolder else { return }
        path.append(e.url)
        load()
    }

    func go(to index: Int) {
        path = Array(path.prefix(index + 1))
        load()
    }

    func setRoot(_ url: URL) {
        path = [url]
        load()
    }

    func trash(_ e: SpaceEntry) {
        if FS.trash([e.url], adminFallback: false).isEmpty {
            cache[e.url] = nil
            // Les tailles des dossiers parents ne sont plus valables.
            for p in path { cache[p] = nil }
            entries.removeAll { $0.url == e.url }
        }
    }

    private func sort() {
        entries.sort { ($0.size ?? -1) > ($1.size ?? -1) }
    }
}

struct SpaceView: View {
    @ObservedObject var model: SpaceModel
    @Local private var toDelete: SpaceEntry?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Espace disque"), subtitle: String(localized: "Visualisez ce qui occupe de la place, dossier par dossier"),
                       icon: "chart.pie.fill", color: .indigo) {
                Menu("Emplacement") {
                    Button("Dossier personnel") { model.setRoot(FS.home) }
                    Button("Applications") { model.setRoot(URL(fileURLWithPath: "/Applications")) }
                    Button("Bibliothèque") { model.setRoot(FS.home.appendingPathComponent("Library")) }
                    Divider()
                    Button("Choisir un dossier…") { if let u = FS.chooseFolder(start: model.current) { model.setRoot(u) } }
                }
                .frame(width: 140)
            }
            FullDiskAccessBanner()

            HStack(spacing: 4) {
                ForEach(Array(model.path.enumerated()), id: \.offset) { idx, url in
                    if idx > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    Button(idx == 0 ? FS.displayPath(url) : url.lastPathComponent) { model.go(to: idx) }
                        .buttonStyle(.link)
                }
                Spacer()
                if model.pending > 0 {
                    ProgressView().controlSize(.small)
                    Text("Calcul… (\(model.pending))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Total : \(formatBytes(model.total))").font(.callout.bold())
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 8)

            List(model.entries) { e in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: e.url.path)).resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.url.lastPathComponent).lineLimit(1)
                        GeometryReader { g in
                            Capsule().fill(Color.indigo.gradient)
                                .frame(width: max(2, g.size.width * CGFloat(Double(e.size ?? 0) / Double(max(model.maxSize, 1)))))
                        }
                        .frame(height: 5)
                    }
                    Text(e.size.map(formatBytes) ?? "…").monospacedDigit().frame(width: 90, alignment: .trailing)
                    if e.isFolder {
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    } else {
                        Spacer().frame(width: 10)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 3)
                .onTapGesture { model.open(e) }
                .contextMenu {
                    Button("Afficher dans le Finder") { FS.reveal([e.url]) }
                    Button("Mettre à la corbeille…", role: .destructive) { toDelete = e }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            BottomBar {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Cliquez sur un dossier pour l'ouvrir · clic droit pour afficher ou supprimer.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onAppear { if model.entries.isEmpty { model.load() } }
        .confirmationDialog("Mettre « \(toDelete?.url.lastPathComponent ?? "") » à la corbeille ?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Mettre à la corbeille", role: .destructive) { if let e = toDelete { model.trash(e) } }
        }
    }
}
