// Run from the repository: xcrun swift scripts/make_m3_fixtures.swift
// Creates synthetic inputs for the user-triggered M3 PDFKit/Vision flow.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: 1)
}

func drawText(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat,
              color: CGColor, bold: Bool = false, context: CGContext) {
    let fontName = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
}

func drawOrder(in context: CGContext) {
    let ink = color(0.12, 0.16, 0.23)
    let secondary = color(0.39, 0.44, 0.52)
    let accent = color(0.25, 0.31, 0.67)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 900, height: 1_100))
    context.setFillColor(accent)
    context.fill(CGRect(x: 48, y: 1_025, width: 62, height: 5))
    drawText("合成订单 · M3 验收样例", x: 48, y: 972, size: 34,
             color: ink, bold: true, context: context)
    drawText("仅供 PersonalSpace 开发测试，不是真实交易凭证", x: 48, y: 930, size: 21,
             color: secondary, context: context)
    let lines = [
        "商品名称：测试耳机",
        "商家：演示商店",
        "订单号：DEMO-M3-001",
        "购买日期：2026-10-20",
        "实付金额：CNY 299.00"
    ]
    for (index, line) in lines.enumerated() {
        let baseline = CGFloat(830 - index * 88)
        drawText(line, x: 56, y: baseline, size: 29, color: ink, context: context)
        context.setStrokeColor(color(0.89, 0.91, 0.94))
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 48, y: baseline - 25))
        context.addLine(to: CGPoint(x: 852, y: baseline - 25))
        context.strokePath()
    }
    drawText("条款示例", x: 48, y: 354, size: 23, color: ink, bold: true, context: context)
    drawText("收货后 7 日内可退货。本样例未提供签收信息。", x: 48, y: 307,
             size: 23, color: secondary, context: context)
    drawText("演示活动于 2026-11-11 结束，与订单提醒日期无关。", x: 48, y: 263,
             size: 23, color: secondary, context: context)
    drawText("请对照原件校对候选字段，手动确认具体日期后再安排提醒。", x: 48, y: 168,
             size: 21, color: accent, context: context)
    drawText("SYNTHETIC FIXTURE / LOCAL DEVELOPMENT ONLY", x: 48, y: 76,
             size: 15, color: secondary, context: context)
}

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = repository.appendingPathComponent("fixtures/M3", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

let pngURL = destination.appendingPathComponent("订单识别样例.png")
guard let bitmap = CGContext(data: nil, width: 1_800, height: 2_200, bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot allocate synthetic PNG bitmap")
}
bitmap.scaleBy(x: 2, y: 2)
drawOrder(in: bitmap)
guard let image = bitmap.makeImage(),
      let png = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot create synthetic PNG destination")
}
CGImageDestinationAddImage(png, image, nil)
guard CGImageDestinationFinalize(png) else { fatalError("Cannot write synthetic PNG") }

let pdfURL = destination.appendingPathComponent("订单文字样例.pdf")
var pageBounds = CGRect(x: 0, y: 0, width: 900, height: 1_100)
guard let consumer = CGDataConsumer(url: pdfURL as CFURL),
      let pdf = CGContext(consumer: consumer, mediaBox: &pageBounds, nil) else {
    fatalError("Cannot create synthetic PDF destination")
}
pdf.beginPDFPage(nil)
drawOrder(in: pdf)
pdf.endPDFPage()
pdf.closePDF()
print("Generated fixtures/M3/订单识别样例.png and fixtures/M3/订单文字样例.pdf (synthetic only)")
