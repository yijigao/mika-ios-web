import SwiftUI

// 标签总览（2026-11-02，案卷 TABS-IMPL-2026-11-02.md）：仅展开态经 BrowserView 工具栏
// 的标签按钮（带数量）打开。每行标题＋网址＋关闭按钮；点选切换并关闭总览；
// 任务绑定的标签页带「任务中」标记。新建标签在底部。
struct TabsOverviewView: View {
    @ObservedObject var controller: WebController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(controller.tabs) { tab in
                    row(tab)
                }
            }
            .navigationTitle("标签页")
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
