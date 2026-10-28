import XCTest
@testable import PersonalSpace

final class LocalFactAssistantTests: XCTestCase {
    func testCandidateValidationRequiresAllowedKeyExactQuotationAndExplicitDate() {
        let text = "商品名称：测试耳机\n购买日期：2026年10月20日\n保修条款：自购买日起两年。\n保修到期日期：2028年10月20日\n无效日期：2026-02-30"
        let candidates = [
            DocumentFactSuggestion(key: "product", valueText: "测试耳机", valueType: "wrong", sourceExcerpt: "商品名称：测试耳机"),
            DocumentFactSuggestion(key: "purchase_date", valueText: "2026-10-20", valueType: "text", sourceExcerpt: "购买日期：2026年10月20日"),
            DocumentFactSuggestion(key: "merchant", valueText: "臆造商店", valueType: "text", sourceExcerpt: "商品名称：测试耳机"),
            DocumentFactSuggestion(key: "warranty_end_date", valueText: "2028-10-20", valueType: "date", sourceExcerpt: "购买日期：2026年10月20日\n保修条款：自购买日起两年。"),
            DocumentFactSuggestion(key: "received_date", valueText: "2026-10-20", valueType: "date", sourceExcerpt: "购买日期：2026年10月20日"),
            DocumentFactSuggestion(key: "end_date", valueText: "2026-02-30", valueType: "date", sourceExcerpt: "无效日期：2026-02-30"),
            DocumentFactSuggestion(key: "deadline", valueText: "2026-10-20", valueType: "date", sourceExcerpt: "购买日期：2026年10月20日"),
            DocumentFactSuggestion(key: "merchant", valueText: "伪造原文", valueType: "text", sourceExcerpt: "伪造原文")
        ]

        let validated = LocalFactAssistant.validatedSuggestions(candidates, in: text,
            allowedKeys: ["product", "purchase_date", "merchant", "warranty_end_date", "end_date", "deadline"])

        XCTAssertEqual(validated.map(\.key), ["product", "purchase_date"])
        XCTAssertEqual(validated.map(\.valueType), ["text", "date"])
        XCTAssertEqual(validated.last?.valueText, "2026-10-20")
    }

    func testCandidateSourceBeyondInputLimitIsNotAccepted() {
        let text = String(repeating: "a", count: LocalFactAssistant.maximumInputCharacters) + "\n商品名称：界外测试"
        let candidate = DocumentFactSuggestion(key: "product", valueText: "界外测试", valueType: "text", sourceExcerpt: "商品名称：界外测试")
        XCTAssertTrue(LocalFactAssistant.validatedSuggestions([candidate], in: text, allowedKeys: ["product"]).isEmpty)
    }

    func testSensitiveDocumentIsRejectedBeforeModelAvailabilityOrGeneration() async throws {
        do {
            _ = try await LocalFactAssistant.suggest(text: "synthetic secret sample", fileName: "密码记录.txt", allowedKeys: ["product"])
            XCTFail("Sensitive filenames must not reach the model")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未送入本机模型"))
        }
    }
}
