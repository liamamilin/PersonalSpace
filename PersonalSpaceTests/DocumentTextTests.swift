import CoreGraphics
import CoreText
import XCTest
@testable import PersonalSpace

@MainActor
final class DocumentTextTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// A genuine selectable-text PDF created with the same system text stack as
    /// the fixture script. No OCR mock or prebuilt extraction result is involved.
    private func makePDF(lines: [String], in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("合成订单.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 900, height: 900)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        for (index, string) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName("PingFangSC-Regular" as CFString, 24, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            context.textPosition = CGPoint(x: 40, y: 840 - CGFloat(index * 48))
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    func testSelectablePDFProducesExplicitCandidatesWithoutInferringReceiptOrDeadline() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makePDF(lines: [
            "合成订单，仅供 PersonalSpace 开发测试",
            "商品名称：测试耳机", "商家：演示商店", "订单号：DEMO-M3-001",
            "购买日期：2026-10-20", "实付金额：CNY 299.00",
            "条款示例：收货后 7 日内可退货。",
            "演示活动于 2026-11-11 结束，与订单提醒日期无关。"
        ], in: root)
        let original = try Data(contentsOf: url)
        let result = try await Task.detached { try DocumentTextExtractor.extract(from: url) }.value
        let fields = Dictionary(uniqueKeysWithValues: result.suggestions.map { ($0.key, $0.valueText) })

        XCTAssertEqual(fields, [
            "product": "测试耳机", "merchant": "演示商店", "order_number": "DEMO-M3-001",
            "purchase_date": "2026-10-20", "amount": "CNY 299.00"
        ])
        XCTAssertTrue(result.text.contains("合成订单"))
        XCTAssertTrue(result.text.contains("2026-11-11"))
        XCTAssertEqual(result.suggestions.first { $0.key == "purchase_date" }?.valueType, "date")
        XCTAssertEqual(result.suggestions.first { $0.key == "amount" }?.valueType, "amount")
        XCTAssertTrue(result.suggestions.allSatisfy { !$0.sourceExcerpt.isEmpty && result.text.contains($0.sourceExcerpt) })
        XCTAssertFalse(result.suggestions.contains { $0.key == "received_date" || $0.key.contains("deadline") })
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testInvalidAndYearlessDatesRemainAbsentEvenWithAnotherDateInPolicy() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makePDF(lines: [
            "合成日期边界测试", "商品名称：测试耳机",
            "购买日期：2026-02-30", "签收日期：10月21日",
            "条款示例于 2026-11-11 生效，不能作为购买或签收日期。"
        ], in: root)

        let result = try await Task.detached { try DocumentTextExtractor.extract(from: url) }.value

        XCTAssertTrue(result.text.contains("2026-02-30"))
        XCTAssertTrue(result.text.contains("10月21日"))
        XCTAssertEqual(result.suggestions.map(\.key), ["product"])
        XCTAssertFalse(result.suggestions.contains { $0.valueType == "date" })
    }

    func testSensitiveFilenameRejectsBeforeReadingDocumentBody() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["密码记录.pdf", "Recovery-Codes.png", "Account details.pdf", "帐号资料.jpg"] {
            XCTAssertTrue(DocumentTextExtractor.isPotentiallySensitive(name: name))
            // These files intentionally do not exist: the safety decision must
            // happen before PDFKit, ImageIO, or an existence/body read.
            XCTAssertThrowsError(try DocumentTextExtractor.extract(from: root.appendingPathComponent(name))) { error in
                XCTAssertTrue(error.localizedDescription.contains("已停止读取正文"))
            }
        }
        XCTAssertFalse(DocumentTextExtractor.isPotentiallySensitive(name: "订单识别样例.png"))
    }
}
