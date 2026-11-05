// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI
import Vision
import UniformTypeIdentifiers
import CryptoKit

/// Petits outils : texte depuis une capture (façon Shottr), pipette, archives (façon Keka), empreintes.
final class UtilitiesModel: ObservableObject {
    @Published var ocrText = ""
    @Published var ocrBusy = false
    @Published var color: NSColor?
    @Published var archiveMessage = ""
    @Published var archiveBusy = false
    @Published var hashes: [(String, String)] = []
    var lastArchive: URL?
    var lastExtracted: [URL] = []

    // MARK: OCR

    func captureAndRecognize() {
        let tmp = FS.fm.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).png")
        ocrBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            // Sélection interactive d'une zone de l'écran (Échap pour annuler)
            Shell.exec("/usr/sbin/screencapture", ["-i", "-x", tmp.path])
            defer { try? FS.fm.removeItem(at: tmp) }
            guard FS.exists(tmp) else { DispatchQueue.main.async { self.ocrBusy = false }; return }
            self.recognize(tmp)
        }
    }

    func recognizeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        ocrBusy = true
        DispatchQueue.global(qos: .userInitiated).async { self.recognize(u) }
    }

    func recognize(_ url: URL) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(url: url).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        DispatchQueue.main.async {
            self.ocrBusy = false
            self.ocrText = text.isEmpty ? "(aucun texte reconnu)" : text
            if !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    // MARK: Pipette

    func pickColor() {
        NSColorSampler().show { [weak self] c in
            guard let c = c?.usingColorSpace(.sRGB) else { return }
            self?.color = c
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.hex(c), forType: .string)
        }
    }

    static func hex(_ c: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    // MARK: Archives

    enum ArchiveFormat: String, CaseIterable, Identifiable {
        case zip = "ZIP", tgz = "TAR.GZ", txz = "TAR.XZ", aar = "Apple Archive", dmg = "Image disque chiffrée (AES-256)"
        var id: String { rawValue }
    }

    func compress(_ format: ArchiveFormat, password: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Compresser"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        compress(panel.urls, format, password: password, reveal: true)
    }

    func compress(_ urls: [URL], _ format: ArchiveFormat, password: String, reveal: Bool) {
        guard let first = urls.first else { return }
        let dir = first.deletingLastPathComponent()
        let base = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        archiveBusy = true
        archiveMessage = "Compression…"
        DispatchQueue.global(qos: .userInitiated).async {
            let names = urls.map(\.lastPathComponent)
            let out: URL
            let r: ShellResult
            switch format {
            case .zip:
                out = Self.unique(dir.appendingPathComponent(base + ".zip"))
                if urls.count == 1 {
                    r = Shell.exec("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
                } else {
                    r = Shell.sh("cd \(Shell.quote(dir.path)) && /usr/bin/zip -qry \(Shell.quote(out.path)) " + names.map(Shell.quote).joined(separator: " "))
                }
            case .tgz, .txz:
                out = Self.unique(dir.appendingPathComponent(base + (format == .tgz ? ".tar.gz" : ".tar.xz")))
                r = Shell.exec("/usr/bin/tar", ["-C", dir.path, format == .tgz ? "-czf" : "-cJf", out.path] + names)
            case .aar:
                out = Self.unique(dir.appendingPathComponent(base + ".aar"))
                if urls.count == 1 && FS.isDirectory(first) {
                    r = Shell.exec("/usr/bin/aa", ["archive", "-d", first.path, "-o", out.path])
                } else {
                    let staging = FS.fm.temporaryDirectory.appendingPathComponent("aar-\(UUID().uuidString)")
                    try? FS.fm.createDirectory(at: staging, withIntermediateDirectories: true)
                    for u in urls { Shell.exec("/usr/bin/ditto", [u.path, staging.appendingPathComponent(u.lastPathComponent).path]) }
                    r = Shell.exec("/usr/bin/aa", ["archive", "-d", staging.path, "-o", out.path])
                    try? FS.fm.removeItem(at: staging)
                }
            case .dmg:
                out = Self.unique(dir.appendingPathComponent(base + ".dmg"))
                let staging = FS.fm.temporaryDirectory.appendingPathComponent("dmg-\(UUID().uuidString)")
                try? FS.fm.createDirectory(at: staging, withIntermediateDirectories: true)
                for u in urls { Shell.exec("/usr/bin/ditto", [u.path, staging.appendingPathComponent(u.lastPathComponent).path]) }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                p.arguments = ["create", "-quiet", "-encryption", "AES-256", "-stdinpass", "-volname", base,
                               "-srcfolder", staging.path, "-format", "UDZO", out.path]
                let pipe = Pipe()
                p.standardInput = pipe
                try? p.run()
                pipe.fileHandleForWriting.write(Data(password.utf8))
                try? pipe.fileHandleForWriting.close()
                p.waitUntilExit()
                try? FS.fm.removeItem(at: staging)
                r = ShellResult(status: p.terminationStatus, output: "")
            }
            DispatchQueue.main.async {
                self.archiveBusy = false
                if r.ok && FS.exists(out) {
                    self.archiveMessage = "Créé : \(out.lastPathComponent) (\(formatBytes(FS.size(of: out))))"
                    self.lastArchive = out
                    if reveal { FS.reveal([out]) }
                } else {
                    self.archiveMessage = "Échec : \(r.output)"
                }
            }
        }
    }

    /// Extraction de zip, 7z, rar, tar, gz, bz2, xz, iso, cab, cpio, aar…
    func extract() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.prompt = "Décompresser"
        guard panel.runModal() == .OK else { return }
        extract(panel.urls, reveal: true)
    }

    func extract(_ files: [URL], reveal: Bool) {
        archiveBusy = true
        archiveMessage = "Décompression…"
        DispatchQueue.global(qos: .userInitiated).async {
            var done: [URL] = [], errors: [String] = []
            for f in files {
                var name = f.lastPathComponent
                for ext in [".tar.gz", ".tar.xz", ".tar.bz2", ".tgz", ".zip", ".7z", ".rar", ".tar", ".aar", ".xz", ".gz", ".bz2", ".iso", ".cab"]
                    where name.lowercased().hasSuffix(ext) { name = String(name.dropLast(ext.count)); break }
                let dest = Self.unique(f.deletingLastPathComponent().appendingPathComponent(name))
                try? FS.fm.createDirectory(at: dest, withIntermediateDirectories: true)
                let r = f.pathExtension.lowercased() == "aar"
                    ? Shell.exec("/usr/bin/aa", ["extract", "-i", f.path, "-d", dest.path])
                    : Shell.exec("/usr/bin/bsdtar", ["-xf", f.path, "-C", dest.path])
                if r.ok { done.append(dest) } else { errors.append("\(f.lastPathComponent) : \(r.output)"); try? FS.fm.removeItem(at: dest) }
            }
            DispatchQueue.main.async {
                self.archiveBusy = false
                self.archiveMessage = errors.isEmpty ? "\(done.count) archive(s) décompressée(s)." : errors.joined(separator: "\n")
                self.lastExtracted = done
                if reveal && !done.isEmpty { FS.reveal(done) }
            }
        }
    }

    static func unique(_ u: URL) -> URL {
        guard FS.exists(u) else { return u }
        let ext = u.pathExtension, base = u.deletingPathExtension().lastPathComponent, dir = u.deletingLastPathComponent()
        var i = 2
        while true {
            let c = dir.appendingPathComponent("\(base) \(i)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !FS.exists(c) { return c }
            i += 1
        }
    }

    // MARK: Empreintes

    func hashFile() {
        let panel = NSOpenPanel()
        guard panel.runModal() == .OK, let u = panel.url else { return }
        hash(u)
    }

    func hash(_ u: URL) {
        hashes = [("Fichier", u.lastPathComponent), ("Calcul…", "")]
        DispatchQueue.global(qos: .userInitiated).async {
            guard let h = FileHandle(forReadingAtPath: u.path) else { return }
            var s256 = SHA256(), s1 = Insecure.SHA1(), m5 = Insecure.MD5()
            while let d = try? h.read(upToCount: 4 << 20), !d.isEmpty { s256.update(data: d); s1.update(data: d); m5.update(data: d) }
            try? h.close()
            func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }
            let res = [("Fichier", u.lastPathComponent), ("SHA-256", hex(s256.finalize())), ("SHA-1", hex(s1.finalize())), ("MD5", hex(m5.finalize()))]
            DispatchQueue.main.async { self.hashes = res }
        }
    }
}

