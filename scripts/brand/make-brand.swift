// Generates every Pier brand asset from one set of shapes:
//   Resources/AppIcon.icon      Icon Composer bundle (layers as SVG) for the macOS 26 app icon
//   docs/brand/*.svg, *.png     icon, logo lockups, GitHub social preview, LinkedIn image
//
// Run from the repository root:  swift scripts/brand/make-brand.swift
//
// The mark: seen from above, a pier is a deck that runs from the shore into the water and
// ends in a rounded tip, which is also the shape of the MacBook notch Pier lives in. A dark
// shore runs along the top, the pier hangs down from it, ripples spread from its end, and a
// lantern burns at the tip.

import AppKit
import SwiftUI

// MARK: - Geometry (1024 × 1024 canvas, y down)

enum Mark {
    static let canvas: CGFloat = 1024
    static let shoreHeight: CGFloat = 176
    static let pierLeft: CGFloat = 382, pierRight: CGFloat = 642
    static let pierEnd: CGFloat = 640
    static let tipRadius: CGFloat = 118
    static let flare: CGFloat = 64
    static let lantern = (center: CGPoint(x: 512, y: 548), radius: CGFloat(44))
    /// Ripples centred on the pier's tip: radius, stroke width, opacity.
    static let ripples: [(radius: CGFloat, width: CGFloat, opacity: Double)] = [(212, 30, 0.85), (318, 26, 0.45)]
    static let rippleCenter = CGPoint(x: 512, y: 548)
    static let rippleSpan: (from: Double, to: Double) = (200, -20) // degrees, sweeping through the bottom
    /// Planks across the deck, as y positions.
    static let planks: [CGFloat] = [262, 338, 414]
    static let plankColor = "#222835"

    // Colors
    static let shore = "#0B0E14"
    static let lanternColor = "#FFB238"
    static let waterTop = (r: 0.16, g: 0.63, b: 0.88)    // #29A0E0
    static let waterBottom = (r: 0.04, g: 0.19, b: 0.44) // #0A3070

    /// Shore and pier as one outline. Same construction as `NotchShape` in the app.
    static var pierSVGPath: String {
        let (l, r, e, t, f, s) = (pierLeft, pierRight, pierEnd, tipRadius, flare, shoreHeight)
        return "M0,0 H\(canvas) V\(s) H\(r + f) Q\(r),\(s) \(r),\(s + f) V\(e - t) Q\(r),\(e) \(r - t),\(e) "
            + "H\(l + t) Q\(l),\(e) \(l),\(e - t) V\(s + f) Q\(l),\(s) \(l - f),\(s) H0 Z"
    }

    static func ripplePoint(radius: CGFloat, degrees: Double) -> CGPoint {
        let a = CGFloat(degrees * .pi / 180)
        return CGPoint(x: rippleCenter.x + radius * cos(a), y: rippleCenter.y + radius * sin(a))
    }

    static func rippleSVGPath(radius: CGFloat) -> String {
        let a = ripplePoint(radius: radius, degrees: rippleSpan.from), b = ripplePoint(radius: radius, degrees: rippleSpan.to)
        return "M\(a.x),\(a.y) A\(radius),\(radius) 0 1 0 \(b.x),\(b.y)"
    }

    static func pierPath(scale k: CGFloat) -> Path {
        let (l, r, e, t, f, s) = (pierLeft * k, pierRight * k, pierEnd * k, tipRadius * k, flare * k, shoreHeight * k)
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: canvas * k, y: 0))
        p.addLine(to: CGPoint(x: canvas * k, y: s))
        p.addLine(to: CGPoint(x: r + f, y: s))
        p.addQuadCurve(to: CGPoint(x: r, y: s + f), control: CGPoint(x: r, y: s))
        p.addLine(to: CGPoint(x: r, y: e - t))
        p.addQuadCurve(to: CGPoint(x: r - t, y: e), control: CGPoint(x: r, y: e))
        p.addLine(to: CGPoint(x: l + t, y: e))
        p.addQuadCurve(to: CGPoint(x: l, y: e - t), control: CGPoint(x: l, y: e))
        p.addLine(to: CGPoint(x: l, y: s + f))
        p.addQuadCurve(to: CGPoint(x: l - f, y: s), control: CGPoint(x: l, y: s))
        p.addLine(to: CGPoint(x: 0, y: s))
        p.closeSubpath()
        return p
    }

    static func ripplePath(radius: CGFloat, scale k: CGFloat) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rippleCenter.x * k, y: rippleCenter.y * k), radius: radius * k,
                 startAngle: .degrees(rippleSpan.from), endAngle: .degrees(rippleSpan.to), clockwise: true)
        return p
    }
}

