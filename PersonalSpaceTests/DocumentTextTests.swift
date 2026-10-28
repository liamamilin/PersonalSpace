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

    func testContractWarrantyAndSubscriptionPDFsExtractOnlyExplicitFields() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(lines: [String], expected: [String: String])] = [
            (["合成合同，仅用于开发测试", "合同相对方：演示房屋服务", "合同编号：DEMO-C-001",
              "生效日期：2026年11月1日", "合同到期日期：2027-10-31", "合同金额：CNY 2400.00",
              "续约条款：双方书面确认后续约。", "取消条款：至少提前 30 日书面通知。"],
             ["counterparty": "演示房屋服务", "contract_number": "DEMO-C-001", "start_date": "2026-11-01",
              "end_date": "2027-10-31", "amount": "CNY 2400.00", "renewal_terms": "双方书面确认后续约。",
              "cancellation_terms": "至少提前 30 日书面通知。"]),
            (["合成保修凭证，仅用于开发测试", "商品名称：测试耳机", "购买日期：2026-10-20",
              "保修到期日期：2028-10-20", "保修条款：凭购买凭证享受演示维修服务。"],
             ["product": "测试耳机", "purchase_date": "2026-10-20", "warranty_end_date": "2028-10-20",
              "warranty_terms": "凭购买凭证享受演示维修服务。"]),
            (["合成订阅凭证，仅用于开发测试", "服务名称：演示云笔记", "服务商：演示软件",
              "下次扣费日期：2026-11-20", "订阅金额：CNY 29.00", "续订条款：每月续订，可在下次扣费前取消。",
              "取消条款：在服务设置中取消自动续订。"],
             ["service": "演示云笔记", "provider": "演示软件", "next_billing_date": "2026-11-20",
              "amount": "CNY 29.00", "renewal_terms": "每月续订，可在下次扣费前取消。",
              "cancellation_terms": "在服务设置中取消自动续订。"])
        ]
        for sample in cases {
            let url = try makePDF(lines: sample.lines, in: root)
            let result = try await Task.detached { try DocumentTextExtractor.extract(from: url) }.value
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.suggestions.map { ($0.key, $0.valueText) }), sample.expected)
            XCTAssertTrue(result.suggestions.allSatisfy { result.text.contains($0.sourceExcerpt) })
        }
    }

    func testPlainTextAndBOMUTF16MarkdownUseSameExplicitFieldPath() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = "合成文本合同\n合同相对方：演示房屋服务\n合同编号：DEMO-TEXT-001\n生效日期：2026-11-01\n保修条款：自购买日起两年。\n"
        let textURL = root.appendingPathComponent("合同.txt")
        let markdownURL = root.appendingPathComponent("合同.md")
        let utf8 = Data(content.utf8)
        let utf16 = Data([0xFF, 0xFE]) + (try XCTUnwrap(content.data(using: .utf16LittleEndian)))
        try utf8.write(to: textURL)
        try utf16.write(to: markdownURL)

        for url in [textURL, markdownURL] {
            let result = try await Task.detached { try DocumentTextExtractor.extract(from: url) }.value
            XCTAssertEqual(result.text, content)
            XCTAssertEqual(result.suggestions.first { $0.key == "contract_number" }?.valueText, "DEMO-TEXT-001")
            XCTAssertEqual(result.suggestions.first { $0.key == "start_date" }?.valueText, "2026-11-01")
            XCTAssertFalse(result.suggestions.contains { $0.key == "warranty_end_date" })
        }
        XCTAssertEqual(try Data(contentsOf: textURL), utf8)
        XCTAssertEqual(try Data(contentsOf: markdownURL), utf16)
    }

    func testOversizedPlainTextReturnsClearFailureInsteadOfPartialResult() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let tooManyCharacters = root.appendingPathComponent("字符过多.txt")
        let tooManyBytes = root.appendingPathComponent("字节过多.md")
        try Data(String(repeating: "a", count: 200_001).utf8).write(to: tooManyCharacters)
        try Data(repeating: 0x61, count: 1_048_577).write(to: tooManyBytes)
        for url in [tooManyCharacters, tooManyBytes] {
            XCTAssertThrowsError(try DocumentTextExtractor.extract(from: url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("超出限制"))
            }
        }
    }

    func testStrictDateNormalizationRejectsMalformedSuffixAndImpossibleDates() {
        XCTAssertEqual(DocumentTextExtractor.normalizingExplicitDate("2024年2月29日"), "2024-02-29")
        XCTAssertEqual(DocumentTextExtractor.normalizingExplicitDate("2026-10-20 09:30"), "2026-10-20")
        for value in ["2026-02-29", "2026-10-20-99", "2026-10-20abc", "10月20日", "2026-10-20 29:30"] {
            XCTAssertNil(DocumentTextExtractor.normalizingExplicitDate(value))
        }
    }
}
