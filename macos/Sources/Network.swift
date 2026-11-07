// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct DNSPreset: Identifiable {
    var id: String { name }
    let name: String
    let detail: String
    let servers: [String]    // vide : DNS automatique (fournisseur d'accès)

    static let all: [DNSPreset] = [
        DNSPreset(name: String(localized: "Automatique"), detail: String(localized: "DNS de votre box / fournisseur d'accès"), servers: []),
        DNSPreset(name: "Cloudflare", detail: String(localized: "Rapide et respectueux de la vie privée"), servers: ["1.1.1.1", "1.0.0.1"]),
        DNSPreset(name: String(localized: "Cloudflare Familles"), detail: String(localized: "Bloque les logiciels malveillants et contenus adultes"), servers: ["1.1.1.3", "1.0.0.3"]),
        DNSPreset(name: "Quad9", detail: String(localized: "Bloque les domaines malveillants"), servers: ["9.9.9.9", "149.112.112.112"]),
        DNSPreset(name: "Google", detail: String(localized: "Public DNS de Google"), servers: ["8.8.8.8", "8.8.4.4"]),
        DNSPreset(name: "AdGuard", detail: String(localized: "Bloque publicités et traqueurs"), servers: ["94.140.14.14", "94.140.15.15"]),
    ]
}

/// DNS, fichier hosts, adresses IP et test de débit (inspiré de SwitchHosts, des changeurs de DNS et de networkQuality).
final class NetworkModel: ObservableObject {
    @Published var services: [String] = []
    @Published var service = ""
    @Published var dns: [String] = []
    @Published var localIP = "—"
    @Published var publicIP: String?
    @Published var hosts = ""
    @Published var savedHosts = ""
    @Published var speed: String?
    @Published var testing = false
    @Published var message: String?
    @Published var loaded = false
    @Published var wifi: [(String, String)] = []

    var hostsDirty: Bool { hosts != savedHosts }

