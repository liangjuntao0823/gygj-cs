import SwiftUI
import UIKit
import SwiftData
import UniformTypeIdentifiers

// MARK: - v2.37 批量录入：批量导入（导入全套/只导入媒体）/ 扫描补全

/// 批量导入的单个房源项（预览用）
struct BatchImportItem: Identifiable {
    let id = UUID()
    var rawRoomNo = ""          // 预览回显：CSV 原始输入 / zip·目录名（用户写什么显示什么）
    var roomNo: String          // 房号本体（不带 2-/1- 前缀；tower 单独记录）
    var tower: Int
    var landlord = ""
    var layout = ""
    var price = 0
    var password = ""
    var remark = ""
    var statusRaw = HouseStatus.available.rawValue
    var mediaDirKey: String?    // 媒体来源目录 key（zip 解压临时目录 或 media/ 下已有目录）
    var duplicate = false       // 本机已收录（同座同房号且未进回收站）
    var cloudDuplicate = false  // 云端已存在该房号
    var diskFileCount = 0       // 目录内媒体文件数
    var existingRecordCount = 0 // 已收录房已有的 MediaItem 记录数
    var missingRecordCount = 0  // 待补记录数（磁盘有、记录没有）
    var excluded = false        // 本次不导入（只导入媒体/媒体合并时的不可导入项）
    var skipReason = ""        // 不导入原因
}

/// 批量导入结果汇总
struct BatchImportSummary {
    var created = 0            // 新建房源
    var skippedDuplicate = 0   // 跳过重复
    var mediaAttached = 0      // 补挂媒体的房源数
    var mediaFiles = 0         // 复制/补建的媒体文件数
    var cloudLedger = 0        // 已同步账本的房源数
    var cloudFailed = 0        // 云端同步失败的房源数
    var errors: [String] = []
}

/// v2.37：批量录入页
/// 顶部两个 tab：
///  1. 批量导入：两个入口——「导入全套」（清单 + 媒体包，两步向导）与「只导入媒体」（给已存在房源补媒体）
///  2. 扫描补全：扫描 Documents/media/ 下已存在的房号目录（逻辑保持原样，仅本机导入不自动上云）
struct HouseBatchImportView: View {
    @Environment(\.houseModelContext) private var houseModelContext
    @Environment(\.dismiss) private var dismiss

    enum TopTab: String, CaseIterable, Identifiable {
        case batch = "批量导入"
        case scan = "扫描补全"
        var id: String { rawValue }
    }
    @State private var tab: TopTab = .batch

    /// 批量导入向导阶段
    enum BatchPhase {
        case entry        // 入口（两个按钮）
        case fullStep1    // 导入全套·第一步：清单（去重后列表）
        case fullStep2    // 导入全套·第二步：媒体包合并展示
        case mediaOnly    // 只导入媒体
    }
    @State private var phase: BatchPhase = .entry

    // —— 清单（导入全套第一步） ——
    @State private var csvText = ""
    @State private var fullListItems: [BatchImportItem] = []
    @State private var parseInfo = ""

    // —— 媒体包（导入全套第二步 / 只导入媒体共用） ——
    @State private var pickedZip: URL?
    @State private var zipTempRoot: URL?
    @State private var pickedIsFolder = false
    @State private var mediaParsed: [BatchImportItem] = []
    @State private var zipParseInfo = ""
    @State private var zipErrorHint = ""

    // —— 只导入媒体 ——
    @State private var mediaOnlyItems: [BatchImportItem] = []

    // —— 扫描补全 ——
    @State private var scanItems: [BatchImportItem] = []
    @State private var scanInfo = ""
    @State private var scanBadHint = ""

    // —— 文件选择（UIKit 文档选择器） ——
    enum PickerTarget: String, Identifiable {
        case csv, zipFile, folder
        var id: String { rawValue }
        var types: [UTType] {
            switch self {
            case .csv: return [.commaSeparatedText, .plainText, .text, .data]
            case .zipFile: return [.zip, .archive, .data]
            case .folder: return [.folder]
            }
        }
    }
    @State private var templateURL: URL?

