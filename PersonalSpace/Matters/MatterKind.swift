import Foundation

enum MatterKind: String, CaseIterable, Identifiable, Sendable {
    case order, contract, warranty, subscription

    var id: String { rawValue }

    var title: String {
        switch self {
        case .order: "订单"
        case .contract: "合同"
        case .warranty: "保修"
        case .subscription: "订阅"
        }
    }

    var image: String {
        switch self {
        case .order: "cart"
        case .contract: "doc.text"
        case .warranty: "checkmark.shield"
        case .subscription: "arrow.triangle.2.circlepath"
        }
    }

    var fieldKeys: [String] {
        switch self {
        case .order:
            ["product", "merchant", "order_number", "purchase_date", "received_date", "amount"]
        case .contract:
            ["counterparty", "contract_number", "start_date", "end_date", "renewal_terms", "cancellation_terms", "amount"]
        case .warranty:
            ["product", "merchant", "purchase_date", "warranty_end_date", "warranty_terms"]
        case .subscription:
            ["service", "provider", "start_date", "next_billing_date", "renewal_terms", "cancellation_terms", "amount"]
        }
    }

    var defaultActionTitle: String {
        switch self {
        case .order: "检查订单与售后"
        case .contract: "到期前核对续签条件"
        case .warranty: "保修到期前检查"
        case .subscription: "扣费前检查订阅"
        }
    }

    static func title(for fieldKey: String) -> String {
        switch fieldKey {
        case "product": "商品"
        case "merchant": "商家"
        case "order_number": "订单号"
        case "purchase_date": "购买日期"
        case "received_date": "签收日期"
        case "amount": "金额"
        case "counterparty": "合同相对方"
        case "contract_number": "合同编号"
        case "start_date": "生效日期"
        case "end_date": "终止日期"
        case "renewal_terms": "续订或续签条款"
        case "cancellation_terms": "取消或通知条款"
        case "warranty_end_date": "保修截止日期"
        case "warranty_terms": "保修条款"
        case "service": "订阅服务"
        case "provider": "服务提供方"
        case "next_billing_date": "下次扣费日期"
        default: fieldKey
        }
    }

    static func valueType(for fieldKey: String) -> String {
        if fieldKey.hasSuffix("_date") { return "date" }
        return fieldKey == "amount" ? "amount" : "text"
    }
}
