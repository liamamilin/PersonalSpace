// Native, deterministic artwork. Run: xcrun swift scripts/make_app_icon.swift
import AppKit
import Foundation

func rounded(_ rectangle: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rectangle, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ path: CGPath, colors: [CGColor], from start: CGPoint, to end: CGPoint, in context: CGContext) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: 1)
}

func makeIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconFailure.render
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1_024, y: CGFloat(pixels) / 1_024)
    context.clear(CGRect(x: 0, y: 0, width: 1_024, height: 1_024))
    context.setAllowsAntialiasing(true)

    let tile = rounded(CGRect(x: 84, y: 84, width: 856, height: 856), radius: 190)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: CGColor(gray: 0, alpha: 0.2))
    context.addPath(tile)
    context.setFillColor(color(0.13, 0.24, 0.48))
    context.fillPath()
    context.restoreGState()
    fillGradient(tile, colors: [color(0.23, 0.38, 0.67), color(0.07, 0.15, 0.34)],
                 from: CGPoint(x: 300, y: 960), to: CGPoint(x: 780, y: 90), in: context)

    let back = CGMutablePath()
    back.move(to: CGPoint(x: 218, y: 660))
    back.addLine(to: CGPoint(x: 218, y: 718))
    back.addQuadCurve(to: CGPoint(x: 250, y: 750), control: CGPoint(x: 218, y: 750))
    back.addLine(to: CGPoint(x: 410, y: 750))
    back.addQuadCurve(to: CGPoint(x: 438, y: 732), control: CGPoint(x: 428, y: 750))
    back.addLine(to: CGPoint(x: 462, y: 698))
    back.addLine(to: CGPoint(x: 774, y: 698))
    back.addQuadCurve(to: CGPoint(x: 806, y: 666), control: CGPoint(x: 806, y: 698))
    back.addLine(to: CGPoint(x: 806, y: 332))
    back.addQuadCurve(to: CGPoint(x: 774, y: 300), control: CGPoint(x: 806, y: 300))
    back.addLine(to: CGPoint(x: 250, y: 300))
    back.addQuadCurve(to: CGPoint(x: 218, y: 332), control: CGPoint(x: 218, y: 300))
    back.closeSubpath()
    fillGradient(back, colors: [color(0.67, 0.83, 0.96), color(0.42, 0.66, 0.88)],
                 from: CGPoint(x: 500, y: 750), to: CGPoint(x: 500, y: 300), in: context)

    // Paper visible above the folder gives the icon its document-library cue.
    context.saveGState()
    context.translateBy(x: 508, y: 570)
    context.rotate(by: 0.075)
    context.setShadow(offset: CGSize(width: 0, height: -3), blur: 10, color: CGColor(gray: 0, alpha: 0.12))
    context.setFillColor(color(0.95, 0.97, 1))
    context.addPath(rounded(CGRect(x: -218, y: -115, width: 436, height: 245), radius: 23))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0)
    context.setStrokeColor(color(0.72, 0.82, 0.91))
    context.setLineWidth(12)
    context.setLineCap(.round)
    for index in 0..<3 {
        let y = CGFloat(78 - index * 40)
        context.move(to: CGPoint(x: -160, y: y))
        context.addLine(to: CGPoint(x: index == 2 ? 40 : 150, y: y))
        context.strokePath()
    }
    context.restoreGState()

    let front = rounded(CGRect(x: 196, y: 278, width: 632, height: 338), radius: 48)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: CGColor(gray: 0, alpha: 0.18))
    context.setFillColor(color(0.71, 0.86, 0.97))
    context.addPath(front)
    context.fillPath()
    context.restoreGState()
    fillGradient(front, colors: [color(0.87, 0.95, 1), color(0.62, 0.8, 0.94)],
                 from: CGPoint(x: 512, y: 616), to: CGPoint(x: 512, y: 278), in: context)
    context.addPath(rounded(CGRect(x: 197, y: 279, width: 630, height: 336), radius: 47))
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
    context.setLineWidth(2)
    context.strokePath()

    // A small personal badge distinguishes this from a generic Finder folder.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: CGColor(gray: 0, alpha: 0.12))
    context.setFillColor(color(0.96, 0.99, 1))
    context.fillEllipse(in: CGRect(x: 424, y: 354, width: 176, height: 176))
    context.restoreGState()
    context.setFillColor(color(0.22, 0.39, 0.65))
    context.fillEllipse(in: CGRect(x: 486, y: 442, width: 52, height: 52))
    let shoulders = CGMutablePath()
    shoulders.move(to: CGPoint(x: 461, y: 394))
    shoulders.addCurve(to: CGPoint(x: 563, y: 394), control1: CGPoint(x: 461, y: 454), control2: CGPoint(x: 563, y: 454))
    shoulders.addQuadCurve(to: CGPoint(x: 551, y: 384), control: CGPoint(x: 563, y: 384))
    shoulders.addLine(to: CGPoint(x: 473, y: 384))
    shoulders.addQuadCurve(to: CGPoint(x: 461, y: 394), control: CGPoint(x: 461, y: 384))
    context.addPath(shoulders)
    context.fillPath()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw IconFailure.render }
    return data
}

private enum IconFailure: Error { case render }

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = repository.appendingPathComponent("PersonalSpace/Assets.xcassets", isDirectory: true)
let appIcon = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
let iconset = repository.appendingPathComponent(".build/app-icon/PersonalSpace.iconset", isDirectory: true)
for directory in [catalog, appIcon, iconset] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        let data = try makeIcon(pixels: size * scale)
        try data.write(to: appIcon.appendingPathComponent(filename))
        try data.write(to: iconset.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let info = ["version": 1, "author": "xcode"] as [String: Any]
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: catalog.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: appIcon.appendingPathComponent("Contents.json"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", iconset.deletingLastPathComponent().appendingPathComponent("PersonalSpace.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { throw IconFailure.render }
print("Generated native AppIcon assets, .build/app-icon/PersonalSpace.iconset and PersonalSpace.icns")
