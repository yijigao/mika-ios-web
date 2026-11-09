import Foundation
enum SafetyPolicy {
    enum Decision: Equatable { case allow, confirm, manual }
    static let keywords = ["pay", "payment", "purchase", "buy now", "checkout", "place order", "confirm order", "authorize", "付款", "支付", "购买", "下单", "确认订单", "确认付款", "同意授权", "立即支付", "提交订单"]
    static func check(_ action: AgentAction, _ element: PageElement) -> Decision {
        if action.action == "type" && (element.sensitive || element.inputType.lowercased() == "password") { return .manual }
        let label = [element.text, element.placeholder, element.name, element.ariaLabel].joined(separator: " ").lowercased()
        return keywords.contains(where: label.contains) ? .confirm : .allow
    }

    // MARK: - SP-01：上传私有文件确认门（F1，2026-11-02）
    //
    // Joey 2026-11-02 23:35 批准的 SafetyPolicy 新增项——本文件除本节外
    // 零改动。agent 把文件上传到网页前的判定：本任务生成的文件（页面
    // 截图、任务产物）走 .allow；其余一律是用户的私有文件（附件中心导入
    // 的、或将在系统选择器里现选的），走 .confirm——引擎须先在对话区
    // 出示确认卡（展示文件名与目标页面），用户确认才触发上传流程。
    // 细则（小灯裁决 DAILY-20261102-R1 第 6 项）：任务生成文件豁免本卡，
    // 但不免除原有对外发送与敏感信息边界；确认是一次性的、绑定具体
    // 附件与页面，取消/失败/重试后旧确认不得复用于不同动作——凭据的
    // 签发与消费在 AttachmentStore 的一次性登记表里（引擎在用户点确认
    // 时消费、在取消时作废）。
    static func uploadDecision(isTaskGenerated: Bool) -> Decision {
        isTaskGenerated ? .allow : .confirm
    }
}
