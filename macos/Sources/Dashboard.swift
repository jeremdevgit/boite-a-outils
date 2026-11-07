// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct BatteryInfo {
    var percent: Int?
    var charging = false
    var cycles: Int?
    var condition: String?
    var maxCapacity: Int?
}

struct SecurityInfo {
    var sip = false
    var gatekeeper = false
    var fileVault = false
    var firewall = false
}

struct SystemInfo {
    var computerName = ""
    var osVersion = ""
    var model = ""
    var chip = ""
    var memTotal: Int64 = 0
    var memUsed: Int64 = 0
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    var cpuUsage: Double = 0
    var uptime: TimeInterval = 0
    var battery: BatteryInfo?
    var security = SecurityInfo()
    var fullDiskAccess = false

    var diskUsedRatio: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }
    var memRatio: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }

    static func collect() -> SystemInfo {
        var i = SystemInfo()
        let pi = ProcessInfo.processInfo
        i.computerName = Shell.exec("/usr/sbin/scutil", ["--get", "ComputerName"]).output
        i.osVersion = "macOS \(Shell.exec("/usr/bin/sw_vers", ["-productVersion"]).output) (\(Shell.exec("/usr/bin/sw_vers", ["-buildVersion"]).output))"
        i.memTotal = Int64(pi.physicalMemory)
        i.uptime = pi.systemUptime
        i.fullDiskAccess = Permissions.hasFullDiskAccess

        if let hw = jsonArray(Shell.exec("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"]).output, key: "SPHardwareDataType")?.first {
            i.model = hw["machine_name"] as? String ?? ""
            i.chip = (hw["chip_type"] as? String) ?? (hw["cpu_type"] as? String) ?? ""
        }

        // Mémoire : actives + câblées + compressées (≈ « Mémoire utilisée » du Moniteur d'activité)
        let vm = Shell.exec("/usr/bin/vm_stat", []).output
        var pageSize: Int64 = 16384
        if let r = vm.range(of: #"page size of (\d+)"#, options: .regularExpression) {
            pageSize = Int64(vm[r].filter(\.isNumber)) ?? pageSize
        }
        func pages(_ key: String) -> Int64 {
            for line in vm.split(separator: "\n") where line.hasPrefix(key) {
                let n = line.split(separator: ":").last?.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                return Int64(n ?? "") ?? 0
            }
            return 0
        }
        i.memUsed = (pages("Pages active") + pages("Pages wired down") + pages("Pages occupied by compressor")) * pageSize

        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            i.diskTotal = Int64(v.volumeTotalCapacity ?? 0)
            i.diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
        }

        let top = Shell.exec("/usr/bin/top", ["-l", "2", "-n", "0", "-s", "1"]).output
        if let line = top.split(separator: "\n").last(where: { $0.hasPrefix("CPU usage") }),
           let r = line.range(of: #"[\d.]+% idle"#, options: .regularExpression) {
            let idle = Double(line[r].replacingOccurrences(of: "% idle", with: "")) ?? 100
            i.cpuUsage = max(0, min(100, 100 - idle))
        }

        i.battery = battery()

        i.security.sip = Shell.exec("/usr/bin/csrutil", ["status"]).output.contains("enabled")
        i.security.gatekeeper = Shell.exec("/usr/sbin/spctl", ["--status"]).output.contains("enabled")
        i.security.fileVault = Shell.exec("/usr/bin/fdesetup", ["status"]).output.contains("is On")
        let fw = Shell.exec("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).output
        i.security.firewall = fw.contains("enabled") || fw.contains("State = 1") || fw.contains("State = 2")
        return i
    }

    private static func battery() -> BatteryInfo? {
        let pm = Shell.exec("/usr/bin/pmset", ["-g", "batt"]).output
        guard pm.contains("InternalBattery") else { return nil }
        var b = BatteryInfo()
        if let r = pm.range(of: #"\d+%"#, options: .regularExpression) { b.percent = Int(pm[r].dropLast()) }
        b.charging = pm.contains("AC Power") && !pm.contains("discharging")
        if let items = jsonArray(Shell.exec("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]).output, key: "SPPowerDataType") {
            for item in items {
                guard let h = item["sppower_battery_health_info"] as? [String: Any] else { continue }
                b.cycles = h["sppower_battery_cycle_count"] as? Int
                b.condition = h["sppower_battery_health"] as? String
                if let m = h["sppower_battery_health_maximum_capacity"] as? String { b.maxCapacity = Int(m.filter(\.isNumber)) }
            }
        }
        return b
    }

    private static func jsonArray(_ s: String, key: String) -> [[String: Any]]? {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o[key] as? [[String: Any]]
    }
}

final class DashboardModel: ObservableObject {
    @Published var info = SystemInfo()
    @Published var loading = false
    @Published var loaded = false

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let i = SystemInfo.collect()
            DispatchQueue.main.async {
                self.info = i
                self.loading = false
                self.loaded = true
            }
        }
    }
}

