import Foundation
import AppKit
import Darwin

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var handlers: [UUID: () -> Void] = [:]
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() {
        lock.lock(); value = true; let callbacks = Array(handlers.values); handlers.removeAll(); lock.unlock()
        callbacks.forEach { $0() }
    }
    func onCancel(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); let immediate = value; if !immediate { handlers[id] = callback }; lock.unlock()
        if immediate { callback() }; return id
    }
    func removeHandler(_ id: UUID) { lock.lock(); handlers.removeValue(forKey: id); lock.unlock() }
}

// Keep the largest K items with a min heap: O(log K) replacement, bounded memory.
struct LargestFiles {
    let limit: Int
    private(set) var heap: [FileRecord] = []
    func accepts(_ bytes: Int64) -> Bool { limit > 0 && (heap.count < limit || bytes > heap[0].bytes) }
    mutating func insert(_ file: FileRecord) {
        guard accepts(file.bytes) else { return }
        if heap.count < limit {
            heap.append(file); var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard heap[child].bytes < heap[parent].bytes else { break }
                heap.swapAt(child, parent); child = parent
            }
        } else {
            heap[0] = file; var parent = 0
            while parent * 2 + 1 < heap.count {
                let left = parent * 2 + 1, right = left + 1
                let smaller = right < heap.count && heap[right].bytes < heap[left].bytes ? right : left
                guard heap[smaller].bytes < heap[parent].bytes else { break }
                heap.swapAt(parent, smaller); parent = smaller
            }
        }
    }
    var sorted: [FileRecord] { heap.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes } }
}

struct FileRecord: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let bytes: Int64
    let modified: Date?
    let identity: String
}
struct FolderTotal: Identifiable {
    var id: String { name }
    let name: String
    let bytes: Int64
}
struct ScanReport {
    var files: [FileRecord] = []
    var folders: [FolderTotal] = []
    var total: Int64 = 0
    var visited = 0
    var unreadable = 0
    var skippedCloud = 0
    var skippedVolumes = 0
    var partial = false
    var reason = ""
}

enum StorageScanner {
    static func scan(_ root: URL, token: CancellationToken, entryLimit: Int = ResourcePolicy.scanEntryLimit, seconds: Double = ResourcePolicy.scanSeconds) -> ScanReport {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey, .isDirectoryKey]
        var report = ScanReport()
        guard !token.cancelled else { report.partial = true; report.reason = "已取消"; return report }
        guard (try? root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else {
            report.partial = true; report.reason = "仅扫描本地卷，远程卷请在 Finder 中查看"; return report
        }
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else { report.partial = true; report.reason = "无法读取目录"; return report }
        let start = ProcessInfo.processInfo.systemUptime
        var totals: [String: Int64] = [:]
        var largest = LargestFiles(limit: ResourcePolicy.scanResultLimit)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in report.unreadable += 1; return !token.cancelled }) else {
            report.reason = "无法读取所选目录"; report.partial = true; return report
        }
        for case let url as URL in enumerator {
            if token.cancelled { report.partial = true; report.reason = "已取消"; break }
            if report.visited >= entryLimit || ProcessInfo.processInfo.systemUptime - start >= seconds {
                report.partial = true; report.reason = "已达到扫描预算"; break
            }
            report.visited += 1
            // lstat only reads metadata, including File Provider's dataless flag.
            var info = stat()
            guard lstat(url.path, &info) == 0 else { report.unreadable += 1; continue }
            if info.st_dev != rootStat.st_dev { report.skippedVolumes += 1; enumerator.skipDescendants(); continue }
            if info.st_flags & UInt32(SF_DATALESS) != 0 { report.skippedCloud += 1; enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: keys) else { report.unreadable += 1; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            report.total += bytes
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let component = relative.split(separator: "/").first.map(String.init) ?? "当前目录"
            let group = relative.contains("/") ? component : "当前目录文件"
            let bucket = totals[group] != nil || totals.count < 100 ? group : "其他目录"
            totals[bucket, default: 0] += bytes
            if largest.accepts(bytes) {
                let identity = values.fileResourceIdentifier.map { String(describing: $0) } ?? ""
                largest.insert(FileRecord(url: url, bytes: bytes, modified: values.contentModificationDate, identity: identity))
            }
            // Yield periodically; scans run only on the utility queue after a user action.
            if report.visited % 512 == 0 { Thread.sleep(forTimeInterval: 0.002) }
        }
        report.files = largest.sorted
        report.folders = totals.map { FolderTotal(name: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
        return report
    }

    static func validate(_ record: FileRecord, inside root: URL) throws {
        var freshURL = URL(fileURLWithPath: record.url.path)
        freshURL.removeAllCachedResourceValues()
        let canonical = freshURL.resolvingSymlinksInPath().standardizedFileURL
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path == record.url.standardizedFileURL.path, canonical.path.hasPrefix(root.path + "/") else {
            throw ToolError.message("文件路径已变化，请重新扫描。")
        }
        let values = try freshURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileResourceIdentifierKey, .contentModificationDateKey, .fileAllocatedSizeKey, .fileSizeKey])
        let identity = values.fileResourceIdentifier.map { String(describing: $0) } ?? ""
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              values.contentModificationDate == record.modified,
              identity == record.identity,
              Int64(values.fileAllocatedSize ?? values.fileSize ?? 0) == record.bytes else {
            throw ToolError.message("\(record.url.lastPathComponent) 已变化，请重新扫描后再操作。")
        }
    }
}

