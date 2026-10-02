import SwiftUI
import AppKit
import ServiceManagement

enum CenterPage: String, CaseIterable, Identifiable {
    case overview = "总览", hardware = "电池与硬件", cooling = "温度与风扇", activity = "网络与磁盘活动", processes = "资源进程", check = "状态检查", storage = "空间整理", apps = "应用卸载", efficiency = "运行开销", settings = "设置与隐私"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .hardware: return "battery.100percent"
        case .cooling: return "fan"
        case .processes: return "list.bullet.rectangle"
        case .activity: return "network"
        case .check: return "checkmark.circle"
        case .efficiency: return "leaf"
        case .storage: return "internaldrive"
        case .apps: return "app.badge"
        case .settings: return "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "关心此刻的状态，让后台保持安静。"
        case .hardware: return "看清充放电功率、电芯组电压与硬件健康。"
        case .cooling: return "实时温度与转速，需要时再接管散热。"
        case .processes: return "按需取样，找出正在消耗资源的进程。"
        case .activity: return "区分接口与存储驱动，查看此刻的数据流动。"
        case .check: return "结合系统状态解释读数，按需检查一次。"
        case .efficiency: return "看清 Open Sensei 自己消耗了多少资源。"
        case .storage: return "先看清空间去向，再决定如何整理。"
        case .apps: return "核对应用和关联文件，所选项目移到废纸篓。"
        case .settings: return "由你决定刷新频率、显示内容与数据保留。"
        }
    }
}

@MainActor final class CenterState: ObservableObject {
    @Published var page = CenterPage.overview
}

let senseiMint = SenseiTheme.accent
private let centerMuted = SenseiTheme.secondary

