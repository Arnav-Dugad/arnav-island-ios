import Charts
import IslandKit
import SwiftUI

/// A question asked before something that can't be taken back (restart, shut down, empty the bin).
struct Confirm: Identifiable { let id = UUID(); let title: String; let detail: String; let action: String; let danger: Bool; let run: () -> Void }

/// Everything on your PC's island, from here (island 0.22): its numbers live, its battery, its controls, the focus clock,
/// its command bar, power, where its sound goes, its pages on the PC and every one of its settings. Asked once a second
/// while this shows; anything changed here shows at once and then follows what the PC says.
struct IslandScreen: View {
    let shown: Bool
    var onPair: () -> Void; var onSettings: (Int) -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @Environment(\.scenePhase) private var phase
    @State private var statsOpen = false
    @State private var confirm: Confirm?

    var body: some View {
        let pc = hub.pc(); let pcs = hub.pairedPCs
        VStack(spacing: 0) {
            ScreenTitle(title: "Island", over: pc.map { $0.online ? "\($0.name)  ·  \(Quality.of($0, t).text.lowercased())" : "\($0.name)  ·  away" } ?? "No PC yet") { if let pc { LiveDot(on: pc.online) } }
            if let pc, pcs.count > 1 { StatsCarousel(pcs: pcs, pc: pc) { statsOpen = true } }
            if let pc {
                if !pc.online { EmptyCard(symbol: "icloud.slash", title: "\(pc.name) is away", detail: "Its island shows here again as soon as it’s back.") }
                else if pc.revision < 5 { EmptyCard(symbol: "arrow.down.app", title: "Update Arnav Island on \(pc.name)", detail: "Version 0.22 or later lets this iPhone control everything on its island.") }
                else {
                    if pcs.count <= 1 { StatsPanel(stats: hub.pcStats, live: true) { statsOpen = true }.arrive(0) }
                    if let b = hub.pcBattery, b.present { SectionLabel(text: "Battery"); BatteryPanel(b: b).arrive(1) }
                    SectionLabel(text: "Controls"); ControlsPanel(c: hub.pcControls).arrive(2)
                    SectionLabel(text: "Focus"); FocusPanel(c: hub.pcControls).arrive(3)
                    SectionLabel(text: "Run on \(pc.name)"); CommandPanel(pcName: pc.name) { confirm = $0 }.arrive(4)
                    SectionLabel(text: "Power"); PowerPanel(pcName: pc.name) { confirm = $0 }.arrive(5)
                    if !hub.outputs.isEmpty { SectionLabel(text: "Sound comes from"); OutputsPanel().arrive(6) }
                    SectionLabel(text: "Show on \(pc.name)"); PagesPanel().arrive(7)
                    SectionLabel(text: "Island settings"); SettingsPanel(onOpen: onSettings).arrive(8)
                }
            } else {
                EmptyCard(symbol: "laptopcomputer", title: "Pair with your PC", detail: "Then everything on its island is here: its numbers, its controls, its settings.") {
                    GlassButton(prominent: true, action: onPair) { Text("Pair").font(TypeScale.bodyStrong) }
                }
            }
        }
        .task(id: "\(pc?.id ?? "")|\(hub.islandReady(pc))|\(shown)|\(phase == .active)") {
            guard hub.islandReady(pc), shown, phase == .active else { return }
            await hub.loadOutputs(); if hub.islandSettings == nil { await hub.loadIslandSettings() }
            var n = 0
            while !Task.isCancelled {
                await hub.refreshIsland(withStats: true)
                n += 1; if n % 10 == 0 { await hub.loadOutputs() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(isPresented: $statsOpen) { StatsSheet().environment(hub).environment(\.tokens, t).presentationDetents([.large]).presentationDragIndicator(.visible) }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { c in
            Button(c.action, role: c.danger ? .destructive : nil) { Haptics.thud(); c.run() }
            Button("Cancel", role: .cancel) {}
        } message: { c in Text(c.detail) }
    }
}

// ---- stats ----
/// With more than one PC, their numbers side by side in a carousel: settle on another and the rest follows it.
struct StatsCarousel: View {
    let pcs: [PeerView]; let pc: PeerView; var onOpen: () -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @State private var shown: String?
    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pcs) { p in
                        let live = p.id == pc.id
                        StatsPanel(stats: live ? hub.pcStats : hub.cachedStats(p.id), live: live && p.online, title: p.name, away: !p.online) { if live { onOpen() } }
                            .padding(.horizontal, 2).containerRelativeFrame(.horizontal).id(p.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging).scrollIndicators(.hidden).scrollClipDisabled()
            .scrollPosition(id: $shown)
            .onAppear { shown = pc.id }
            .onChange(of: shown) { _, s in if let s, s != pc.id { Haptics.tick(); hub.choose(s) } }
            HStack(spacing: 6) { ForEach(pcs) { p in Capsule().fill(p.id == (shown ?? pc.id) ? t.accent : t.faint.opacity(0.5)).frame(width: p.id == (shown ?? pc.id) ? 18 : 6, height: 6).animation(.spring(response: 0.35), value: shown) } }
        }
        .padding(.bottom, 4)
    }
}

/// The PC's numbers: its rings, a flowing graph of the processor and a bar for each core. The card warms when the processor
/// has worked hard for half a minute.
struct StatsPanel: View {
    let stats: PcStats?; let live: Bool; var title: String? = nil; var away = false
    var onOpen: () -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    private static let hot = Color(hex: 0xFF8A3D)
    var body: some View {
        let heat: Double = {
            guard live else { return 0 }
            let cpu = hub.statsTrail.suffix(30).map(\.cpu).filter { $0 >= 0 }; guard cpu.count >= 10 else { return 0 }
            return max(0, min(1, (cpu.reduce(0, +) / Double(cpu.count) - 55) / 35))
        }()
        let cpuColor = t.accent.mixed(with: Self.hot, by: heat)
        Button(action: { Haptics.tap(); onOpen() }) {
            VStack(spacing: 0) {
                if let title {
                    HStack { Text(title).font(TypeScale.bodyStrong).foregroundStyle(t.text).lineLimit(1); Spacer(); Text(away ? "AWAY" : live ? "LIVE" : "SWIPE TO SEE IT LIVE").font(TypeScale.micro).foregroundStyle(live && !away ? t.good : t.muted) }.padding(.bottom, 10)
                }
                HStack {
                    Gauge(label: "CPU", value: stats?.cpu ?? -1, color: cpuColor); Spacer()
                    Gauge(label: "GPU", value: stats?.gpu ?? -1, color: t.accent2); Spacer()
                    Gauge(label: "Memory", value: stats?.ramPercent ?? -1, color: t.good)
                }
                .padding(.horizontal, 6)
                if heat > 0.5 { Text("Working hard: \(Int(stats?.cpu ?? 0))% for the last half minute").font(TypeScale.caption).foregroundStyle(Self.hot).padding(.top, 8) }
                FlowGraph(samples: stats?.cpuHistory ?? [], color: cpuColor, top: 100).frame(height: 46).padding(.top, 14)
                if let cores = stats?.cores, !cores.isEmpty { CoreBars(cores: cores, color: cpuColor, live: live).padding(.top, 12) }
                HStack {
                    rate("arrow.down", stats?.download); Spacer(); rate("arrow.up", stats?.upload); Spacer()
                    HStack(spacing: 2) { Text("More"); Image(systemName: "chevron.right") }.font(TypeScale.caption).foregroundStyle(t.muted)
                }
                .padding(.top, 12)
            }
            .padding(18).opacity(away ? 0.5 : 1)
            .background { if heat > 0.01 { RadialGradient(colors: [Self.hot.opacity(0.35 * heat), .clear], center: .top, startRadius: 0, endRadius: 320).allowsHitTesting(false) } }
            .glassCard()
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .accessibilityLabel("\(title.map { $0 + ": " } ?? "")Your PC's numbers. Tap for more")
    }
    private func rate(_ symbol: String, _ bytes: Double?) -> some View {
        HStack(spacing: 6) { Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(t.accent); Text(bytes.map(rateText) ?? "—").font(TypeScale.bodyStrong.monospacedDigit()).foregroundStyle(t.text).contentTransition(.numericText()) }
    }
}

struct Gauge: View {
    let label: String; let value: Double; let color: Color; var size: CGFloat = 86
    @Environment(\.tokens) private var t
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                ProgressRing(fraction: value >= 0 ? value / 100 : 0, color: color, size: size, stroke: 6)
                Text(value >= 0 ? "\(Int(value.rounded()))%" : "—").font(TypeScale.headline.monospacedDigit()).foregroundStyle(value >= 0 ? t.text : t.faint).contentTransition(.numericText(value: value))
                    .animation(.snappy, value: Int(value))
            }
            Text(label).font(TypeScale.caption).foregroundStyle(t.muted)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(value >= 0 ? "\(label) \(Int(value)) percent" : "\(label) unknown")
    }
}

