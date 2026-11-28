import SwiftUI
import UIKit
import AVKit

/// v2.71 分享面板轻流程：开场零网络，只给房号输入框；
/// 点「查重」单 GET 一个房号（ExtensionHouseClient.fetchOne，秒回，不再拉全量房号等十几秒）：
/// - 云端没有 → 展开与 App 内新增同要素的表单（座号/房号/租金/房东/户型/密码/备注/状态）→ 新增上传；
/// - 云端已有 → 提示有无媒体：无媒体直接补传；有媒体先「调取预览」再决定保留补传或清旧传新。
/// 表单带「从剪贴板识别导入」（复用 HouseClipboardParser 与确认卡，只填空白字段）。
/// v2.69：Action Extension（com.apple.ui-services）承载 → 共享菜单下方动作列表。
struct SharePanelView: View {
    let staged: [ShareUploadCoordinator.StagedItem]
    let onFinish: () -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator = ShareUploadCoordinator()

    private enum Phase { case input, checking, form, existing, preview, saving, result }
    @State private var phase: Phase = .input
    @State private var roomInput = ""
    @State private var checkError: String?
    @State private var existingRec: CloudHouseRecord?
    @State private var form = ShareUploadCoordinator.NewRoomForm()
    @State private var towerTouched = false
    @State private var outcome: ShareUploadCoordinator.Outcome?
    @State private var clipboardPayload: ClipboardPayload?
    @State private var pasteTip: String?
    @State private var pasteAvailable = false
    @State private var videoPayload: VideoPayload?
    @State private var replaceConfirm = false
    @State private var submitError: String?
    @State private var previewFiles: [String: URL] = [:]
    @State private var previewError: String?

    private struct ClipboardPayload: Identifiable {
        let id = UUID()
        let text: String
    }

    private struct VideoPayload: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var imageCount: Int { staged.filter { $0.kind == "image" }.count }
    private var videoCount: Int { staged.filter { $0.kind == "video" }.count }