struct UtilitiesView: View {
    @ObservedObject var model: UtilitiesModel
    @Local private var format = UtilitiesModel.ArchiveFormat.zip
    @Local private var password = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Utilitaires", subtitle: "Texte depuis l'écran, pipette, archives, empreintes",
                           icon: "hammer.fill", color: .brown)
                Group {
                    Card(title: "Copier le texte d'une zone de l'écran (OCR)", icon: "text.viewfinder") {
                        HStack {
                            Button("Sélectionner une zone…") { model.captureAndRecognize() }.buttonStyle(.borderedProminent)
                            Button("Depuis une image ou un PDF…") { model.recognizeFile() }
                            if model.ocrBusy { ProgressView().controlSize(.small) }
                            Spacer()
                            if !model.ocrText.isEmpty { Text("Copié dans le presse-papiers ✓").font(.caption).foregroundStyle(.green) }
                        }
                        if !model.ocrText.isEmpty {
                            TextEditor(text: $model.ocrText).font(.callout).frame(minHeight: 100, maxHeight: 220)
                        }
                        Text("Reconnaissance locale (Vision d'Apple), en français et en anglais. Nécessite l'autorisation « Enregistrement de l'écran ».")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Card(title: "Pipette", icon: "eyedropper") {
                        HStack(spacing: 14) {
                            Button("Choisir une couleur à l'écran") { model.pickColor() }
                            if let c = model.color {
                                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: c)).frame(width: 40, height: 28)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.2)))
                                Text(UtilitiesModel.hex(c)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Text(String(format: "rgb(%d, %d, %d)", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)))
                                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("(copié)").font(.caption).foregroundStyle(.green)
                            }
                        }
                    }

                    Card(title: "Archives", icon: "archivebox.fill") {
                        HStack {
                            Picker("Format", selection: $format) {
                                ForEach(UtilitiesModel.ArchiveFormat.allCases) { Text($0.rawValue).tag($0) }
                            }.frame(maxWidth: 360)
                            if format == .dmg { SecureField("Mot de passe", text: $password).frame(width: 180) }
                            Button("Compresser…") { model.compress(format, password: password) }
                                .disabled(model.archiveBusy || (format == .dmg && password.count < 4))
                        }
                        HStack {
                            Button("Décompresser…") { model.extract() }.disabled(model.archiveBusy)
                            Text("zip, 7z, rar, tar, gz, bz2, xz, iso, cab, aar…").font(.caption).foregroundStyle(.secondary)
                            if model.archiveBusy { ProgressView().controlSize(.small) }
                        }
                        if !model.archiveMessage.isEmpty { Text(model.archiveMessage).font(.callout).foregroundStyle(.secondary) }
                    }

                    Card(title: "Empreinte d'un fichier", icon: "number") {
                        Button("Choisir un fichier…") { model.hashFile() }
                        ForEach(model.hashes, id: \.0) { h in
                            HStack(alignment: .top) {
                                Text(h.0).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                                Text(h.1).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        Text("Pour vérifier qu'un téléchargement n'a pas été modifié : comparez avec l'empreinte publiée par l'éditeur.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
    }
}
