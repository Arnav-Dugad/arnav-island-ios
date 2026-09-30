import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// Your PC on the Home Screen, the Lock Screen, in the Dynamic Island and in Control Center. The app writes what it sees of
// the PC into the app group; these read it. Their buttons are Live Activity intents, which iOS runs in the app itself.

@main
struct IslandWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        StatsWidget()
        ActionsWidget()
        NowPlayingActivity()
        TransferActivity()
        FocusActivity()
        PlayPauseControl()
        LockControl()
        FindControl()
    }
}

extension Color {
    init(hexString s: String, fallback: Color = Color(red: 0.65, green: 0.85, blue: 0.77)) {
        guard let v = UInt32(s, radix: 16) else { self = fallback; return }
        self.init(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}
private func clockText(_ s: Double) -> String { let v = max(0, Int(s)); return String(format: "%d:%02d", v / 60, v % 60) }

struct SnapEntry: TimelineEntry { let date: Date; let snap: Snapshot; let cover: UIImage? }
struct SnapProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapEntry { SnapEntry(date: .now, snap: Self.sample, cover: nil) }
    func getSnapshot(in context: Context, completion: @escaping (SnapEntry) -> Void) { completion(context.isPreview ? placeholder(in: context) : entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapEntry>) -> Void) {
        let e = entry()
        // While a song plays, redrawn as it would end; otherwise every half hour (the app asks for more when things change).
        let next = e.snap.playing && e.snap.duration > 0 ? Date().addingTimeInterval(max(60, e.snap.duration - e.snap.positionNow())) : Date().addingTimeInterval(1800)
        completion(Timeline(entries: [e], policy: .after(next)))
    }
    private func entry() -> SnapEntry { SnapEntry(date: .now, snap: Snapshot.load(), cover: (try? Data(contentsOf: Snapshot.coverFile)).flatMap(UIImage.init(data:))) }
    static let sample: Snapshot = { var s = Snapshot(); s.pcName = "Studio PC"; s.online = true; s.title = "Glass Horizons"; s.artist = "Aurora Fields"; s.playing = true; s.duration = 214; s.position = 71; s.at = .now; s.volume = 42; s.battery = 86; s.cpu = 18; s.gpu = 7; s.ram = 41; return s }()
}

/// The widget's glass: the song's colours, deep, with a sheen.
struct WidgetGlass: View {
    let snap: Snapshot
    var body: some View {
        ZStack {
            Color(hexString: snap.deep, fallback: Color(red: 0.04, green: 0.07, blue: 0.13))
            LinearGradient(colors: [Color(hexString: snap.accent).opacity(0.55), .clear], startPoint: .topLeading, endPoint: .center)
            LinearGradient(colors: [.clear, Color(hexString: snap.accent2).opacity(0.35)], startPoint: .center, endPoint: .bottomTrailing)
        }
    }
}

// ---- now playing ----
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "nowplaying", provider: SnapProvider()) { e in NowPlayingView(e: e).containerBackground(for: .widget) { WidgetGlass(snap: e.snap) } }
            .configurationDisplayName("Playing on your PC")
            .description("What plays on your PC, with play and pause.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
struct NowPlayingView: View {
    let e: SnapEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let s = e.snap, accent = Color(hexString: s.accent)
        switch family {
        case .accessoryInline: Label(s.title.isEmpty ? (s.pcName.isEmpty ? "No PC yet" : "\(s.pcName): nothing playing") : "\(s.title) · \(s.artist)", systemImage: s.playing ? "waveform" : "laptopcomputer")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if s.duration > 0 && s.playing { ProgressView(timerInterval: Date().addingTimeInterval(-s.positionNow())...Date().addingTimeInterval(s.duration - s.positionNow()), countsDown: false) { EmptyView() }.progressViewStyle(.circular) }
                Button(intent: PlayPausePCIntent()) { Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .bold)) }.buttonStyle(.plain)
            }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                if let c = e.cover { Image(uiImage: c).resizable().scaledToFill().frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 8)).widgetAccentable(false) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title.isEmpty ? "Nothing playing" : s.title).font(.headline).lineLimit(1)
                    Text(s.artist.isEmpty ? s.pcName : s.artist).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    if s.playing, s.duration > 0 { ProgressView(timerInterval: Date().addingTimeInterval(-s.positionNow())...Date().addingTimeInterval(s.duration - s.positionNow()), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }.tint(accent) }
                }
            }
        case .systemMedium:
            HStack(spacing: 14) {
                cover(e.cover, accent: accent, size: 116)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ON \(s.pcName.uppercased())").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    Text(s.title.isEmpty ? "Nothing playing" : s.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                    Text(s.artist).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Spacer(minLength: 0)
                    if s.playing, s.duration > 0 { ProgressView(timerInterval: Date().addingTimeInterval(-s.positionNow())...Date().addingTimeInterval(s.duration - s.positionNow()), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }.tint(.white) }
                    HStack(spacing: 18) {
                        Button(intent: PreviousTrackPCIntent()) { Image(systemName: "backward.fill") }
                        Button(intent: PlayPausePCIntent()) { Image(systemName: s.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30)) }
                        Button(intent: NextTrackPCIntent()) { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain).foregroundStyle(.white).font(.system(size: 17))
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    cover(e.cover, accent: accent, size: 58)
                    Spacer()
                    Button(intent: PlayPausePCIntent()) { Image(systemName: s.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white) }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Text(s.title.isEmpty ? (s.online ? "Nothing playing" : "\(s.pcName.isEmpty ? "Your PC" : s.pcName) is away") : s.title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                Text(s.artist.isEmpty ? s.pcName : s.artist).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
        }
    }
    private func cover(_ img: UIImage?, accent: Color, size: CGFloat) -> some View {
        ZStack {
            if let img { Image(uiImage: img).resizable().scaledToFill() } else { accent.opacity(0.35); Image(systemName: "music.note").font(.system(size: size * 0.35)).foregroundStyle(.white) }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

// ---- the PC's numbers ----
struct StatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "stats", provider: SnapProvider()) { e in StatsView(s: e.snap).containerBackground(for: .widget) { WidgetGlass(snap: e.snap) } }
            .configurationDisplayName("Your PC’s numbers")
            .description("Its processor, graphics, memory and battery.")
            .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}