/// A graph of the last samples that flows as new ones arrive (Swift Charts, smoothed).
struct FlowGraph: View {
    let samples: [Double]; let color: Color; var top: Double? = nil
    var body: some View {
        let known = samples.map { max(0, $0) }
        Chart {
            ForEach(Array(known.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("t", i), y: .value("v", v)).foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.catmullRom)
                LineMark(x: .value("t", i), y: .value("v", v)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round)).interpolationMethod(.catmullRom)
            }
            if let last = known.last { PointMark(x: .value("t", known.count - 1), y: .value("v", last)).foregroundStyle(color).symbolSize(40) }
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .chartYScale(domain: 0...(top ?? max(1, (known.max() ?? 1) * 1.15)))
        .chartXScale(domain: 0...max(1, known.count - 1))
        .animation(.easeOut(duration: 0.45), value: known)
        .accessibilityHidden(true)
    }
}

/// A bar for each core, its height its load; a busy core (70% or more) shimmers.
struct CoreBars: View {
    let cores: [Double]; let color: Color; let live: Bool
    @Environment(\.tokens) private var t
    var body: some View {
        VStack(spacing: 4) {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !live || !cores.contains { $0 >= 70 })) { ctx in
                let time = ctx.date.timeIntervalSinceReferenceDate
                HStack(alignment: .bottom, spacing: cores.count > 24 ? 2 : 3) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                        let f = max(0, v) / 100
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(t.track)
                            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.55 + 0.45 * f)).frame(height: max(2, 30 * f))
                                .overlay { if live && f >= 0.7 { RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.25 * (0.5 + 0.5 * sin(time * 6 - Double(i) * 0.6)))) } }
                        }
                        .frame(height: 30)
                    }
                }
                .animation(.easeOut(duration: 0.4), value: cores)
            }
            HStack { Text("\(cores.count) cores"); Spacer(); let busy = cores.filter { $0 >= 70 }.count; if busy > 0 { Text("\(busy) busy") } }.font(TypeScale.micro).foregroundStyle(t.muted)
        }
        .accessibilityElement().accessibilityLabel("\(cores.count) cores")
    }
}

