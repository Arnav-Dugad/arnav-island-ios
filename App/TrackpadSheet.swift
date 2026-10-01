import IslandKit
import SwiftUI
import UIKit

/// Where keys and typing go: the trackpad's session, or the PC's screen shown here.
protocol Typist: AnyObject { func frame(_ f: [UInt8]) }
extension Typist {
    func key(_ vk: Int, _ modifiers: Int...) {
        for m in modifiers { frame(Frames.key(m, 1)) }
        frame(Frames.key(vk, 2))
        for m in modifiers.reversed() { frame(Frames.key(m, 0)) }
    }
}

/// The trackpad's connection: moves and scrolls are gathered and sent 30 times a second (through the relay, or straight
/// over the Wi-Fi); clicks and keys go at once, in order after the movement before them.
@MainActor
final class InputLink: ObservableObject, Typist {
    @Published var state = 0 // 0 connecting, 1 ready, 2 couldn't connect
    private var session: InputSession?
    private var dx = 0.0, dy = 0.0, wheel = 0.0, hwheel = 0.0
    private let queue = DispatchQueue(label: "trackpad")
    private var timer: Timer?
    private var closed = false
    func start() {
        guard timer == nil else { return }
        Task { let s = await Hub.shared.openInput(); session = s; state = s == nil ? 2 : 1 }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in MainActor.assumeIsolated { self.flush() } }
    }
    private func deliver(_ f: [UInt8]) {
        let s = session
        queue.async { [weak self] in
            if let s, s.alive, s.send(f) { return }
            // The PC closed an idle session: once more, freshly opened.
            s?.close()
            Task { @MainActor in
                guard let self, !self.closed else { return }
                let fresh = await Hub.shared.openInput(); self.session = fresh
                if let fresh { let ok = await io { fresh.send(f) }; self.state = ok ? 1 : 2 } else { self.state = 2 }
            }
        }
    }
    func move(_ x: Double, _ y: Double) { dx += x; dy += y }
    func scroll(_ v: Double, _ h: Double) { wheel += v; hwheel += h }
    func frame(_ f: [UInt8]) { flush(); deliver(f) }
    private func flush() {
        let mx = Int(dx), my = Int(dy), w = Int(wheel), h = Int(hwheel)
        dx -= Double(mx); dy -= Double(my); wheel -= Double(w); hwheel -= Double(h)
        if mx != 0 || my != 0 { deliver(Frames.move(mx, my)) }
        if w != 0 || h != 0 { deliver(Frames.scroll(w, h)) }
    }
    func close() { closed = true; timer?.invalidate(); timer = nil; let s = session; queue.async { s?.close() } }
}

/// The iPhone as the PC's trackpad and keyboard. One finger moves the pointer (faster the faster it goes), a tap clicks, two
/// fingers scroll and a two-finger tap right-clicks; a double tap held down drags. Below: the two buttons, the keys a phone's
/// keyboard lacks, and typing that goes straight to the PC.
struct TrackpadSheet: View {
    private var hub: Hub { Hub.shared }
    @Environment(\.tokens) private var t
    @StateObject private var input = InputLink()
    var body: some View {
        let pc = hub.pc()
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trackpad").font(TypeScale.title).foregroundStyle(t.text)
                    Text(input.state == 0 ? "Connecting to \(pc?.name ?? "your PC")…" : input.state == 1 ? "Controlling \(pc?.name ?? "your PC")  ·  \(pc?.lan == true ? "on this Wi-Fi" : "through the relay")" : "Couldn’t connect. On the island: Settings › Privacy & productivity › My phone can control this PC")
                        .font(TypeScale.caption).foregroundStyle(input.state == 2 ? t.danger : t.muted).lineLimit(3)
                }
                Spacer()
                LiveDot(on: input.state == 1)
            }
            TouchPad(input: input)
            HStack(spacing: 10) {
                MouseButton(label: "Left click") { input.frame(Frames.button(0, $0 ? 1 : 0)) }
                MouseButton(label: "Right click") { input.frame(Frames.button(1, $0 ? 1 : 0)) }
            }
            .frame(height: 54)
            KeysRow(input: input)
            TypingField(input: input, pcName: pc?.name ?? "your PC")
        }
        .padding(20)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .presentationBackground { SheetBackdrop() }
        .interactiveDismissDisabled(false)
        .onAppear { input.start() }
        .onDisappear { input.close() }
    }
}

