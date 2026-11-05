// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

// Décodage USB Power Delivery inspiré de WhatCable (MIT, © 2026 Darryl Morley).

struct PDIdentity {
    enum Endpoint: String { case partner = "Appareil / chargeur", cable = "Câble (côté Mac)", cableFar = "Câble (extrémité)" }
    let endpoint: Endpoint
    let port: Int
    let vendorID: Int
    let productID: Int
    let vdos: [UInt32]

    var header: UInt32? { vdos.first }
    /// Type de produit annoncé (bits 29..27 de l'en-tête d'identité).
    var ufpType: Int { Int(((header ?? 0) >> 27) & 0b111) }
    var isCable: Bool { ufpType == 3 || ufpType == 4 }
    var isActiveCable: Bool { ufpType == 4 }
    /// Identifiant de certification USB-IF (0 : non certifié).
    var xid: UInt32? { vdos.count > 1 ? vdos[1] : nil }
    var cableVDO: UInt32? { isCable && vdos.count > 3 ? vdos[3] : nil }

    var speed: String? {
        guard let v = cableVDO else { return nil }
        switch Int(v & 0b111) {
        case 0: return "USB 2.0 (480 Mb/s)"
        case 1: return "USB 3.2 Gen 1 (5 Gb/s)"
        case 2: return "USB 3.2 Gen 2 (10 Gb/s)"
        case 3: return "USB4 Gen 3 (40 Gb/s, classe Thunderbolt 4)"
        case 4: return "USB4 Gen 4 (80 Gb/s, classe Thunderbolt 5)"
        default: return "Inconnue"
        }
    }
    var isUSB2Only: Bool { cableVDO.map { $0 & 0b111 == 0 } ?? false }

    var maxAmps: Double? {
        guard let v = cableVDO else { return nil }
        return (v >> 5) & 0b11 == 2 ? 5 : 3
    }
    var maxVolts: Int? {
        guard let v = cableVDO else { return nil }
        return [20, 30, 40, 50][Int((v >> 9) & 0b11)]
    }
    var epr: Bool { cableVDO.map { ($0 >> 17) & 1 == 1 } ?? false }
    var maxWatts: Int? {
        guard let a = maxAmps, let v = maxVolts else { return nil }
        // Au-delà de 20 V, seule l'extension EPR (48 V) est utilisée en pratique.
        return Int(a * Double(epr ? min(v, 48) : 20))
    }

    var vendorName: String { PDIdentity.vendors[vendorID] ?? String(format: "Fabricant 0x%04X", vendorID) }

    static let vendors: [Int: String] = [
        0x05AC: "Apple", 0x291A: "Anker", 0x050D: "Belkin", 0x2B89: "UGREEN", 0x04E8: "Samsung", 0x18D1: "Google",
        0x0BDA: "Realtek", 0x2109: "VIA Labs", 0x1A86: "QinHeng", 0x8087: "Intel", 0x17EF: "Lenovo", 0x413C: "Dell",
        0x03F0: "HP", 0x045E: "Microsoft", 0x2D01: "Satechi", 0x2E8A: "Raspberry Pi", 0x1D5C: "Fresco Logic",
        0x0B05: "ASUS", 0x2717: "Xiaomi", 0x22B8: "Motorola", 0x0FCE: "Sony", 0x1004: "LG", 0x20A0: "Cable Matters",
        0x2537: "Norelsys", 0x315C: "CalDigit", 0x1E50: "OWC", 0x05E3: "Genesys Logic", 0x0451: "Texas Instruments",
        0x1D6B: "Linux Foundation", 0x2A70: "OnePlus", 0x0E8D: "MediaTek",
    ]
}

struct PowerOption: Identifiable {
    let id = UUID()
    let volts: Double
    let amps: Double
    let watts: Double
}

struct USBCPort: Identifiable {
    var id: Int { number }
    let number: Int
    let name: String
    let connected: Bool
    let transportsActive: [String]
    let transportsSupported: [String]
    let activeCable: Bool
    let opticalCable: Bool
    let superSpeed: Bool
    let connectionCount: Int?
    let plugEvents: Int?
    let overcurrent: Int?
    var identities: [PDIdentity] = []
    var powerOptions: [PowerOption] = []
    var negotiated: PowerOption?

    var cable: PDIdentity? { identities.first { $0.endpoint == .cable } ?? identities.first { $0.isCable } }
    var partner: PDIdentity? { identities.first { $0.endpoint == .partner && !$0.isCable } }
    var chargerMax: Double? { powerOptions.map(\.watts).max() }
}

