import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

struct DocumentTextResult: Sendable {
    let text: String
    let suggestions: [DocumentFactSuggestion]
    let note: String?
}

struct DocumentFactSuggestion: Sendable {
    let key: String
    let valueText: String
    let valueType: String
    let sourceExcerpt: String
}

/// Invoked only after a user asks to identify one document. The caller keeps its
/// security-scoped access alive and runs this synchronous work off the main actor.
struct DocumentTextExtractor {
    private static let maximumOCRPages = 12
    private static let maximumImageDimension = 3_200
    private static let maximumTextBytes = 1_048_576
    private static let maximumTextCharacters = 200_000

    static func extract(from url: URL) throws -> DocumentTextResult {
        try Task.checkCancellation()
        // Check before opening the body, including for a copied/managed document.
        guard !isPotentiallySensitive(name: url.lastPathComponent) else {
            throw DocumentTextError.sensitiveDocument
        }
        guard url.isFileURL else { throw DocumentTextError.unreadableDocument }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DocumentTextError.unreadableDocument
            }
            let fileExtension = url.pathExtension.lowercased()
            let type = UTType(filenameExtension: fileExtension)
            if ["txt", "md", "markdown"].contains(fileExtension) {
                guard (values.fileSize ?? 0) <= maximumTextBytes else { throw DocumentTextError.textTooLarge }
                return try result(text: readPlainText(from: url), note: nil)
            }
            // Extension fallbacks keep standard formats usable when Launch
            // Services cannot resolve tags in a sandboxed/background process.
            if fileExtension == "pdf" || type?.conforms(to: .pdf) == true {
                return try extractPDF(from: url)
            }
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "jp2", "avif"]
            if imageExtensions.contains(fileExtension) || type?.conforms(to: .image) == true {
                let (text, frameCount) = try autoreleasepool {
                    let loaded = try image(from: url)
                    return (try recognize(image: loaded.image), loaded.frameCount)
                }
                var note = "图片文字由本机识别，仅为候选。请对照原件校对；未识别的字段可以手动填写。"
                if frameCount > 1 {
                    note += "此图片含 \(frameCount) 帧或页，本次仅识别首帧/页；其他页面可单独导出后识别。"
                }
                return try result(text: text, note: note)
            }
            throw DocumentTextError.unsupportedFormat
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DocumentTextError {
            throw error
        } catch {
            // Do not surface framework errors containing a personal path or text.
            throw DocumentTextError.unreadableDocument
        }
    }

    static func isPotentiallySensitive(name: String) -> Bool {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let indicators = [
            "密码", "密碼", "口令", "恢复码", "恢復碼", "恢复代码", "恢復代碼", "恢复密钥", "恢復金鑰",
            "备用码", "備用碼", "备份码", "備份碼", "备援码", "備援碼",
            "助记词", "助記詞", "私钥", "私鑰", "账号", "帐号", "帳號", "賬號", "账户", "帐户", "帳戶", "賬戶",
            "password", "passwd", "passphrase", "recoverycode", "recoverykey", "backupcode",
            "privatekey", "secretkey", "seedphrase", "mnemonic", "credential", "account"
        ]
        return indicators.contains { normalized.contains($0) }
    }

    private static func readPlainText(from url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        // A bounded read also handles a file growing after its metadata check.
        while let chunk = try handle.read(upToCount: min(32_768, maximumTextBytes + 1 - data.count)), !chunk.isEmpty {
            try Task.checkCancellation()
            data.append(chunk)
            guard data.count <= maximumTextBytes else { throw DocumentTextError.textTooLarge }
        }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text else { throw DocumentTextError.unsupportedTextEncoding }
        guard text.count <= maximumTextCharacters else { throw DocumentTextError.textTooLarge }
        return text
    }

    private static func extractPDF(from url: URL) throws -> DocumentTextResult {
        guard let document = PDFDocument(url: url) else {
            throw DocumentTextError.unreadableDocument
        }
        guard !document.isLocked else { throw DocumentTextError.lockedPDF }
        guard document.pageCount > 0 else { throw DocumentTextError.noReadableText }

        var pages: [String] = []
        var ocrPageCount = 0
        var omittedOCRPageCount = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let text: String? = try autoreleasepool {
                guard let page = document.page(at: index) else {
                    throw DocumentTextError.unreadableDocument
                }
                if let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
                // Selectable PDF text remains available on every page. Only the
                // more expensive image recognition is capped.
                guard ocrPageCount < maximumOCRPages else {
                    omittedOCRPageCount += 1
                    return nil
                }
                ocrPageCount += 1
                return try recognize(image: render(page: page))
            }
            if let text, !text.isEmpty {
                pages.append(document.pageCount > 1 ? "〔第 \(index + 1) 页〕\n\(text)" : text)
            }
        }
        try Task.checkCancellation()
        var notes: [String] = []
        if ocrPageCount > 0 {
            notes.append("无可选文字的页面由本机识别。请对照原件校对，识别字段均为候选。")
        }
        if omittedOCRPageCount > 0 {
            notes.append("此 PDF 共 \(document.pageCount) 页，本次仅识别前 \(maximumOCRPages) 个无文字页面；另有 \(omittedOCRPageCount) 个扫描页面未识别，可拆分 PDF 后重试或手动填写。")
        }
        return try result(text: pages.joined(separator: "\n\n"),
                          note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }

    private static func image(from url: URL) throws -> (image: CGImage, frameCount: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumImageDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw DocumentTextError.unreadableDocument
        }
        try Task.checkCancellation()
        return (image, CGImageSourceGetCount(source))
    }

    private static func render(page: PDFPage) throws -> CGImage {
        try Task.checkCancellation()
        guard let reference = page.pageRef else { throw DocumentTextError.unreadableDocument }
        let bounds = reference.getBoxRect(.cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            throw DocumentTextError.unreadableDocument
        }
        let isRotated = abs(reference.rotationAngle) % 180 == 90
        let width = isRotated ? bounds.height : bounds.width
        let height = isRotated ? bounds.width : bounds.height
        // At most 3,200 pixels per side, roughly 40 MB for the RGBA bitmap.
        let scale = min(3, CGFloat(maximumImageDimension) / max(width, height))
        let pixelWidth = max(1, Int(ceil(width * scale)))
        let pixelHeight = max(1, Int(ceil(height * scale)))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DocumentTextError.unreadableDocument
        }
        let rectangle = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rectangle)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: rectangle,
                                                           rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { throw DocumentTextError.unreadableDocument }
        try Task.checkCancellation()
        return image
    }

    private static func recognize(image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // Vision invokes progress during the synchronous request. Cancellation is
        // also checked on either side and for every PDF page.
        request.progressHandler = { request, _, _ in
            if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
                request.cancel()
            }
        }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            try Task.checkCancellation()
            throw DocumentTextError.recognitionFailed
        }
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func result(text: String, note: String?) throws -> DocumentTextResult {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentTextError.noReadableText
        }
        return DocumentTextResult(text: text, suggestions: suggestions(from: text), note: note)
    }

    private static func suggestions(from text: String) -> [DocumentFactSuggestion] {
        let fields: [(key: String, type: String, labels: String)] = [
            ("product", "text", "商品名称|商品|产品名称|产品|品名|product name|product|item"),
            ("merchant", "text", "商家|商户|店铺|店家|卖家|merchant|seller|store"),
            ("order_number", "text", "订单号|订单编号|订单号码|order number|order no\\.?|order id"),
            ("purchase_date", "date", "购买日期|购买时间|下单日期|下单时间|订单日期|purchase date|order date"),
            ("received_date", "date", "收货日期|收货时间|签收日期|签收时间|送达日期|received date|delivery date"),
            ("amount", "amount", "实付金额|支付金额|订单金额|合同金额|订阅金额|实付款|总金额|合计|amount paid|total amount|amount|total"),
            ("counterparty", "text", "合同相对方|合同对方|相对方|对方名称|乙方|counterparty"),
            ("contract_number", "text", "合同编号|合同号|contract number|contract no\\.?|contract id"),
            ("start_date", "date", "开始日期|起始日期|生效日期|合同开始日期|start date|effective date"),
            ("end_date", "date", "结束日期|终止日期|到期日期|合同到期日期|合同结束日期|end date|expiry date|expiration date"),
            ("renewal_terms", "text", "续订条款|续约条款|续费条款|renewal terms|renewal policy"),
            ("cancellation_terms", "text", "取消条款|解约条款|终止条款|取消方式|cancellation terms|cancellation policy"),
            ("warranty_end_date", "date", "保修到期日期|保修到期日|保修截止日期|保修结束日期|质保到期日期|warranty end date|warranty expiry date"),
            ("warranty_terms", "text", "保修条款|保修范围|质保条款|warranty terms|warranty coverage"),
            ("service", "text", "服务名称|订阅服务|订阅名称|service name|service(?![ \\t]+provider\\b)|subscription name"),
            ("provider", "text", "服务商|服务提供方|提供商|provider|service provider"),
            ("next_billing_date", "date", "下次扣费日期|下次扣费日|下次账单日期|下次续费日期|next billing date|next payment date")
        ]
        var suggestions: [DocumentFactSuggestion] = []
        let lines = text.components(separatedBy: .newlines)
        for field in fields {
            // A label must begin a line and have a colon or spacing before its
            // value. Unlabelled dates and policy text never become date facts.
            let pattern = "^\\s*(?:[-•]\\s*)?(?:" + field.labels + ")(?:\\s*[:：]\\s*|[ \\t]+)(\\S.*)$"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            for line in lines {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = expression.firstMatch(in: line, range: range),
                      let valueRange = Range(match.range(at: 1), in: line) else { continue }
                let rawValue = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value: String
                if field.type == "date" {
                    guard let date = normalizingExplicitDate(rawValue) else { continue }
                    value = date
                } else {
                    value = String(rawValue.prefix(200))
                }
                suggestions.append(DocumentFactSuggestion(key: field.key, valueText: value,
                    valueType: field.type, sourceExcerpt: String(line.prefix(300))))
                break
            }
        }
        return suggestions
    }

    static func normalizingExplicitDate(_ value: String) -> String? {
        // Require a complete, explicitly written calendar date. Do not infer a
        // year, treat purchase as receipt, or derive any policy deadline.
        let pattern = "^(\\d{4})\\s*[-/.年]\\s*(\\d{1,2})\\s*[-/.月]\\s*(\\d{1,2})(?:日|号)?(?:[ T](?:[01]?\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d)?)?$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) else {
            return nil
        }
        let values = (1...3).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
        guard values.count == 3, (1...9999).contains(values[0]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: values[0], month: values[1], day: values[2])
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return String(format: "%04d-%02d-%02d", values[0], values[1], values[2])
    }
}