struct StatsView: View {
    let s: Snapshot
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if family == .accessoryCircular {
            Gauge(value: Double(max(0, s.cpu)), in: 0...100) { Text("CPU") } currentValueLabel: { Text("\(max(0, s.cpu))") }.gaugeStyle(.accessoryCircular)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: "laptopcomputer"); Text(s.pcName.isEmpty ? "Your PC" : s.pcName).lineLimit(1); Spacer(); Circle().fill(s.online ? .green : .gray).frame(width: 7, height: 7) }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                row("CPU", Double(s.cpu)); row("GPU", s.gpu); row("Memory", s.ram)
                if s.battery >= 0 { row(s.charging ? "Charging" : "Battery", Double(s.battery)) }
            }
        }
    }
    private func row(_ label: String, _ v: Double) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).frame(width: 52, alignment: .leading)
            GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(.white.opacity(0.18)); Capsule().fill(Color(hexString: s.accent)).frame(width: g.size.width * max(0, min(1, v / 100))) } }.frame(height: 5)
            Text(v >= 0 ? "\(Int(v))%" : "—").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white).frame(width: 34, alignment: .trailing)
        }
    }
}

// ---- actions ----
struct ActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "actions", provider: SnapProvider()) { e in ActionsView(s: e.snap).containerBackground(for: .widget) { WidgetGlass(snap: e.snap) } }
            .configurationDisplayName("Your PC, a tap away")
            .description("Lock it, find it, play or pause, open its trackpad.")
            .supportedFamilies([.systemMedium])
    }
}
struct ActionsView: View {
    let s: Snapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(s.pcName.isEmpty ? "Your PC" : s.pcName).font(.system(size: 14, weight: .bold)).foregroundStyle(.white); Spacer(); if s.battery >= 0 { Label("\(s.battery)%", systemImage: s.charging ? "battery.100percent.bolt" : "battery.75percent").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8)) } }
            HStack(spacing: 10) {
                tile(LockPCIntent(), "lock.fill", "Lock")
                tile(FindPCIntent(), "bell.and.waves.left.and.right.fill", "Find")
                tile(PlayPausePCIntent(), s.playing ? "pause.fill" : "play.fill", s.playing ? "Pause" : "Play")
                Button(intent: OpenIslandIntent(.trackpad)) { face("rectangle.and.hand.point.up.left.fill", "Trackpad") }.buttonStyle(.plain)
            }
        }
    }
    private func tile<I: AppIntent>(_ intent: I, _ symbol: String, _ label: String) -> some View { Button(intent: intent) { face(symbol, label) }.buttonStyle(.plain) }
    private func face(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 6) { Image(systemName: symbol).font(.system(size: 20, weight: .semibold)); Text(label).font(.system(size: 11, weight: .semibold)) }
            .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 70).background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.14)))
    }
}

