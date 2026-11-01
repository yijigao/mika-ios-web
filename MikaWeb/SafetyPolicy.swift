import Foundation
enum SafetyPolicy {
    enum Decision { case allow, confirm, manual }
    static let keywords = ["pay", "payment", "purchase", "buy now", "checkout", "place order", "confirm order", "authorize", "付款", "支付", "购买", "下单", "确认订单", "确认付款", "同意授权", "立即支付", "提交订单"]
    static func check(_ action: AgentAction, _ element: PageElement) -> Decision {
        if action.action == "type" && (element.sensitive || element.inputType.lowercased() == "password") { return .manual }
        let label = [element.text, element.placeholder, element.name, element.ariaLabel].joined(separator: " ").lowercased()
        return keywords.contains(where: label.contains) ? .confirm : .allow
    }
}