/// The PC's battery (island 0.23): its level, charging and for how long, the power going in or out, its health and its last day.
struct BatteryPanel: View {
    let b: PcBattery
    @Environment(\.tokens) private var t
    var body: some View {
        let colour = b.charging ? t.good : b.percent >= 0 && b.percent <= 20 ? t.danger : t.accent
        let watts = abs(Double(b.rateMw)) / 1000
        GlassPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    ZStack {
                        ProgressRing(fraction: b.percent >= 0 ? Double(b.percent) / 100 : 0, color: colour, size: 92, stroke: 7)
                        VStack(spacing: 0) {
                            Text(b.percent >= 0 ? "\(b.percent)%" : "—").font(TypeScale.headline.monospacedDigit()).foregroundStyle(t.text).contentTransition(.numericText(value: Double(b.percent)))
                            if b.charging { Image(systemName: "bolt.fill").font(.system(size: 13)).foregroundStyle(t.good).symbolEffect(.pulse) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.charging && b.minutesToFull > 0 ? "Full in \(span(Double(b.minutesToFull * 60)))" : b.charging ? "Charging" : b.online ? "On power" : b.minutesLeft > 0 ? "\(span(Double(b.minutesLeft * 60))) left" : "On battery")
                            .font(TypeScale.headline).foregroundStyle(t.text)
                        if watts > 0.05 { Text(b.rateMw > 0 ? String(format: "%.1f W going in", watts) : String(format: "Using %.1f W", watts)).font(TypeScale.caption).foregroundStyle(t.muted) }
                        if b.saver { Text("Battery saver is on").font(TypeScale.caption).foregroundStyle(t.warn) }
                    }
                    Spacer(minLength: 0)
                }
                if b.day.count >= 2 { BatteryDay(day: b.day).padding(.top, 14) }
                FlowChips(items: facts).padding(.top, 10)
            }
        }
    }
    private var facts: [String] {
        var f: [String] = []
        if b.health >= 0 { var s = "Health \(Int((b.health * 100).rounded()))%"; if b.healthBefore >= 0 && abs(b.health - b.healthBefore) >= 0.0005 { s += String(format: ", %@%.1f this week", b.health >= b.healthBefore ? "+" : "−", abs(b.health - b.healthBefore) * 100) }; f.append(s) }
        if b.cycles > 0 { f.append("\(b.cycles) cycles") }
        if b.temperatureDeciK > 0 { f.append(String(format: "%.1f°C", Double(b.temperatureDeciK) / 10 - 273.15)) }
        if b.fullMwh > 0 { f.append(String(format: "%.1f of %.1f Wh", Double(b.remainingMwh) / 1000, Double(b.fullMwh) / 1000)) }
        if b.voltageMv > 0 { f.append(String(format: "%.2f V", Double(b.voltageMv) / 1000)) }
        let who = [b.manufacturer, b.name].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " "); if !who.isEmpty { f.append(who) }
        return f
    }
}
/// The battery over the last day, charging stretches in green; touch it to read any moment.
struct BatteryDay: View {
    let day: [BatteryPoint]
    @Environment(\.tokens) private var t
    @State private var picked: Date?
    var body: some View {
        let points = day.map { (Date(timeIntervalSince1970: Double($0.at)), $0.percent, $0.charging) }
        VStack(spacing: 2) {
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("When", p.0), y: .value("Battery", p.1)).foregroundStyle(LinearGradient(colors: [t.accent.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.monotone)
                    LineMark(x: .value("When", p.0), y: .value("Battery", p.1)).foregroundStyle(p.2 ? t.good : t.accent).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                }
                if let picked, let near = points.min(by: { abs($0.0.timeIntervalSince(picked)) < abs($1.0.timeIntervalSince(picked)) }) {
                    RuleMark(x: .value("When", near.0)).foregroundStyle(t.text.opacity(0.3))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) { Text("\(near.1)%  ·  \(near.0.formatted(date: .omitted, time: .shortened))").font(TypeScale.micro).padding(.horizontal, 8).padding(.vertical, 4).glassCapsule(interactive: false) }
                }
            }
            .chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden)
            .chartXSelection(value: $picked)
            .onChange(of: picked) { _, _ in Haptics.tick() }
            .frame(height: 54)
            HStack { Text("A day ago"); Spacer(); Text("Now") }.font(TypeScale.micro).foregroundStyle(t.faint)
        }
        .accessibilityLabel("The battery over the last day")
    }
}

/// Chips that wrap onto more lines.
struct FlowChips: View {
    let items: [String]
    var body: some View { WrapLayout(spacing: 6) { ForEach(items, id: \.self) { GlassChip(label: $0) } } }
}
struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity; var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews { let z = s.sizeThatFits(.unspecified); if x > 0 && x + z.width > w { y += row + spacing; x = 0; row = 0 }; x += z.width + spacing; row = max(row, z.height); widest = max(widest, x) }
        return CGSize(width: min(w, widest), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews { let z = s.sizeThatFits(.unspecified); if x > bounds.minX && x + z.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }; s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z)); x += z.width + spacing; row = max(row, z.height) }
    }
}