func hex(_ c: (r: Double, g: Double, b: Double)) -> String {
    String(format: "#%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
}

func color(_ c: (r: Double, g: Double, b: Double)) -> Color { Color(red: c.r, green: c.g, blue: c.b) }
func color(hex s: String) -> Color {
    let v = Int(s.dropFirst(), radix: 16)!
    return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

// MARK: - SwiftUI renderings

/// The full icon: water, ripples, shore and pier, lantern.
struct PierIcon: View {
    var size: CGFloat
    var masked = true

    var body: some View {
        let k = size / Mark.canvas
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [color(Mark.waterTop), color(Mark.waterBottom)], startPoint: .top, endPoint: .bottom)
            ForEach(Mark.ripples.indices, id: \.self) { i in
                let ripple = Mark.ripples[i]
                Mark.ripplePath(radius: ripple.radius, scale: k)
                    .stroke(.white.opacity(ripple.opacity), style: StrokeStyle(lineWidth: ripple.width * k, lineCap: .round))
            }
            Mark.pierPath(scale: k).fill(color(hex: Mark.shore))
            ForEach(Mark.planks, id: \.self) { y in
                Path { p in
                    p.move(to: CGPoint(x: (Mark.pierLeft + 34) * k, y: y * k))
                    p.addLine(to: CGPoint(x: (Mark.pierRight - 34) * k, y: y * k))
                }
                .stroke(color(hex: Mark.plankColor), style: StrokeStyle(lineWidth: 14 * k, lineCap: .round))
            }
            Circle()
                .fill(color(hex: Mark.lanternColor))
                .frame(width: Mark.lantern.radius * 2 * k, height: Mark.lantern.radius * 2 * k)
                .position(x: Mark.lantern.center.x * k, y: Mark.lantern.center.y * k)
        }
        .frame(width: size, height: size)
        // macOS icon grid: the shape is 824 of 1024 with a continuous corner of ~185.
        .clipShape(RoundedRectangle(cornerRadius: masked ? size * 0.2237 : 0, style: .continuous))
    }
}

/// Icon in its 824/1024 grid position, as macOS shows it, for use next to text.
struct GridIcon: View {
    var size: CGFloat
    var body: some View {
        PierIcon(size: size)
            .shadow(color: .black.opacity(0.28), radius: size * 0.03, y: size * 0.015)
    }
}

struct Lockup: View {
    var dark: Bool
    var body: some View {
        HStack(spacing: 34) {
            GridIcon(size: 168)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pier")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .tracking(-2)
                Text("hidden in the notch")
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .opacity(0.6)
            }
            .foregroundStyle(dark ? Color.white : color(hex: Mark.shore))
        }
        .padding(24)
    }
}

struct Showcase: View {
    var width: CGFloat
    var height: CGFloat
    var screenshot: NSImage

    var body: some View {
        ZStack {
            LinearGradient(colors: [color(hex: "#0A1B3A"), color(hex: "#05080F")], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Ripples from the brand mark, large and faint, behind everything.
            ForEach([520.0, 760, 1000], id: \.self) { radius in
                Circle()
                    .stroke(.white.opacity(0.05), lineWidth: 22)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: width * 0.08, y: height * 1.02)
            }
            HStack(spacing: width * 0.045) {
                VStack(alignment: .leading, spacing: height * 0.035) {
                    GridIcon(size: height * 0.24)
                    Text("Pier")
                        .font(.system(size: height * 0.17, weight: .bold, design: .rounded))
                        .tracking(-2)
                        .foregroundStyle(.white)
                    Text("Your Mac's vitals, music, files,\nand wallpaper, hidden in the notch.")
                        .font(.system(size: height * 0.042, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineSpacing(height * 0.008)
                    HStack(spacing: 10) {
                        tag("Open source")
                        tag("SwiftUI")
                        tag("macOS 26")
                    }
                }
                .frame(width: width * 0.36, alignment: .leading)

                Image(nsImage: screenshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: height * 0.03, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: height * 0.03, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 2))
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
                    .frame(width: width * 0.5)
            }
            .padding(.horizontal, width * 0.055)
        }
        .frame(width: width, height: height)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: height * 0.026, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, height * 0.022)
            .padding(.vertical, height * 0.01)
            .background(.white.opacity(0.1), in: Capsule())
    }
}

// MARK: - Output

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brand = root.appendingPathComponent("docs/brand")
let iconBundle = root.appendingPathComponent("Resources/AppIcon.icon")
try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconBundle)
try FileManager.default.createDirectory(at: iconBundle.appendingPathComponent("Assets"), withIntermediateDirectories: true)