struct USBDeviceInfo: Identifiable {
    let id = UUID()
    let name: String
    let vendor: String
    let speed: String
    let slow: Bool
}

final class PortsModel: ObservableObject {
    @Published var ports: [USBCPort] = []
    @Published var usb: [USBDeviceInfo] = []
    @Published var thunderbolt: [String] = []
    @Published var power = Sensors.Power()
    @Published var loaded = false
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ports = Self.readPorts()
            let usb = Self.readUSB()
            let p = Sensors.power()
            DispatchQueue.main.async {
                self.ports = ports
                self.usb = usb
                self.power = p
                self.loaded = true
            }
        }
        if thunderbolt.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                let tb = Self.readThunderbolt()
                DispatchQueue.main.async { self.thunderbolt = tb }
            }
        }
    }

    static func readPorts() -> [USBCPort] {
        let classes = ["AppleTCControllerType10", "AppleTCControllerType11", "AppleHPMInterfaceType10",
                       "AppleHPMInterfaceType11", "AppleHPMInterfaceType12", "AppleHPMInterfaceType18"]
        var ports: [USBCPort] = []
        for c in classes {
            for p in IORegistry.all(ofClass: c) {
                guard let n = IORegistry.int(p["PortNumber"]), !ports.contains(where: { $0.number == n }) else { continue }
                ports.append(USBCPort(
                    number: n,
                    name: (p["PortDescription"] as? String) ?? "Port USB-C \(n)",
                    connected: (p["ConnectionActive"] as? Bool) ?? false,
                    transportsActive: p["TransportsActive"] as? [String] ?? [],
                    transportsSupported: p["TransportsSupported"] as? [String] ?? [],
                    activeCable: (p["ActiveCable"] as? Bool) ?? false,
                    opticalCable: (p["OpticalCable"] as? Bool) ?? false,
                    superSpeed: (p["IOAccessoryUSBSuperSpeedActive"] as? Bool) ?? false,
                    connectionCount: IORegistry.int(p["ConnectionCount"]),
                    plugEvents: IORegistry.int(p["Plug Event Count"]),
                    overcurrent: IORegistry.int(p["Overcurrent Count"])))
            }
        }
        // Identités USB-PD : appareil (SOP), câble (SOP', SOP'')
        let sop: [(String, PDIdentity.Endpoint)] = [("IOPortTransportComponentCCUSBPDSOP", .partner),
                                                    ("IOPortTransportComponentCCUSBPDSOPp", .cable),
                                                    ("IOPortTransportComponentCCUSBPDSOPpp", .cableFar)]
        for (cls, ep) in sop {
            for p in IORegistry.all(ofClass: cls) {
                let port = IORegistry.int(p["ParentBuiltInPortNumber"]) ?? IORegistry.int(p["ParentPortNumber"]) ?? 0
                let meta = p["Metadata"] as? [String: Any] ?? [:]
                let vdos = ((meta["VDOs"] as? [Any]) ?? []).compactMap { v -> UInt32? in
                    if let d = v as? Data, d.count >= 4 { return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
                    return (v as? NSNumber)?.uint32Value
                }
                guard !vdos.isEmpty else { continue }
                let id = PDIdentity(endpoint: ep, port: port,
                                    vendorID: IORegistry.int(meta["Vendor ID"]) ?? IORegistry.int(p["Vendor ID"]) ?? Int(vdos[0] & 0xFFFF),
                                    productID: IORegistry.int(meta["Product ID"]) ?? IORegistry.int(p["Product ID"]) ?? 0,
                                    vdos: vdos)
                if let i = ports.firstIndex(where: { $0.number == port }) { ports[i].identities.append(id) }
            }
        }
        // Profils proposés par le chargeur et profil retenu
        for p in IORegistry.all(ofClass: "IOPortFeaturePowerSource") where (p["PowerSourceName"] as? String) == "USB-PD" {
            let port = IORegistry.int(p["ParentBuiltInPortNumber"]) ?? IORegistry.int(p["ParentPortNumber"]) ?? 0
            guard let i = ports.firstIndex(where: { $0.number == port }), ports[i].connected else { continue }
            func option(_ o: [String: Any]) -> PowerOption? {
                guard let mv = IORegistry.int(o["Voltage (mV)"]), let ma = IORegistry.int(o["Max Current (mA)"]) else { return nil }
                let mw = IORegistry.int(o["Max Power (mW)"]) ?? mv * ma / 1000
                return PowerOption(volts: Double(mv) / 1000, amps: Double(ma) / 1000, watts: Double(mw) / 1000)
            }
            ports[i].powerOptions = ((p["PowerSourceOptions"] as? [[String: Any]]) ?? []).compactMap(option)
            if let w = p["WinningPowerSourceOption"] as? [String: Any] { ports[i].negotiated = option(w) }
        }
        return ports.sorted { $0.number < $1.number }
    }

    static func readUSB() -> [USBDeviceInfo] {
        let speeds = ["Basse vitesse (1,5 Mb/s)", "Pleine vitesse (12 Mb/s)", "USB 2.0 (480 Mb/s)",
                      "USB 3 (5 Gb/s)", "USB 3 (10 Gb/s)", "USB 3 (20 Gb/s)"]
        return IORegistry.all(ofClass: "IOUSBHostDevice").compactMap { d in
            guard let name = d["USB Product Name"] as? String ?? d["kUSBProductString"] as? String else { return nil }
            let s = IORegistry.int(d["Device Speed"]) ?? -1
            let builtIn = (d["Built-In"] as? Bool) ?? false
            if builtIn { return nil }
            return USBDeviceInfo(name: name, vendor: d["USB Vendor Name"] as? String ?? d["kUSBVendorString"] as? String ?? "",
                                 speed: s >= 0 && s < speeds.count ? speeds[s] : "—", slow: s >= 0 && s <= 2)
        }
    }

    static func readThunderbolt() -> [String] {
        let out = Shell.exec("/usr/sbin/system_profiler", ["SPThunderboltDataType", "-json"]).output
        guard let data = out.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buses = o["SPThunderboltDataType"] as? [[String: Any]] else { return [] }
        var names: [String] = []
        func walk(_ items: [[String: Any]]) {
            for i in items {
                if let n = i["_name"] as? String, !(i["_name"] as? String ?? "").hasPrefix("thunderbolt_bus") {
                    let speed = (i["receptacle_upstream_ambiguous_tag"] as? [String: Any])?["current_speed_key"] as? String
                    names.append(n + (speed.map { " — \($0)" } ?? ""))
                }
                if let sub = i["_items"] as? [[String: Any]] { walk(sub) }
            }
        }
        for b in buses { walk(b["_items"] as? [[String: Any]] ?? []) }
        return names
    }

    /// Diagnostic en clair, à la manière de WhatCable.
    static func diagnosis(_ p: USBCPort, usb: [USBDeviceInfo]) -> [(String, Color, String)] {
        var out: [(String, Color, String)] = []
        guard p.connected else { return out }
        if let c = p.cable {
            if let w = c.maxWatts, let charger = p.chargerMax, charger > Double(w) + 1 {
                out.append(("exclamationmark.triangle.fill", .orange,
                            "Le câble est le maillon faible : il supporte \(w) W alors que le chargeur peut fournir \(Int(charger)) W."))
            }
            if c.isUSB2Only && p.transportsActive.contains("USB3") == false && !usb.isEmpty {
                out.append(("tortoise.fill", .orange, "Ce câble ne transporte que l'USB 2.0 (480 Mb/s) : les disques et docks seront lents."))
            }
            if c.xid == 0 {
                out.append(("questionmark.circle.fill", .secondary, "Câble non certifié USB-IF. Ce n'est pas forcément un mauvais câble, mais méfiance s'il chauffe."))
            }
        } else if !p.powerOptions.isEmpty || !p.transportsActive.isEmpty {
            out.append(("info.circle.fill", .secondary, "Câble sans puce e-marker : limité à 60 W (3 A) et généralement à l'USB 2.0 ou 3.x."))
        }
        if let n = p.negotiated, let max = p.chargerMax, n.watts + 1 < max {
            out.append(("bolt.fill", .secondary, String(format: "Le Mac a retenu %.0f W sur les %.0f W proposés (normal si la batterie est presque pleine).", n.watts, max)))
        }
        if let o = p.overcurrent, o > 0 {
            out.append(("bolt.trianglebadge.exclamationmark.fill", .red, "\(o) surintensité(s) détectée(s) sur ce port depuis le démarrage."))
        }
        if out.isEmpty { out.append(("checkmark.circle.fill", .green, "Aucune limitation détectée.")) }
        return out
    }
}

