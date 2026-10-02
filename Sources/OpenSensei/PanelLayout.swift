import SwiftUI

enum DashboardModule: String, CaseIterable, Identifiable {
    case cpu, memoryStorage, gpu, network, battery
    var id: String { rawValue }
    var title: String {
        switch self { case .cpu: return "处理器与温度"; case .memoryStorage: return "内存与空间"; case .gpu: return "GPU"; case .network: return "网络"; case .battery: return "电池与供电" }
    }
    static func normalized(_ values: [String]) -> [Self] {
        var result: [Self] = []
        for value in values.compactMap(Self.init(rawValue:)) + allCases where !result.contains(value) { result.append(value) }
        return result
    }
}

struct PanelOrderView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("菜单栏展开面板的顺序").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(Array(monitor.dashboardOrder.enumerated()), id: \.element) { index, module in
                HStack {
                    Text(module.title).font(.system(size: 12))
                    Spacer()
                    Button { monitor.moveModule(module, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0).accessibilityLabel("上移\(module.title)")
                    Button { monitor.moveModule(module, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == monitor.dashboardOrder.count - 1).accessibilityLabel("下移\(module.title)")
                }
            }
        }
    }
}

struct CollapsedPanelView: View {
    let expand: () -> Void
    let hide: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Button(action: expand) {
                VStack(spacing: 9) {
                    Image(systemName: "waveform.path").font(.system(size: 20))
                    Image(systemName: "chevron.left.chevron.right").font(.system(size: 11))
                }.frame(width: 38, height: 65)
            }.buttonStyle(.plain).foregroundStyle(SenseiTheme.accent).help("展开 Open Sensei").accessibilityLabel("展开 Open Sensei 面板")
            Button(action: hide) { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 28, height: 20) }
                .buttonStyle(.plain).help("隐藏侧边条").accessibilityLabel("隐藏侧边条")
        }.padding(.vertical, 10).frame(width: 44).background(.regularMaterial)
    }
}
