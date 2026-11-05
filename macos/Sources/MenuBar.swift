// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI
import IOKit.ps

/// Mesures légères pour la barre des menus (inspiré de Stats), lues directement via Mach/IOKit.
final class SystemMonitor: ObservableObject {
    @Published var cpu: Double = 0
    @Published var memUsed: Int64 = 0
    @Published var memTotal = Int64(ProcessInfo.processInfo.physicalMemory)
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var netIn: Double = 0      // octets/s
    @Published var netOut: Double = 0
    @Published var battery: Int?
    @Published var charging = false
    @Published var gpu: Double?
    @Published var hottest: Double?

    private var timer: Timer?
    private var prevTicks: [UInt32]?
    private var prevNet: [String: (UInt32, UInt32)] = [:]
    private var prevNetDate = Date()

    var memRatio: Double { Double(memUsed) / Double(max(memTotal, 1)) }
    var diskRatio: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }

    init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    }

    private func sample() {
        cpu = readCPU()
        memUsed = readMemory()
        readNetwork()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            diskTotal = Int64(v.volumeTotalCapacity ?? 0)
            diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
        }
        readBattery()
        gpu = GPU.utilization
        hottest = Sensors.readAll().filter { $0.group.hasPrefix("Processeur") }.map(\.value).max()
    }

    private func readCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return cpu }
        let t = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]   // user, system, idle, nice
        defer { prevTicks = t }
        guard let p = prevTicks else { return 0 }
        let d = zip(t, p).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? (total - d[2]) / total * 100 : 0
    }

    private func readMemory() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return memUsed }
        let pages = Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return pages * Int64(vm_kernel_page_size)
    }

    private func readNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        var current: [String: (UInt32, UInt32)] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = ptr.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data else { continue }
            let name = String(cString: a.ifa_name)
            if name.hasPrefix("lo") { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        let now = Date()
        let dt = now.timeIntervalSince(prevNetDate)
        if !prevNet.isEmpty && dt > 0 {
            var i: UInt64 = 0, o: UInt64 = 0
            for (k, v) in current {
                guard let p = prevNet[k] else { continue }
                i += UInt64(v.0 &- p.0)     // compteurs 32 bits : &- gère le débordement
                o += UInt64(v.1 &- p.1)
            }
            netIn = Double(i) / dt
            netOut = Double(o) / dt
        }
        prevNet = current
        prevNetDate = now
    }

    private func readBattery() {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        for s in sources {
            guard let d = IOPSGetPowerSourceDescription(blob, s)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                battery = cur * 100 / max
            }
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
        }
    }
}

func formatRate(_ bps: Double) -> String {
    bps < 1_000 ? "\(Int(bps)) o/s" : ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
}

struct MenuBarLabel: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var awake = KeepAwake.shared
    @ObservedObject var security = SecurityMonitor.shared
    var body: some View {
        Text("\(security.cameraOn || security.micOn ? "🔴 " : "")\(awake.active ? "☕︎ " : "")CPU \(Int(monitor.cpu)) %  RAM \(Int(monitor.memRatio * 100)) %").monospacedDigit()
    }
}

struct MenuBarPanel: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var awake = KeepAwake.shared
    @ObservedObject var clipboard = ClipboardHistory.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Boîte à outils").font(.headline)
            meter("Processeur", "cpu", monitor.cpu / 100, "\(Int(monitor.cpu)) %", .purple)
            if let g = monitor.gpu { meter("GPU", "cpu.fill", g / 100, "\(Int(g)) %", .orange) }
            if let t = monitor.hottest {
                HStack {
                    Label("Température processeur", systemImage: "thermometer.medium")
                    Spacer()
                    Text(String(format: "%.0f °C", t)).monospacedDigit().foregroundStyle(t > 85 ? .red : .secondary)
                }
            }
            meter("Mémoire", "memorychip", monitor.memRatio, "\(formatBytes(monitor.memUsed)) / \(formatBytes(monitor.memTotal))", .green)
            meter("Disque", "internaldrive", monitor.diskRatio, "\(formatBytes(monitor.diskFree)) libres", .indigo)
            HStack {
                Label("Réseau", systemImage: "network")
                Spacer()
                Text("↓ \(formatRate(monitor.netIn))   ↑ \(formatRate(monitor.netOut))").monospacedDigit().foregroundStyle(.secondary)
            }
            if let b = monitor.battery {
                meter("Batterie", monitor.charging ? "battery.100.bolt" : "battery.75", Double(b) / 100,
                      "\(b) %\(monitor.charging ? " · en charge" : "")", b < 20 ? .red : .green)
            }
            Divider()
            HStack {
                Menu {
                    if awake.active { Button("Arrêter") { awake.stop() } }
                    ForEach(KeepAwake.durations, id: \.0) { d in Button(d.0) { awake.start(minutes: d.1) } }
                } label: {
                    Label(awake.active ? "Éveillé" : "Garder éveillé", systemImage: awake.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                }
                .fixedSize()
                Button { DispatchQueue.global().async { Mac.setDark(!Mac.isDark) } } label: { Label("Sombre / clair", systemImage: "circle.lefthalf.filled") }
            }
            .controlSize(.small)
            if !clipboard.items.isEmpty {
                Text("Copié récemment").font(.caption).foregroundStyle(.secondary)
                ForEach(clipboard.items.prefix(5)) { item in
                    Button { clipboard.copy(item) } label: {
                        Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Cliquer pour recopier")
                }
            }
            Divider()
            HStack {
                Button("Ouvrir la Boîte à outils") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Libérer la RAM") { DispatchQueue.global().async { Shell.admin("purge") } }
                Button("Quitter") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func meter(_ title: String, _ icon: String, _ value: Double, _ text: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(value, 0), 1)).tint(color)
        }
    }
}