    func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Shell.exec("/usr/sbin/networksetup", ["-listallnetworkservices"]).output
                .components(separatedBy: "\n").dropFirst().filter { !$0.hasPrefix("*") && !$0.isEmpty }
            let iface = Shell.sh("route -n get default 2>/dev/null | awk '/interface:/{print $2}'").output
            let ip = iface.isEmpty ? "" : Shell.exec("/usr/sbin/ipconfig", ["getifaddr", iface]).output
            let hosts = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
            let wifi = Self.wifiInfo()
            DispatchQueue.main.async {
                self.services = Array(list)
                if self.service.isEmpty { self.service = list.first { $0 == "Wi-Fi" } ?? list.first ?? "" }
                self.localIP = ip.isEmpty ? "—" : "\(ip) (\(iface))"
                self.hosts = hosts
                self.savedHosts = hosts
                self.wifi = wifi
                self.loaded = true
                self.loadDNS()
            }
        }
    }

    /// Détails du Wi-Fi (équivalent de l'option-clic sur l'icône Wi-Fi).
    static func wifiInfo() -> [(String, String)] {
        let out = Shell.exec("/usr/sbin/system_profiler", ["SPAirPortDataType", "-json"]).output
        guard let d = out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let iface = ((o["SPAirPortDataType"] as? [[String: Any]])?.first?["spairport_airport_interfaces"] as? [[String: Any]])?.first,
              let c = iface["spairport_current_network_information"] as? [String: Any] else { return [] }
        var rows: [(String, String)] = []
        if let n = c["_name"] as? String { rows.append((String(localized: "Réseau"), n)) }
        if let s = c["spairport_signal_noise"] as? String {
            rows.append((String(localized: "Signal / bruit"), s))
            let nums = s.components(separatedBy: CharacterSet(charactersIn: "-0123456789").inverted).compactMap { Int($0) }
            if nums.count >= 2 {
                let snr = nums[0] - nums[1]
                rows.append((String(localized: "Qualité"), "\(snr) dB — " + (snr >= 40 ? String(localized: "excellente") : snr >= 25 ? String(localized: "bonne") : snr >= 15 ? String(localized: "moyenne") : String(localized: "faible"))))
            }
        }
        if let ch = c["spairport_network_channel"] as? String { rows.append((String(localized: "Canal"), ch)) }
        if let p = c["spairport_network_phymode"] as? String { rows.append((String(localized: "Norme"), p + (p.contains("ax") ? " (Wi-Fi 6)" : p.contains("be") ? " (Wi-Fi 7)" : p.contains("ac") ? " (Wi-Fi 5)" : ""))) }
        if let r = c["spairport_network_rate"] as? Int { rows.append((String(localized: "Débit négocié"), "\(r) Mb/s")) }
        if let sec = c["spairport_security_mode"] as? String {
            let open = sec.contains("none")
            rows.append((String(localized: "Sécurité"), open ? String(localized: "Aucune (réseau ouvert ⚠︎)") : sec.replacingOccurrences(of: "spairport_security_mode_", with: "").replacingOccurrences(of: "_", with: " ").uppercased()))
        }
        return rows
    }

    func loadDNS() {
        let svc = service
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Shell.exec("/usr/sbin/networksetup", ["-getdnsservers", svc]).output
            let servers = out.contains(" ") ? [] : out.components(separatedBy: "\n").filter { !$0.isEmpty }
            DispatchQueue.main.async { self.dns = servers }
        }
    }

    var currentPreset: String? {
        DNSPreset.all.first { $0.servers == dns }?.name
    }

    func apply(_ p: DNSPreset) {
        let svc = service
        DispatchQueue.global(qos: .userInitiated).async {
            let servers = p.servers.isEmpty ? "Empty" : p.servers.joined(separator: " ")
            let r = Shell.admin("networksetup -setdnsservers \(Shell.quote(svc)) \(servers) && dscacheutil -flushcache; killall -HUP mDNSResponder; true")
            DispatchQueue.main.async {
                self.message = r.ok ? String(localized: "DNS « \(p.name) » appliqué sur \(svc).") : String(localized: "Annulé.")
                self.loadDNS()
            }
        }
    }

    func fetchPublicIP() {
        publicIP = "…"
        URLSession.shared.dataTask(with: URL(string: "https://api.ipify.org")!) { data, _, _ in
            let ip = data.map { String(decoding: $0, as: UTF8.self) } ?? "indisponible"
            DispatchQueue.main.async { self.publicIP = ip }
        }.resume()
    }

    func speedTest() {
        testing = true
        speed = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Shell.exec("/usr/bin/networkQuality", ["-c"])
            var text = r.output
            if let d = r.output.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                func mbps(_ k: String) -> String {
                    (j[k] as? Double).map { String(format: "%.0f Mb/s", $0 / 1_000_000) } ?? "—"
                }
                let rpm = (j["responsiveness"] as? Double) ?? (j["dl_responsiveness"] as? Double)
                text = "↓ \(mbps("dl_throughput"))   ↑ \(mbps("ul_throughput"))"
                if let rpm { text += String(localized: "   Réactivité : \(Int(rpm)) RPM") }
            }
            DispatchQueue.main.async {
                self.speed = r.ok ? text : String(localized: "Échec du test : \(r.output)")
                self.testing = false
            }
        }
    }

    func blockSite(_ domain: String) {
        let d = domain.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/").first ?? ""
        // Nom de domaine uniquement : empêche d'injecter d'autres lignes dans /etc/hosts.
        guard !d.isEmpty, d.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }), d.contains(".") else {
            message = String(localized: "« \(domain) » n'est pas un nom de domaine valide (ex. : exemple.com).")
            return
        }
        let bare = d.hasPrefix("www.") ? String(d.dropFirst(4)) : d
        if !hosts.hasSuffix("\n") { hosts += "\n" }
        hosts += "0.0.0.0 \(bare)\n0.0.0.0 www.\(bare)\n"
        saveHosts()
    }

    func saveHosts() {
        let content = hosts
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FS.fm.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString)")
            defer { try? FS.fm.removeItem(at: tmp) }
            guard FS.fm.createFile(atPath: tmp.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600]) else { return }
            let r = Shell.admin("[ -f /etc/hosts.boiteaoutils.bak ] || cp /etc/hosts /etc/hosts.boiteaoutils.bak; cp \(Shell.quote(tmp.path)) /etc/hosts && chmod 644 /etc/hosts && dscacheutil -flushcache; killall -HUP mDNSResponder; true")
            DispatchQueue.main.async {
                if r.ok {
                    self.savedHosts = content
                    self.message = String(localized: "Fichier hosts enregistré (sauvegarde d'origine : /etc/hosts.boiteaoutils.bak).")
                } else {
                    self.message = String(localized: "Enregistrement annulé.")
                }
            }
        }
    }
}

