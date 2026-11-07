// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

final class LargeFilesModel: ObservableObject {
    @Published var root = FS.home
    @Published var minMB = 100
    @Published var olderThanMonths = 0
    @Published var includeLibrary = false
    @Published var results: [FoundFile] = []
    @Published var scanning = false
    @Published var scannedCount = 0
    @Published var scannedOnce = false
    var cancelled = false

    var selected: [FoundFile] { results.filter(\.selected) }
    var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }

    func scan() {
        cancelled = false
        scanning = true
        results = []
        scannedCount = 0
        let root = root, min = Int64(minMB) * 1_000_000, includeLib = includeLibrary
        let cutoff = olderThanMonths > 0 ? Date().addingTimeInterval(-Double(olderThanMonths) * 30 * 86_400) : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            let skip: Set<String> = [FS.home.appendingPathComponent("Library").path, FS.home.appendingPathComponent(".Trash").path]
            var found: [FoundFile] = []
            var n = 0
            let en = FS.fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                                      errorHandler: { _, _ in true })
            while let f = en?.nextObject() as? URL {
                if self.cancelled { break }
                if skip.contains(f.path) && !(includeLib && f.lastPathComponent == "Library") { en?.skipDescendants(); continue }
                autoreleasepool {
                    guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return }
                    n += 1
                    if n % 2_000 == 0 { let c = n; DispatchQueue.main.async { self.scannedCount = c } }
                    let s = Int64(v.fileSize ?? 0)
                    guard s >= min else { return }
                    if let cutoff, let m = v.contentModificationDate, m > cutoff { return }
                    found.append(FoundFile(url: f, size: s, modified: v.contentModificationDate))
                }
            }
            found.sort { $0.size > $1.size }
            DispatchQueue.main.async {
                self.results = found
                self.scannedCount = n
                self.scanning = false
                self.scannedOnce = true
            }
        }
    }

    func trashSelected() {
        let urls = selected.map(\.url)
        let failed = Set(FS.trash(urls, adminFallback: false))
        results.removeAll { $0.selected && !failed.contains($0.url) }
    }
}

struct LargeFilesView: View {
    @ObservedObject var model: LargeFilesModel
    @Local private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Gros fichiers"), subtitle: String(localized: "Retrouvez les fichiers volumineux et anciens oubliés"),
                       icon: "doc.zipper", color: .orange)

            HStack(spacing: 14) {
                Button { if let u = FS.chooseFolder(start: model.root) { model.root = u } } label: {
                    Label(FS.displayPath(model.root), systemImage: "folder")
                }
                Picker("Taille min.", selection: $model.minMB) {
                    Text("50 Mo").tag(50); Text("100 Mo").tag(100); Text("500 Mo").tag(500); Text("1 Go").tag(1000)
                }.frame(width: 170)
                Picker("Non modifié depuis", selection: $model.olderThanMonths) {
                    Text("Peu importe").tag(0); Text("6 mois").tag(6); Text("1 an").tag(12); Text("2 ans").tag(24)
                }.frame(width: 250)
                Toggle("Inclure la Bibliothèque", isOn: $model.includeLibrary)
                Spacer()
                if model.scanning {
                    Button("Arrêter") { model.cancelled = true }
                } else {
                    Button("Rechercher") { model.scan() }.buttonStyle(.borderedProminent).tint(.orange)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 10)

            if model.scanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("\(model.scannedCount) fichiers examinés…").foregroundStyle(.secondary).monospacedDigit()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.scannedOnce {
                EmptyState(icon: "doc.zipper", title: String(localized: "Rechercher les gros fichiers"),
                           message: String(localized: "Choisissez un dossier et une taille minimale. Les fichiers supprimés vont à la corbeille."),
                           actionTitle: String(localized: "Rechercher")) { model.scan() }
            } else if model.results.isEmpty {
                EmptyState(icon: "checkmark.seal", title: String(localized: "Aucun fichier trouvé"),
                           message: String(localized: "Aucun fichier ne correspond aux critères (\(model.scannedCount) fichiers examinés)."))
            } else {
                List { ForEach($model.results) { $f in FileRow(file: $f) } }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                BottomBar {
                    Text("\(model.results.count) fichiers · sélection : \(formatBytes(model.selectedSize))").font(.headline)
                    Button("Tout sélectionner") { for i in model.results.indices { model.results[i].selected = true } }
                    Button("Tout désélectionner") { for i in model.results.indices { model.results[i].selected = false } }
                    Spacer()
                    Button("Afficher dans le Finder") { FS.reveal(model.selected.map(\.url)) }.disabled(model.selected.isEmpty)
                    Button("Mettre à la corbeille") { confirm = true }
                        .buttonStyle(.borderedProminent).tint(.orange).disabled(model.selected.isEmpty)
                }
            }
        }
        .confirmationDialog("Mettre \(model.selected.count) fichier(s) à la corbeille ?", isPresented: $confirm) {
            Button("Mettre à la corbeille", role: .destructive) { model.trashSelected() }
        } message: { Text("\(formatBytes(model.selectedSize)) seront libérés après avoir vidé la corbeille.") }
    }
}
