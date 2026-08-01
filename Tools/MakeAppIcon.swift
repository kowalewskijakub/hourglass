import SwiftUI
import AppKit

// The app icon: the hourglass mark in the Orbit palette, and nothing else.
//
// Generated rather than drawn so it stays in step with the palette and uses the
// same SF Symbol vocabulary as the app. Deliberately plain — an icon is read at
// 16 pt in a Finder list and at a glance on a home screen, so scene detail that
// looks good at 1024 is only noise everywhere the icon actually gets used.
//
//   swift Tools/MakeAppIcon.swift <output-directory> [style]
//
// Styles: `night` (default) — ember mark on deep space.
//         `ember` — dark mark knocked out of an ember field.

enum IconStyle: String {
    case night
    case ember
}

struct IconArt: View {
    var style: IconStyle
    /// iOS icons are full bleed and masked by the system; macOS icons are drawn
    /// inside the squircle with the conventional margin around them.
    var inset: CGFloat

    private static let sky = Color(red: 0x07 / 255, green: 0x0A / 255, blue: 0x10 / 255)
    private static let skyLift = Color(red: 0x16 / 255, green: 0x22 / 255, blue: 0x39 / 255)
    private static let ember = Color(red: 0xF0 / 255, green: 0xA3 / 255, blue: 0x3F / 255)
    private static let emberDeep = Color(red: 0xD4 / 255, green: 0x88 / 255, blue: 0x25 / 255)
    private static let onEmber = Color(red: 0x21 / 255, green: 0x13 / 255, blue: 0x03 / 255)

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            let content = side * (1 - inset * 2)

            ZStack {
                background
                Image(systemName: "hourglass")
                    .font(.system(size: content * 0.54, weight: .medium))
                    .foregroundStyle(mark)
            }
            .frame(width: content, height: content)
            // Only macOS draws its own squircle. An iOS icon must be an opaque
            // square with square corners — the system applies the mask, and
            // rounding it here leaves transparent corners that fail App Store
            // validation.
            .clipShape(
                RoundedRectangle(
                    cornerRadius: inset > 0 ? content * 0.2237 : 0,
                    style: .continuous
                )
            )
            .position(x: side / 2, y: side / 2)
        }
    }

    /// One soft gradient, just enough that the field is not flat paint. Nothing
    /// that competes with the mark.
    private var background: some View {
        LinearGradient(
            colors: style == .night ? [Self.skyLift, Self.sky] : [Self.ember, Self.emberDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var mark: Color {
        style == .night ? Self.ember : Self.onEmber
    }
}

@MainActor
func render(size: CGFloat, style: IconStyle, inset: CGFloat, to url: URL) {
    let renderer = ImageRenderer(
        content: IconArt(style: style, inset: inset).frame(width: size, height: size)
    )
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("failed at \(size)")
        return
    }
    try? png.write(to: url)
}

@MainActor
func main() {
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    let style = CommandLine.arguments.count > 2
        ? IconStyle(rawValue: CommandLine.arguments[2]) ?? .night
        : .night
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    for size in [16, 32, 64, 128, 256, 512, 1024] as [CGFloat] {
        render(size: size, style: style, inset: 0.09,
               to: out.appendingPathComponent("mac_\(Int(size)).png"))
    }
    render(size: 1024, style: style, inset: 0, to: out.appendingPathComponent("ios_1024.png"))
    print("rendered \(style.rawValue)")
}

MainActor.assumeIsolated { main() }
