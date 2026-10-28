// Run: xcrun swift scripts/make_m4_fixtures.swift
// These readable PDF documents are synthetic app development inputs only.
import CoreGraphics
import CoreText
import Foundation

struct Fixture {
    let name: String
    let title: String
    let fields: [String]
    let note: String
}

func drawText(_ value: String, baseline: CGFloat, size: CGFloat, bold: Bool = false,
              color: CGColor = CGColor(gray: 0.16, alpha: 1), in context: CGContext) {
    let font = CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
    ]
    context.textPosition = CGPoint(x: 48, y: baseline)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes)), context)
}

let fixtures = [
    Fixture(name: "合同文字样例.pdf", title: "合成合同 · M4 验收样例", fields: [
        "合同相对方：演示房屋服务", "合同编号：DEMO-C-001", "生效日期：2026-11-01",
        "合同到期日期：2027-10-31", "合同金额：CNY 2400.00",
        "续约条款：双方书面确认后续约。", "取消条款：至少提前 30 日书面通知。"
    ], note: "条款仅供演示。任何行动的提醒时间都需用户另行确认。"),
    Fixture(name: "保修文字样例.pdf", title: "合成保修凭证 · M4 验收样例", fields: [
        "商品名称：测试耳机", "商家：演示商店", "购买日期：2026-10-20",
        "保修到期日期：2028-10-20", "保修条款：凭购买凭证享受演示维修服务。"
    ], note: "仅提取凭证上明确写出的保修日期，不从购买日期推算。"),
    Fixture(name: "订阅文字样例.pdf", title: "合成订阅凭证 · M4 验收样例", fields: [
        "服务名称：演示云笔记", "服务商：演示软件", "下次扣费日期：2026-11-20",
        "订阅金额：CNY 29.00", "续订条款：每月续订，可在下次扣费前取消。",
        "取消条款：在服务设置中取消自动续订。"
    ], note: "仅为合成收费示例。不会触发实际扣费，也不自动安排提醒。")
]
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = repository.appendingPathComponent("fixtures/M4", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for fixture in fixtures {
    let url = destination.appendingPathComponent(fixture.name)
    var bounds = CGRect(x: 0, y: 0, width: 950, height: 1_120)
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
        fatalError("Cannot create synthetic PDF")
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(bounds)
    context.setFillColor(CGColor(red: 0.25, green: 0.31, blue: 0.67, alpha: 1))
    context.fill(CGRect(x: 48, y: 1_050, width: 62, height: 5))
    drawText(fixture.title, baseline: 995, size: 32, bold: true, in: context)
    drawText("仅供 PersonalSpace 开发测试，不是真实凭证或承诺", baseline: 950, size: 21,
             color: CGColor(gray: 0.45, alpha: 1), in: context)
    for (index, field) in fixture.fields.enumerated() {
        let baseline = CGFloat(860 - index * 80)
        drawText(field, baseline: baseline, size: 25, in: context)
        context.setStrokeColor(CGColor(gray: 0.9, alpha: 1))
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 48, y: baseline - 26))
        context.addLine(to: CGPoint(x: 902, y: baseline - 26))
        context.strokePath()
    }
    drawText(fixture.note, baseline: 188, size: 21, in: context)
    drawText("演示资料校对日：2026-12-12，此日期不是事务的截止日。", baseline: 144, size: 21,
             color: CGColor(gray: 0.45, alpha: 1), in: context)
    drawText("SYNTHETIC FIXTURE / LOCAL DEVELOPMENT ONLY", baseline: 72, size: 15,
             color: CGColor(gray: 0.45, alpha: 1), in: context)
    context.endPDFPage()
    context.closePDF()
}
print("Generated 3 synthetic M4 PDF fixtures in fixtures/M4")