enum ToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct InstalledApp: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String
    let version: String
}
struct AppFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let label: String
}
enum AppInventory {
    static func load(token: CancellationToken = CancellationToken()) -> [InstalledApp] {
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var result: [InstalledApp] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if token.cancelled { return [] }
                if enumerator.level > 3 { enumerator.skipDescendants(); continue }
                guard url.pathExtension == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                result.append(InstalledApp(url: url, name: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? url.deletingPathExtension().lastPathComponent,
                                           bundleID: id, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func candidates(for app: InstalledApp, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AppFile] {
        var result = [AppFile(url: app.url, label: "应用本体")]
        let id = app.bundleID
        guard validBundleID(id) else { return result }
        let paths = [("Library/Caches/\(id)", "缓存"), ("Library/Preferences/\(id).plist", "偏好设置"),
                     ("Library/Application Support/\(id)", "应用支持文件"), ("Library/Saved Application State/\(id).savedState", "窗口状态")]
        for (path, label) in paths {
            let url = home.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path),
               (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                result.append(AppFile(url: url, label: label))
            }
        }
        return result
    }
    static func validBundleID(_ id: String) -> Bool {
        let genericIDs: Set<String> = ["com.github.Electron", "com.electron", "com.electron.app"]
        return !genericIDs.contains(id) && id.contains(".") && !id.contains("..") && id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }
    @MainActor static func validate(_ app: InstalledApp, selected: [AppFile]) throws {
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let canonical = app.url.resolvingSymlinksInPath().standardizedFileURL
        guard roots.contains(where: { canonical.path.hasPrefix($0.path + "/") }),
              canonical.path == app.url.standardizedFileURL.path,
              Bundle(url: canonical)?.bundleIdentifier == app.bundleID,
              app.bundleID != Bundle.main.bundleIdentifier,
              !app.bundleID.hasPrefix("com.apple.") else { throw ToolError.message("此应用属于系统或当前工具，无法在这里卸载。") }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty else { throw ToolError.message("请先退出 \(app.name)，再进行卸载。") }
        let allowed = Set(candidates(for: app).map { $0.url.path })
        guard selected.allSatisfy({ allowed.contains($0.url.path) && $0.url.resolvingSymlinksInPath().path == $0.url.path }) else {
            throw ToolError.message("文件路径已变化，请重新查看卸载清单。")
        }
    }
}

struct BenchmarkResult {
    let write: Double
    let read: Double
}
enum DiskBenchmark {
    static func run(in directory: URL, token: CancellationToken) throws -> BenchmarkResult {
        let url = directory.appendingPathComponent(".opensensei-benchmark-\(UUID().uuidString).tmp")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ToolError.message("无法创建临时测速文件，请选择可写目录。") }
        // Unlink immediately: the kernel releases all storage even if the app crashes.
        guard Darwin.unlink(url.path) == 0 else { Darwin.close(fd); try? FileManager.default.removeItem(at: url); throw ToolError.message("无法建立自动回收的临时文件。") }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_NOCACHE, 1) == 0 else { throw ToolError.message("此卷不支持绕过文件缓存，无法进行可靠测速。") }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        arc4random_buf(&buffer, buffer.count)
        let start = ProcessInfo.processInfo.systemUptime
        try buffer.withUnsafeMutableBytes { bytes in
            for _ in 0..<32 {
                if token.cancelled { throw ToolError.message("测速已取消，临时空间已回收。") }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw ToolError.message("写入失败，临时空间已回收。") }
                    offset += count
                }
            }
        }
        guard fsync(fd) == 0 else { throw ToolError.message("同步写入失败。") }
        let writeTime = ProcessInfo.processInfo.systemUptime - start
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw ToolError.message("读取定位失败。") }
        let readStart = ProcessInfo.processInfo.systemUptime
        var total = 0
        try buffer.withUnsafeMutableBytes { bytes in
            while total < ResourcePolicy.benchmarkBytes {
                if token.cancelled { throw ToolError.message("测速已取消，临时空间已回收。") }
                let count = Darwin.read(fd, bytes.baseAddress!, min(bytes.count, ResourcePolicy.benchmarkBytes - total))
                guard count > 0 else { throw ToolError.message("读取失败。") }
                total += count
            }
        }
        return BenchmarkResult(write: Double(ResourcePolicy.benchmarkBytes) / max(0.0001, writeTime),
                               read: Double(total) / max(0.0001, ProcessInfo.processInfo.systemUptime - readStart))
    }
}