private enum DocumentTextError: LocalizedError {
    case sensitiveDocument, unsupportedFormat, unreadableDocument, lockedPDF, recognitionFailed, noReadableText
    case textTooLarge, unsupportedTextEncoding

    var errorDescription: String? {
        switch self {
        case .sensitiveDocument:
            "此文件名疑似包含密码、恢复码或账号资料，已停止读取正文。请选择普通凭证，或手动填写必要字段。"
        case .unsupportedFormat:
            "此格式暂不支持文字识别。请选择 PDF、系统支持的图片、TXT 或 Markdown，也可以手动填写事务。"
        case .unreadableDocument:
            "无法读取此凭证。请检查原件是否可用、来源是否已授权，或改为手动填写。"
        case .lockedPDF:
            "此 PDF 需要密码，无法读取文字。请先在系统应用中解锁另存，或手动填写事务。"
        case .recognitionFailed:
            "本机文字识别未能完成。可以重试、换用更清晰的凭证，或手动填写事务。"
        case .noReadableText:
            "未识别到可读文字。可以换用更清晰的 PDF、图片或文本，或手动填写事务。"
        case .textTooLarge:
            "纯文本识别仅支持不超过 1 MiB 且不超过 20 万字符的文件。超出限制，未返回部分识别结果。请拆分后重试，也可以手动填写。"
        case .unsupportedTextEncoding:
            "无法按 UTF-8 或带 BOM 的 UTF-16 读取此文本。请另存为 UTF-8 后重试，也可以手动填写。"
        }
    }
}