struct NetworkView: View {
    @ObservedObject var model: NetworkModel
    @Local private var blockDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Réseau"), subtitle: String(localized: "DNS, blocage de sites, adresses IP et test de débit"),
                       icon: "network", color: .blue) {
                Button { model.load() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
            }
            if let m = model.message {
                Label(m, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            Form {
                Section("Connexion") {
                    LabeledContent("Adresse IP locale", value: model.localIP)
                    LabeledContent("Adresse IP publique") {
                        HStack {
                            Text(model.publicIP ?? "—").textSelection(.enabled)
                            Button("Afficher") { model.fetchPublicIP() }
                        }
                    }
                    LabeledContent("Débit (Apple networkQuality)") {
                        HStack {
                            if model.testing {
                                ProgressView().controlSize(.small)
                                Text("Test en cours (~20 s)…").foregroundStyle(.secondary)
                            } else if let s = model.speed {
                                Text(s).monospacedDigit()
                            }
                            Button("Tester") { model.speedTest() }.disabled(model.testing)
                        }
                    }
                }

                if !model.wifi.isEmpty {
                    Section {
                        ForEach(model.wifi, id: \.0) { LabeledContent($0.0, value: $0.1) }
                        Button("Ouvrir Diagnostic sans fil") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Wireless Diagnostics.app"))
                        }
                    } header: {
                        Text("Wi-Fi")
                    }
                }

                Section {
                    Picker("Interface", selection: $model.service) {
                        ForEach(model.services, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: model.service) { _, _ in model.loadDNS() }
                    LabeledContent("DNS actuels", value: model.dns.isEmpty ? String(localized: "Automatique") : model.dns.joined(separator: ", "))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                        ForEach(DNSPreset.all) { p in
                            Button { model.apply(p) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(p.name).bold()
                                        if model.currentPreset == p.name { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                    }
                                    Text(p.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                        }
                    }
                } header: {
                    Text("Serveurs DNS")
                } footer: {
                    Text("Changer de DNS peut accélérer la navigation ou bloquer publicités et sites malveillants. Mot de passe administrateur requis.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        TextField("Bloquer un site (ex. : facebook.com)", text: $blockDraft)
                        Button("Bloquer") { model.blockSite(blockDraft); blockDraft = "" }.disabled(blockDraft.isEmpty)
                    }
                    TextEditor(text: $model.hosts)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 180)
                    HStack {
                        Spacer()
                        Button("Annuler les modifications") { model.hosts = model.savedHosts }.disabled(!model.hostsDirty)
                        Button("Enregistrer") { model.saveHosts() }.buttonStyle(.borderedProminent).disabled(!model.hostsDirty)
                    }
                } header: {
                    Text("Fichier hosts (/etc/hosts)")
                } footer: {
                    Text("Chaque ligne « 0.0.0.0 domaine » bloque ce domaine sur tout le Mac. Une copie d'origine est conservée au premier enregistrement.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(!model.loaded)
        }
        .onAppear { if !model.loaded { model.load() } }
    }
}