    // —— 通用 ——
    @State private var isImporting = false
    @State private var summary: BatchImportSummary?
    @State private var showSummary = false
    @State private var showError = false
    @State private var errorMessage = ""
    @ObservedObject private var syncCenter = SyncTaskCenter.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("模式", selection: $tab) {
                        ForEach(TopTab.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: tab) { _, _ in
                        // 切 tab 不影响向导数据；扫描与批量各自独立
                    }

                    if tab == .batch {
                        batchTabView
                    } else {
                        scanModeView
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("批量录入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .alert("导入结果", isPresented: $showSummary) {
            Button("好", role: .cancel) {
                if (summary?.created ?? 0) > 0 || (summary?.mediaFiles ?? 0) > 0 { dismiss() }
            }
        } message: {
            if let s = summary { Text(resultText(s)) }
        }
        .alert("导入失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .overlay {
            if isImporting && syncCenter.running.isEmpty {
                ProgressView("正在导入…").padding(24).background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear {
            if templateURL == nil {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("房源导入模板.csv")
                let text = "房号,座号,房东,户型,租金,密码,备注,状态\n1-2334上,,康,单间,1100,,,待租\n2-1418下,,业主,单间,900,,,已租\n"
                // 加 UTF-8 BOM，Windows 的 Excel/记事本打开不乱码
                var bytes = Data([0xEF, 0xBB, 0xBF])
                if let body = text.data(using: .utf8) { bytes.append(body) }
                try? bytes.write(to: url)
                templateURL = url
            }
        }
    }

    // MARK: - 批量导入 tab

    private var batchTabView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let record = syncCenter.running.first(where: { $0.kind == .media || $0.kind == .pushUp }) {
                TaskRowView(record: record)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }

            if phase != .entry {
                Button {
                    phase = .entry
                } label: {
                    Label("返回入口", systemImage: "chevron.left")
                        .font(.footnote)
                }
            }

            switch phase {
            case .entry: entryView
            case .fullStep1: fullStep1View
            case .fullStep2: fullStep2View
            case .mediaOnly: mediaOnlyView
            }
        }
    }

    /// 入口：小字说明 + 两个按钮
    private var entryView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("「导入全套」：先导入房源清单（自动检查并剔除云端已有的重复房号），再导入媒体包，把清单和媒体合并核对，确认后一次性建房源、挂媒体并同步云端。\n「只导入媒体」：仅给本机已存在的房源补媒体（本机没有的房源无法补，会标注原因），确认后补媒体并同步云端。\n导入过程显示在顶部进度条，可最小化；请保持网络通畅，媒体包内文件夹名需带 1-/2- 座号前缀。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))

            Button {
                startFullFlow()
            } label: {
                Label("导入全套", systemImage: "tray.and.arrow.down.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)

            Button {
                startMediaOnly()
            } label: {
                Label("只导入媒体", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(isImporting)
        }
    }

    private func startFullFlow() {
        phase = .fullStep1
        parseInfo = ""
        if fullListItems.isEmpty { parseInfo = "请粘贴或选择清单后点「解析并去重」" }
    }

    private func startMediaOnly() {
        phase = .mediaOnly
        mediaOnlyItems = []
        zipParseInfo = ""
        zipErrorHint = ""
    }

    // MARK: 导入全套·第一步：清单

    private var fullStep1View: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("第一步 · 导入房源清单（每行一间，逗号分隔）：\n房号,座号,房东,户型,租金,密码,备注,状态\n例：1-2334上,,康,单间,1100,,,待租\n房号带 1-/2- 前缀自动识别座号；解析后会自动剔除云端/本机已有的重复房号")
                .font(.footnote)
                .foregroundColor(.secondary)
            TextEditor(text: $csvText)
                .frame(minHeight: 120)
                .font(.system(.callout, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.systemGray4)))
            HStack(spacing: 12) {
                if let templateURL {
                    ShareLink(item: templateURL) {
                        Label("导出模板", systemImage: "square.and.arrow.up")
                    }.font(.subheadline)
                }
                Spacer()
                Button("选 CSV 文件") { presentDocumentPicker(.csv) }.font(.subheadline)
                Button("解析并去重") { parseFullList() }
                    .buttonStyle(.borderedProminent)
            }
            if !parseInfo.isEmpty {
                Text(parseInfo).font(.footnote).foregroundColor(.secondary)
            }
            if !fullListItems.isEmpty {
                previewList(items: fullListItems, style: .fullStep1)
                Button {
                    phase = .fullStep2
                    prepareFullStep2()
                } label: {
                    Text("下一步：选择媒体包（\(fullListItems.count) 间）")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)
            }
        }
    }

    /// 解析清单并做云端/本机去重（重复自动剔除）
    private func parseFullList() {
        parseInfo = ""
        let parsed = parseCsvIntoItems()
        let items = parsed.items
        let badLines = parsed.badCount
        Task {
            let cloudKeys = Set<String>()
            await MainActor.run {
                var kept: [BatchImportItem] = []
                var removed = 0
                for var item in items {
                    let key = roomKeyString(item)
                    if item.duplicate || cloudKeys.contains(key) {
                        item.cloudDuplicate = cloudKeys.contains(key)
                        removed += 1
                        continue
                    }
                    kept.append(item)
                }
                self.fullListItems = kept
                var info = "解析 \(items.count) 间，自动剔除重复 \(removed) 间，可导入 \(kept.count) 间"
                if badLines > 0 { info += "；无法识别 \(badLines) 行" }
                self.parseInfo = info
            }
        }
    }

    // MARK: 导入全套·第二步：媒体包合并

    private var fullStep2View: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("第二步 · 导入媒体包：选 zip 或直接选文件夹（不压缩也行）。根目录按房号建子文件夹（如 1-2334上/），里面放照片视频。\n媒体会按房号自动合并到第一步的清单；没有对应清单的媒体文件夹会单独列出、不导入。")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button("选压缩包") { presentDocumentPicker(.zipFile) }.font(.subheadline)
                Button("选文件夹") { presentDocumentPicker(.folder) }.font(.subheadline)
                Spacer()
                if let name = pickedZip?.lastPathComponent {
                    Text("\(name)\(pickedIsFolder ? "（文件夹）" : "")").font(.footnote).foregroundColor(.secondary)
                } else {
                    Text("未选择").foregroundColor(.secondary)
                }
            }
            if !zipParseInfo.isEmpty {
                Text(zipParseInfo).font(.footnote).foregroundColor(.secondary)
            }
            if !zipErrorHint.isEmpty {
                Text(zipErrorHint).font(.footnote).foregroundColor(.red)
            }
            if !fullListItems.isEmpty {
                previewList(items: fullListItems, style: .fullStep2)
                Button {
                    executeCloudImport(items: fullListItems, flowTitle: "批量导入全套")
                } label: {
                    Text("开始导入并同步云端（\(fullListItems.count) 间）")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)
            }
        }
    }

    /// 进入第二步时重置媒体合并状态
    private func prepareFullStep2() {
        mediaParsed = []
        zipParseInfo = ""
        zipErrorHint = ""
        pickedZip = nil
        zipTempRoot = nil
    }

    /// 媒体包解析后，把媒体合并进第一步清单（原地更新 fullListItems）
    private func mergeMediaIntoFullList() {
        var mediaByKey: [String: BatchImportItem] = [:]
        for m in mediaParsed { mediaByKey[roomKeyString(m)] = m }
        var combined: [BatchImportItem] = []
        for var item in fullListItems {
            if let m = mediaByKey[roomKeyString(item)] {
                item.mediaDirKey = m.mediaDirKey
                item.diskFileCount = m.diskFileCount
                item.missingRecordCount = m.diskFileCount
            }
            combined.append(item)
        }
        let listKeys = Set(fullListItems.map { roomKeyString($0) })
        let unmatched = mediaParsed.filter { !listKeys.contains(roomKeyString($0)) }
        fullListItems = combined
        var info = "媒体包识别 \(mediaParsed.count) 个房号目录，已合并到清单"
        if !unmatched.isEmpty {
            info += "\n以下媒体目录在清单里没有对应房源，本次不导入：\(unmatched.map { $0.rawRoomNo }.joined(separator: "，"))"
        }
        zipParseInfo = info
    }

    // MARK: 只导入媒体

    private var mediaOnlyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择媒体包（zip 或文件夹），系统会逐间检查房号：本机已存在的房源才能补媒体；本机没有的房源（无论云端是否存在）会标注原因、不导入。")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button("选压缩包") { presentDocumentPicker(.zipFile) }.font(.subheadline)
                Button("选文件夹") { presentDocumentPicker(.folder) }.font(.subheadline)
                Spacer()
                if let name = pickedZip?.lastPathComponent {
                    Text("\(name)\(pickedIsFolder ? "（文件夹）" : "")").font(.footnote).foregroundColor(.secondary)
                } else {
                    Text("未选择").foregroundColor(.secondary)
                }
            }
            if !zipParseInfo.isEmpty {
                Text(zipParseInfo).font(.footnote).foregroundColor(.secondary)
            }
            if !zipErrorHint.isEmpty {
                Text(zipErrorHint).font(.footnote).foregroundColor(.red)
            }
            if !mediaOnlyItems.isEmpty {
                previewList(items: mediaOnlyItems, style: .mediaOnly)
                let canImport = mediaOnlyItems.filter { !$0.excluded && $0.missingRecordCount > 0 }.count
                if canImport > 0 {
                    Button {
                        executeCloudImport(items: mediaOnlyItems.filter { !$0.excluded }, flowTitle: "只导入媒体")
                    } label: {
                        Text("开始导入并同步云端（\(canImport) 间）")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)
                }
            }
        }
    }

    /// 只导入媒体：解析媒体包后逐间判断本机/云端是否存在、能否导入
    private func buildMediaOnlyItems() {
        let local = (try? houseModelContext?.fetch(FetchDescriptor<House>())) ?? []
        Task {
            let cloudKeys = Set<String>()
            await MainActor.run {
                var result: [BatchImportItem] = []
                for var item in mediaParsed {
                    let key = roomKeyString(item)
                    if let house = BatchImporter.findDuplicate(roomNo: item.roomNo, tower: item.tower, in: local) {
                        item.duplicate = true
                        item.existingRecordCount = house.mediaItems.count
                        let src = self.mediaSourceURL(for: item)
                        let disk = Set(MediaStore.mediaFileNames(in: src))
                        let exist = Set(house.mediaItems.map { $0.fileName })
                        item.missingRecordCount = disk.subtracting(exist).count
                        if item.missingRecordCount == 0 {
                            item.excluded = true
                            item.skipReason = "媒体已齐全，没有新增文件"
                        }
                    } else if cloudKeys.contains(key) {
                        item.excluded = true
                        item.cloudDuplicate = true
                        item.skipReason = "云端有该房源，但本机没有，请先在房源页同步后再补媒体"
                    } else {
                        item.excluded = true
                        item.skipReason = "本机和云端都没有该房源，无法只补媒体，请用「导入全套」"
                    }
                    result.append(item)
                }
                self.mediaOnlyItems = result
                let can = result.filter { !$0.excluded && $0.missingRecordCount > 0 }.count
                self.zipParseInfo = "识别 \(result.count) 个房号目录，可补媒体 \(can) 间，其余已标注原因"
            }
        }
    }

    // MARK: - 文件选择 & 编码

    private func presentDocumentPicker(_ target: PickerTarget) {
        // 文件夹导入不支持 asCopy，只有纯文件选择才用 asCopy 复制到沙盒
        DocumentPickerPresenter.present(types: target.types, asCopy: target != .folder) { urls in
            guard let url = urls.first else { return }
            switch target {
            case .csv:
                loadCsvFile(url)
            case .zipFile:
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue { parseFolder(url) } else { parseZip(url) }
            case .folder:
                parseFolder(url)
            }
        }
    }

    private func loadCsvFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "无法读取该文件"; showError = true; return
        }
        guard let text = decodeCSV(data) else {
            errorMessage = "无法识别该文件编码（支持 UTF-8 / GBK / Unicode）"
            showError = true; return
        }
        csvText = text
        if phase == .fullStep1 { parseFullList() }
    }

    private func decodeCSV(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        }
        if let s = String(data: data, encoding: .utf8), !s.contains("\u{FFFD}") { return s }
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gbk) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return nil
    }

    /// CSV 文本解析为房源项（不做云端去重，仅本机查重标记），同时返回坏行数
    private func parseCsvIntoItems() -> (items: [BatchImportItem], badCount: Int) {
        var items: [BatchImportItem] = []
        var badLines = 0
        let all = (try? houseModelContext?.fetch(FetchDescriptor<House>())) ?? []
        for (idx, rawLine) in csvText.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var cols = line.components(separatedBy: [",", "，", "\t"])
            cols = cols.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }
            if idx == 0 && (cols.contains("房号") || cols.contains("房间") || cols.contains("room")) { continue }
            guard cols.count >= 1, !cols[0].isEmpty else { badLines += 1; continue }
            let rawRoom = cols[0]
            let rawRoomNorm = rawRoom.replacingOccurrences(of: "2－", with: "2-").replacingOccurrences(of: "1－", with: "1-")
            guard rawRoomNorm.hasPrefix("1-") || rawRoomNorm.hasPrefix("2-") else {
                badLines += 1; continue
            }
            let (roomNo, tower) = BatchImporter.parseRoom(rawRoom, explicitTower: cols.count > 1 ? Int(cols[1].replacingOccurrences(of: "座", with: "")) ?? 0 : 0)
            guard !roomNo.isEmpty else { badLines += 1; continue }
            var item = BatchImportItem(roomNo: roomNo, tower: tower)
            item.rawRoomNo = rawRoom
            if cols.count > 2 { item.landlord = cols[2] }
            if cols.count > 3 { item.layout = cols[3] }
            if cols.count > 4 { item.price = Int(cols[4].replacingOccurrences(of: "元", with: "")) ?? 0 }
            if cols.count > 5 { item.password = cols[5] }
            if cols.count > 6 { item.remark = cols[6] }
            if cols.count > 7 {
                let st = cols[7].lowercased()
                if st.contains("已租") || st == "rented" { item.statusRaw = HouseStatus.rented.rawValue }
                else { item.statusRaw = HouseStatus.available.rawValue }
            }
            item.duplicate = BatchImporter.findDuplicate(roomNo: roomNo, tower: tower, in: all) != nil
            items.append(item)
        }
        return (items, badLines)
    }

    // MARK: - 媒体包解析

    private func parseZip(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let extracted = MediaStore.extractMediaZipToTemp(url: url) else {
            errorMessage = "无法解析该 zip（不是有效的压缩包，或使用了不支持的压缩方式）"
            showError = true; return
        }
        pickedZip = url
        pickedIsFolder = false
        zipTempRoot = extracted.tempRoot
        buildMediaParsed(from: extracted.tempRoot, keys: extracted.roomKeys)
    }

    private func parseFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let keys = MediaStore.subdirNames(at: url)
        guard !keys.isEmpty else {
            errorMessage = "该文件夹下没有按房号建好的子文件夹"
            showError = true; return
        }
        pickedZip = url
        pickedIsFolder = true
        zipTempRoot = url
        buildMediaParsed(from: url, keys: keys)
    }

    /// 媒体包解析公共逻辑：从根目录 + 房号 key 列表构建媒体项
    private func buildMediaParsed(from root: URL, keys: [String]) {
        zipErrorHint = ""
        var items: [BatchImportItem] = []
        var badKeys: [String] = []
        for key in keys {
            let norm = key.replacingOccurrences(of: "2－", with: "2-").replacingOccurrences(of: "1－", with: "1-")
            guard norm.hasPrefix("1-") || norm.hasPrefix("2-") else {
                badKeys.append(key); continue
            }
            let (roomNo, tower) = BatchImporter.parseRoom(key, explicitTower: key.hasPrefix("2-") ? 2 : 0)
            guard !roomNo.isEmpty else { continue }
            var item = BatchImportItem(roomNo: roomNo, tower: tower)
            item.rawRoomNo = key
            item.mediaDirKey = key
            let src = root.appendingPathComponent(key, isDirectory: true)
            item.diskFileCount = MediaStore.mediaFileNames(in: src).count
            item.missingRecordCount = item.diskFileCount
            items.append(item)
        }
        mediaParsed = items
        var info = "媒体包识别 \(items.count) 个合规房号目录"
        if !badKeys.isEmpty {
            info += "；未识别（未带 1-/2- 前缀）\(badKeys.count) 个：\(badKeys.joined(separator: "，"))"
            zipErrorHint = "以下目录名不符合规范（未带座号前缀），已跳过：\(badKeys.joined(separator: "，"))"
        }
        // 根据当前向导阶段分流
        switch phase {
        case .fullStep2:
            mergeMediaIntoFullList()
        case .mediaOnly:
            zipParseInfo = info
            buildMediaOnlyItems()
        default:
            zipParseInfo = info
        }
    }

    /// 媒体项对应的源目录 URL
    private func mediaSourceURL(for item: BatchImportItem) -> URL {
        if let root = zipTempRoot, let key = item.mediaDirKey {
            return root.appendingPathComponent(key, isDirectory: true)
        }
        return MediaStore.houseDirectory(roomKey: roomKeyString(item))
    }

    // MARK: - 扫描补全（逻辑保持原样）

    private var scanModeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("扫描 Documents/media/ 下已按房号建好的文件夹：\n已收录房号 → 比对磁盘与记录，缺失的补建媒体记录；未收录房号 → 自动新建房源（字段留空待补）。\n电脑导入：在「访达/文件」里找到 App 的 Documents/media/，把按房号的文件夹整体拖进去，再回这里点扫描。文件夹名需带座号前缀（1-xxx / 2-xxx）。")
                .font(.footnote)
                .foregroundColor(.secondary)
            Button("扫描 media 目录") { runScan() }
                .buttonStyle(.borderedProminent)
            if !scanInfo.isEmpty {
                Text(scanInfo).font(.footnote).foregroundColor(.secondary)
            }
            if !scanBadHint.isEmpty {
                Text(scanBadHint).font(.footnote).foregroundColor(.red)
            }
            if !scanItems.isEmpty { previewList(items: scanItems, style: .scan) }
            if !scanItems.isEmpty {
                Button("确认导入（新建 \(scanItems.filter { !$0.duplicate }.count) 间，补媒体 \(scanItems.filter { $0.duplicate && $0.missingRecordCount > 0 }.count) 间）") {
                    runLocalImport(items: scanItems)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(isImporting)
            }
        }
    }

    private func runScan() {
        scanInfo = ""
        scanBadHint = ""
        let keys = MediaStore.scanMediaDirectoryKeys()
        guard !keys.isEmpty else {
            scanInfo = "media 目录下没有房号文件夹"
            scanItems = []
            return
        }
        let all = (try? houseModelContext?.fetch(FetchDescriptor<House>())) ?? []
        var items: [BatchImportItem] = []
        var badKeys: [String] = []
        for key in keys {
            let norm = key.replacingOccurrences(of: "2－", with: "2-").replacingOccurrences(of: "1－", with: "1-")
            guard norm.hasPrefix("1-") || norm.hasPrefix("2-") else {
                badKeys.append(key); continue
            }
            let (roomNo, tower) = BatchImporter.parseRoom(key, explicitTower: key.hasPrefix("2-") ? 2 : 0)
            guard !roomNo.isEmpty else { continue }
            var item = BatchImportItem(roomNo: roomNo, tower: tower)
            item.rawRoomNo = key
            item.mediaDirKey = key
            let dir = MediaStore.houseDirectory(roomKey: key)
            item.diskFileCount = MediaStore.mediaFileNames(in: dir).count
            if let house = BatchImporter.findDuplicate(roomNo: roomNo, tower: tower, in: all) {
                item.duplicate = true
                item.existingRecordCount = house.mediaItems.count
                let disk = Set(MediaStore.mediaFileNames(in: dir))
                let exist = Set(house.mediaItems.map { $0.fileName })
                item.missingRecordCount = disk.subtracting(exist).count
            }
            items.append(item)
        }
        scanItems = items
        var info = "发现 \(keys.count) 个房号目录：新建 \(items.filter { !$0.duplicate }.count) 间，补媒体 \(items.filter { $0.duplicate && $0.missingRecordCount > 0 }.count) 间，媒体齐全 \(items.filter { $0.duplicate && $0.missingRecordCount == 0 }.count) 间"
        if !badKeys.isEmpty {
            info += "\n未识别（房号未带 1-/2- 前缀）：\(badKeys.joined(separator: "，"))"
            scanBadHint = "以下目录名不符合规范（未带座号前缀），已跳过：\(badKeys.joined(separator: "，"))"
        }
        scanInfo = info
    }

    // MARK: - 预览列表

    enum PreviewStyle {
        case fullStep1, fullStep2, mediaOnly, scan
    }

    private func previewList(items: [BatchImportItem], style: PreviewStyle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.rawRoomNo.isEmpty ? roomKeyString(item) : item.rawRoomNo)
                            .font(.subheadline).fontWeight(.medium)
                        Spacer()
                        if !item.layout.isEmpty { Text(item.layout).font(.footnote).foregroundColor(.secondary) }
                        if item.price > 0 { Text("\(item.price)元").font(.footnote).foregroundColor(.secondary) }
                        if style == .fullStep1 || style == .fullStep2 {
                            Text(item.statusRaw == HouseStatus.rented.rawValue ? "已租" : "待租")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(item.statusRaw == HouseStatus.rented.rawValue ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                    Text(actionText(for: item, style: style))
                        .font(.caption)
                        .foregroundColor(actionColor(for: item, style: style))
                }
                .padding(.vertical, 4)
                Divider().opacity(0.4)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func actionText(for item: BatchImportItem, style: PreviewStyle) -> String {
        if item.excluded {
            return "不导入 · \(item.skipReason)"
        }
        if !item.duplicate {
            if item.diskFileCount > 0 {
                return "未收录 · 将新建房源（含 \(item.diskFileCount) 个媒体文件）并同步云端"
            }
            if style == .scan {
                return "未收录 · 将新建房源（无媒体）"
            }
            return "未收录 · 将新建房源（无媒体）并同步云端"
        }
        switch style {
        case .fullStep1:
            return "已收录 · 重复房号（应已在去重时剔除）"
        case .fullStep2:
            return "已收录 · 重复房号（应已在去重时剔除）"
        case .mediaOnly:
            if item.missingRecordCount > 0 {
                return "已收录 · 将补挂 \(item.missingRecordCount) 个媒体并同步云端"
            }
            return "已收录 · 媒体齐全"
        case .scan:
            if item.missingRecordCount > 0 {
                return "已收录 · 磁盘 \(item.diskFileCount) 个 · 已有 \(item.existingRecordCount) 条 · 将补挂 \(item.missingRecordCount) 个"
            }
            return "已收录 · 媒体记录齐全（\(item.diskFileCount) 个）"
        }
    }

    private func actionColor(for item: BatchImportItem, style: PreviewStyle) -> Color {
        if item.excluded { return .red }
        if !item.duplicate { return .accentColor }
        if item.missingRecordCount > 0 { return .orange }
        return Color(.systemGreen)
    }

    // MARK: - 本机写入（扫描 & 云端导入共用）

    private func roomKeyString(_ item: BatchImportItem) -> String {
        (item.tower == 2 ? "2-" : "1-") + item.roomNo
    }

    /// 本机写入：新建房源 / 补挂媒体，返回受影响房源与汇总（不做云端动作）
    @MainActor
    private func writeLocal(items: [BatchImportItem]) async -> (houses: [House], summary: BatchImportSummary) {
        guard let ctx = houseModelContext else { return ([], BatchImportSummary()) }
        var summary = BatchImportSummary()
        var all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        // 再查一遍云端账本，防止另一台设备已建同号房（拉取失败退回只查本地，不阻断）
        var cloudRoomKeys = Set<String>()
        var affected: [House] = []

        // 新建房源
        for item in items where !item.duplicate && !item.excluded {
            let itemKey = roomKeyString(item)
            if cloudRoomKeys.contains(itemKey) { summary.skippedDuplicate += 1; continue }
            if BatchImporter.findDuplicate(roomNo: item.roomNo, tower: item.tower, in: all) != nil {
                summary.skippedDuplicate += 1; continue
            }
            let house = House(
                roomNo: item.roomNo, tower: item.tower, landlord: item.landlord, layout: item.layout,
                price: item.price, password: item.password, remark: item.remark,
                status: HouseStatus(rawValue: item.statusRaw) ?? .available)
            ctx.insert(house)
            all.append(house)
            summary.created += 1
            if let key = item.mediaDirKey {
                _ = key
                let files = mediaFilesToAttach(for: item)
                for f in files {
                    let lower = f.lowercased()
                    let media = MediaItem(fileName: f, kind: (lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")) ? "video" : "image")
                    media.house = house
                    ctx.insert(media)
                    summary.mediaFiles += 1
                }
                if !files.isEmpty { summary.mediaAttached += 1 }
            }
            affected.append(house)
        }

        // 已收录房源补挂媒体
        for item in items where item.duplicate && !item.excluded {
            guard let house = BatchImporter.findDuplicate(roomNo: item.roomNo, tower: item.tower, in: all) else { continue }
            let files = mediaFilesToAttach(for: item).filter { f in
                !house.mediaItems.contains(where: { $0.fileName == f })
            }
            var added = 0
            for f in files {
                let lower = f.lowercased()
                let media = MediaItem(fileName: f, kind: (lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")) ? "video" : "image")
                media.house = house
                ctx.insert(media)
                added += 1
            }
            if added > 0 {
                summary.mediaAttached += 1
                summary.mediaFiles += added
                if !affected.contains(where: { $0.mediaRoomKey == house.mediaRoomKey }) { affected.append(house) }
            }
        }
        try? ctx.save()
        return (affected, summary)
    }

    // MARK: - 扫描补全：仅本机导入（保持原逻辑，不自动上云）

    private func runLocalImport(items: [BatchImportItem]) {
        guard let ctx = houseModelContext else { return }
        isImporting = true
        Task { @MainActor in
            let scoped = pickedIsFolder ? (pickedZip?.startAccessingSecurityScopedResource() ?? false) : false
            defer { if scoped { pickedZip?.stopAccessingSecurityScopedResource() } }
            let (houses, baseSummary) = await writeLocal(items: items)
            var summary = baseSummary
            summary.skippedDuplicate += items.filter { $0.duplicate && $0.mediaDirKey == nil }.count
            // 原逻辑：扫描导入不自动上云，清空补传队列，写本地账本镜像
            HouseMediaUploadQueue.clearAll()
            for h in houses {
                LocalHouseLedger.save(h)
                // v2.45：本机导入写账本；v2.46：图片/视频分型
                let scanSplit = HouseLedgerFormat.split(h.mediaItems.map { (name: $0.fileName, kind: $0.kind) })
                let scanSummary = HouseLedgerFormat.mediaSummary(images: scanSplit.images.count, videos: scanSplit.videos.count)
                HouseLedgerStore.append(
                    roomKey: h.mediaRoomKey,
                    action: "扫描补全导入",
                    detail: "本机扫描导入，" + (scanSummary.isEmpty ? "无媒体" : scanSummary),
                    cloudLog: false)
            }
            isImporting = false
            self.summary = summary
            BackupLogStore.log(category: "房源", action: "扫描补全", result: "成功",
                              detail: resultText(summary).replacingOccurrences(of: "\n", with: "；"))
            showSummary = true
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        }
    }

    // MARK: - 批量导入：本机写入 + 同步云端

    private func executeCloudImport(items: [BatchImportItem], flowTitle: String) {
        guard let ctx = houseModelContext else { return }
        isImporting = true
        Task { @MainActor in
            let scoped = pickedIsFolder ? (pickedZip?.startAccessingSecurityScopedResource() ?? false) : false
            defer { if scoped { pickedZip?.stopAccessingSecurityScopedResource() } }

            // 1. 本机写入
            let (houses, baseSummary) = await writeLocal(items: items)
            var summary = baseSummary
            guard !houses.isEmpty else {
                isImporting = false
                errorMessage = "没有可导入的房源（可能全部重复或被剔除）"
                showError = true
                return
            }

            // 2. 同步服务器：已接入走服务器权威库；未接入仅保存本机
            if HouseServerMode.ready {
                let _ = await syncBatchToServer(houses: houses, flowTitle: flowTitle, summary: &summary)
            } else {
                // 未接入服务器：仅本机导入，写本地账本镜像
                for h in houses {
                    LocalHouseLedger.save(h)
                    let localSplit = HouseLedgerFormat.split(h.mediaItems.map { (name: $0.fileName, kind: $0.kind) })
                    let localSummary = HouseLedgerFormat.mediaSummary(images: localSplit.images.count, videos: localSplit.videos.count)
                    HouseLedgerStore.append(
                        roomKey: h.mediaRoomKey,
                        action: flowTitle,
                        detail: "新建房源（仅本机），" + (localSummary.isEmpty ? "无媒体" : localSummary),
                        cloudLog: false)
                }
                summary.errors.append("未接入服务器，本次仅保存到本机")
            }

            isImporting = false
            self.summary = summary
            BackupLogStore.log(category: "房源", action: flowTitle, result: summary.cloudFailed == 0 ? "成功" : "部分失败",
                              detail: resultText(summary).replacingOccurrences(of: "\n", with: "；"), cloud: true)
            showSummary = true
            // v2.44：批量导入完成系统通知
            HouseActionNotifier.shared.send(
                key: "batchimport.\(flowTitle)",
                title: "批量导入完成",
                body: "成功 \(summary.created) 套，云端失败 \(summary.cloudFailed) 套" + (summary.skippedDuplicate > 0 ? "，跳过重复 \(summary.skippedDuplicate) 套" : "")
            )
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        }
    }

    /// 服务器模式批量导入：媒体直传服务器本地磁盘（uploadMedia 内压缩/转码并回写真实文件名映射），
    /// 文本逐套推服务器权威库；文本失败入待补传队列联网自动重试，媒体失败入媒体补传队列。
    /// 返回未同步成功的房号。
    private func syncBatchToServer(houses: [House], flowTitle: String,
                                   summary: inout BatchImportSummary) async -> [String] {
        let totalUnits = max(1, houses.reduce(0) { $0 + $1.mediaItems.count } + houses.count)
        let importID = syncCenter.begin(kind: .media, title: flowTitle,
                                        roomKeys: houses.map { $0.mediaRoomKey }, total: totalUnits)
        var failedMediaRooms: [String] = []
        var failedLedgerRooms: [String] = []
        await MediaActivityGate.shared.beginUpload()
        defer { Task { await MediaActivityGate.shared.endUpload() } }
        var done = 0
        for house in houses {
            let roomKey = house.mediaRoomKey
            let files = house.mediaItems
            syncCenter.advance(id: importID, done: done, note: "正在处理 \(roomKey)")
            for mi in files {
                do {
                    let localURL = MediaStore.url(for: mi.fileName, roomKey: roomKey)
                    guard FileManager.default.fileExists(atPath: localURL.path) else {
                        throw HouseAPIError(message: "本地媒体不存在：\(mi.fileName)")
                    }
                    let data = try Data(contentsOf: localURL)
                    _ = try await HouseRemoteClient.shared.uploadMedia(
                        roomKey: roomKey, fileName: mi.fileName, kind: mi.kind, data: data)
                    HouseMediaUploadQueue.remove(roomKey: roomKey, fileName: mi.fileName)
                } catch {
                    HouseMediaUploadQueue.enqueue(roomKey: roomKey, fileName: mi.fileName, kind: mi.kind)
                    if !failedMediaRooms.contains(roomKey) { failedMediaRooms.append(roomKey) }
                }
                done += 1
                syncCenter.advance(id: importID, done: done)
            }
            do {
                try await HouseSyncEngine.shared.pushHouse(house)
                house.cloudStatus = .both
                SyncFailStore.clear(roomKey)
                summary.cloudLedger += 1
            } catch {
                HousePendingUploader.shared.markPending(roomKey)
                SyncFailStore.mark(roomKey)
                if !failedLedgerRooms.contains(roomKey) { failedLedgerRooms.append(roomKey) }
                summary.cloudFailed += 1
            }
            done += 1
            syncCenter.advance(id: importID, done: done)
        }
        try? houseModelContext?.save()
        let failedRooms = Array(Set(failedMediaRooms + failedLedgerRooms))
        if failedRooms.isEmpty {
            syncCenter.finish(id: importID, success: true, note: "导入完成 \(houses.count) 套")
        } else {
            let roomText = failedRooms.prefix(6).joined(separator: "、")
            let more = failedRooms.count > 6 ? " 等 \(failedRooms.count) 套" : ""
            syncCenter.finish(id: importID, success: false,
                              failure: "这几套没同步上：\(roomText)\(more)，点重试")
        }
        return failedRooms
    }

    /// 该房源要挂的媒体文件：媒体包模式从临时目录复制进正式目录；返回实际复制/可用的文件名
    private func mediaFilesToAttach(for item: BatchImportItem) -> [String] {
        guard let key = item.mediaDirKey else { return [] }
        let normalized = roomKeyString(item)
        if let zipRoot = zipTempRoot {
            let src = zipRoot.appendingPathComponent(key, isDirectory: true)
            return MediaStore.importMediaFiles(fromTempDir: src, toRoomKey: normalized)
        }
        let dir = MediaStore.houseDirectory(roomKey: normalized)
        return MediaStore.mediaFileNames(in: dir)
    }

    private func resultText(_ s: BatchImportSummary) -> String {
        var lines = ["新建房源 \(s.created) 间"]
        if s.mediaAttached > 0 { lines.append("补上媒体 \(s.mediaAttached) 间（\(s.mediaFiles) 个文件）") }
        if s.skippedDuplicate > 0 { lines.append("跳过重复 \(s.skippedDuplicate) 间") }
        if s.cloudLedger > 0 { lines.append("已同步云端账本 \(s.cloudLedger) 间") }
        if s.cloudFailed > 0 { lines.append("云端同步失败 \(s.cloudFailed) 间（已标记，可稍后重试）") }
        for e in s.errors { lines.append(e) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - v2.28 文档选择器（顶层直接 present）

/// 用法：DocumentPickerPresenter.present(types: [...]) { urls in ... }
enum DocumentPickerPresenter {
    private final class Host: NSObject, UIDocumentPickerDelegate {
        var onPick: (([URL]) -> Void)?
        var onCancel: (() -> Void)?
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let cb = onPick
            clear()
            cb?(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            let cb = onCancel
            clear()
            cb?()
        }
        private func clear() {
            DocumentPickerPresenter.host = nil
        }
    }

    private static var host: Host?

    static func present(types: [UTType], asCopy: Bool = true, onPick: @escaping ([URL]) -> Void, onCancel: (() -> Void)? = nil) {
        guard let vc = topViewController() else { return }
        let h = Host()
        h.onPick = onPick
        h.onCancel = onCancel
        host = h
        // asCopy = true：系统先把文件复制到 App 沙盒再回调，避免点文件不回调；
        // 但文件夹（UTType.folder）导入不支持 asCopy，系统会直接抛 NSInternalInconsistencyException，
        // 因此文件夹选择必须 asCopy = false（回调为安全作用域 URL，由解析侧自行 startAccessing）。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = false
        picker.delegate = h
        vc.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.flatMap { $0.windows }.first
        guard var vc = keyWindow?.rootViewController else { return nil }
        while true {
            if let presented = vc.presentedViewController, !presented.isBeingDismissed {
                vc = presented
            } else if let nav = vc as? UINavigationController, let top = nav.visibleViewController {
                vc = top
            } else if let tab = vc as? UITabBarController, let sel = tab.selectedViewController {
                vc = sel
            } else {
                return vc
            }
        }
    }
}

// MARK: - 批量导入工具函数

enum BatchImporter {
    /// 房号解析：剥离「2- / 1-」前缀（2- 前缀 → 2座），返回（房号本体, 座号）
    static func parseRoom(_ raw: String, explicitTower: Int) -> (String, Int) {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "2－", with: "2-")
        var tower = explicitTower
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)); if tower == 0 { tower = 2 } }
        else if t.hasPrefix("1-") { t = String(t.dropFirst(2)); if tower == 0 { tower = 1 } }
        if tower == 0 { tower = 1 }
        return (t, tower)
    }

    /// 查重：同座同房号（排除回收站）返回已存在房源
    static func findDuplicate(roomNo: String, tower: Int, in all: [House]) -> House? {
        all.first { other in
            if other.isDeleted == true { return false }
            return other.tower == tower && normalized(other.roomNo) == roomNo
        }
    }

    private static func normalized(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "2－", with: "2-")
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("1-") { t = String(t.dropFirst(2)) }
        return t
    }
}
