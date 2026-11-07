// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct ProcInfo: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let cpu: Double
    let memKB: Int64
    let user: String
    let name: String
}

final class ProcessesModel: ObservableObject {
    @Published var procs: [ProcInfo] = []
    @Published var sortByMemory = false { didSet { refresh() } }
    @Published var onlyMine = false { didSet { refresh() } }
    @Published var message: String?
    @Published var details: ProcessDetails?
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let byMem = sortByMemory, mine = onlyMine, me = NSUserName()
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Shell.exec("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,user=,comm="]).output
            var list: [ProcInfo] = []
            for line in out.split(separator: "\n") {
                let p = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                guard p.count == 5, let pid = Int32(p[0]) else { continue }
                let user = String(p[3])
                if mine && user != me { continue }
                list.append(ProcInfo(pid: pid, cpu: Double(p[1].replacingOccurrences(of: ",", with: ".")) ?? 0,
                                     memKB: Int64(p[2]) ?? 0, user: user, name: String(p[4])))
            }
            list.sort { byMem ? $0.memKB > $1.memKB : $0.cpu > $1.cpu }
            let top = Array(list.prefix(80))
            DispatchQueue.main.async { self.procs = top }
        }
    }

    /// Fiche détaillée d'un processus (inspiré de TaskExplorer).
    func inspect(_ p: ProcInfo) {
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [CChar](repeating: 0, count: 4096)
            let path = proc_pidpath(p.pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
            let ps = Shell.exec("/bin/ps", ["-o", "ppid=,lstart=,args=", "-p", String(p.pid)]).output
            let parts = ps.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let ppid = parts.first.map(String.init) ?? "—"
            let rest = parts.count > 1 ? String(parts[1]) : ""
            let started = String(rest.prefix(24)).trimmingCharacters(in: .whitespaces)
            let args = String(rest.dropFirst(24)).trimmingCharacters(in: .whitespaces)
            let sig = path.isEmpty ? nil : SignatureInfo.check(path)
            let files = Shell.exec("/usr/sbin/lsof", ["-p", String(p.pid), "-F", "n"]).output.components(separatedBy: "\n").filter { $0.hasPrefix("n") }
            let net = Shell.exec("/usr/sbin/lsof", ["-a", "-p", String(p.pid), "-i", "-n", "-P", "-F", "n"]).output
                .components(separatedBy: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
            let d = ProcessDetails(name: p.name, pid: p.pid, ppid: ppid, user: p.user, path: path, args: args, started: started,
                                   signature: sig, openFiles: files.count, connections: net)
            DispatchQueue.main.async { self.details = d }
        }
    }

    func quit(_ p: ProcInfo, force: Bool) {
        if !force, let app = NSRunningApplication(processIdentifier: p.pid) {
            app.terminate()
        } else if kill(p.pid, force ? SIGKILL : SIGTERM) != 0 {
            message = String(localized: "Impossible de quitter « \(p.name) » (processus système ou d'un autre utilisateur).")
            return
        }
        message = force ? String(localized: "« \(p.name) » forcé à quitter.") : String(localized: "« \(p.name) » quitté.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
    }
}

struct ProcessDetails: Identifiable {
    var id: Int32 { pid }
    let name: String
    let pid: Int32
    let ppid: String
    let user: String
    let path: String
    let args: String
    let started: String
    let signature: SignatureInfo?
    let openFiles: Int
    let connections: [String]
}

struct ProcessDetailsSheet: View {
    let d: ProcessDetails
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let icon = NSRunningApplication(processIdentifier: d.pid)?.icon {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                }
                Text(d.name).font(.title2.bold())
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row(String(localized: "PID / parent"), "\(d.pid) / \(d.ppid)")
                row(String(localized: "Utilisateur"), d.user)
                row(String(localized: "Démarré"), d.started)
                row(String(localized: "Exécutable"), d.path.isEmpty ? "—" : d.path)
                row(String(localized: "Arguments"), d.args.isEmpty ? "—" : d.args)
                row(String(localized: "Signature"), d.signature?.label ?? "—")
                row(String(localized: "Fichiers ouverts"), "\(d.openFiles)")
            }
            if d.signature?.suspicious == true {
                Label("Ce programme n'a pas de signature valide d'un développeur identifié.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text("Connexions réseau (\(d.connections.count))").font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(d.connections, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 120)
            HStack {
                if !d.path.isEmpty { Button("Afficher dans le Finder") { FS.reveal([URL(fileURLWithPath: d.path)]) } }
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).lineLimit(3)
        }
    }
}

struct ProcessesView: View {
    @ObservedObject var model: ProcessesModel
    @Local private var toForce: ProcInfo?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Processus"), subtitle: String(localized: "Ce qui consomme le processeur et la mémoire en ce moment"),
                       icon: "cpu", color: .purple) {
                Toggle("Mes processus", isOn: $model.onlyMine).toggleStyle(.checkbox)
                Picker("", selection: $model.sortByMemory) {
                    Text("Processeur").tag(false); Text("Mémoire").tag(true)
                }.pickerStyle(.segmented).frame(width: 200).labelsHidden()
                Button("Moniteur d'activité") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }
            if let m = model.message {
                Text(m).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            List(model.procs) { p in
                HStack(spacing: 10) {
                    Group {
                        if let icon = NSRunningApplication(processIdentifier: p.pid)?.icon {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "gearshape").foregroundStyle(.secondary)
                        }
                    }.frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).lineLimit(1)
                        Text("PID \(p.pid) · \(p.user)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f %%", p.cpu)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        .foregroundStyle(p.cpu > 50 ? .orange : .primary)
                    Text(formatBytes(p.memKB * 1024)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    Button("Quitter") { model.quit(p, force: false) }.controlSize(.small)
                }
                .contextMenu {
                    Button("Informations…") { model.inspect(p) }
                    Button("Quitter") { model.quit(p, force: false) }
                    Button("Forcer à quitter…", role: .destructive) { toForce = p }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            BottomBar {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                Text("Actualisation toutes les 3 secondes · clic droit : informations (signature, connexions) ou forcer à quitter.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .sheet(item: $model.details) { ProcessDetailsSheet(d: $0) }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .confirmationDialog("Forcer « \(toForce?.name ?? "") » à quitter ?",
                            isPresented: Binding(get: { toForce != nil }, set: { if !$0 { toForce = nil } })) {
            Button("Forcer à quitter", role: .destructive) { if let p = toForce { model.quit(p, force: true) } }
        } message: { Text("Les modifications non enregistrées seront perdues.") }
    }
}