@MainActor final class ToolsModel: ObservableObject {
    let processes = ProcessModel()
    let check = CheckModel()
    let batteryDetails = BatteryDetailsModel()
    @Published var scan: ScanReport?
    @Published var scanRoot: URL?
    @Published var scanning = false
    @Published var selectedFiles = Set<String>()
    @Published var apps: [InstalledApp] = []
    @Published var loadingApps = false
    @Published var drives: [DriveInfo] = []
    @Published var volumes: [VolumeInfo] = []
    @Published var driveDate: Date?
    @Published var loadingDrives = false
    @Published var driveLoaded = false
    @Published var benchmarking = false
    @Published var benchmark: BenchmarkResult?
    @Published var message: String?
    private var scanToken: CancellationToken?
    private var benchmarkToken: CancellationToken?
    private var appToken: CancellationToken?
    private var driveToken: CancellationToken?

    func chooseScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择要分析的文件夹。只读取文件大小，不读取文件内容。"
        panel.prompt = "开始扫描"
        panel.begin { [weak self] result in
            if result == .OK, let url = panel.url { self?.startScan(url) }
        }
    }
    func startScan(_ root: URL) {
        guard !scanning else { return }
        let token = CancellationToken()
        scanToken = token; scanning = true; scan = nil; scanRoot = root; selectedFiles = []
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = StorageScanner.scan(root, token: token)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanToken === token else { return }
                self.scan = report; self.scanning = false
            }
        }
    }
    func cancelScan() { scanToken?.cancel() }
    func clearScan() { scanToken?.cancel(); scanToken = nil; scanning = false; scan = nil; scanRoot = nil; selectedFiles = [] }
    func loadApps() {
        guard !loadingApps else { return }
        let token = CancellationToken(); appToken = token; loadingApps = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = AppInventory.load(token: token)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.appToken === token else { return }
                self.apps = result; self.loadingApps = false; self.appToken = nil
            }
        }
    }
    func loadDrives() {
        guard !loadingDrives else { return }
        let token = CancellationToken(); driveToken = token; loadingDrives = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try SystemReport.drives(token: token) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.driveToken === token else { return }
                loadingDrives = false; driveLoaded = true; driveToken = nil
                switch result {
                case .success(let value): drives = value.drives; volumes = value.volumes; driveDate = value.date
                case .failure(let error): message = error.localizedDescription
                }
            }
        }
    }
    func startBenchmark() {
        guard !benchmarking else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "开始 32 MiB 测速"
        panel.message = "在所选卷临时写入并读取 32 MiB；完成、取消或退出后自动回收。小样本结果仅供参考。"
        panel.begin { [weak self] result in
            guard let self, result == .OK, let directory = panel.url else { return }
            let token = CancellationToken()
            benchmarkToken = token; benchmarking = true; benchmark = nil
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { try DiskBenchmark.run(in: directory, token: token) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.benchmarkToken === token else { return }
                    self.benchmarking = false; self.benchmarkToken = nil
                    switch result { case .success(let value): self.benchmark = value; case .failure(let error): self.message = error.localizedDescription }
                }
            }
        }
    }
    func cancelBenchmark() { benchmarkToken?.cancel() }
    func cancelAll() {
        cancelScan(); cancelBenchmark(); appToken?.cancel(); driveToken?.cancel(); processes.cancel(); check.cancel(); batteryDetails.cancel()
        appToken = nil; driveToken = nil; benchmarkToken = nil
        loadingApps = false; loadingDrives = false; benchmarking = false
    }
    func releaseResults() {
        clearScan(); processes.clear(); check.clear(); batteryDetails.clear()
        apps = []; drives = []; volumes = []; driveDate = nil; driveLoaded = false; benchmark = nil; message = nil
    }

    func trashSelectedFiles() {
        guard let root = scanRoot, let records = scan?.files.filter({ selectedFiles.contains($0.id) }), !records.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "将选中的 \(records.count) 个文件移到废纸篓？"
        alert.informativeText = "请先关闭可能使用这些文件的应用。可在 Finder 废纸篓中恢复；清空废纸篓前，磁盘空间不会完全释放。\n\n" + records.prefix(8).map { $0.url.lastPathComponent }.joined(separator: "\n")
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移到废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        var moved = Set<String>()
        do {
            for record in records { try StorageScanner.validate(record, inside: root) }
            for record in records { try FileManager.default.trashItem(at: record.url, resultingItemURL: nil); moved.insert(record.id) }
            message = "已移动 \(moved.count) 个文件到废纸篓。目录统计保留扫描时的值；请重新扫描以更新。"
        } catch { message = "已移动 \(moved.count) 项。\(error.localizedDescription)" }
        scan?.files.removeAll { moved.contains($0.id) }; selectedFiles.subtract(moved)
    }

    func uninstall(_ app: InstalledApp, selected: [AppFile]) {
        guard !selected.isEmpty else { return }
        do { try AppInventory.validate(app, selected: selected) } catch { message = error.localizedDescription; return }
        let alert = NSAlert()
        alert.messageText = "将 \(app.name) 的所选项目移到废纸篓？"
        alert.informativeText = "应用支持文件可能包含个人数据，请确认清单。可从废纸篓恢复。\n\n" + selected.map { $0.url.path }.joined(separator: "\n")
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移到废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        var moved = 0
        do {
            try AppInventory.validate(app, selected: selected)
            for file in selected { try FileManager.default.trashItem(at: file.url, resultingItemURL: nil); moved += 1 }
            message = "已移动 \(moved) 项到废纸篓。"
            if !FileManager.default.fileExists(atPath: app.url.path) { apps.removeAll { $0.id == app.id } }
        } catch { message = "已移动 \(moved) 项。\(error.localizedDescription)" }
    }
}