/// The pad: a glass surface that glows under each finger and ripples where it clicks.
struct TouchPad: View {
    let input: InputLink
    @Environment(\.tokens) private var t
    @State private var touches: [CGPoint] = []
    @State private var ripple: (CGPoint, Date)?
    @State private var used = false
    var body: some View {
        ZStack {
            TouchSurface(input: input, onTouches: { touches = $0; if !$0.isEmpty { used = true } }, onClick: { ripple = ($0, Date()) })
            Canvas { ctx, _ in
                for p in touches {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 46, y: p.y - 46, width: 92, height: 92)), with: .radialGradient(Gradient(colors: [t.accent.opacity(0.42), t.accent.opacity(0.1), .clear]), center: p, startRadius: 0, endRadius: 46))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.white.opacity(0.5)))
                }
            }
            .allowsHitTesting(false)
            if let (p, at) = ripple {
                TimelineView(.animation) { ctx in
                    let a = min(1, ctx.date.timeIntervalSince(at) / 0.42)
                    Circle().stroke(t.accent.opacity((1 - a) * 0.6), lineWidth: 2).frame(width: 24 + 88 * (1 - pow(1 - a, 3)), height: 24 + 88 * (1 - pow(1 - a, 3))).position(p)
                }
                .allowsHitTesting(false)
            }
            if !used {
                VStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 30))
                    Text("One finger moves  ·  tap to click\nTwo fingers scroll  ·  two-finger tap for right-click\nDouble-tap and hold to drag").font(TypeScale.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(t.faint).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous), .control)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityLabel("Trackpad")
    }
}

/// UIKit's touches, for every finger exactly.
struct TouchSurface: UIViewRepresentable {
    let input: InputLink; let onTouches: ([CGPoint]) -> Void; let onClick: (CGPoint) -> Void
    func makeUIView(context: Context) -> Surface { let v = Surface(); v.isMultipleTouchEnabled = true; v.backgroundColor = .clear; v.input = input; v.onTouches = onTouches; v.onClick = onClick; return v }
    func updateUIView(_ v: Surface, context: Context) { v.onTouches = onTouches; v.onClick = onClick }
    final class Surface: UIView {
        weak var input: InputLink?
        var onTouches: ([CGPoint]) -> Void = { _ in }, onClick: (CGPoint) -> Void = { _ in }
        private var active = Set<UITouch>(), first: (CGPoint, TimeInterval)?, most = 1, travelled: CGFloat = 0, holding = false
        private var lastTap: TimeInterval = 0, lastTapAt = CGPoint.zero, lastAt: TimeInterval = 0
        private func report() { onTouches(active.map { $0.location(in: self) }) }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if active.isEmpty, let t = touches.first {
                let p = t.location(in: self); first = (p, t.timestamp); most = 1; travelled = 0; lastAt = t.timestamp
                holding = t.timestamp - lastTap < 0.3 && hypot(p.x - lastTapAt.x, p.y - lastTapAt.y) < 48
                if holding { MainActor.assumeIsolated { input?.frame(Frames.button(0, 1)); Haptics.thud() } }
            }
            active.formUnion(touches); most = max(most, active.count); report()
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches {
                let cur = t.location(in: self), prev = t.previousLocation(in: self), dx = cur.x - prev.x, dy = cur.y - prev.y, dist = hypot(dx, dy)
                let dt = max(1.0 / 240, t.timestamp - lastAt); lastAt = t.timestamp
                if active.count == 1 && most == 1 {
                    travelled += dist
                    // Pointer acceleration: slow moves are precise, quick ones cross the screen.
                    let speed = dist / CGFloat(dt * 1000), gain = 1.6 * (1 + min(speed * 1.4, 2.6))
                    MainActor.assumeIsolated { input?.move(Double(dx * gain), Double(dy * gain)) }
                } else if active.count >= 2 {
                    // Two fingers: the content follows them, 120 a notch every 20 points.
                    travelled += dist
                    let n = CGFloat(active.count)
                    MainActor.assumeIsolated { input?.scroll(Double(dy / n * 12), Double(-dx / n * 12)) }
                }
            }
            report()
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            active.subtract(touches); report()
            guard active.isEmpty, let f = first, let t = touches.first else { return }
            let quick = t.timestamp - f.1 < 0.28
            MainActor.assumeIsolated {
                if holding { input?.frame(Frames.button(0, 0)) }
                else if travelled < 9 && quick {
                    if most >= 2 { input?.frame(Frames.button(1, 2)); Haptics.tap() }
                    else { input?.frame(Frames.button(0, 2)); Haptics.tick(); lastTap = t.timestamp; lastTapAt = f.0 }
                    onClick(f.0)
                }
            }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { active.subtract(touches); report() }
    }
}