    /// 输入框带 2- 前缀自动判 2 座（与 App 房号命名规则一致）
    private var autoTower: Int {
        let s = roomInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s.hasPrefix("2-") || s.hasPrefix("2－")) ? 2 : 1
    }

    private var inputForm: ShareUploadCoordinator.NewRoomForm {
        var f = ShareUploadCoordinator.NewRoomForm()
        f.roomNo = roomInput
        f.tower = autoTower
        return f
    }

    private var existingMediaSplit: (images: [String], videos: [String]) {
        let names = existingRec?.mediaNames ?? []
        return HouseLedgerFormat.split(names.map { (name: $0, kind: Self.kind(ofName: $0)) })
    }

    private static func kind(ofName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return (ext == "mp4" || ext == "mov") ? "video" : "image"
    }

    private func previewURL(_ name: String, video: Bool) -> URL? {
        previewFiles[name]
    }

    /// 进入预览前把服务器媒体二进制下载到扩展临时目录（服务器媒体需鉴权，不能直链）
    private func loadPreview() async {
        guard let rec = existingRec, !rec.mediaNames.isEmpty else { return }
        previewError = nil
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("share-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String: URL] = [:]
        var failed = 0
        for name in rec.mediaNames {
            do {
                let data = try await ExtensionHouseClient.downloadMedia(roomKey: rec.roomKey, fileName: name)
                let target = dir.appendingPathComponent(name)
                try data.write(to: target, options: .atomic)
                files[name] = target
            } catch {
                failed += 1
            }
        }
        previewFiles = files
        if failed > 0 && files.isEmpty {
            previewError = "预览加载失败：\(failed) 个媒体无法读取"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(Color(.systemBackground))
        .onAppear { pasteAvailable = UIPasteboard.general.hasStrings }
        .sheet(item: $clipboardPayload) { payload in
            HouseClipboardImportSheet(rawText: payload.text, fallbackTower: form.tower) { parsed in
                applyParsed(parsed)
                clipboardPayload = nil
            }
        }
        .sheet(item: $videoPayload) { payload in
            VideoPlaySheet(url: payload.url)
        }
        .alert("清掉旧媒体？", isPresented: $replaceConfirm) {
            Button("清旧传新", role: .destructive) { Task { await start(.replace) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该房云端与本机旧的 \(existingRec?.mediaNames.count ?? 0) 个媒体会被删除，再上传本次选择的 \(staged.count) 个媒体。")
        }
    }

    private var header: some View {
        HStack {
            Button(phase == .input || phase == .saving || phase == .result || phase == .checking ? "取消" : "返回") {
                if phase == .input || phase == .saving || phase == .result || phase == .checking {
                    onCancel()
                } else {
                    existingRec = nil
                    submitError = nil
                    phase = .input
                    pasteAvailable = UIPasteboard.general.hasStrings
                }
            }
            .disabled(phase == .saving)
            Spacer()
            Text("保存到公寓管家")
                .font(.headline)
            Spacer()
            Text("\(imageCount)图 \(videoCount)视频")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .input: inputContent
        case .checking:
            VStack(spacing: 12) {
                ProgressView("正在查重…")
                Text("只请求这一个房号，不拉全量房源").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        case .form: formContent
        case .existing: existingContent
        case .preview: previewContent
        case .saving: savingContent
        case .result: resultContent
        }
    }

    private var inputContent: some View {
        VStack(spacing: 14) {
            Text("输入房号，查重后决定新增或补传")
                .font(.subheadline.weight(.medium))
            TextField("房号（如 2334上 / 2-1418下）", text: $roomInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if pasteAvailable {
                Button {
                    openClipboard()
                } label: {
                    Label("从剪贴板识别导入", systemImage: "doc.on.clipboard")
                }
            }
            if let tip = pasteTip {
                Text(tip).font(.caption).foregroundStyle(.orange)
            }
            if let err = checkError {
                Text(err).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Text("带 2- 前缀自动判 2 座；开场不联网，点查重才请求云端。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var formContent: some View {
        Form {
            Section {
                Picker("座号", selection: $form.tower) {
                    Text("1座").tag(1)
                    Text("2座").tag(2)
                }
                .onChange(of: form.tower) { _, _ in towerTouched = true }
                TextField("房号（如 2334上）", text: $form.roomNo)
                    .autocorrectionDisabled()
                TextField("租金（数字）", text: $form.priceText)
                    .keyboardType(.numberPad)
                TextField("房东", text: $form.landlord)
                TextField("户型（如 单间 / 复式）", text: $form.layout)
                TextField("密码（可空）", text: $form.password)
                TextField("备注（可空）", text: $form.remark)
                Picker("状态", selection: $form.statusRaw) {
                    Text("待租").tag(HouseStatus.available.rawValue)
                    Text("已租").tag(HouseStatus.rented.rawValue)
                }
            } footer: {
                if let err = form.validationError {
                    Text(err).foregroundStyle(.orange)
                } else if let err = submitError {
                    Text(err).foregroundStyle(.orange)
                } else {
                    Text("与 App 内新增同要素；保存后媒体直传上云，同时写本机房源库。")
                }
            }
            Section {
                Button {
                    openClipboard()
                } label: {
                    Label("从剪贴板识别导入", systemImage: "doc.on.clipboard")
                }
            } footer: {
                Text("只填空白字段，不覆盖已输入内容；识别结果先经确认卡再填入。")
            }
        }
    }

    private var existingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let rec = existingRec {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(rec.roomKey).font(.title3.weight(.semibold))
                        Text("房东 \(rec.landlord.isEmpty ? "未填" : rec.landlord) · 户型 \(rec.layout.isEmpty ? "未填" : rec.layout) · 租金 ¥\(rec.price)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(rec.status == HouseStatus.rented.rawValue ? "已租" : "待租")
                            .font(.caption)
                            .foregroundStyle(rec.status == HouseStatus.rented.rawValue ? .orange : .green)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    let split = existingMediaSplit
                    if rec.mediaNames.isEmpty {
                        Text("该房还没有实拍媒体，可直接补传本次选择的 \(staged.count) 个媒体。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("云端已有 \(rec.mediaNames.count) 个媒体（图 \(split.images.count) · 视频 \(split.videos.count)）。可先调取预览，再决定保留补传或清旧传新。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let err = submitError {
                    Text(err).font(.footnote).foregroundStyle(.orange)
                }
            }
            .padding(16)
        }
    }

    private var previewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let split = existingMediaSplit
                if !split.images.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        ForEach(split.images, id: \.self) { name in
                            AsyncImage(url: previewURL(name, video: false)) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                ProgressView()
                            }
                            .frame(height: 92)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .cornerRadius(8)
                        }
                    }
                }
                ForEach(split.videos, id: \.self) { name in
                    HStack {
                        Image(systemName: "video.fill").foregroundStyle(.secondary)
                        Text(name).font(.caption).lineLimit(1)
                        Spacer()
                        Button("播放") { if let u = previewURL(name, video: true) { videoPayload = VideoPayload(url: u) } }
                            .disabled(previewURL(name, video: true) == nil)
                            .font(.caption)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                if let previewError {
                    Text(previewError).font(.caption2).foregroundStyle(.red)
                }
                Text("预览来自服务器；确认后再选保留补传或清旧传新。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .onAppear { Task { await loadPreview() } }
    }

    private var savingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(coordinator.phaseText)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            List(coordinator.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: row.kind == "video" ? "video" : "photo")
                            .foregroundStyle(.secondary)
                        Text(row.fileName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        switch row.state {
                        case "success":
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case "failed":
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        default:
                            Text(row.stage).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if row.state == "uploading" {
                        ProgressView(value: row.percent)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var resultContent: some View {
        VStack(spacing: 12) {
            if let o = outcome {
                Image(systemName: o.failed == 0 && o.ledgerOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(o.failed == 0 && o.ledgerOK ? .green : .orange)
                Text(o.title)
                    .font(.headline)
                Text(o.body)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if o.success > 0 || o.failed > 0 || o.skipped > 0 {
                    Text("成功 \(o.success) · 失败 \(o.failed)" + (o.skipped > 0 ? " · 跳过 \(o.skipped)" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if o.failed > 0 {
                    Text("失败的媒体已挂到主 App「同步任务中心」，打开 App 点重试即可，文件不会丢。")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Text("本次入库已写本机待写账，打开 App 自动进房源库，不用手动拉云端。")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            switch phase {
            case .result:
                Spacer()
                Button("完成") { onFinish() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            case .input:
                Spacer()
                Button("查重") { Task { await check() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(roomInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            case .form:
                Spacer()
                Button("新增并上传") { Task { await submitNew() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(form.validationError != nil)
                Spacer()
            case .existing:
                Spacer()
                if existingRec?.mediaNames.isEmpty == false {
                    Button("调取预览") { phase = .preview }
                }
                Button(existingRec?.mediaNames.isEmpty == false ? "保留补传" : "补传并上传") {
                    Task { await start(.append) }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            case .preview:
                Spacer()
                Button("保留补传") { Task { await start(.append) } }
                    .buttonStyle(.borderedProminent)
                Button("清旧传新", role: .destructive) { replaceConfirm = true }
                Spacer()
            default:
                Spacer()
                Text(phase == .saving ? "上传中，请勿关闭…" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 流程

    /// 查重：单 GET 一个房号（404→nil=新房），不拉全量
    private func check() async {
        checkError = nil
        phase = .checking
        do {
            let rec = try await ExtensionHouseClient.fetchOne(roomKey: inputForm.roomKey)
            HouseActionNotifier.shared.prepare()
            if let rec {
                existingRec = rec
                submitError = nil
                phase = .existing
            } else {
                var f = inputForm
                f.roomNo = Self.stripPrefixes(roomInput.trimmingCharacters(in: .whitespacesAndNewlines))
                form = f
                towerTouched = false
                submitError = nil
                phase = .form
            }
        } catch {
            checkError = error.localizedDescription
            phase = .input
        }
    }

    /// 新增提交前再单 GET 防重复建账（用户在表单里改过房号时兜底）
    private func submitNew() async {
        submitError = nil
        phase = .checking
        do {
            if let rec = try await ExtensionHouseClient.fetchOne(roomKey: form.roomKey) {
                existingRec = rec
                submitError = "「\(rec.roomKey)」已存在，改为补传媒体。"
                phase = .existing
                return
            }
        } catch {
            // 查重失败不挡新增：upsert 乐观锁在保存阶段兜底冲突
        }
        await start(.newHouse)
    }

    private func start(_ mode: ShareUploadCoordinator.RunMode) async {
        phase = .saving
        let o = await coordinator.run(staged: staged, existing: existingRec, form: form, mode: mode)
        outcome = o
        phase = .result
    }

    // MARK: - 剪贴板

    private func openClipboard() {
        pasteTip = nil
        guard let raw = UIPasteboard.general.string,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pasteTip = "剪贴板没有文字，先复制房源信息再点"
            return
        }
        clipboardPayload = ClipboardPayload(text: raw)
    }

    /// 与 HouseEditView.applyParsed 同口径：只填空白字段；状态以识别为准；座号仅未手动改过时写
    private func applyParsed(_ p: HouseClipboardParseResult) {
        if phase == .input {
            var f = inputForm
            f.roomNo = Self.stripPrefixes(roomInput.trimmingCharacters(in: .whitespacesAndNewlines))
            form = f
            towerTouched = false
            phase = .form
        }
        if form.roomNo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let no = p.roomNo {
            form.roomNo = Self.stripPrefixes(no)
        }
        if form.priceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let price = p.price {
            form.priceText = String(price)
        }
        if form.landlord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let l = p.landlord { form.landlord = l }
        if form.layout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let l = p.layout { form.layout = l }
        if form.password.isEmpty, let pw = p.password { form.password = pw }
        if form.remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let r = p.remark { form.remark = r }
        if let s = p.statusRaw { form.statusRaw = s }
        if !towerTouched, let t = p.tower { form.tower = t }
    }

    private static func stripPrefixes(_ s: String) -> String {
        var out = s
        let prefixes = ["2-", "1-", "2－", "1－"]
        var changed = true
        while changed {
            changed = false
            for p in prefixes where out.hasPrefix(p) {
                out = String(out.dropFirst(p.count))
                changed = true
            }
        }
        return out
    }
}

/// 预览视频播放页（本地临时目录文件）
private struct VideoPlaySheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: url))
                .navigationTitle("视频预览")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}