/// The PC's numbers in full: live graphs for the processor, graphics and network (scrub them to read any moment), and what the PC is.
struct StatsSheet: View {
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    var body: some View {
        ScrollView {
            if let s = hub.pcStats {
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.name.isEmpty ? "Your PC" : s.name).font(TypeScale.title).foregroundStyle(t.text)
                    if !s.model.isEmpty { Text(s.model).font(TypeScale.caption).foregroundStyle(t.muted) }
                    BigGraph(title: "Processor", now: s.cpu >= 0 ? "\(Int(s.cpu))%" : "—", series: series(\.cpu, s.cpuHistory), color: t.accent, percent: true, detail: s.cpuName.isEmpty ? nil : "\(s.cpuName)  ·  \(s.logical) threads").padding(.top, 8)
                    BigGraph(title: "Graphics", now: s.gpu >= 0 ? "\(Int(s.gpu))%" : "—", series: series(\.gpu, s.gpuHistory), color: t.accent2, percent: true, detail: s.gpuName.isEmpty ? nil : s.gpuName)
                    BigGraph(title: "Downloading", now: rateText(s.download), series: series(\.download, s.downloadHistory), color: t.good, percent: false, detail: "Sending \(rateText(s.upload))")
                    GlassPanel(padding: 0) {
                        VStack(spacing: 0) {
                            fact("memorychip", "Memory", String(format: "%.1f of %.1f GB  ·  %d%%", s.ramUsedGiB, s.ramTotalGiB, Int(s.ramPercent)))
                            if s.diskUsedPercent >= 0 { Divider().overlay(t.hairline); fact("internaldrive", "Disk", "\(Int(s.diskFreeGiB)) GB free of \(Int(s.diskTotalGiB)) GB") }
                            if s.battery >= 0 { Divider().overlay(t.hairline); fact(s.charging ? "battery.100percent.bolt" : "battery.75percent", "Battery", "\(s.battery)%" + (s.charging ? "  ·  charging" : s.batteryMinutes > 0 ? "  ·  \(span(s.batteryMinutes * 60)) left" : "")) }
                            Divider().overlay(t.hairline); fact("timer", "On for", span(Double(s.uptime)))
                            if !s.os.isEmpty { Divider().overlay(t.hairline); fact("pc", "Windows", s.os) }
                        }
                    }
                }
                .padding(20)
            }
        }
        .presentationBackground(.clear)
        .background(Ambient(playing: false, still: true))
    }
    private func series(_ pick: KeyPath<StatsPoint, Double>, _ history: [Double]) -> [(Date, Double)] {
        let trail = hub.statsTrail
        if trail.count >= history.count && trail.count >= 10 { return trail.map { ($0.at, $0[keyPath: pick]) } }
        let now = Date(); return history.enumerated().map { (now.addingTimeInterval(-Double(history.count - 1 - $0.offset)), $0.element) }
    }
    private func fact(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 12) { Image(systemName: symbol).foregroundStyle(t.accent).frame(width: 24); Text(title).font(TypeScale.body).foregroundStyle(t.text); Spacer(); Text(value).font(TypeScale.caption).foregroundStyle(t.muted).multilineTextAlignment(.trailing) }
            .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
struct BigGraph: View {
    let title: String; let now: String; let series: [(Date, Double)]; let color: Color; let percent: Bool; let detail: String?
    @Environment(\.tokens) private var t
    @State private var picked: Date?
    var body: some View {
        let values = series.map { max(0, $0.1) }
        let scale: Double = percent ? ([10, 25, 50, 75, 100].first { $0 >= min(100, (values.max() ?? 0) * 1.15) } ?? 100) : max(1, (values.max() ?? 1) * 1.15)
        GlassPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .lastTextBaseline) { Text(title).font(TypeScale.bodyStrong).foregroundStyle(t.text); Spacer(); Text(now).font(TypeScale.headline.monospacedDigit()).foregroundStyle(color).contentTransition(.numericText()) }
                if let detail { Text(detail).font(TypeScale.caption).foregroundStyle(t.muted).lineLimit(2) }
                Chart {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("When", p.0), y: .value(title, max(0, p.1))).foregroundStyle(LinearGradient(colors: [color.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.catmullRom)
                        LineMark(x: .value("When", p.0), y: .value(title, max(0, p.1))).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.catmullRom)
                    }
                    if let picked, let near = series.min(by: { abs($0.0.timeIntervalSince(picked)) < abs($1.0.timeIntervalSince(picked)) }) {
                        RuleMark(x: .value("When", near.0)).foregroundStyle(t.text.opacity(0.35))
                        PointMark(x: .value("When", near.0), y: .value(title, max(0, near.1))).foregroundStyle(color).symbolSize(70)
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                let ago = Int(Date().timeIntervalSince(near.0))
                                Text("\(percent ? "\(Int(near.1))%" : rateText(near.1))  ·  \(ago < 2 ? "now" : ago < 90 ? "\(ago) s ago" : "\(ago / 60) min ago")").font(TypeScale.micro).padding(.horizontal, 8).padding(.vertical, 4).glassCapsule(interactive: false)
                            }
                    }
                }
                .chartYScale(domain: 0...scale).chartXAxis(.hidden)
                .chartYAxis { AxisMarks(position: .trailing, values: [scale]) { _ in AxisValueLabel { Text(percent ? "\(Int(scale))%" : "").font(TypeScale.micro).foregroundStyle(t.faint) } } }
                .chartXSelection(value: $picked)
                .onChange(of: picked) { _, _ in Haptics.tick() }
                .frame(height: 84).padding(.top, 8)
                .animation(.easeOut(duration: 0.4), value: values)
            }
        }
    }
}