func svg(_ body: String, defs: String = "") -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\(defs)
    \(body)
    </svg>

    """
}

let rippleSVG = Mark.ripples.map {
    "<path d=\"\(Mark.rippleSVGPath(radius: $0.radius))\" fill=\"none\" stroke=\"#FFFFFF\" stroke-opacity=\"\($0.opacity)\" stroke-width=\"\($0.width)\" stroke-linecap=\"round\"/>"
}.joined(separator: "\n")
let pierSVG = "<path d=\"\(Mark.pierSVGPath)\" fill=\"\(Mark.shore)\"/>\n" + Mark.planks.map {
    "<path d=\"M\(Mark.pierLeft + 34),\($0) H\(Mark.pierRight - 34)\" stroke=\"\(Mark.plankColor)\" stroke-width=\"14\" stroke-linecap=\"round\"/>"
}.joined(separator: "\n")
let lanternSVG = "<circle cx=\"\(Mark.lantern.center.x)\" cy=\"\(Mark.lantern.center.y)\" r=\"\(Mark.lantern.radius)\" fill=\"\(Mark.lanternColor)\"/>"

// Icon Composer layers: square and unmasked; the system adds the shape and the glass.
try svg(rippleSVG).write(to: iconBundle.appendingPathComponent("Assets/ripples.svg"), atomically: true, encoding: .utf8)
try svg(pierSVG).write(to: iconBundle.appendingPathComponent("Assets/pier.svg"), atomically: true, encoding: .utf8)
try svg(lanternSVG).write(to: iconBundle.appendingPathComponent("Assets/lantern.svg"), atomically: true, encoding: .utf8)

func p3(_ c: (r: Double, g: Double, b: Double)) -> String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b) }
let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "\(p3(Mark.waterTop))",
      "\(p3(Mark.waterBottom))"
    ]
  },
  "groups" : [
    {
      "layers" : [
        { "image-name" : "lantern.svg", "name" : "lantern" },
        { "image-name" : "pier.svg", "name" : "pier" }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.4 }
    },
    {
      "layers" : [
        { "image-name" : "ripples.svg", "name" : "ripples" }
      ],
      "shadow" : { "kind" : "none", "opacity" : 0 },
      "translucency" : { "enabled" : true, "value" : 0.3 }
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}

"""
try iconJSON.write(to: iconBundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)

// A flat vector of the whole icon, for places that can't read an .icon bundle (GitHub, slides).
let flatIcon = svg("""
<g clip-path="url(#shape)">
<rect width="1024" height="1024" fill="url(#water)"/>
\(rippleSVG)
\(pierSVG)
\(lanternSVG)
</g>
""", defs: """

<defs>
<linearGradient id="water" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\(hex(Mark.waterTop))"/><stop offset="1" stop-color="\(hex(Mark.waterBottom))"/></linearGradient>
<clipPath id="shape"><rect width="1024" height="1024" rx="229" ry="229"/></clipPath>
</defs>
""")
try flatIcon.write(to: brand.appendingPathComponent("pier-icon.svg"), atomically: true, encoding: .utf8)

// Template glyph for the menu bar: shore, pier and one ripple in a single color.
let menuGlyph = """
<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
<path fill-rule="evenodd" fill="#000" d="M1,1.5 H17 V4 H12.3 Q11.4,4 11.4,4.9 V9.3 Q11.4,11.5 9.2,11.5 H8.8 Q6.6,11.5 6.6,9.3 V4.9 Q6.6,4 5.7,4 H1 Z M10.1,9.2 A1.1,1.1 0 1 0 7.9,9.2 A1.1,1.1 0 1 0 10.1,9.2 Z"/>
<path d="M4.11,7.42 A5.2,5.2 0 1 0 13.89,7.42" fill="none" stroke="#000" stroke-width="1.5" stroke-linecap="round"/>
</svg>
"""
try menuGlyph.write(to: brand.appendingPathComponent("pier-menubar.svg"), atomically: true, encoding: .utf8)

@MainActor
func png<V: View>(_ view: V, _ name: String, scale: CGFloat = 1) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try data.write(to: brand.appendingPathComponent(name))
    print("wrote docs/brand/\(name) \(image.width)×\(image.height)")
}

let screenshot = NSImage(contentsOf: root.appendingPathComponent("docs/screenshots/notch-open.png"))!

try MainActor.assumeIsolated {
    try png(PierIcon(size: 1024), "pier-icon.png")
    try png(Lockup(dark: false), "logo-light.png", scale: 2)
    try png(Lockup(dark: true), "logo-dark.png", scale: 2)
    try png(Showcase(width: 1280, height: 640, screenshot: screenshot), "social-preview.png")
    try png(Showcase(width: 1200, height: 627, screenshot: screenshot), "linkedin.png", scale: 2)
}
print("wrote Resources/AppIcon.icon")
