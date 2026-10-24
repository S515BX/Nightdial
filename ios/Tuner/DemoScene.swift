import SwiftUI
import UIKit
import CoreText

/// A drawn "broadcast" for demo channels, used when the sample streams can't be reached.
@MainActor
struct DemoScene: View {
    let channel: Channel
    let program: Program?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let ch = channel
            let p = program
            Canvas { g, size in
                DemoScene.draw(&g, size: size, t: t, channel: ch, program: p)
            }
        }
        .accessibilityLabel("Demo picture for \(channel.name)")
    }

    nonisolated private static func face(_ size: CGFloat, _ weight: UIFont.Weight) -> Font {
        Font(TFont.broadcast(max(8, size), weight) as CTFont)
    }

    nonisolated private static func draw(_ g: inout GraphicsContext, size: CGSize, t: Double, channel: Channel, program: Program?) {
        let w = size.width, h = size.height
        guard w > 1, h > 1 else { return }
        let hue = channel.hue / 360
        let top = Color(hue: hue, saturation: 0.55, brightness: 0.30)
        let bottom = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.08)
        g.fill(Path(CGRect(origin: .zero, size: size)),
               with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: .zero, endPoint: CGPoint(x: w, y: h)))

        for i in 0..<8 {
            let fi = Double(i)
            let x = ((fi * 0.17 + t * 0.02 * (1 + fi.truncatingRemainder(dividingBy: 3))).truncatingRemainder(dividingBy: 1.2)) * w - w * 0.1
            let y = h * (0.15 + 0.55 * (fi * 0.37).truncatingRemainder(dividingBy: 1))
            let r = h * (0.08 + 0.04 * fi.truncatingRemainder(dividingBy: 3))
            let alpha = 0.12 + 0.06 * sin(t * 0.7 + fi)
            let glow = Color(hue: (hue + fi * 0.03).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.95)
            g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                   with: .radialGradient(Gradient(colors: [glow.opacity(alpha), glow.opacity(0)]),
                                         center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
        }

        // Lower third with the program title.
        let barY = h * 0.70, barH = h * 0.11, x0 = w * 0.06
        let isLive = program?.live == true
        let tag = g.resolve(Text(isLive ? "LIVE" : "ON AIR").font(face(barH * 0.42, .bold)).foregroundColor(.white))
        let tagW = tag.measure(in: CGSize(width: w, height: barH)).width + barH * 0.5
        g.fill(Path(CGRect(x: x0, y: barY, width: tagW, height: barH)),
               with: .color(isLive ? Theme.live : Color(hue: hue, saturation: 0.55, brightness: 0.45)))
        g.draw(tag, at: CGPoint(x: x0 + barH * 0.25, y: barY + barH / 2), anchor: .leading)
        let titleW = max(0, w * 0.84 - tagW)
        g.fill(Path(CGRect(x: x0 + tagW, y: barY, width: titleW, height: barH)), with: .color(Color.white.opacity(0.95)))
        let title = g.resolve(Text(program?.title ?? channel.name).font(face(barH * 0.48, .semibold)).foregroundColor(Color(uiColor: UIColor(hex: 0x10161D))))
        var clipped = g
        clipped.clip(to: Path(CGRect(x: x0 + tagW, y: barY, width: max(0, titleW - barH * 0.2), height: barH)))
        clipped.draw(title, at: CGPoint(x: x0 + tagW + barH * 0.25, y: barY + barH / 2), anchor: .leading)

        // Ticker.
        let tickerY = h * 0.885, tickerH = h * 0.075
        g.fill(Path(CGRect(x: 0, y: tickerY, width: w, height: tickerH)), with: .color(Color.black.opacity(0.85)))
        let ticker = g.resolve(Text(Demo.ticker).font(face(tickerH * 0.5, .medium)).foregroundColor(Color(uiColor: Palette.fg)))
        let tickerW = max(1, ticker.measure(in: CGSize(width: 100_000, height: tickerH)).width)
        var tx = -(t * h * 0.12).truncatingRemainder(dividingBy: tickerW)
        while tx < w {
            g.draw(ticker, at: CGPoint(x: tx, y: tickerY + tickerH / 2), anchor: .leading)
            tx += tickerW
        }

        // Channel bug.
        let bug = g.resolve(Text("\(channel.initials) \(channel.num)").font(face(h * 0.045, .bold)).foregroundColor(Color.white.opacity(0.7)))
        g.draw(bug, at: CGPoint(x: w * 0.96, y: h * 0.09), anchor: .trailing)
    }
}