// ---- controls ----
struct ControlsPanel: View {
    let c: PcControls?
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    var body: some View {
        if let c {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    SwitchTile(on: "wifi", off: "wifi.slash", label: "Wi-Fi", state: c.wifi, busy: c.busy & 1 != 0) { on in hub.setControl(IslandWire.wifi, on ? 1 : 0) { $0.wifi = on ? 1 : 0; $0.busy |= 1 } }
                    SwitchTile(on: "wave.3.right", off: "wave.3.right", label: "Bluetooth", state: c.bluetooth, busy: c.busy & 2 != 0) { on in hub.setControl(IslandWire.bluetooth, on ? 1 : 0) { $0.bluetooth = on ? 1 : 0; $0.busy |= 2 } }
                    SwitchTile(on: "airplane", off: "airplane", label: "Airplane", state: c.wifi < -1 && c.bluetooth < -1 ? -2 : c.airplane ? 1 : 0, busy: c.busy & 4 != 0) { on in
                        hub.setControl(IslandWire.airplane, on ? 1 : 0) { $0.wifi = on ? 0 : 1; if $0.bluetooth >= -1 { $0.bluetooth = on ? 0 : 1 }; $0.busy |= 4 }
                    }
                }
                HStack(spacing: 10) {
                    SwitchTile(on: "moon.fill", off: "sun.max.fill", label: "Dark mode", state: c.dark, busy: c.busy & 8 != 0) { on in hub.setControl(IslandWire.dark, on ? 1 : 0) { $0.dark = on ? 1 : 0; $0.busy |= 8 } }
                    SwitchTile(on: "mic.slash.fill", off: "mic.fill", label: "Mic muted", state: !c.micAvailable ? -2 : c.micMuted ? 1 : 0, busy: false) { on in hub.setControl(IslandWire.mic, on ? 1 : 0) { $0.micMuted = on } }
                    SwitchTile(on: "speaker.slash.fill", off: "speaker.wave.2.fill", label: "Muted", state: c.muted ? 1 : 0, busy: false) { on in hub.setControl(IslandWire.mute, on ? 1 : 0) { $0.muted = on } }
                }
                GlassPanel(padding: 16) {
                    VStack(spacing: 12) {
                        if c.brightness >= 0 { Level(symbol: "sun.max.fill", label: "Brightness", value: c.brightness) { v in hub.setControl(IslandWire.brightness, v) { $0.brightness = v } } }
                        Level(symbol: c.muted || c.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Volume", value: c.volume) { v in hub.setControl(IslandWire.volume, v) { $0.volume = v } }
                        HStack(spacing: 10) {
                            Text("Volume").font(TypeScale.caption).foregroundStyle(t.muted); Spacer()
                            StepButton(symbol: "minus", label: "Volume down") { let v = max(0, (hub.pcControls?.volume ?? c.volume) - 5); hub.setControl(IslandWire.volume, v) { $0.volume = v; $0.muted = false } }
                            StepButton(symbol: "plus", label: "Volume up") { let v = min(100, (hub.pcControls?.volume ?? c.volume) + 5); hub.setControl(IslandWire.volume, v) { $0.volume = v; $0.muted = false } }
                        }
                    }
                }
            }
        } else { GlassPanel { ProgressView().frame(maxWidth: .infinity, minHeight: 90) } }
    }
}
/// A switch as a glass tile: lit when on; spinning while it's changing on the PC; dimmed when the PC has no such thing.
struct SwitchTile: View {
    let on: String; let off: String; let label: String; let state: Int; let busy: Bool
    let onChange: (Bool) -> Void
    @Environment(\.tokens) private var t
    var body: some View {
        let lit = state == 1, none = state < -1
        Button { Haptics.tap(); onChange(!lit) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: lit ? on : off).font(.system(size: 19, weight: .semibold)).foregroundStyle(none ? t.faint : lit ? t.accent : t.text).contentTransition(.symbolEffect(.replace)) }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(TypeScale.caption).foregroundStyle(none ? t.faint : t.text).lineLimit(1)
                    Text(none ? "Not here" : busy ? "Changing…" : state == -1 ? "…" : lit ? "On" : "Off").font(TypeScale.micro).foregroundStyle(t.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous), .control, tint: lit ? t.accent : nil, interactive: true)
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .disabled(none || busy || state < 0)
        .accessibilityLabel("\(label), \(none ? "not on this PC" : busy ? "changing" : lit ? "on" : "off")")
        .accessibilityAddTraits(lit ? [.isSelected, .isButton] : .isButton)
    }
}
struct Level: View {
    let symbol: String; let label: String; let value: Int; let onDone: (Int) -> Void
    @Environment(\.tokens) private var t
    @State private var moving: Double?
    var body: some View {
        let shown = moving ?? Double(value) / 100
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(t.accent).frame(width: 24).contentTransition(.symbolEffect(.replace))
            GlassSlider(value: shown, onChange: { moving = $0 }, onDone: { v in moving = nil; onDone(Int((v * 100).rounded())) }, label: label)
            Text("\(Int((shown * 100).rounded()))%").font(TypeScale.caption.monospacedDigit()).foregroundStyle(t.muted).frame(minWidth: 40, alignment: .trailing)
        }
    }
}