// ---- Live Activities ----
private func coverImage() -> UIImage? { (try? Data(contentsOf: Snapshot.coverFile)).flatMap(UIImage.init(data:)) }

struct NowPlayingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { ctx in
            NowPlayingLock(ctx: ctx).activityBackgroundTint(Color.black.opacity(0.55)).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = ctx.state, accent = Color(hexString: s.accent)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { art(58).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "waveform").font(.system(size: 22, weight: .semibold)).foregroundStyle(accent)
                        .symbolEffect(.variableColor.iterative.reversing, isActive: s.playing).padding(.trailing, 6).padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(s.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(s.artist.isEmpty ? "On \(ctx.attributes.pcName)" : s.artist).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        progress(s, accent: accent)
                        HStack(spacing: 34) {
                            Button(intent: PreviousTrackPCIntent()) { Image(systemName: "backward.fill") }
                            Button(intent: PlayPausePCIntent()) { Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.system(size: 26)) }
                            Button(intent: NextTrackPCIntent()) { Image(systemName: "forward.fill") }
                        }
                        .buttonStyle(.plain).font(.system(size: 20)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                art(22)
            } compactTrailing: {
                Image(systemName: "waveform").foregroundStyle(accent).symbolEffect(.variableColor.iterative.reversing, isActive: s.playing)
            } minimal: {
                art(22)
            }
            .keylineTint(accent)
        }
    }
    private func art(_ size: CGFloat) -> some View {
        ZStack { if let c = coverImage() { Image(uiImage: c).resizable().scaledToFill() } else { Color.gray.opacity(0.4); Image(systemName: "music.note").font(.system(size: size * 0.45)) } }
            .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
    @ViewBuilder private func progress(_ s: NowPlayingAttributes.ContentState, accent: Color) -> some View {
        if s.duration > 0 {
            if s.playing {
                ProgressView(timerInterval: s.started...s.started.addingTimeInterval(s.duration), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }.tint(accent)
            } else { ProgressView(value: min(1, s.pausedAt / s.duration)).tint(accent) }
        }
    }
}
struct NowPlayingLock: View {
    let ctx: ActivityViewContext<NowPlayingAttributes>
    var body: some View {
        let s = ctx.state, accent = Color(hexString: s.accent)
        HStack(spacing: 14) {
            ZStack { if let c = coverImage() { Image(uiImage: c).resizable().scaledToFill() } else { accent.opacity(0.35); Image(systemName: "music.note").font(.system(size: 26)) } }
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("ON \(ctx.attributes.pcName.uppercased())").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.55))
                Text(s.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(s.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                if s.duration > 0 {
                    if s.playing { ProgressView(timerInterval: s.started...s.started.addingTimeInterval(s.duration), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }.tint(accent) }
                    else { ProgressView(value: min(1, s.pausedAt / s.duration)).tint(accent) }
                }
            }
            VStack(spacing: 10) {
                Button(intent: PlayPausePCIntent()) { Image(systemName: s.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34)) }
                Button(intent: NextTrackPCIntent()) { Image(systemName: "forward.fill").font(.system(size: 16)) }
            }
            .buttonStyle(.plain).foregroundStyle(.white)
        }
        .padding(16)
    }
}