struct PortsView: View {
    @ObservedObject var model: PortsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Câbles & ports", subtitle: "Ce que vos câbles USB-C, chargeurs et accessoires savent vraiment faire",
                           icon: "cable.connector", color: .orange)
                Group {
                    if let w = model.power.inWatts {
                        Card {
                            HStack(spacing: 24) {
                                metric(String(format: "%.1f W", w), "Puissance reçue")
                                if let v = model.power.inVolts { metric(String(format: "%.2f V", v), "Tension") }
                                if let a = model.power.inAmps { metric(String(format: "%.2f A", a), "Courant") }
                                if let s = model.power.systemWatts { metric(String(format: "%.1f W", s), "Consommation du Mac") }
                                Spacer()
                                Text("Mesure en direct (2 s)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(model.ports) { portCard($0) }
                    if model.loaded && model.ports.isEmpty {
                        Card { Text("Aucun port USB-C lisible sur ce Mac (les Mac Intel exposent moins d'informations).").foregroundStyle(.secondary) }
                    }
                    Card(title: "Appareils USB branchés", icon: "externaldrive.connected.to.line.below") {
                        if model.usb.isEmpty { Text("Aucun appareil USB externe.").foregroundStyle(.secondary) }
                        ForEach(model.usb) { d in
                            HStack {
                                Text(d.name)
                                if !d.vendor.isEmpty { Text("· \(d.vendor)").foregroundStyle(.secondary) }
                                Spacer()
                                Text(d.speed).foregroundStyle(d.slow ? .orange : .secondary)
                            }
                        }
                    }
                    if !model.thunderbolt.isEmpty {
                        Card(title: "Thunderbolt / USB4", icon: "bolt.horizontal.fill") {
                            ForEach(model.thunderbolt, id: \.self) { Text($0) }
                        }
                    }
                    Text("Décodage USB Power Delivery inspiré de WhatCable (MIT, Darryl Morley). Les câbles sans puce e-marker ne transmettent aucune identité.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func portCard(_ p: USBCPort) -> some View {
        Card {
            HStack {
                Image(systemName: p.connected ? "cable.connector" : "circle.dashed").font(.title2)
                    .foregroundStyle(p.connected ? .orange : .secondary)
                VStack(alignment: .leading) {
                    Text(p.name.replacingOccurrences(of: "Port-USB-C@", with: "Port USB-C ")).font(.headline)
                    Text(p.connected ? "Branché · " + (p.transportsActive.isEmpty ? "alimentation seule" : p.transportsActive.map(transportName).joined(separator: ", "))
                                     : "Rien de branché")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let c = p.connectionCount { Text("\(c) branchements").font(.caption).foregroundStyle(.secondary) }
            }
            if p.connected {
                if let c = p.cable {
                    Divider()
                    Text("Câble").font(.subheadline.bold())
                    grid([("Fabricant", c.vendorName), ("Type", c.isActiveCable || p.activeCable ? (p.opticalCable ? "Actif optique" : "Actif") : "Passif"),
                          ("Données", c.speed ?? "—"), ("Puissance max", c.maxWatts.map { "\($0) W (\(Int(c.maxAmps ?? 3)) A\(c.epr ? ", EPR" : ""))" } ?? "—"),
                          ("Certification USB-IF", c.xid.map { $0 == 0 ? "Non certifié" : String(format: "XID %u", $0) } ?? "—")])
                }
                if let partner = p.partner {
                    Divider()
                    Text("Appareil connecté").font(.subheadline.bold())
                    grid([("Fabricant", partner.vendorName), ("Produit", String(format: "0x%04X", partner.productID))])
                }
                if !p.powerOptions.isEmpty {
                    Divider()
                    Text("Chargeur : profils proposés").font(.subheadline.bold())
                    HStack(spacing: 8) {
                        ForEach(p.powerOptions) { o in
                            let chosen = p.negotiated.map { abs($0.volts - o.volts) < 0.1 } ?? false
                            Text(String(format: "%.0f V · %.1f A · %.0f W", o.volts, o.amps, o.watts))
                                .font(.caption.monospacedDigit()).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(chosen ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.12)))
                        }
                    }
                }
                Divider()
                ForEach(Array(PortsModel.diagnosis(p, usb: model.usb).enumerated()), id: \.offset) { _, d in
                    Label(d.2, systemImage: d.0).foregroundStyle(d.1).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func transportName(_ t: String) -> String {
        switch t {
        case "CC": "USB-PD"
        case "USB2": "USB 2"
        case "USB3": "USB 3"
        case "CIO": "Thunderbolt/USB4"
        case "DisplayPort": "Écran (DisplayPort)"
        default: t
        }
    }

    private func grid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(rows, id: \.0) { r in
                GridRow { Text(r.0).foregroundStyle(.secondary); Text(r.1).textSelection(.enabled) }
            }
        }
    }

    private func metric(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading) {
            Text(v).font(.title2.bold().monospacedDigit())
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
    }
}