struct CenterView: View {
    @AppStorage("appearance") private var appearance = "system"
    @ObservedObject var monitor: Monitor
    @ObservedObject var state: CenterState
    @ObservedObject var tools: ToolsModel
    @ObservedObject var fanControl: FanControl
    @ObservedObject var processes: ProcessModel
    @State private var selectedApp: InstalledApp?
    @State private var appSelection = Set<String>()
    @State private var query = ""
    @State private var processSort = "cpu"
    @State private var groupProcesses = true
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var report = ""
    @State private var showingReport = false
    var onPageChange: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.page.rawValue).font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text(state.page.subtitle).font(.system(size: 12)).foregroundStyle(centerMuted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Label(monitor.cadenceLabel, systemImage: "leaf").font(.system(size: 11)).foregroundStyle(senseiMint)
                        Button {
                            report = SnapshotReport.make(monitor.snapshot, chip: monitor.chip, cadence: monitor.cadenceLabel, version: AppVersion.current)
                            showingReport = true
                        } label: { Label("状态摘要", systemImage: "doc.text") }.controlSize(.small)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch state.page {
                        case .overview: overview
                        case .hardware: hardware
                        case .cooling: CoolingView(snapshot: monitor.snapshot, history: monitor.thermalHistory, control: fanControl)
                        case .processes: processPage
                        case .activity: ActivityView(monitor: monitor)
                        case .check: CheckView(model: tools.check, openPage: { state.page = $0 })
                        case .efficiency: EfficiencyView(monitor: monitor)
                        case .storage: storage
                        case .apps: applications
                        case .settings: settings
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
                }.id(state.page)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 650)
        .background(SenseiTheme.background)
        .foregroundStyle(Color.primary)
        .tint(senseiMint)
        .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
        .sheet(isPresented: $showingReport) { SnapshotReportView(report: report) }
        .onChange(of: state.page) { old, _ in
            if old == .processes { processes.cancel() }
            if old == .check { tools.check.cancel() }
            if old == .hardware { tools.batteryDetails.cancel() }
            onPageChange()
        }
        .alert("Open Sensei", isPresented: Binding(get: { tools.message != nil }, set: { if !$0 { tools.message = nil } })) {
            Button("好") { tools.message = nil }
        } message: { Text(tools.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path").font(.system(size: 25)).foregroundStyle(senseiMint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open Sensei").font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                    Text("为你的 Mac 留出余地").font(.system(size: 11)).foregroundStyle(centerMuted)
                }
            }.padding(.vertical, 24).padding(.horizontal, 10)
            List(selection: Binding<CenterPage?>(get: { state.page }, set: { if let page = $0 { state.page = page } })) {
                Section("监测") {
                    ForEach([CenterPage.overview, .hardware, .cooling, .activity, .processes]) { page in
                        Label(page.rawValue, systemImage: page.icon).font(.system(size: 13)).padding(.vertical, 5).tag(page)
                    }
                }
                Section("管理") {
                    ForEach([CenterPage.check, .storage, .apps, .efficiency, .settings]) { page in
                        Label(page.rawValue, systemImage: page.icon).font(.system(size: 13)).padding(.vertical, 5).tag(page)
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Spacer()
            VStack(alignment: .leading, spacing: 7) {
                Label("本地处理，无数据上传", systemImage: "lock.shield")
                Text("v\(AppVersion.current) · 原生 macOS 应用")
            }.font(.system(size: 11)).foregroundStyle(centerMuted).padding(12)
        }.padding(.horizontal, 12).frame(width: 210)
            .background(.regularMaterial)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "desktopcomputer").font(.system(size: 27)).foregroundStyle(senseiMint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(monitor.chip).font(.system(size: 17, weight: .medium))
                    Text("\(ProcessInfo.processInfo.activeProcessorCount) 核心 · \(Int(monitor.snapshot.memoryTotal / 1_073_741_824)) GB 内存 · macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)")
                        .font(.system(size: 11)).foregroundStyle(centerMuted)
                }
                Spacer()
                Button("活动监视器", action: openActivityMonitor).controlSize(.small)
            }.senseiCard()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                metric("CPU", value: "\(Format.percent(monitor.snapshot.cpu))%", detail: monitor.snapshot.sensors.hottest.map { String(format: "核心热点 %.1f °C · 归一化使用率", $0) } ?? "所有核心合计，归一化至 100%", symbol: "cpu", color: senseiMint, values: monitor.cpuHistory)
                metric("GPU", value: "\(Format.percent(monitor.snapshot.gpu))%", detail: monitor.snapshot.gpu == nil ? "驱动未提供此指标" : "驱动报告的设备使用率", symbol: "square.stack.3d.up", color: .purple, values: [])
                storageCapacity
                metric("交换空间", value: monitor.snapshot.swap.map(Format.bytes) ?? "—", detail: "由 macOS 按需管理 · 内存构成见下方", symbol: "memorychip", color: .purple, values: [])
                metric("下载", value: monitor.snapshot.stamps[.network]?.condition == .ready ? Format.rate(monitor.snapshot.network.download) : "—", detail: monitor.networkInterface == "all" ? "en* 接口合计" : monitor.networkInterface, symbol: "arrow.down", color: senseiMint, values: monitor.downloadHistory, ceiling: max(1024, monitor.downloadHistory.max() ?? 0))
                metric("上传", value: monitor.snapshot.stamps[.network]?.condition == .ready ? Format.rate(monitor.snapshot.network.upload) : "—", detail: "不重复计算 VPN 接口", symbol: "arrow.up", color: .purple, values: monitor.uploadHistory, ceiling: max(1024, monitor.uploadHistory.max() ?? 0))
            }
            MemoryCompositionView(snapshot: monitor.snapshot)
            note("趋势最多保留 \(ResourcePolicy.historyLimit) 个点，只存在于内存。关闭面板后清空，退出应用后不保留。", symbol: "leaf")
        }
    }

    private var storageCapacity: some View {
        HStack(spacing: 16) {
            ValueRing(fraction: monitor.snapshot.diskFree == nil ? nil : monitor.snapshot.diskFraction,
                      value: "\(Format.percent(monitor.snapshot.diskFree == nil ? nil : monitor.snapshot.diskFraction))%",
                      caption: "已用存储", color: .orange, diameter: 82)
            VStack(alignment: .leading, spacing: 8) {
                Text("可用空间").font(.system(size: 12)).foregroundStyle(centerMuted)
                Text(monitor.snapshot.diskFree.map(Format.bytes) ?? "—").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text("共 \(monitor.snapshot.diskTotal.map(Format.bytes) ?? "—") · 每分钟更新").font(.system(size: 10)).foregroundStyle(centerMuted)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).senseiCard()
    }

    private func metric(_ title: String, value: String, detail: String, symbol: String, color: Color, values: [Double], ceiling: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 12)).foregroundStyle(centerMuted)
            HStack {
                Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                if !values.isEmpty { Sparkline(values: values, color: color, ceiling: ceiling).frame(width: 94, height: 35) }
            }
            Text(detail).font(.system(size: 11)).foregroundStyle(centerMuted).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).senseiCard()
    }

    private var hardware: some View {
        VStack(alignment: .leading, spacing: 15) {
            BatteryDetailView(snapshot: monitor.snapshot, details: tools.batteryDetails,
                              historyDays: monitor.historyDays, historyEnabled: monitor.batteryHistoryEnabled,
                              historyBytes: monitor.historyBytes, setHistory: { monitor.setBatteryHistory($0) },
                              lowPower: monitor.lowPower || monitor.snapshot.thermal == .serious || monitor.snapshot.thermal == .critical)
            section("磁盘健康", symbol: "internaldrive") {
                HStack {
                    Text("按需读取 SMART、TRIM 与已挂载卷").font(.system(size: 11)).foregroundStyle(centerMuted)
                    Spacer()
                    Button(tools.loadingDrives ? "读取中…" : "读取硬件报告") { tools.loadDrives() }.disabled(tools.loadingDrives)
                }
                ForEach(tools.drives) { drive in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text(drive.name); Text(drive.capacity).foregroundStyle(centerMuted) }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("SMART：\(drive.smart == "Verified" ? "已通过" : drive.smart)").foregroundStyle(drive.smart == "Verified" ? senseiMint : .secondary)
                            Text("TRIM：\(drive.trim == "Yes" ? "已启用" : drive.trim)")
                        }
                    }.font(.system(size: 12)).padding(.vertical, 6)
                }
                if let date = tools.driveDate { Text("报告时间 \(date.formatted(date: .omitted, time: .standard)) · 手动刷新").font(.system(size: 11)).foregroundStyle(centerMuted) }
                if !tools.volumes.isEmpty {
                    Divider()
                    Text("已挂载卷").font(.system(size: 12, weight: .medium))
                    ForEach(tools.volumes) { volume in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(volume.name); Spacer(); Text("可用 \(volume.free.map(Format.bytes) ?? "—") / \(volume.total.map(Format.bytes) ?? "—")").monospacedDigit() }
                            Text("\(volume.format) · \(volume.connection) · \(volume.writable == "yes" ? "可写" : volume.writable == "no" ? "只读" : "写入状态未提供")").foregroundStyle(centerMuted)
                            Text(volume.mount).font(.system(size: 10, design: .monospaced)).foregroundStyle(centerMuted).textSelection(.enabled)
                        }.font(.system(size: 11)).padding(.vertical, 6)
                    }
                    Text("APFS 卷可能共享同一容器的剩余空间，容量不能直接相加。外接硬盘的 SMART / TRIM 是否可读取取决于桥接芯片和驱动；未提供不等于健康通过。").font(.system(size: 11)).foregroundStyle(centerMuted)
                }
                if tools.driveLoaded && tools.drives.isEmpty && !tools.loadingDrives { note("系统未提供可读取的驱动器健康报告；外接盘可能不支持。") }
                Text("SMART 状态不能保证磁盘不会故障。此处只读取状态，TRIM 由系统管理。")
                    .font(.system(size: 11)).foregroundStyle(centerMuted)
            }
            section("轻量磁盘测速", symbol: "speedometer") {
                Text("选择目录后进行一次 32 MiB 读写测试。完成、取消或退出后自动释放临时空间，不保留测速历史。")
                    .font(.system(size: 11)).foregroundStyle(centerMuted)
                HStack {
                    Button(tools.benchmarking ? "测速中…" : "选择目录并测速") { tools.startBenchmark() }.disabled(tools.benchmarking)
                    if tools.benchmarking { Button("取消") { tools.cancelBenchmark() } }
                    if let result = tools.benchmark {
                        Spacer()
                        Text("写 \(Format.rate(result.write)) · 读 \(Format.rate(result.read))").font(.system(size: 12, design: .monospaced))
                    }
                }
                Text("小样本顺序 I/O 参考值，受硬件缓存和后台负载影响，不代表持续峰值。测速期间会短暂占用磁盘。")
                    .font(.system(size: 11)).foregroundStyle(centerMuted)
            }

        }
    }

    private var processPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("按应用归组", isOn: $groupProcesses).toggleStyle(.checkbox)
                Picker("排序", selection: $processSort) { Text("CPU").tag("cpu"); Text("内存").tag("memory") }.frame(width: 150)
                Spacer()
                if processes.loading { Button("取消") { processes.cancel() } }
                if let updated = processes.updated { Text(updated, style: .time).font(.system(size: 11)).foregroundStyle(centerMuted) }
                Button(processes.loading ? "采样中…" : "采样一次") { processes.refresh() }.disabled(processes.loading)
            }
            note("只在点击时做一次短采样，最多显示 30 项。CPU 以单核心 100% 计，多线程进程可超过 100%；无权读取的进程会跳过。归组按可执行文件所属的 .app 识别；驻留内存相加可能重复计入共享页。")
            if processes.updated == nil { empty("查看此刻的资源占用", detail: "点击“采样一次”，不会启动后台进程轮询。", icon: "list.bullet.rectangle") }
            ForEach(Array(ProcessGrouping.rows(processes.rows, grouped: groupProcesses).sorted { processSort == "cpu" ? $0.cpu > $1.cpu : $0.memory > $1.memory }.prefix(30))) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 3) { Text(row.name).font(.system(size: 12)); Text(row.detail).font(.system(size: 11)).foregroundStyle(centerMuted) }
                    Spacer()
                    Text(String(format: "%.1f%%", row.cpu)).frame(width: 75, alignment: .trailing)
                    Text(Format.bytes(row.memory)).frame(width: 85, alignment: .trailing)
                }.font(.system(size: 11, design: .monospaced)).padding(10).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            }
            Button("打开活动监视器管理进程", action: openActivityMonitor)
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("选择文件夹") { tools.chooseScan() }.disabled(tools.scanning)
                Button("查看用户缓存") { tools.startScan(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")) }.disabled(tools.scanning)
                Spacer()
                if tools.scanning { ProgressView().controlSize(.small); Button("取消") { tools.cancelScan() } }
                else if tools.scan != nil { Button("清空结果") { tools.clearScan() } }
            }
            note("单次最多 25 秒 / 10 万项，只保留最大的 200 个文件。仅扫描所选本地卷；跳过云端占位项、其他挂载卷、隐藏文件、符号链接和应用包内部。只读元数据，不下载文件，结果不写入磁盘。")
            if let root = tools.scanRoot {
                Text(root.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(centerMuted).textSelection(.enabled)
            }
            if let scan = tools.scan {
                HStack(spacing: 28) {
                    bigValue("扫描到的占用", Format.bytes(Double(scan.total)))
                    bigValue("已检查", "\(scan.visited) 项")
                    bigValue("无法读取", "\(scan.unreadable) 项")
                }.senseiCard()
                if scan.skippedCloud + scan.skippedVolumes > 0 { note("已跳过 \(scan.skippedCloud) 个云端占位项、\(scan.skippedVolumes) 个其他卷入口。") }
                if scan.partial { note("\(scan.reason)。以下是部分结果，可选择更小的子目录继续。", symbol: "info.circle") }
                ForEach(Array(scan.folders.prefix(6))) { folder in
                    HStack { Text(folder.name).lineLimit(1); Spacer(); Text(Format.bytes(Double(folder.bytes))).foregroundStyle(centerMuted) }.font(.system(size: 11))
                    Meter(value: Double(folder.bytes) / max(1, Double(scan.total)), color: senseiMint)
                }
                HStack {
                    Text("大文件清单").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("将所选项移到废纸篓…") { tools.trashSelectedFiles() }.disabled(tools.selectedFiles.isEmpty)
                }.padding(.top, 8)
                ForEach(scan.files) { file in
                    HStack(spacing: 9) {
                        Toggle("", isOn: Binding(get: { tools.selectedFiles.contains(file.id) }, set: { if $0 { tools.selectedFiles.insert(file.id) } else { tools.selectedFiles.remove(file.id) } })).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.url.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                            Text(file.url.deletingLastPathComponent().path).font(.system(size: 11)).foregroundStyle(centerMuted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(Format.bytes(Double(file.bytes))).font(.system(size: 10, design: .monospaced))
                        Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                    }.padding(9).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                }
            } else if !tools.scanning { empty("空间整理，由你开始", detail: "选择一个目录分析；不会自动扫描整个磁盘。", icon: "externaldrive.badge.magnifyingglass") }
        }
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("搜索应用", text: $query).textFieldStyle(.roundedBorder)
                Button(tools.loadingApps ? "读取中…" : "读取应用列表") { tools.loadApps() }.disabled(tools.loadingApps)
            }
            note("读取“应用程序”文件夹中的应用，并按应用唯一标识匹配关联文件。应用支持文件可能包含个人数据；共享文件和系统应用交由系统管理。")
            if let app = selectedApp {
                section("\(app.name) · 卸载清单", symbol: "app.badge") {
                    ForEach(AppInventory.candidates(for: app)) { file in
                        Toggle(isOn: Binding(get: { appSelection.contains(file.id) }, set: { if $0 { appSelection.insert(file.id) } else { appSelection.remove(file.id) } })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.label).font(.system(size: 11))
                                Text(file.url.path).font(.system(size: 11)).foregroundStyle(centerMuted).textSelection(.enabled)
                            }
                        }.toggleStyle(.checkbox)
                    }
                    HStack {
                        Button("取消选择") { selectedApp = nil; appSelection = [] }
                        Spacer()
                        Button("移到废纸篓…") {
                            tools.uninstall(app, selected: AppInventory.candidates(for: app).filter { appSelection.contains($0.id) })
                            selectedApp = nil; appSelection = []
                        }.disabled(appSelection.isEmpty)
                    }
                }
            }
            if tools.apps.isEmpty && !tools.loadingApps { empty("应用与关联文件，一起核对", detail: "读取应用列表后，选择一个应用查看卸载清单。", icon: "square.stack.3d.up") }
            ForEach(tools.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }) { app in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.system(size: 12, weight: .medium))
                        Text("\(app.version) · \(app.bundleID)").font(.system(size: 11)).foregroundStyle(centerMuted).lineLimit(1)
                    }
                    Spacer()
                    Button("查看清单") { selectedApp = app; appSelection = [app.url.path] }
                        .disabled(app.bundleID.hasPrefix("com.apple.") || app.bundleID == Bundle.main.bundleIdentifier)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } label: { Image(systemName: "folder") }
                }.padding(12).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 15) {
            section("刷新与耗电", symbol: "leaf") {
                Picker("面板展开时", selection: Binding(get: { monitor.interval }, set: { monitor.setInterval($0) })) {
                    Text("每 1 秒").tag(1.0); Text("每 2 秒 · 推荐").tag(2.0); Text("每 5 秒").tag(5.0)
                }
                Picker("面板收起时", selection: Binding(get: { monitor.idleInterval }, set: { monitor.setIdleInterval($0) })) {
                    Text("每 30 秒 · 推荐").tag(30.0); Text("每 60 秒").tag(60.0); Text("每 120 秒").tag(120.0); Text("完全暂停").tag(0.0)
                }
                Text("休眠或熄屏时暂停；低电量模式或系统热压力较高时，展开最快 5 秒，后台最快 60 秒。后台仅按所选菜单栏指标采集；仅图标且未开启摘要和提醒时没有周期采样。展开后也只采集当前页面需要的模块。卷容量每分钟、电芯每 10 秒、电池温度最快每 5 秒读取。手动风扇的守护检查独立每 2 秒执行。")
                    .font(.system(size: 11)).foregroundStyle(centerMuted)
                Text("当前：\(monitor.cadenceLabel) · 本次已采样 \(monitor.sampleCount) 次")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(senseiMint)
            }
            section("轻量状态提醒", symbol: "bell") { AlertSettingsView(manager: monitor.alerts) }
            section("数据保留", symbol: "externaldrive.badge.checkmark") {
                Toggle("保留电池容量变化摘要", isOn: Binding(get: { monitor.batteryHistoryEnabled }, set: { monitor.setBatteryHistory($0) }))
                Text("默认关闭。开启后每天最多一条：日期、估算容量和循环次数，最多 90 条，文件硬上限 64 KiB。用于观察电池容量变化，不记录完整监测数据。")
                    .font(.system(size: 11)).foregroundStyle(centerMuted)
                HStack {
                    Text("已保存 \(monitor.historyDays.count) 天 · \(monitor.historyBytes) 字节").font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Button("关闭记录并清除摘要") { monitor.setBatteryHistory(false); monitor.clearHistory() }
                }
                if let error = monitor.historyError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
                if let first = monitor.historyDays.first, let last = monitor.historyDays.last, monitor.historyDays.count > 1 {
                    Text(String(format: "%@ → %@：估算容量变化 %+.1f 个百分点。日常读数存在波动。", first.day, last.day, last.capacity - first.capacity)).font(.system(size: 11)).foregroundStyle(centerMuted)
                }
                Text("其余数据：CPU、网络和温度各最多 60 个内存趋势点、当前扫描结果和报告；不写日志、不建数据库、不联网。偏好设置由 macOS 保存。")
                    .font(.system(size: 11)).foregroundStyle(centerMuted)
            }
            section("菜单栏与面板", symbol: "menubar.rectangle") {
                Picker("外观", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                Picker("菜单栏显示", selection: $monitor.menuMetric) { Text("CPU 使用率").tag("cpu"); Text("内存占用率").tag("memory"); Text("电池电量").tag("battery"); Text("实时下载速度").tag("network"); Text("电源输入功率").tag("power"); Text("仅图标").tag("icon") }.onChange(of: monitor.menuMetric) { _, _ in monitor.saveAppearance() }
                HStack(spacing: 18) {
                    Toggle("GPU", isOn: $monitor.showGPU)
                    Toggle("网络", isOn: $monitor.showNetwork)
                    Toggle("电池", isOn: $monitor.showBattery)
                    Toggle("温度", isOn: $monitor.showTemperatures)
                }.onChange(of: monitor.showGPU) { _, _ in monitor.saveAppearance() }
                    .onChange(of: monitor.showNetwork) { _, _ in monitor.saveAppearance() }
                    .onChange(of: monitor.showBattery) { _, _ in monitor.saveAppearance() }
                    .onChange(of: monitor.showTemperatures) { _, _ in monitor.saveAppearance() }
            }
            section("面板布局", symbol: "rectangle.3.group") { PanelOrderView(monitor: monitor) }
            section("启动与系统", symbol: "power") {
                Toggle("登录时启动 Open Sensei", isOn: Binding(get: { loginEnabled }, set: setLogin))
                Text("建议先将 App 放入“应用程序”文件夹。登录时只驻留菜单栏，不自动弹出窗口。")
                    .font(.system(size: 11)).foregroundStyle(centerMuted)
                if let loginError { Text(loginError).font(.system(size: 11)).foregroundStyle(.orange) }
                Button("打开系统登录项设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
            }
            section("关于此版本", symbol: "info.circle") {
                Text("Open Sensei \(AppVersion.current) · SwiftUI + AppKit · MIT 许可").font(.system(size: 12))
                Text("独立开发，与 Cindori Sensei 无关联。支持监测、电池健康、磁盘状态、手动扫描、应用卸载和轻量测速。已接入 SMC 温度、转速和临时风扇控制。传感器可用性随机型变化；详细 SMART 属性及跨机兼容仍有待完善。")
                    .font(.system(size: 11)).foregroundStyle(centerMuted)
            }
        }.controlSize(.small)
    }

    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginError = SMAppService.mainApp.status == .requiresApproval ? "请在系统登录项设置中允许此应用。" : nil
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; loginError = error.localizedDescription }
    }
    private var thermalText: String {
        switch monitor.snapshot.thermal { case .nominal: return "正常"; case .fair: return "轻度"; case .serious: return "较高"; case .critical: return "严重"; @unknown default: return "未提供" }
    }
    private func bigValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(centerMuted)
            Text(value).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
        }
    }
    private func note(_ text: String, symbol: String = "info.circle") -> some View {
        HStack(alignment: .top, spacing: 7) { Image(systemName: symbol).foregroundStyle(senseiMint); Text(text).fixedSize(horizontal: false, vertical: true) }
            .font(.system(size: 11)).foregroundStyle(centerMuted).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(senseiMint.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
    private func empty(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(senseiMint)
            Text(title).font(.system(size: 17, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(centerMuted)
        }.frame(maxWidth: .infinity).padding(.vertical, 60).senseiCard()
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(senseiMint)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).senseiCard()
    }
}

extension View {
    func senseiCard() -> some View {
        padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.055), lineWidth: 1))
    }
}