struct TransferActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferAttributes.self) { ctx in
            let s = ctx.state, f = s.total > 0 ? Double(s.done) / Double(s.total) : 0
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 5)
                    Circle().trim(from: 0, to: s.finished ? 1 : f).stroke(s.failed ? Color.red : Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                    Image(systemName: s.finished ? "checkmark" : s.failed ? "xmark" : ctx.attributes.outgoing ? "arrow.up" : "arrow.down").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ctx.attributes.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(s.finished ? (ctx.attributes.outgoing ? "Sent to \(ctx.attributes.pcName)" : "Received from \(ctx.attributes.pcName)") : s.failed ? "Didn’t finish" : "\(Int(f * 100))%  ·  \(ctx.attributes.outgoing ? "to" : "from") \(ctx.attributes.pcName)")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }
            .padding(16).activityBackgroundTint(Color.black.opacity(0.55))
        } dynamicIsland: { ctx in
            let s = ctx.state, f = s.total > 0 ? Double(s.done) / Double(s.total) : 0
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: ctx.attributes.outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill").font(.system(size: 30)).foregroundStyle(.green).padding(.leading, 6) }
                DynamicIslandExpandedRegion(.trailing) { Text("\(Int((s.finished ? 1 : f) * 100))%").font(.system(size: 20, weight: .semibold).monospacedDigit()).padding(.trailing, 6) }
                DynamicIslandExpandedRegion(.center) { Text(ctx.attributes.title).font(.system(size: 14, weight: .semibold)).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) { ProgressView(value: s.finished ? 1 : f).tint(.green).padding(.horizontal, 10) }
            } compactLeading: {
                Image(systemName: ctx.attributes.outgoing ? "arrow.up" : "arrow.down").foregroundStyle(.green)
            } compactTrailing: {
                ZStack { Circle().stroke(.white.opacity(0.2), lineWidth: 2.5); Circle().trim(from: 0, to: s.finished ? 1 : f).stroke(.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90)) }.frame(width: 18, height: 18)
            } minimal: {
                ZStack { Circle().stroke(.white.opacity(0.2), lineWidth: 2.5); Circle().trim(from: 0, to: s.finished ? 1 : f).stroke(.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90)) }.frame(width: 18, height: 18)
            }
        }
    }
}

struct FocusActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusAttributes.self) { ctx in
            let s = ctx.state
            HStack(spacing: 14) {
                Image(systemName: s.mode == 1 ? "cup.and.saucer.fill" : s.mode == 2 ? "stopwatch.fill" : "scope").font(.system(size: 26, weight: .semibold)).foregroundStyle(s.mode == 1 ? .green : .mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.mode == 1 ? "Break" : s.mode == 2 ? "Stopwatch" : "Focus").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    timer(s).font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                }
                Spacer()
                Text("On \(ctx.attributes.pcName)").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(18).activityBackgroundTint(Color.black.opacity(0.55))
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: s.mode == 1 ? "cup.and.saucer.fill" : s.mode == 2 ? "stopwatch.fill" : "scope").font(.system(size: 26)).foregroundStyle(.mint).padding(.leading, 6) }
                DynamicIslandExpandedRegion(.trailing) { timer(s).font(.system(size: 26, weight: .light, design: .rounded).monospacedDigit()).frame(maxWidth: 110).padding(.trailing, 6) }
                DynamicIslandExpandedRegion(.bottom) { Text(s.mode == 1 ? "A break, on \(ctx.attributes.pcName)" : "Focusing, on \(ctx.attributes.pcName)").font(.system(size: 13)).foregroundStyle(.secondary) }
            } compactLeading: {
                Image(systemName: s.mode == 1 ? "cup.and.saucer.fill" : "scope").foregroundStyle(.mint)
            } compactTrailing: {
                timer(s).monospacedDigit().frame(maxWidth: 52).foregroundStyle(.mint)
            } minimal: {
                Image(systemName: "scope").foregroundStyle(.mint)
            }
        }
    }
    @ViewBuilder private func timer(_ s: FocusAttributes.ContentState) -> some View {
        if s.running && s.mode != 2 { Text(timerInterval: Date()...max(Date(), s.ends), countsDown: true) }
        else if s.running { Text(Date().addingTimeInterval(-s.shown), style: .timer) }
        else { Text(clockText(s.shown)) }
    }
}

// ---- Control Center (iOS 18) ----
struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.arnavdugad.arnavisland.playpause") {
            ControlWidgetButton(action: PlayPausePCIntent()) { Label(Snapshot.load().playing ? "Pause PC" : "Play on PC", systemImage: Snapshot.load().playing ? "pause.fill" : "play.fill") }
        }
        .displayName("Play or Pause on My PC")
        .description("Plays or pauses what plays on your PC.")
    }
}
struct LockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.arnavdugad.arnavisland.lock") {
            ControlWidgetButton(action: LockPCIntent()) { Label("Lock My PC", systemImage: "lock.laptopcomputer") }
        }
        .displayName("Lock My PC")
        .description("Locks your PC right away.")
    }
}
struct FindControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.arnavdugad.arnavisland.find") {
            ControlWidgetButton(action: FindPCIntent()) { Label("Find My PC", systemImage: "bell.and.waves.left.and.right") }
        }
        .displayName("Find My PC")
        .description("Your PC's island chimes and lights up.")
    }
}
