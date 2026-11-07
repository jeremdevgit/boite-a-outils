// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI
import CryptoKit

struct DupGroup: Identifiable {
    let id = UUID()
    var files: [FoundFile]
    var size: Int64 { files.first?.size ?? 0 }
    var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
}

final class DuplicatesModel: ObservableObject {
    @Published var root = FS.home
    @Published var minKB = 1_000
    @Published var groups: [DupGroup] = []
    @Published var scanning = false
    @Published var scannedOnce = false
    @Published var status = ""
    var cancelled = false

    var selected: [FoundFile] { groups.flatMap { $0.files.filter(\.selected) } }
    var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }
    var wasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    func scan() {
        cancelled = false
        scanning = true
        groups = []
        let root = root, min = Int64(minKB) * 1_000
        DispatchQueue.global(qos: .userInitiated).async {
            func setStatus(_ s: String) { DispatchQueue.main.async { self.status = s } }

            // 1. Regroupement par taille
            setStatus(String(localized: "Inventaire des fichiers…"))
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
            let library = FS.home.appendingPathComponent("Library").path
            var bySize: [Int64: [FoundFile]] = [:]
            let en = FS.fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                      options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in true })
            while let f = en?.nextObject() as? URL {
                if self.cancelled { break }
                if f.path == library { en?.skipDescendants(); continue }
                guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
                let s = Int64(v.fileSize ?? 0)
                if s >= min { bySize[s, default: []].append(FoundFile(url: f, size: s, modified: v.contentModificationDate)) }
            }

            // 2. Empreinte partielle puis complète
            let candidates = bySize.values.filter { $0.count > 1 }
            var result: [DupGroup] = []
            for (i, group) in candidates.enumerated() {
                if self.cancelled { break }
                if i % 20 == 0 { setStatus(String(localized: "Comparaison du contenu… \(i)/\(candidates.count)")) }
                for partial in Self.split(group, limit: 65_536) {
                    for full in Self.split(partial, limit: nil) {
                        // Le plus ancien est conservé, les autres sont présélectionnés.
                        var files = full.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
                        for j in files.indices { files[j].selected = j > 0 }
                        result.append(DupGroup(files: files))
                    }
                }
            }
            result.sort { $0.wasted > $1.wasted }
            DispatchQueue.main.async {
                self.groups = result
                self.scanning = false
                self.scannedOnce = true
                self.status = ""
            }
        }
    }

    private static func split(_ files: [FoundFile], limit: Int?) -> [[FoundFile]] {
        var byHash: [String: [FoundFile]] = [:]
        for f in files { if let h = hash(f.url, limit: limit) { byHash[h, default: []].append(f) } }
        return byHash.values.filter { $0.count > 1 }
    }

    private static func hash(_ url: URL, limit: Int?) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var read = 0
        while true {
            let ok: Bool = autoreleasepool {
                let want = limit.map { min($0 - read, 1 << 20) } ?? (1 << 20)
                guard want > 0, let chunk = try? h.read(upToCount: want), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                read += chunk.count
                return true
            }
            if !ok { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func autoSelect() {
        for g in groups.indices { for j in groups[g].files.indices { groups[g].files[j].selected = j > 0 } }
    }

    func deselectAll() {
        for g in groups.indices { for j in groups[g].files.indices { groups[g].files[j].selected = false } }
    }

    func trashSelected() {
        // Sécurité : on garde toujours au moins un exemplaire par groupe.
        for g in groups.indices where groups[g].files.allSatisfy(\.selected) { groups[g].files[0].selected = false }
        let failed = Set(FS.trash(selected.map(\.url), adminFallback: false))
        for g in groups.indices { groups[g].files.removeAll { $0.selected && !failed.contains($0.url) } }
        groups.removeAll { $0.files.count < 2 }
    }
}

struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesModel
    @Local private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Doublons"), subtitle: String(localized: "Fichiers identiques au contenu près (empreinte SHA-256)"),
                       icon: "square.on.square", color: .teal)

            HStack(spacing: 14) {
                Button { if let u = FS.chooseFolder(start: model.root) { model.root = u } } label: {
                    Label(FS.displayPath(model.root), systemImage: "folder")
                }
                Picker("Taille min.", selection: $model.minKB) {
                    Text("100 Ko").tag(100); Text("1 Mo").tag(1_000); Text("10 Mo").tag(10_000); Text("100 Mo").tag(100_000)
                }.frame(width: 170)
                Spacer()
                if model.scanning {
                    Button("Arrêter") { model.cancelled = true }
                } else {
                    Button("Rechercher") { model.scan() }.buttonStyle(.borderedProminent).tint(.teal)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 10)

            if model.scanning {
                VStack(spacing: 10) { ProgressView(); Text(model.status).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.scannedOnce {
                EmptyState(icon: "square.on.square", title: String(localized: "Rechercher les doublons"),
                           message: String(localized: "Les fichiers sont comparés octet par octet via leur empreinte. Le plus ancien de chaque groupe est conservé par défaut."),
                           actionTitle: String(localized: "Rechercher")) { model.scan() }
            } else if model.groups.isEmpty {
                EmptyState(icon: "checkmark.seal", title: String(localized: "Aucun doublon"), message: String(localized: "Aucun fichier en double dans ce dossier."))
            } else {
                List {
                    ForEach($model.groups) { $g in
                        Section {
                            ForEach($g.files) { $f in FileRow(file: $f) }
                        } header: {
                            Text("\(g.files.count) copies · \(formatBytes(g.size)) chacune · \(formatBytes(g.wasted)) récupérables")
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                BottomBar {
                    VStack(alignment: .leading) {
                        Text("Sélection : \(formatBytes(model.selectedSize))").font(.headline)
                        Text("\(model.groups.count) groupes · \(formatBytes(model.wasted)) récupérables au total")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sélection auto") { model.autoSelect() }
                    Button("Tout désélectionner") { model.deselectAll() }
                    Button("Mettre à la corbeille") { confirm = true }
                        .buttonStyle(.borderedProminent).tint(.teal).disabled(model.selected.isEmpty)
                }
            }
        }
        .confirmationDialog("Mettre \(model.selected.count) doublon(s) à la corbeille ?", isPresented: $confirm) {
            Button("Mettre à la corbeille", role: .destructive) { model.trashSelected() }
        } message: { Text("Au moins un exemplaire de chaque fichier est toujours conservé.") }
    }
}