// ---- focus ----
/// The island's focus clock: running on here from the PC's last word, with focus, break and stopwatch to start.
struct FocusPanel: View {
    let c: PcControls?
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    var body: some View {
        if let c {
            TimelineView(.periodic(from: .now, by: c.focusRunning ? 0.25 : 60)) { ctx in
                let gone = c.focusRunning ? max(0, ctx.date.timeIntervalSince(hub.controlsAt)) : 0
                let stopwatch = c.focusMode == 2
                let shown = stopwatch ? c.focusShown + gone : max(0, c.focusShown - gone)
                let fraction = stopwatch ? shown.truncatingRemainder(dividingBy: 60) / 60 : c.focusDuration > 0 ? shown / c.focusDuration : 0
                let state = c.focusFinished ? "Done" : c.focusRunning ? "Running" : stopwatch ? (shown > 0.5 ? "Paused" : "Ready") : shown < c.focusDuration - 0.5 ? "Paused" : "Ready"
                GlassPanel {
                    VStack(spacing: 16) {
                        HStack(spacing: 18) {
                            ZStack {
                                ProgressRing(fraction: fraction, color: c.focusMode == 1 ? t.good : t.accent, size: 104, stroke: 7)
                                VStack(spacing: 0) {
                                    Text(clock(shown)).font(TypeScale.headline.monospacedDigit()).foregroundStyle(t.text).contentTransition(.numericText(countsDown: !stopwatch))
                                    Text(c.focusMode == 1 ? "BREAK" : stopwatch ? "STOPWATCH" : "FOCUS").font(TypeScale.micro).foregroundStyle(t.muted)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state).font(TypeScale.bodyStrong).foregroundStyle(t.text)
                                Text(stopwatch ? "Counting up on your PC" : "On your PC’s island, and in your Dynamic Island").font(TypeScale.caption).foregroundStyle(t.muted)
                                HStack(spacing: 8) {
                                    GlassIconButton(symbol: c.focusRunning ? "pause.fill" : "play.fill", label: c.focusRunning ? "Pause" : "Start", size: 44, iconSize: 17, prominent: true) { hub.setControl(IslandWire.focusToggle, 0) { $0.focusRunning.toggle(); $0.focusShown = shown } }
                                    GlassIconButton(symbol: "arrow.counterclockwise", label: "Reset", size: 44, iconSize: 17) { hub.setControl(IslandWire.focusReset, 0) { $0.focusRunning = false; $0.focusShown = $0.focusMode == 2 ? 0 : $0.focusDuration } }
                                    GlassIconButton(symbol: "stopwatch", label: "Stopwatch", size: 44, iconSize: 17) { hub.setControl(IslandWire.stopwatch, 0) { $0.focusMode = 2; $0.focusRunning = true; $0.focusShown = 0 } }
                                }
                                .padding(.top, 8)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 8) {
                            ForEach([15, 25, 45], id: \.self) { m in
                                GlassButton(action: { hub.setControl(IslandWire.focus, m) { $0.focusMode = 0; $0.focusDuration = Double(m * 60); $0.focusShown = Double(m * 60); $0.focusRunning = true } }) { Text("\(m) min").font(TypeScale.caption) }.frame(maxWidth: .infinity)
                            }
                            GlassButton(action: { hub.setControl(IslandWire.breakTime, 5) { $0.focusMode = 1; $0.focusDuration = 300; $0.focusShown = 300; $0.focusRunning = true } }) { Text("Break").font(TypeScale.caption) }.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }
}

// ---- the command bar ----
/// The PC's command bar: what's typed is asked as it's typed; a row runs on the PC (asking first where the island would).
struct CommandPanel: View {
    let pcName: String; var onConfirm: (Confirm) -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @State private var text = ""
    @State private var rows: [CommandRow] = []
    @State private var asked = ""
    @FocusState private var focused: Bool
    var body: some View {
        GlassPanel(padding: 6) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(t.muted)
                    TextField("An app, a file, a setting, “timer 10”…", text: $text).font(.system(size: 16)).focused($focused).submitLabel(.go).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { if let r = rows.first { run(0, r, false) } }
                        .onChange(of: text) { _, v in if v.count > 160 { text = String(v.prefix(160)) } }
                    if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(t.muted) }.accessibilityLabel("Clear") }
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .glassCapsule(.control, interactive: false)
                .padding(8)
                ForEach(Array(rows.prefix(6).enumerated()), id: \.offset) { i, row in
                    if i > 0 { Divider().overlay(t.hairline).padding(.leading, 62) }
                    Button { Haptics.tick(); run(i, row, false) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: Self.symbol(row.kind)).font(.system(size: 16, weight: .semibold)).foregroundStyle(t.accent).frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.accent.opacity(0.14)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).font(TypeScale.bodyStrong).foregroundStyle(t.text).lineLimit(1)
                                if !row.detail.isEmpty { Text(row.detail).font(TypeScale.caption).foregroundStyle(t.muted).lineLimit(1) }
                            }
                            Spacer()
                            if !row.answer.isEmpty { Text(row.answer).font(TypeScale.bodyStrong).foregroundStyle(t.accent) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: rows)
        }
        .task(id: text) {
            if !text.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled, let r = await hub.queryCommands(text) else { return }
            rows = r.rows; asked = text
        }
    }
    private func run(_ i: Int, _ row: CommandRow, _ confirmed: Bool) {
        Task {
            let o = await hub.runCommand(asked, i, row.title, confirmed: confirmed)
            switch o?.outcome {
            case 0: Haptics.success(); hub.show(Banner(kind: .info, title: o!.message, detail: "On \(pcName)")); focused = false; if [12, 13, 14, 36].contains(row.kind) { text = "" }
            case 1:
                let q = o!.message; let cut = q.range(of: "? ")
                let title = (cut.map { String(q[..<$0.lowerBound]) + "?" } ?? q).replacingOccurrences(of: "the PC", with: pcName)
                let detail = cut.map { String(q[$0.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "." } ?? "On \(pcName)"
                focused = false
                onConfirm(Confirm(title: title, detail: detail, action: row.title.split(separator: " ").first.map(String.init) ?? "Go ahead", danger: [32, 34, 35].contains(row.kind)) { run(i, row, true) })
            case 3: if let r = await hub.queryCommands(asked) { rows = r.rows }; hub.show(Banner(kind: .info, title: o!.message))
            default: Haptics.error(); hub.show(Banner(kind: .failed, title: o?.message ?? "\(pcName) didn't answer"))
            }
        }
    }
    /// The island's command kinds, as symbols.
    static func symbol(_ kind: Int) -> String {
        let m: [Int: String] = [1: "speaker.wave.2.fill", 2: "speaker.wave.2.fill", 4: "speaker.wave.2.fill", 3: "speaker.slash.fill", 5: "play.fill", 6: "pause.fill", 7: "forward.fill", 8: "backward.fill", 9: "timer", 10: "timer", 11: "timer.circle",
                                12: "app.fill", 13: "magnifyingglass", 14: "gearshape.fill", 15: "square.grid.2x2.fill", 16: "square.grid.2x2.fill", 17: "square.grid.2x2.fill", 18: "doc.on.clipboard", 27: "doc.on.clipboard", 19: "clear.fill", 20: "lock.fill",
                                21: "mic.slash.fill", 22: "mic.fill", 23: "mic.fill", 24: "camera.viewfinder", 25: "textformat", 26: "paintpalette.fill", 38: "paintpalette.fill", 28: "moon.fill", 29: "wave.3.right", 30: "wifi", 31: "airplane",
                                32: "trash.fill", 33: "moon.zzz.fill", 34: "arrow.clockwise", 35: "power", 36: "doc.text.fill", 37: "dollarsign.arrow.circlepath", 39: "cloud.fill", 40: "music.note", 41: "shuffle", 42: "laptopcomputer.and.iphone"]
        return m[kind] ?? "bolt.fill"
    }
}

// ---- power ----
struct PowerPanel: View {
    let pcName: String; var onConfirm: (Confirm) -> Void
    private var hub: Hub { Hub.shared }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ActionTile(symbol: "lock.fill", label: "Lock") { hub.setControl(IslandWire.lock, 1) }
                ActionTile(symbol: "moon.zzz.fill", label: "Sleep") { power(IslandWire.sleep, "Put \(pcName) to sleep?", "It wakes when you open it or press a key.", "Sleep", false) }
                ActionTile(symbol: "arrow.clockwise", label: "Restart") { power(IslandWire.restart, "Restart \(pcName)?", "Anything unsaved there may be lost.", "Restart", true) }
                ActionTile(symbol: "power", label: "Shut down") { power(IslandWire.shutDown, "Shut down \(pcName)?", "Anything unsaved there may be lost.", "Shut down", true) }
            }
            GlassPanel(padding: 14) {
                Button { Haptics.tap(); power(IslandWire.emptyBin, "Empty the recycle bin?", "What's in it on \(pcName) is deleted for good.", "Empty", true) } label: {
                    SettingRow(symbol: "trash.fill", title: "Empty the recycle bin", detail: "For good, on \(pcName)") { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                }.buttonStyle(PressStyle(scale: 0.98))
            }
        }
    }
    private func power(_ control: Int, _ title: String, _ detail: String, _ action: String, _ danger: Bool) {
        onConfirm(Confirm(title: title, detail: detail, action: action, danger: danger) { hub.setControl(control, 1) })
    }
}
struct ActionTile: View {
    let symbol: String; let label: String; var height: CGFloat = 78; let action: () -> Void
    @Environment(\.tokens) private var t
    var body: some View {
        Button { Haptics.tap(); action() } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(t.text)
                Text(label).font(TypeScale.micro).foregroundStyle(t.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: height)
            .glass(RoundedRectangle(cornerRadius: 20, style: .continuous), .control, interactive: true)
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .accessibilityLabel(label)
    }
}

// ---- sound output, pages ----
struct OutputsPanel: View {
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    var body: some View {
        let direct = hub.islandSettings?.items.first { $0.key == "directAudio" }
        GlassPanel(padding: 14) {
            VStack(spacing: 0) {
                ForEach(Array(hub.outputs.enumerated()), id: \.element.id) { i, o in
                    if i > 0 { Divider().overlay(t.hairline) }
                    Button { if !o.current { Haptics.tick(); hub.selectOutput(o.id) } } label: {
                        SettingRow(symbol: o.form == 3 ? "headphones" : o.form == 4 ? "mic.fill" : "hifispeaker.fill", title: o.name, detail: o.current ? "Playing here" : nil, tint: o.current ? t.accent : t.muted) {
                            if o.current { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(t.accent).transition(.scale.combined(with: .opacity)) }
                        }
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                }
                if let direct, direct.value == 0 {
                    Divider().overlay(t.hairline)
                    SettingRow(symbol: "arrow.left.arrow.right", title: direct.title, detail: "Needed to switch from here", tint: t.warn) {
                        Toggle("", isOn: Binding(get: { false }, set: { if $0 { hub.setIslandSetting("directAudio", 1) } })).labelsHidden().tint(t.accent)
                    }
                }
            }
            .animation(.spring(response: 0.35), value: hub.outputs)
        }
    }
}
struct PagesPanel: View {
    private var hub: Hub { Hub.shared }
    private let symbols = ["house.fill", "music.note", "gauge.with.dots.needle.67percent", "scope", "gearshape.fill", "tray.full.fill", "slider.vertical.3", "switch.2"]
    var body: some View {
        VStack(spacing: 10) {
            ForEach([[0, 1, 2, 3], [5, 6, 7, 4]], id: \.self) { row in
                HStack(spacing: 10) { ForEach(row, id: \.self) { i in ActionTile(symbol: symbols[i], label: IslandWire.pages[i], height: 70) { hub.openIslandPage(i) } } }
            }
            GlassButton(action: { hub.closeIsland() }) { Image(systemName: "arrow.down.right.and.arrow.up.left"); Text("Close the island").font(TypeScale.caption) }.frame(maxWidth: .infinity)
        }
    }
}

// ---- settings ----
enum IslandSettingsInfo {
    static let symbols = ["slider.horizontal.3", "rectangle.split.3x1", "paintpalette.fill", "sparkles", "text.alignleft", "music.note", "battery.100percent.bolt", "house.fill", "hand.raised.fill", "info.circle.fill"]
    static func shown(_ i: IslandSetting) -> Bool { !(i.control == 5 && [1, 16].contains(i.action)) }
    /// Switching these off cuts this iPhone off from the PC: asked first.
    static let lifelines: [String: String] = [
        "sharing": "This iPhone loses its connection to the PC until sharing is turned back on there.", "phoneControl": "This iPhone can’t control the PC until that’s turned back on there.",
        "relay": "This iPhone reaches the PC only through the internet: it can’t, until that’s turned back on there.",
    ]
}
struct SettingsPanel: View {
    var onOpen: (Int) -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    var body: some View {
        if let s = hub.islandSettings {
            GlassPanel(padding: 14) {
                VStack(spacing: 0) {
                    let sections = s.sections.enumerated().filter { i, _ in s.items.contains { $0.section == i && IslandSettingsInfo.shown($0) } }
                    ForEach(Array(sections.enumerated()), id: \.offset) { n, pair in
                        let (i, name) = pair
                        let count = s.items.filter { $0.section == i && IslandSettingsInfo.shown($0) }.count
                        if n > 0 { Divider().overlay(t.hairline) }
                        Button { Haptics.tick(); onOpen(i) } label: {
                            SettingRow(symbol: IslandSettingsInfo.symbols[safe: i] ?? "slider.horizontal.3", title: name, detail: "\(count) setting\(count == 1 ? "" : "s")") { Image(systemName: "chevron.right").foregroundStyle(t.muted) }
                        }.buttonStyle(PressStyle(scale: 0.98))
                    }
                }
            }
        } else { GlassPanel { ProgressView().frame(maxWidth: .infinity, minHeight: 60) } }
    }
}
extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

/// One section of the island's settings, every one of them as its Settings has it.
struct IslandSettingsSheet: View {
    let section: Int
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @State private var confirm: Confirm?
    var body: some View {
        NavigationStack {
            ScrollView {
                if let s = hub.islandSettings {
                    VStack(spacing: 10) {
                        Text("On your PC’s island, as its Settings has it").font(TypeScale.caption).foregroundStyle(t.muted).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(s.items.filter { $0.section == section && IslandSettingsInfo.shown($0) }) { item in SettingCard(item: item) { confirm = $0 } }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(hub.islandSettings?.sections[safe: section] ?? "Settings")
            .navigationBarTitleDisplayMode(.large)
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { c in
            Button(c.action, role: c.danger ? .destructive : nil) { c.run() }; Button("Cancel", role: .cancel) {}
        } message: { c in Text(c.detail) }
    }
}
struct SettingCard: View {
    let item: IslandSetting; var onConfirm: (Confirm) -> Void
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @State private var moving: Int?
    var body: some View {
        let range = max(1, item.hi - item.lo), shown = moving ?? item.value
        GlassPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                switch item.control {
                case 0:
                    HStack { head; Spacer(); Toggle("", isOn: Binding(get: { item.value != 0 }, set: { on in
                        if !on, let warn = IslandSettingsInfo.lifelines[item.key] { onConfirm(Confirm(title: "Turn off “\(item.title)”?", detail: warn, action: "Turn off", danger: true) { hub.setIslandSetting(item.key, 0) }) }
                        else { Haptics.tick(); hub.setIslandSetting(item.key, on ? 1 : 0) }
                    })).labelsHidden().tint(t.accent) }
                case 1:
                    HStack { head; Spacer(); Text("\(shown)\(item.unit)").font(TypeScale.bodyStrong.monospacedDigit()).foregroundStyle(t.accent).contentTransition(.numericText(value: Double(shown))) }
                    GlassSlider(value: Double(shown - item.lo) / Double(range), onChange: { let v = snap($0); if v != moving { if moving != nil { Haptics.detent() }; moving = v } }, onDone: { f in let v = snap(f); moving = nil; hub.setIslandSetting(item.key, v) }, label: item.title)
                case 2:
                    head
                    WrapLayout(spacing: 8) { ForEach(Array(item.options.enumerated()), id: \.offset) { i, o in GlassChip(label: o, selected: item.value == i) { if item.value != i { hub.setIslandSetting(item.key, i) } } } }
                case 3:
                    HStack(spacing: 8) {
                        head; Spacer()
                        GlassIconButton(symbol: "minus", label: "Less", size: 38, iconSize: 15) { hub.setIslandSetting(item.key, max(item.lo, item.value - item.step)) }.disabled(item.value <= item.lo)
                        Text(item.options[safe: item.value - item.lo] ?? "\(item.value)\(item.unit)").font(TypeScale.bodyStrong).foregroundStyle(t.text).padding(.horizontal, 6)
                        GlassIconButton(symbol: "plus", label: "More", size: 38, iconSize: 15) { hub.setIslandSetting(item.key, min(item.hi, item.value + item.step)) }.disabled(item.value >= item.hi)
                    }
                case 4:
                    head
                    HStack(spacing: 12) {
                        ForEach(Array(item.colours.enumerated()), id: \.offset) { i, c in
                            let chosen = item.value == i
                            Button { Haptics.tick(); if !chosen { hub.setIslandSetting(item.key, i) } } label: {
                                Circle().fill(Color(hex: UInt32(c & 0xFFFFFF))).frame(width: 34, height: 34)
                                    .overlay(Circle().stroke(t.text, lineWidth: chosen ? 2.5 : 0).padding(-4))
                                    .scaleEffect(chosen ? 1.08 : 1).animation(.spring(response: 0.3, dampingFraction: 0.6), value: chosen)
                            }
                            .accessibilityLabel((item.options[safe: i] ?? "Colour \(i + 1)") + (chosen ? ", chosen" : ""))
                        }
                    }
                default:
                    let verb = [2, 6].contains(item.action) ? "Reset" : [4, 12, 14, 17].contains(item.action) ? "Clear" : item.action == 18 ? "Check" : "Open"
                    let ask: String? = item.action == 2 ? "The island on your PC goes back to how it came." : item.action == 6 ? "The island’s pages go back to where they started." : [4, 12, 14, 17].contains(item.action) ? "It can’t be undone." : nil
                    HStack { head; Spacer(); GlassButton(action: {
                        if let ask { onConfirm(Confirm(title: "\(item.title)?", detail: ask, action: verb, danger: true) { hub.islandSettingAction(item.action, done: item.title) }) }
                        else { hub.islandSettingAction(item.action, done: item.title) }
                    }) { Text(verb).font(TypeScale.caption) } }
                }
            }
        }
    }
    private var head: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(TypeScale.bodyStrong).foregroundStyle(t.text)
            if !item.detail.isEmpty { Text(item.detail).font(TypeScale.caption).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func snap(_ f: Double) -> Int {
        let range = max(1, item.hi - item.lo), raw = item.lo + Int((f * Double(range)).rounded()), step = max(1, item.step)
        return max(item.lo, min(item.hi, item.lo + (raw - item.lo + step / 2) / step * step))
    }
}
