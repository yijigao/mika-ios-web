import SwiftUI
import Combine

enum PanelCollapseReason { case user, execution }
enum PanelEdge: String { case left, right }
@MainActor final class FloatingPanelStore: ObservableObject {
    @Published private(set) var expanded = true
    @Published private(set) var collapseReason: PanelCollapseReason?
    @Published private(set) var edge: PanelEdge
    @Published private(set) var verticalFraction: CGFloat
    private var cancellable: AnyCancellable?
    init() {
        edge = PanelEdge(rawValue: UserDefaults.standard.string(forKey: "floatingEdge") ?? "right") ?? .right
        verticalFraction = CGFloat(min(1, max(0, UserDefaults.standard.double(forKey: "floatingVerticalFraction"))))
        if UserDefaults.standard.object(forKey: "floatingVerticalFraction") == nil { verticalFraction = 0.65 }
    }
    func bind(to engine: AgentEngine) {
        guard cancellable == nil else { return }
        cancellable = engine.$executionSerial.dropFirst().sink { [weak self] _ in self?.collapse(reason: .execution) }
    }
    func expand() { guard !expanded else { return }; expanded = true; collapseReason = nil }
    func collapse(reason: PanelCollapseReason) { guard expanded else { return }; expanded = false; collapseReason = reason }
    func commitPosition(edge: PanelEdge, verticalFraction: CGFloat) {
        self.edge = edge; self.verticalFraction = min(1, max(0, verticalFraction))
        UserDefaults.standard.set(edge.rawValue, forKey: "floatingEdge")
        UserDefaults.standard.set(Double(self.verticalFraction), forKey: "floatingVerticalFraction")
    }
}
