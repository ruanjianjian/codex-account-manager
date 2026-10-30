import AppKit
import SwiftUI
import AccountCore

/// Tibot's mascot: a small black tile peeking over a gray stone, as on the app icon. Its other moods are the other
/// sketches: a >_ wink to say hello, thin legs and big shoes for a hop, one buck tooth for good news, dead-fish
/// eyes when every account is out, odd eyes while the gateway is not up.
struct Dango: View {
    let mood: MascotMood
    /// How far the peeking mascot rises over its stone, 0...1.
    var lift: CGFloat = 0
    private static let ink = Color(white: 0.067)
    private static let gray = Color(red: 0.557, green: 0.557, blue: 0.576)
    private static let lightGray = Color(red: 0.682, green: 0.682, blue: 0.698)
    var body: some View {
        Canvas { context, size in Self.draw(context, s: min(size.width, size.height), mood: mood, lift: lift) }
            .accessibilityHidden(true)
    }

    /// Every mood is drawn in its sketch's 160-unit square; the crop is the part of it that fills the view.
    private static func draw(_ context: GraphicsContext, s: CGFloat, mood: MascotMood, lift: CGFloat) {
        var c = context
        let crop: (x: CGFloat, y: CGFloat, w: CGFloat) = switch mood {
        case .open, .blink: (20, 32, 120)
        case .sad: (32, 32, 96)
        case .puzzled: (29, 29, 102)
        case .hello: (26, 26, 108)
        case .hop: (26, 24, 108)
        case .star: (34, 30, 92)
        }
        c.scaleBy(x: s / crop.w, y: s / crop.w)
        c.translateBy(x: -crop.x, y: -crop.y)
        func tile(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ corner: CGFloat) {
            c.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: corner), with: .color(ink))
        }
        func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: Color) {
            c.fill(Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry)), with: .color(color))
        }
        func line(_ points: [CGPoint], _ width: CGFloat, _ color: Color) {
            var path = Path(); path.addLines(points)
            c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        switch mood {
        case .open, .blink:
            // Hands on the stone; the head rises over it.
            let y = -8 * lift
            tile(40, 40 + y, 80, 80, 26)
            for x in [66.0, 94] as [CGFloat] {
                if mood == .blink {
                    line([CGPoint(x: x - 7, y: 69 + y), CGPoint(x: x + 7, y: 69 + y)], 3.5, .white)
                } else {
                    oval(x, 68 + y, 8.5, 8.5, .white); oval(x + 4, 69 + y, 3.6, 3.6, ink)
                }
            }
            oval(80, 116, 60, 28, gray); oval(80, 103, 52, 14, lightGray)
            oval(52, 92, 8, 6, ink); oval(108, 92, 8, 6, ink)
        case .sad:
            tile(32, 32, 96, 96, 30)
            oval(62, 74, 14, 14, .white); oval(98, 74, 14, 14, .white)
            c.fill(Path(CGRect(x: 44, y: 56, width: 72, height: 18)), with: .color(ink))
            oval(62, 81, 5, 5, ink); oval(98, 81, 5, 5, ink)
            line([CGPoint(x: 72, y: 106), CGPoint(x: 90, y: 104)], 4, .white)
        case .puzzled:
            c.translateBy(x: 80, y: 80); c.rotate(by: .degrees(-6)); c.translateBy(x: -80, y: -80)
            tile(34, 34, 92, 92, 28)
            oval(64, 74, 17, 17, .white); oval(70, 77, 6.5, 6.5, ink)
            oval(101, 66, 4.5, 4.5, .white)
            line([CGPoint(x: 76, y: 106), CGPoint(x: 96, y: 106)], 4, gray)
        case .hello:
            tile(26, 26, 108, 108, 34)
            line([CGPoint(x: 44, y: 58), CGPoint(x: 64, y: 72), CGPoint(x: 44, y: 86)], 9, .white)
            oval(104, 72, 9, 9, .white)
            c.fill(Path(roundedRect: CGRect(x: 66, y: 104, width: 34, height: 9), cornerRadius: 4.5), with: .color(gray))
        case .hop:
            tile(64, 86, 4, 32, 2); tile(92, 86, 4, 32, 2)
            oval(59, 124, 18, 8, gray); oval(101, 124, 18, 8, gray)
            tile(46, 24, 68, 66, 22)
            oval(68, 54, 6, 6, .white); oval(92, 54, 6, 6, .white)
            line([CGPoint(x: 74, y: 72), CGPoint(x: 86, y: 72)], 3.5, .white)
        case .star:
            tile(34, 30, 92, 92, 28)
            oval(64, 66, 7, 7, .white); oval(96, 66, 7, 7, .white)
            line([CGPoint(x: 62, y: 94), CGPoint(x: 98, y: 94)], 4, .white)
            let tooth = CGAffineTransform(translationX: 80, y: 103).rotated(by: .pi / 30).translatedBy(x: -80, y: -103)
            c.fill(Path(roundedRect: CGRect(x: 73, y: 93, width: 14, height: 20), cornerRadius: 3).applying(tooth), with: .color(.white))
        }
    }

    /// The mascot as a PNG, for a notification's thumbnail.
    @MainActor static func png(_ mood: MascotMood, size: CGFloat = 160) -> Data? {
        let renderer = ImageRenderer(content: Dango(mood: mood).frame(width: size * 0.8, height: size * 0.8).frame(width: size, height: size))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// The mascot alive: it blinks every few seconds while it peeks, and bobs while a request is running (peeking, only
/// its head rises over the stone). Otherwise nothing redraws.
struct LiveDango: View {
    let mood: MascotMood
    var busy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinking = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !busy || reduceMotion)) { timeline in
            let bob = busy && !reduceMotion ? abs(sin(timeline.date.timeIntervalSinceReferenceDate * 7)) : 0
            GeometryReader { proxy in
                Dango(mood: mood == .open && blinking ? .blink : mood, lift: mood == .open ? bob : 0)
                    .offset(y: mood == .open ? 0 : -bob * proxy.size.height * 0.1)
            }
        }
        .task(id: reduceMotion || mood != .open) {
            guard !reduceMotion, mood == .open else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.6...4.8)))
                blinking = true
                try? await Task.sleep(for: .milliseconds(140))
                blinking = false
            }
        }
    }
}

/// First run: the mascot winks and asks for the first account.
struct DangoWelcome: View {
    let add: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            LiveDango(mood: .hello).frame(width: 46, height: 46)
            Text("嗨，先连上你的 Codex 账号").font(.system(size: 13, weight: .medium))
            Button(action: add) {
                Text("连接").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 5).background(Color(white: 0.12), in: Capsule())
            }.buttonStyle(.plain).accessibilityLabel("连接第一个 Codex 账号")
        }
    }
}
