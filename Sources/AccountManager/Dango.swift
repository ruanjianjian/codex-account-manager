import AppKit
import SwiftUI
import AccountCore

/// 「终端团子」: the dark >_ tile grown soft, with eyes, blush and the "_" as a mint smile.
struct Dango: View {
    let mood: MascotMood
    private static let body = Color(white: 0.11)
    private static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    var body: some View {
        Canvas { context, size in Self.draw(&context, s: min(size.width, size.height), mood: mood) }
            .rotationEffect(.degrees(mood == .hello ? -8 : 0))
            .accessibilityHidden(true)
    }

    private static func draw(_ context: inout GraphicsContext, s: CGFloat, mood: MascotMood) {
        let ey = s * 0.42, er = s * 0.105, line = max(1.2, s * 0.05)
        context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerRadius: s * 0.3), with: .color(body))
        for side in [-1.0, 1.0] {
            let cx = s / 2 + side * s * 0.2
            switch mood {
            case .open, .hello:
                context.fill(Path(ellipseIn: CGRect(x: cx - er, y: ey - er * 1.15, width: er * 2, height: er * 2.3)), with: .color(.white))
                let pr = er * 0.55
                context.fill(Path(ellipseIn: CGRect(x: cx + s * 0.02 - pr, y: ey + s * 0.012 - pr, width: pr * 2, height: pr * 2)), with: .color(body))
            case .blink, .sleep:
                let y = mood == .sleep ? ey + s * 0.03 : ey
                context.fill(Path(roundedRect: CGRect(x: cx - er * 0.85, y: y - line / 2, width: er * 1.7, height: line), cornerRadius: line / 2), with: .color(.white))
            case .hop:
                var chevron = Path()
                chevron.move(to: CGPoint(x: cx + side * er, y: ey - er * 0.8))
                chevron.addLine(to: CGPoint(x: cx - side * er * 0.6, y: ey))
                chevron.addLine(to: CGPoint(x: cx + side * er, y: ey + er * 0.8))
                context.stroke(chevron, with: .color(.white), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            case .star:
                // A four-point sparkle for each eye.
                let r = s * 0.13, w = s * 0.034
                var star = Path()
                star.move(to: CGPoint(x: cx, y: ey - r))
                for (dx, dy) in [(w, -w), (r, 0), (w, w), (0, r), (-w, w), (-r, 0), (-w, -w)] as [(CGFloat, CGFloat)] {
                    star.addLine(to: CGPoint(x: cx + dx, y: ey + dy))
                }
                star.closeSubpath()
                context.fill(star, with: .color(Color(red: 1, green: 0.84, blue: 0.04)))
            case .sad:
                // Round eyes looking down, with drooping lids.
                context.fill(Path(ellipseIn: CGRect(x: cx - er * 0.95, y: ey + s * 0.02 - er * 0.95, width: er * 1.9, height: er * 1.9)), with: .color(.white))
                let pr = er * 0.5
                context.fill(Path(ellipseIn: CGRect(x: cx - pr, y: ey + s * 0.05 - pr, width: pr * 2, height: pr * 2)), with: .color(body))
                var lid = context
                lid.translateBy(x: cx, y: ey - s * 0.04); lid.rotate(by: .degrees(side * 12))
                lid.fill(Path(CGRect(x: -s * 0.12, y: -s * 0.1, width: s * 0.24, height: s * 0.1)), with: .color(body))
            }
            if mood != .sad {
                let blush = CGRect(x: s / 2 + side * s * 0.33 - s * 0.085, y: s * 0.64 - s * 0.048, width: s * 0.17, height: s * 0.096)
                context.fill(Path(ellipseIn: blush), with: .color(Color(red: 1, green: 0.5, blue: 0.59).opacity(0.6)))
            }
        }
        switch mood {
        case .star, .hello:
            var smile = Path()
            smile.move(to: CGPoint(x: s * 0.41, y: s * 0.66))
            smile.addQuadCurve(to: CGPoint(x: s * 0.59, y: s * 0.66), control: CGPoint(x: s * 0.5, y: s * 0.8))
            smile.closeSubpath()
            context.fill(smile, with: .color(green))
        case .sad:
            var frown = Path()
            frown.move(to: CGPoint(x: s * 0.42, y: s * 0.72))
            frown.addQuadCurve(to: CGPoint(x: s * 0.58, y: s * 0.72), control: CGPoint(x: s * 0.5, y: s * 0.64))
            context.stroke(frown, with: .color(Color(white: 0.56)), style: StrokeStyle(lineWidth: line * 0.8, lineCap: .round))
        default:
            let mouth = CGRect(x: s / 2 - s * 0.09, y: s * 0.68, width: s * 0.18, height: max(1.5, s * 0.05))
            context.fill(Path(roundedRect: mouth, cornerRadius: mouth.height / 2), with: .color(green))
        }
        if mood == .sleep {
            var z = Path()
            let x = s * 0.7, y = s * 0.1, d = s * 0.11
            z.move(to: CGPoint(x: x, y: y)); z.addLine(to: CGPoint(x: x + d, y: y))
            z.addLine(to: CGPoint(x: x, y: y + d)); z.addLine(to: CGPoint(x: x + d, y: y + d))
            context.stroke(z, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: line * 0.7, lineCap: .round, lineJoin: .round))
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

/// The mascot alive: it blinks every few seconds while its eyes are open and bobs while a request is running.
/// Otherwise nothing redraws.
struct LiveDango: View {
    let mood: MascotMood
    var busy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinking = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !busy || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                Dango(mood: mood == .open && blinking ? .blink : mood)
                    .offset(y: busy && !reduceMotion ? -abs(sin(t * 7)) * proxy.size.height * 0.1 : 0)
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

/// First run: the mascot waves and asks for the first account.
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