/// A mouse button: pressed while the finger is on it (so it can hold a drag).
struct MouseButton: View {
    let label: String; let onState: (Bool) -> Void
    @Environment(\.tokens) private var t
    @State private var down = false
    var body: some View {
        Text(label).font(TypeScale.caption).foregroundStyle(down ? t.text : t.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), .control, tint: down ? t.accent : nil)
            .scaleEffect(down ? 0.96 : 1).animation(.spring(response: 0.2, dampingFraction: 0.6), value: down)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in if !down { down = true; Haptics.tick(); onState(true) } }.onEnded { _ in if down { down = false; onState(false) } })
            .accessibilityElement().accessibilityLabel(label).accessibilityAddTraits(.isButton).accessibilityAction { onState(true); onState(false) }
    }
}

/// The keys a phone's keyboard lacks.
struct KeysRow: View {
    let input: Typist
    @Environment(\.tokens) private var t
    private var keys: [(String, String?, (Typist) -> Void)] { [
        ("Esc", nil, { $0.key(VK.escape) }), ("Tab", nil, { $0.key(VK.tab) }),
        ("Left", "arrow.left", { $0.key(VK.left) }), ("Up", "arrow.up", { $0.key(VK.up) }), ("Down", "arrow.down", { $0.key(VK.down) }), ("Right", "arrow.right", { $0.key(VK.right) }),
        ("Backspace", "delete.left", { $0.key(VK.back) }), ("Del", nil, { $0.key(VK.delete) }), ("Enter", nil, { $0.key(VK.enter) }),
        ("Start", nil, { $0.key(VK.win) }), ("Switch app", nil, { $0.key(VK.tab, VK.alt) }),
        ("Copy", nil, { $0.key(0x43, VK.control) }), ("Paste", nil, { $0.key(0x56, VK.control) }), ("Undo", nil, { $0.key(0x5A, VK.control) }),
        ("Desktop", nil, { $0.key(0x44, VK.win) }), ("Home", nil, { $0.key(VK.home) }), ("End", nil, { $0.key(VK.end) }), ("Page up", nil, { $0.key(VK.pageUp) }), ("Page down", nil, { $0.key(VK.pageDown) }),
    ] }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                    if let symbol = k.1 {
                        Button { Haptics.tick(); k.2(input) } label: { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(t.muted).frame(width: 46, height: 32).glassCapsule() }
                            .buttonStyle(PressStyle()).accessibilityLabel(k.0)
                    } else { GlassChip(label: k.0) { k.2(input) } }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden).scrollClipDisabled()
    }
}

