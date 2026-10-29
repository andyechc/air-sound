import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let stageDir = CommandLine.arguments[1]

/// Renders the Air Sound mark (center dot + two radio-wave arcs per side) at
/// `size` px. Opaque full-bleed background for iOS; for macOS the background is
/// clipped to a Big-Sur-style squircle sitting in a transparent canvas margin.
func render(size: Int, macSquircle: Bool) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Background: subtle vertical sky-blue gradient (Apple icon language), no
    // glow, no stripes. Same accent family as the in-app AccentColor asset.
    if macSquircle {
        let shape = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                           cornerWidth: 185, cornerHeight: 185, transform: nil)
        c.addPath(shape)
        c.clip()
    }
    let top = CGColor(srgbRed: 0.13, green: 0.66, blue: 0.98, alpha: 1)
    let bottom = CGColor(srgbRed: 0.00, green: 0.49, blue: 0.86, alpha: 1)
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

    // The mark, drawn in 1024 master coordinates.
    let s = CGFloat(size) / 1024
    let center = CGPoint(x: 512, y: 512)
    c.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    c.setLineWidth(60 * s)
    c.setLineCap(.round)
    let spread: CGFloat = 0.63 // ~36 degrees, matches a "waves reaching out" pose
    for radius in [205.0, 318.0] {
        c.addArc(center: center, radius: radius * s, startAngle: -spread, endAngle: spread, clockwise: false)
        c.strokePath()
        c.addArc(center: center, radius: radius * s, startAngle: .pi - spread, endAngle: .pi + spread, clockwise: false)
        c.strokePath()
    }
    let dot = CGRect(x: center.x - 88 * s, y: center.y - 88 * s, width: 176 * s, height: 176 * s)
    c.fillEllipse(in: dot)

    return c.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

writePNG(render(size: 1024, macSquircle: false), to: "\(stageDir)/AirSound-iOS-1024.png")
writePNG(render(size: 1024, macSquircle: true), to: "\(stageDir)/AirSound-mac-1024.png")
print("icons rendered")
