import SwiftUI
import SwiftData
import CryptoKit
import UIKit

/// 数据路径诊断（只读）
/// ------------------------------------------------------------------
/// 用途：判断新旧两个 App 的数据是否落在同一个物理库 / 同一个文件系统 / 同一个 App Group。
/// 读取项：Bundle 身份、运行环境与沙盒形态、主库与房源库路径/大小/时间/SHA256 前 8 位、
///        主库各表条数、Documents/备份/media 路径与文件数、App Group 容器与云端配置实际值。
/// 唯一写操作：用户主动点「写入探针」时在 Documents 根目录写一个 probe_*.txt（不碰业务库）。
struct DataPathDiagnosticsView: View {
    @Environment(\.modelContext) private var mainContext
    @Environment(\.houseModelContext) private var houseContext: ModelContext?

    @State private var snap = DiagSnapshot()
    @State private var probes: [ProbeItem] = []
    @State private var alertText: String?

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    var body: some View {
        Form {
            identitySection
            runtimeSection
            mainStoreSection
            houseStoreSection
            directorySection
            sharedSection
            probeSection
            verdictSection
        }
        .navigationTitle("数据路径诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        copyReport()
                    } label: {
                        Label("复制全部诊断信息", systemImage: "doc.on.doc")
                    }
                    Button {
                        exportTxt()
                    } label: {
                        Label("导出 TXT", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { reload() }
        .alert("提示", isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("好", role: .cancel) { alertText = nil }
        } message: {
            Text(alertText ?? "")
        }
    }

    // MARK: - 各分组

    private var identitySection: some View {
        Section {
            diagRow("Bundle ID", snap.bundleID, mono: true)
            diagRow("App 名称", snap.appName)
            diagRow("版本号 / 构建号", "\(snap.version) / \(snap.build)")
            diagRow("诊断时间", snap.generated)
        } header: {
            Text("身份")
        }
    }

    private var runtimeSection: some View {
        Section {
            diagRow("NSHomeDirectory()", snap.home, mono: true)
            diagRow("Bundle.main.bundlePath", snap.bundlePath, mono: true)
            diagRow("沙盒判定", snap.sandbox)
        } header: {
            Text("运行环境")
        } footer: {
            Text("路径以 /var/mobile/Containers/Data/Application/ 开头 = 独立沙盒容器；直接是 /var/mobile = 文件系统对外共享。")
        }
    }

    private var mainStoreSection: some View {
        Section {
            diagRow("默认假定路径（仅参考）", snap.mainPath, mono: true)
            diagRow("SwiftData 实际 URL", snap.mainActualPath.isEmpty ? "—" : snap.mainActualPath, mono: true)
            diagRow("实际库 inode", snap.mainActualInode.isEmpty ? "—" : snap.mainActualInode, mono: true)
            diagRow("内存模式", snap.mainInMemory ? "是（重启即清空）" : "否")
            diagRow("主库迁移来源", snap.mainMigratedFrom.isEmpty ? "—（未迁移）" : snap.mainMigratedFrom, mono: true)
            diagRow("是否存在 / 大小", snap.mainExists ? "存在 · \(snap.mainSize)" : "不存在")
            diagRow("最后修改时间", snap.mainMtime)
            diagRow("SHA256 前 8 位", snap.mainSHA.isEmpty ? "—" : snap.mainSHA, mono: true)
            diagRow("WAL / SHM", snap.walText)
            ForEach(snap.mainCounts) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(item.count).foregroundStyle(.secondary)
                }
            }
            if !snap.mainCountError.isEmpty {
                Text(snap.mainCountError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("主库（经营数据）")
        } footer: {
            Text("以「SwiftData 实际 URL」为准；两个 App 显示同一路径或同一 inode，说明打开的是同一个物理文件。默认假定路径可能因签名/App Group 变化而失真。")
        }
    }

    private var houseStoreSection: some View {
        Section {
            diagRow("路径", snap.housePath, mono: true)
            diagRow("SwiftData 实际 URL", snap.houseActualPath.isEmpty ? "—" : snap.houseActualPath, mono: true)
            diagRow("实际库 inode", snap.houseActualInode.isEmpty ? "—" : snap.houseActualInode, mono: true)
            diagRow("内存模式", snap.houseInMemory ? "是（重启即清空）" : "否")
            diagRow("是否存在 / 大小", snap.houseExists ? "存在 · \(snap.houseSize)" : "不存在")
            diagRow("最后修改时间", snap.houseMtime)
            HStack {
                Text("房源（House）")
                Spacer()
                Text(snap.houseCount).foregroundStyle(.secondary)
            }
            HStack {
                Text("媒体（MediaItem）")
                Spacer()
                Text(snap.mediaCount).foregroundStyle(.secondary)
            }
            if !snap.houseError.isEmpty {
                Text(snap.houseError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("房源库")
        } footer: {
            Text("房源库固定为 Documents/备份/housekeeper.store，与主库相互独立。")
        }
    }

    private var directorySection: some View {
        Section {
            diagRow("Documents/", snap.docsPath, mono: true)
            diagRow("文件个数", "\(snap.docsFiles) 个")
            diagRow("备份/", snap.backupPath, mono: true)
            diagRow("文件个数", "\(snap.backupFiles) 个")
            diagRow("media/", snap.mediaPath, mono: true)
            diagRow("文件个数", "\(snap.mediaFiles) 个")
        } header: {
            Text("目录")
        } footer: {
            Text("文件个数按目录递归统计（含子目录里的普通文件）。")
        }
    }

    private var sharedSection: some View {
        Section {
            diagRow("App Group ID", snap.groupID, mono: true)
            diagRow("App Group 容器", snap.groupPath, mono: true)
            diagRow("共享区 cloud.username", snap.sharedUser)
            diagRow("共享区 cloud.functionURL", snap.sharedFunctionURL, mono: true)
            diagRow("本机标准 cloud.username", snap.standardUser)
            diagRow("本机标准 cloud.functionURL", snap.standardFunctionURL, mono: true)
            diagRow("实际生效 CloudUser.username", snap.effectiveUser)
            diagRow("实际生效 CloudConfig.functionURL", snap.effectiveFunctionURL, mono: true)
        } header: {
            Text("共享区与云端配置")
        } footer: {
            Text("共享区有值 = App Group 可用；容器显示 nil = 该安装没有可用的 App Group（未签名侧载常见）。")
        }
    }

    private var probeSection: some View {
        Section {
            Button {
                writeProbe()
            } label: {
                Label("写入探针", systemImage: "mappin.and.ellipse")
            }
            Button {
                refreshProbes()
                alertText = "探针列表已刷新（\(probes.count) 个）"
            } label: {
                Label("刷新探针列表", systemImage: "arrow.clockwise")
            }
            if probes.isEmpty {
                Text("暂无探针文件").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(probes) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Text("\(p.size) · \(p.modified)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("探针")
        } footer: {
            Text("探针写在 Documents/ 根目录，命名 probe_<BundleID>_<时间>.txt。另一个 App 能刷出本 App 写的探针，说明两者文件系统是同一处。")
        }
    }

    private var verdictSection: some View {
        Section {
            diagRow("主库指纹（SHA256 前 8 位）", snap.mainSHA.isEmpty ? "—" : snap.mainSHA, mono: true)
            Text("两个 App 显示同一串 → 打开的是同一个物理文件；不同 → 本地库分开，问题在共享区或云端。")
                .font(.caption)
                .foregroundStyle(.secondary)
            diagRow("探针互见", probeVerdict)
            if !foreignProbes.isEmpty {
                ForEach(foreignProbes) { p in
                    Text(p.name)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("判据")
        }
    }

    // MARK: - 取值

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var ownProbePrefix: String { "probe_\(snap.bundleID)_" }

    private var foreignProbes: [ProbeItem] {
        probes.filter { !$0.name.hasPrefix(ownProbePrefix) }
    }

    private var probeVerdict: String {
        if probes.isEmpty {
            return "尚无探针，点上方「写入探针」"
        }
        if foreignProbes.isEmpty {
            return "只看到本 App 的 \(probes.count) 个探针 → 文件系统隔离"
        }
        return "发现 \(foreignProbes.count) 个其它 App 的探针 → 文件系统共享"
    }

    private func reload() {
        var s = DiagSnapshot()
        let now = Date()
        s.generated = Self.stampFormatter.string(from: now)

        let bundle = Bundle.main
        s.bundleID = bundle.bundleIdentifier ?? "nil"
        s.appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "—"
        s.version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
        s.build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
        s.home = NSHomeDirectory()
        s.bundlePath = bundle.bundlePath

        if s.home.hasPrefix("/var/mobile/Containers/Data/Application/") {
            s.sandbox = "沙盒（独立数据容器）"
        } else if s.home.hasPrefix("/var/mobile") {
            s.sandbox = "非沙盒（共享 /var/mobile）"
        } else {
            s.sandbox = "其它路径（疑似模拟器 / 调试环境）"
        }

        // 主库：SwiftData 默认 store（Application Support/default.store）
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? documentsURL
        let mainURL = appSupport.appendingPathComponent("default.store")
        s.mainPath = mainURL.path
        let mainInfo = Self.fileInfo(mainURL)
        s.mainExists = mainInfo.exists
        s.mainSize = mainInfo.sizeText
        s.mainMtime = mainInfo.modifiedText
        s.mainSHA = mainInfo.hash
        s.walText = Self.sidecarText(for: mainURL)

        let mainConfigs = mainContext.container.configurations
        s.mainActualPath = mainConfigs.compactMap { $0.url?.path }.joined(separator: " | ")
        s.mainInMemory = mainConfigs.contains { $0.isStoredInMemoryOnly }
        if let actual = mainConfigs.compactMap({ $0.url }).first {
            s.mainActualInode = Self.inodeText(actual)
        }
        s.mainMigratedFrom = AgentToolApp.MainStoreLocation.migratedFrom

        s.mainCounts = [
            countRow("房源（Property）", Property.self),
            countRow("成交（DealRecord）", DealRecord.self),
            countRow("收租月记录（RentMonthRecord）", RentMonthRecord.self),
            countRow("杂费收入（MiscIncome）", MiscIncome.self),
            countRow("杂费支出（MiscExpense）", MiscExpense.self),
            countRow("待办（TodoItem）", TodoItem.self),
            countRow("包租（PayoutRecord）", PayoutRecord.self),
            countRow("水电季度（UtilityQuarterRecord）", UtilityQuarterRecord.self),
            countRow("水电结算（UtilitySettlementRecord）", UtilitySettlementRecord.self),
            countRow("包租月记录（PayoutMonthRecord）", PayoutMonthRecord.self),
            countRow("包租水电（PayoutUtilityRecord）", PayoutUtilityRecord.self),
            countRow("结算历史（UtilitySettlementHistory）", UtilitySettlementHistory.self)
        ]

        // 房源库：Documents/备份/housekeeper.store
        let houseURL = DataRoot.url().appendingPathComponent("housekeeper.store")
        s.housePath = houseURL.path
        let houseInfo = Self.fileInfo(houseURL)
        s.houseExists = houseInfo.exists
        s.houseSize = houseInfo.sizeText
        s.houseMtime = houseInfo.modifiedText
        if let ctx = houseContext {
            let cfgs = ctx.container.configurations
            s.houseActualPath = cfgs.compactMap { $0.url?.path }.joined(separator: " | ")
            s.houseInMemory = cfgs.contains { $0.isStoredInMemoryOnly }
            if let actual = cfgs.compactMap({ $0.url }).first {
                s.houseActualInode = Self.inodeText(actual)
            }
            do {
                s.houseCount = "\(try ctx.fetchCount(FetchDescriptor<House>()))"
                s.mediaCount = "\(try ctx.fetchCount(FetchDescriptor<MediaItem>()))"
            } catch {
                s.houseError = "房源库读取失败：\(error.localizedDescription)"
            }
        } else {
            s.houseError = "未注入房源 ModelContext（houseModelContext 为 nil）"
        }

        // 目录
        s.docsPath = documentsURL.path
        s.docsFiles = Self.fileCount(in: documentsURL)
        let backupURL = DataRoot.url()
        s.backupPath = backupURL.path
        s.backupFiles = Self.fileCount(in: backupURL)
        let mediaURL = MediaStore.mediaDirectory()
        s.mediaPath = mediaURL.path
        s.mediaFiles = Self.fileCount(in: mediaURL)

        // 共享区与云端配置
        s.groupID = SharedBridge.groupID
        s.groupPath = SharedBridge.containerURL?.path ?? "nil（App Group 不可用）"
        let sharedDefaults = UserDefaults(suiteName: SharedBridge.groupID)
        s.sharedUser = sharedDefaults?.string(forKey: "cloud.username") ?? "—"
        s.sharedFunctionURL = sharedDefaults?.string(forKey: "cloud.functionURL") ?? "—"
        s.standardUser = UserDefaults.standard.string(forKey: "cloud.username") ?? "—"
        s.standardFunctionURL = UserDefaults.standard.string(forKey: "cloud.functionURL") ?? "—"
        s.effectiveUser = CloudUser.username
        s.effectiveFunctionURL = CloudConfig.functionURL

        s.generated = s.generated.isEmpty ? Self.stampFormatter.string(from: now) : s.generated
        snap = s
        refreshProbes()
    }

    private func countRow<T: PersistentModel>(_ name: String, _ type: T.Type) -> CountItem {
        do {
            let n = try mainContext.fetchCount(FetchDescriptor<T>())
            return CountItem(name: name, count: "\(n)")
        } catch {
            return CountItem(name: name, count: "读取失败")
        }
    }

    private func refreshProbes() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []
        probes = files
            .filter { $0.lastPathComponent.hasPrefix("probe_") && $0.pathExtension.lowercased() == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let size = ByteCountFormatter.string(
                    fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
                let modified = values?.contentModificationDate.map { Self.stampFormatter.string(from: $0) } ?? "—"
                return ProbeItem(name: url.lastPathComponent, size: size, modified: modified)
            }
    }

    private func writeProbe() {
        var body = "probe\n"
        body += "bundleID=\(snap.bundleID)\n"
        body += "app=\(snap.appName)\n"
        body += "version=\(snap.version)(\(snap.build))\n"
        body += "home=\(snap.home)\n"
        body += "time=\(Self.stampFormatter.string(from: Date()))\n"
        let name = "probe_\(snap.bundleID)_\(Self.fileStampFormatter.string(from: Date())).txt"
        let url = documentsURL.appendingPathComponent(name)
        do {
            try body.data(using: .utf8)?.write(to: url, options: .atomic)
            refreshProbes()
            alertText = "已写入 \(name)\n请到另一台 App 的同一页面点「刷新探针列表」看是否能刷出。"
        } catch {
            alertText = "写入失败：\(error.localizedDescription)"
        }
    }

    private func copyReport() {
        UIPasteboard.general.string = buildReport()
        alertText = "已复制完整诊断信息"
    }

    private func exportTxt() {
        let name = "数据路径诊断_\(snap.bundleID)_\(Self.fileStampFormatter.string(from: Date())).txt"
        let url = documentsURL.appendingPathComponent(name)
        do {
            try buildReport().data(using: .utf8)?.write(to: url, options: .atomic)
            SharePresenter.present(items: [url])
        } catch {
            alertText = "导出失败：\(error.localizedDescription)"
        }
    }

    private func buildReport() -> String {
        var lines: [String] = []
        lines.append("公寓管家 · 数据路径诊断")
        lines.append("生成时间：\(snap.generated)")
        lines.append("")
        lines.append("[身份]")
        lines.append("Bundle ID：\(snap.bundleID)")
        lines.append("App 名称：\(snap.appName)")
        lines.append("版本号 / 构建号：\(snap.version) / \(snap.build)")
        lines.append("")
        lines.append("[运行环境]")
        lines.append("NSHomeDirectory：\(snap.home)")
        lines.append("bundlePath：\(snap.bundlePath)")
        lines.append("沙盒判定：\(snap.sandbox)")
        lines.append("")
        lines.append("[主库]")
        lines.append("路径：\(snap.mainPath)")
        lines.append("SwiftData 实际 URL：\(snap.mainActualPath)")
        lines.append("实际库 inode：\(snap.mainActualInode)")
        lines.append("内存模式：\(snap.mainInMemory ? "是（重启即清空）" : "否")")
        lines.append("主库迁移来源：\(snap.mainMigratedFrom.isEmpty ? "—（未迁移）" : snap.mainMigratedFrom)")
        lines.append("存在 / 大小：\(snap.mainExists ? "存在" : "不存在") / \(snap.mainSize)")
        lines.append("最后修改：\(snap.mainMtime)")
        lines.append("SHA256 前 8 位：\(snap.mainSHA.isEmpty ? "—" : snap.mainSHA)")
        lines.append("WAL / SHM：\(snap.walText)")
        for item in snap.mainCounts {
            lines.append("  \(item.name)：\(item.count)")
        }
        if !snap.mainCountError.isEmpty { lines.append("  错误：\(snap.mainCountError)") }
        lines.append("")
        lines.append("[房源库]")
        lines.append("路径：\(snap.housePath)")
        lines.append("SwiftData 实际 URL：\(snap.houseActualPath)")
        lines.append("实际库 inode：\(snap.houseActualInode)")
        lines.append("内存模式：\(snap.houseInMemory ? "是（重启即清空）" : "否")")
        lines.append("存在 / 大小：\(snap.houseExists ? "存在" : "不存在") / \(snap.houseSize)")
        lines.append("最后修改：\(snap.houseMtime)")
        lines.append("House：\(snap.houseCount)")
        lines.append("MediaItem：\(snap.mediaCount)")
        if !snap.houseError.isEmpty { lines.append("错误：\(snap.houseError)") }
        lines.append("")
        lines.append("[目录]")
        lines.append("Documents/：\(snap.docsPath)（\(snap.docsFiles) 个文件）")
        lines.append("备份/：\(snap.backupPath)（\(snap.backupFiles) 个文件）")
        lines.append("media/：\(snap.mediaPath)（\(snap.mediaFiles) 个文件）")
        lines.append("")
        lines.append("[共享区与云端配置]")
        lines.append("App Group ID：\(snap.groupID)")
        lines.append("App Group 容器：\(snap.groupPath)")
        lines.append("共享区 cloud.username：\(snap.sharedUser)")
        lines.append("共享区 cloud.functionURL：\(snap.sharedFunctionURL)")
        lines.append("本机标准 cloud.username：\(snap.standardUser)")
        lines.append("本机标准 cloud.functionURL：\(snap.standardFunctionURL)")
        lines.append("实际生效 CloudUser.username：\(snap.effectiveUser)")
        lines.append("实际生效 CloudConfig.functionURL：\(snap.effectiveFunctionURL)")
        lines.append("")
        lines.append("[探针]")
        lines.append("本 App 探针前缀：\(ownProbePrefix)")
        if probes.isEmpty {
            lines.append("暂无探针文件")
        } else {
            for p in probes {
                lines.append("\(p.name)  \(p.size)  \(p.modified)")
            }
        }
        lines.append("判据：\(probeVerdict)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func diagRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(mono ? .system(.footnote, design: .monospaced) : .footnote)
                .textSelection(.enabled)
        }
    }

    // MARK: - 文件取值

    private struct FileInfo {
        var exists: Bool
        var sizeText: String
        var modifiedText: String
        var hash: String
    }

    private static func fileInfo(_ url: URL) -> FileInfo {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return FileInfo(exists: false, sizeText: "—", modifiedText: "—", hash: "")
        }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs?[.modificationDate] as? Date).map { stampFormatter.string(from: $0) } ?? "—"
        let hash = shaPrefix8(url)
        return FileInfo(
            exists: true,
            sizeText: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
            modifiedText: modified,
            hash: hash
        )
    }

    /// 文件资源标识（iOS 上通常对应 inode）；两个 App 显示同一值说明指向同一物理文件
    private static func inodeText(_ url: URL) -> String {
        guard let id = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier else {
            return ""
        }
        return String(describing: id)
    }

    private static func shaPrefix8(_ url: URL) -> String {        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func sidecarText(for storeURL: URL) -> String {
        let fm = FileManager.default
        var parts: [String] = []
        for suffix in ["-wal", "-shm"] {
            let path = storeURL.path + suffix
            if fm.fileExists(atPath: path),
               let attrs = try? fm.attributesOfItem(atPath: path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                parts.append("\(suffix) \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            }
        }
        return parts.isEmpty ? "无（未启用 WAL 或已 checkpoint）" : parts.joined(separator: " · ")
    }

    private static func fileCount(in url: URL) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        var count = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == false {
                count += 1
            }
        }
        return count
    }
}

// MARK: - 数据载体

private struct CountItem: Identifiable {
    let id = UUID()
    let name: String
    let count: String
}

private struct ProbeItem: Identifiable {
    var id: String { name }
    let name: String
    let size: String
    let modified: String
}

private struct DiagSnapshot {
    var generated = ""
    var bundleID = ""
    var appName = ""
    var version = ""
    var build = ""
    var home = ""
    var bundlePath = ""
    var sandbox = ""
    var mainPath = ""
    var mainExists = false
    var mainSize = ""
    var mainMtime = ""
    var mainSHA = ""
    var walText = ""
    var mainActualPath = ""
    var mainActualInode = ""
    var mainInMemory = false
    var mainMigratedFrom = ""
    var mainCounts: [CountItem] = []
    var mainCountError = ""
    var housePath = ""
    var houseExists = false
    var houseSize = ""
    var houseMtime = ""
    var houseActualPath = ""
    var houseActualInode = ""
    var houseInMemory = false
    var houseCount = "—"
    var mediaCount = "—"
    var houseError = ""
    var docsPath = ""
    var docsFiles = 0
    var backupPath = ""
    var backupFiles = 0
    var mediaPath = ""
    var mediaFiles = 0
    var groupID = ""
    var groupPath = ""
    var sharedUser = ""
    var sharedFunctionURL = ""
    var standardUser = ""
    var standardFunctionURL = ""
    var effectiveUser = ""
    var effectiveFunctionURL = ""
}