/// Typing goes straight to the PC: each letter as it's typed, Delete as Backspace, Return as Enter; with a keyboard
/// attached, its arrows, Esc, Tab and ⌘ shortcuts (as Ctrl) too.
struct TypingField: View {
    let input: Typist; let pcName: String
    @Environment(\.tokens) private var t
    @State private var typing = false
    @State private var last = ""
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard").foregroundStyle(typing ? t.accent : t.muted)
            ZStack(alignment: .leading) {
                Text(typing ? (last.isEmpty ? "Typing on \(pcName)…" : last) : "Type on \(pcName)").font(TypeScale.body).foregroundStyle(typing && !last.isEmpty ? t.text : t.faint).lineLimit(1).truncationMode(.head)
                KeyCatcherView(active: $typing, onText: { s in
                    s.split(separator: "\n", omittingEmptySubsequences: false).enumerated().forEach { i, part in if i > 0 { input.key(VK.enter) }; if !part.isEmpty { input.frame(Frames.text(String(part))) } }
                    last = String((last + s.replacingOccurrences(of: "\n", with: " ")).suffix(40))
                }, onBackspace: { input.key(VK.back); last = String(last.dropLast()) }, onKey: { vk, mods in
                    for m in mods { input.frame(Frames.key(m, 1)) }; input.frame(Frames.key(vk, 2)); for m in mods.reversed() { input.frame(Frames.key(m, 0)) }
                })
                .frame(maxWidth: .infinity).frame(height: 22)
            }
            .frame(height: 22)
            if typing { Button("Done") { typing = false }.font(TypeScale.caption).foregroundStyle(t.accent) }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .glassCapsule(.control, tint: typing ? t.accent : nil, interactive: false)
        .contentShape(Capsule()).onTapGesture { typing = true }
        .accessibilityElement().accessibilityLabel("Type on \(pcName)").accessibilityAddTraits(.isButton).accessibilityAction { typing = true }
    }
}

/// A view that takes the keyboard itself (UIKeyInput): what's typed is handed on as it's typed, nothing kept.
struct KeyCatcherView: UIViewRepresentable {
    @Binding var active: Bool
    let onText: (String) -> Void; let onBackspace: () -> Void; let onKey: (Int, [Int]) -> Void
    func makeUIView(context: Context) -> Catcher { let c = Catcher(); c.onText = onText; c.onBackspace = onBackspace; c.onKey = onKey; c.onEnd = { active = false }; return c }
    func updateUIView(_ c: Catcher, context: Context) {
        c.onText = onText; c.onBackspace = onBackspace; c.onKey = onKey
        DispatchQueue.main.async { if active && !c.isFirstResponder { c.becomeFirstResponder() } else if !active && c.isFirstResponder { _ = c.resignFirstResponder() } }
    }
    final class Catcher: UIView, UIKeyInput {
        var onText: (String) -> Void = { _ in }, onBackspace: () -> Void = {}, onKey: (Int, [Int]) -> Void = { _, _ in }, onEnd: () -> Void = {}
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .sentences
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        var smartDashesType: UITextSmartDashesType = .no
        var returnKeyType: UIReturnKeyType = .send
        var keyboardAppearance: UIKeyboardAppearance = .default
        override var canBecomeFirstResponder: Bool { true }
        var hasText: Bool { true }
        func insertText(_ text: String) { onText(text) }
        func deleteBackward() { onBackspace() }
        override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); onEnd(); return r }
        /// A keyboard's own keys (an iPad's, or one paired to the iPhone).
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for p in presses {
                guard let k = p.key else { continue }
                var mods: [Int] = []
                if k.modifierFlags.contains(.command) || k.modifierFlags.contains(.control) { mods.append(VK.control) }
                if k.modifierFlags.contains(.alternate) { mods.append(VK.alt) }
                let named: [UIKeyboardHIDUsage: Int] = [.keyboardEscape: VK.escape, .keyboardTab: VK.tab, .keyboardLeftArrow: VK.left, .keyboardRightArrow: VK.right, .keyboardUpArrow: VK.up, .keyboardDownArrow: VK.down,
                                                        .keyboardDeleteForward: VK.delete, .keyboardHome: VK.home, .keyboardEnd: VK.end, .keyboardPageUp: VK.pageUp, .keyboardPageDown: VK.pageDown]
                if k.modifierFlags.contains(.shift) && (!mods.isEmpty || named[k.keyCode] != nil) { mods.append(VK.shift) }
                if let vk = named[k.keyCode] { onKey(vk, mods); handled = true; continue }
                let f = k.keyCode.rawValue
                if f >= UIKeyboardHIDUsage.keyboardF1.rawValue && f <= UIKeyboardHIDUsage.keyboardF12.rawValue { onKey(0x70 + f - UIKeyboardHIDUsage.keyboardF1.rawValue, mods); handled = true; continue }
                if !mods.isEmpty, let c = k.charactersIgnoringModifiers.uppercased().unicodeScalars.first, c.isASCII, (c.value >= 0x30 && c.value <= 0x39) || (c.value >= 0x41 && c.value <= 0x5A) { onKey(Int(c.value), mods); handled = true }
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }
    }
}