struct Advice: Identifiable {
    let id = UUID()
    let icon: String
    let color: Color
    let text: String
    var actionTitle: String? = nil
    var target: Tool? = nil
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var cleaner: CleanerModel
    @ObservedObject var permissions = PermissionCenter.shared
    let go: (Tool) -> Void

    private var info: SystemInfo { model.info }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: info.computerName.isEmpty ? String(localized: "Mon Mac") : info.computerName,
                           subtitle: [info.model, info.chip, info.osVersion].filter { !$0.isEmpty }.joined(separator: " · "),
                           icon: "laptopcomputer", color: .blue) {
                    if model.loading { ProgressView().controlSize(.small) }
                    Button { model.refresh() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                }

                smartScan.padding(.horizontal, 24)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    Card(title: String(localized: "Disque"), icon: "internaldrive") {
                        HStack(spacing: 16) {
                            Ring(value: info.diskUsedRatio, color: info.diskUsedRatio > 0.85 ? .red : .indigo)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(formatBytes(info.diskFree)) libres").bold()
                                Text("sur \(formatBytes(info.diskTotal))").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Card(title: String(localized: "Mémoire"), icon: "memorychip") {
                        HStack(spacing: 16) {
                            Ring(value: info.memRatio, color: info.memRatio > 0.85 ? .orange : .green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(formatBytes(info.memUsed)) utilisés").bold()
                                Text("sur \(formatBytes(info.memTotal))").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Card(title: String(localized: "Processeur"), icon: "cpu") {
                        HStack(spacing: 16) {
                            Ring(value: info.cpuUsage / 100, color: info.cpuUsage > 70 ? .orange : .purple)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Allumé depuis").foregroundStyle(.secondary)
                                Text(uptimeText).bold()
                            }
                        }
                    }
                    if let b = info.battery {
                        Card(title: String(localized: "Batterie"), icon: b.charging ? "battery.100.bolt" : "battery.75") {
                            HStack(spacing: 16) {
                                Ring(value: Double(b.maxCapacity ?? 100) / 100,
                                     color: (b.maxCapacity ?? 100) < 80 ? .orange : .green,
                                     label: b.maxCapacity.map { "\($0) %" } ?? "–")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Santé : \(b.condition ?? "–")").bold()
                                    Text("\(b.cycles ?? 0) cycles").foregroundStyle(.secondary)
                                    if let p = b.percent { Text("Charge : \(p) %").foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)

                HStack(alignment: .top, spacing: 16) {
                    Card(title: String(localized: "Sécurité"), icon: "checkmark.shield") {
                        securityRow(String(localized: "Protection de l'intégrité (SIP)"), info.security.sip)
                        securityRow("Gatekeeper", info.security.gatekeeper)
                        securityRow(String(localized: "Chiffrement FileVault"), info.security.fileVault)
                        securityRow(String(localized: "Pare-feu"), info.security.firewall)
                        if !info.security.firewall || !info.security.fileVault {
                            Button("Ouvrir Confidentialité et sécurité") {
                                Permissions.openSettings("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
                            }
                        }
                    }
                    Card(title: String(localized: "Recommandations"), icon: "lightbulb") {
                        if advices.isEmpty {
                            Label("Tout est en ordre 👌", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        ForEach(advices) { a in
                            HStack(alignment: .top) {
                                Image(systemName: a.icon).foregroundStyle(a.color).frame(width: 20)
                                Text(a.text).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                if let t = a.target, let title = a.actionTitle {
                                    Button(title) { go(t) }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .redacted(reason: model.loaded ? [] : .placeholder)
        .onAppear { if !model.loaded { model.refresh() } }
    }

    private var smartScan: some View {
        Card {
            HStack(spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.pink.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Analyse intelligente").font(.headline)
                    if cleaner.scanning {
                        Text(cleaner.status).foregroundStyle(.secondary)
                    } else if cleaner.scannedOnce {
                        Text("\(formatBytes(cleaner.totalSize)) de fichiers inutiles détectés.").foregroundStyle(.secondary)
                    } else {
                        Text("Recherche les caches, journaux et fichiers superflus qui encombrent votre Mac.").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if cleaner.scanning {
                    ProgressView().controlSize(.small)
                } else if cleaner.scannedOnce {
                    Button("Voir et nettoyer") { go(.cleaner) }.buttonStyle(.borderedProminent)
                } else {
                    Button("Analyser") { cleaner.scan() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func securityRow(_ title: String, _ ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(title)
            Spacer()
            Text(ok ? "Activé" : "Désactivé").foregroundStyle(.secondary)
        }
    }

    private var uptimeText: String {
        let d = Int(info.uptime) / 86400, h = (Int(info.uptime) % 86400) / 3600, m = (Int(info.uptime) % 3600) / 60
        return d > 0 ? "\(d) j \(h) h" : "\(h) h \(m) min"
    }

    private var advices: [Advice] {
        guard model.loaded else { return [] }
        var a: [Advice] = []
        if info.diskTotal > 0 && Double(info.diskFree) / Double(info.diskTotal) < 0.15 {
            a.append(Advice(icon: "internaldrive", color: .red, text: String(localized: "Espace disque faible (moins de 15 % libre)."), actionTitle: String(localized: "Libérer"), target: .space))
        }
        if cleaner.scannedOnce && cleaner.totalSize > 1_000_000_000 {
            a.append(Advice(icon: "sparkles", color: .pink, text: String(localized: "\(formatBytes(cleaner.totalSize)) de fichiers inutiles peuvent être supprimés."), actionTitle: String(localized: "Nettoyer"), target: .cleaner))
        }
        if info.uptime > 7 * 86400 {
            a.append(Advice(icon: "restart", color: .orange, text: String(localized: "Votre Mac n'a pas redémarré depuis plus d'une semaine. Un redémarrage libère la mémoire et applique les mises à jour.")))
        }
        if info.memRatio > 0.85 {
            a.append(Advice(icon: "memorychip", color: .orange, text: String(localized: "La mémoire est très sollicitée."), actionTitle: String(localized: "Processus"), target: .processes))
        }
        if let m = info.battery?.maxCapacity, m < 80 {
            a.append(Advice(icon: "battery.25", color: .orange, text: String(localized: "Capacité maximale de la batterie à \(m) % : un remplacement peut être envisagé.")))
        }
        if permissions.states[.fullDisk] == .denied {
            a.append(Advice(icon: "lock", color: .yellow, text: String(localized: "Accordez l'« Accès complet au disque » pour une analyse plus complète."),
                            actionTitle: String(localized: "Autorisations"), target: .permissions))
        }
        return a
    }
}
