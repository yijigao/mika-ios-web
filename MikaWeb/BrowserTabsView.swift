import SwiftUI

// 标签总览（2026-11-02，案卷 TABS-IMPL-2026-11-02.md）：仅展开态经 BrowserView 工具栏
// 的标签按钮（带数量）打开。每行标题＋网址＋关闭按钮；点选切换并关闭总览；
// 任务绑定的标签页带「任务中」标记。新建标签在底部。
// M1（2026-11-02）：只列当前会话的标签（visibleTabs，置顶在前）；每行带
// 置顶开关，置顶标签显示「置顶」标记且不给关闭按钮（关闭守卫在
// WebController.closeTab，UI 隐藏只是呈现口径）；标题带会话名，免得
// 用户以为在看全部会话的标签。
struct TabsOverviewView: View {
    @ObservedObject var controller: WebController
    @ObservedObject private var sessionStore = SessionStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(controller.visibleTabs) { tab in
                    row(tab)
                }
            }
            .navigationTitle("标签页 · \(sessionTitle)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    controller.newTab()
                    dismiss()
                } label: {
                    Label("新建标签页", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }

    private func row(_ tab: BrowserTab) -> some View {
        HStack(spacing: 8) {
            Button {
                controller.activateTab(tab.id)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(controller.tabTitle(for: tab.id))
                            .font(.body)
                            .lineLimit(1)
                        if tab.isPinned {
                            Text("置顶")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.18), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                        if tab.id == controller.executionTabID {
                            Text("任务中")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                        if tab.id == controller.activeTabID {
                            Text("当前")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(tab.urlString.isEmpty ? "空白页" : tab.urlString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                controller.setTabPinned(tab.id, !tab.isPinned)
            } label: {
                Image(systemName: tab.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(tab.isPinned ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.isPinned ? "取消置顶「\(controller.tabTitle(for: tab.id))」" : "置顶「\(controller.tabTitle(for: tab.id))」")
            if !tab.isPinned {
                Button {
                    controller.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭标签页「\(controller.tabTitle(for: tab.id))」")
            }
        }
    }

    private var sessionTitle: String {
        sessionStore.sessions.first(where: { $0.id == controller.displayedSessionID })?.title ?? "会话"
    }
}
