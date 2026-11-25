import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct HouseEditView: View {
    /// 房源板块专属 context（独立 HouseStore 容器，由 App 注入）
    @Environment(\.houseModelContext) private var houseModelContext
    @Environment(\.dismiss) private var dismiss

    /// 当前可用的房源数据上下文（App 内必然已注入；缺失属程序 bug，崩溃前留痕便于定位）
    private var modelContext: ModelContext {
        guard let ctx = houseModelContext else {
            CrashLogCollector.logFatal(title: "HouseEditView 缺少 houseModelContext 注入", body: "house 房号：\(house?.roomNo ?? "新增")")
            fatalError("houseModelContext 未注入")
        }
        return ctx
    }

    /// 传入房源 = 编辑；nil = 新增
    let house: House?
    /// v2.41：由快捷指令深链唤起时（gongyuguanjia://paste），进页面即自动解析剪贴板并弹确认卡
    var autoImportClipboard: Bool = false
    @State private var autoImportHandled = false

    @State private var roomNo = ""
    @State private var tower = 1
    @State private var landlord = ""
    @State private var layout = ""
    @State private var priceText = ""
    @State private var password = ""
    @State private var remark = ""
    @State private var status: HouseStatus = .available
    @State private var mediaItems: [MediaItem] = []

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedVideos: [PhotosPickerItem] = []
    @State private var loadingMedia = false
    @State private var showError = false
    @State private var errorMessage = ""
    // v1.40 第10点：无网络保存确认
    @State private var showOfflineAlert = false
    // v1.42：保存后云端上传失败 → 提示「已存本机，待网络恢复自动补传」（此前静默入队，用户无感知）
    @State private var pendingUploadTip: String?
    /// b118（P0③ CAS）：上传被写前校验拦截（云端已被他人更新）→ 独立提示，不覆盖云端数据
    @State private var conflictUploadTip: String?
    // v2.39：保存前强校验 / 落草稿 的提示
    @State private var draftTip: String?

    /// 用户是否手动改过座号（改过后不再被房号前缀自动覆盖）
    @State private var towerTouched = false
    /// 编辑前原房号目录 key（房号变更时迁移媒体目录）
    @State private var originalRoomKey = ""
    /// b118（P0① 先探后写）：新增保存前探测到云端已有同房号记录 → 三选一（同步到本地/仍然覆盖/取消）
    @State private var cloudConflictRec: CloudHouseRecord?
    @State private var showCloudConflictAlert = false
    /// v1.7：房号实时查重——输入时即提示（变红），与保存时校验同一口径
    @State private var duplicateHint: House?
    @State private var showDuplicateHint = false
    @State private var noPrefixHint = false   // v1.69：新增时房号未带座号前缀的红提示

    // v2.40：从剪贴板（微信复制的房源文字）一键导入
    @State private var showPasteBanner = false
    /// 确认卡顶部展示的原文本（可在卡内编辑，改完自动重识别）
    @State private var clipboardRawText = ""
    @State private var showClipboardSheet = false
    @State private var pasteAppliedTip: String?

    private var isEditing: Bool { house != nil }

    // v2.7（P2⑭）：从全量房源取已知房东/户型去重，做输入辅助下拉（不强制，可手动输入新值）
    private var knownLandlords: [String] {
        let all = (try? modelContext.fetch(FetchDescriptor<House>())) ?? []
        return Array(Set(all.compactMap { $0.landlord.isEmpty ? nil : $0.landlord })).sorted()
    }
    private var knownLayouts: [String] {
        let all = (try? modelContext.fetch(FetchDescriptor<House>())) ?? []
        return Array(Set(all.compactMap { $0.layout.isEmpty ? nil : $0.layout })).sorted()
    }

    var body: some View {
        NavigationStack {
            contentWithSheet
        }
    }

    /// v2.42：把原来一条超长 alert/sheet 链拆成 4 段、每段独立 `some View`。
    /// 之前 body 单表达式类型推断量过大，CI 直接报 type-check timeout（v2.41/v2.42 都栽在这里）。
    private var contentWithToolbar: some View {
        formContent
            .navigationTitle(isEditing ? "编辑房源" : "登记房源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onChange(of: selectedPhotos) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task { await loadPhotos(from: newValue) }
            }
            .onChange(of: selectedVideos) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task { await loadVideos(from: newValue) }
            }
    }

    private var contentWithSaveAlerts: some View {
        contentWithToolbar
            .alert("无法保存", isPresented: Binding(
                get: { showError },
                set: { showError = $0 }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            // v1.40 第10点：无网络时保存新增/编辑房源 → 先提示「仅存本机」，确认后才落盘（联网后可同步云端）
            .alert("当前无网络", isPresented: $showOfflineAlert) {
                Button("仅存本机", role: .destructive) { performSave() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("检测不到网络连接，本次保存只会存在本机，不会同步到云端。联网后可在房源列表刷新同步。")
            }
            // v1.42：保存后上传云端失败 → 提示已存本机、待网络恢复自动补传（媒体已入队，账本恢复后刷新同步）
            .alert("已保存到本机", isPresented: Binding(
                get: { pendingUploadTip != nil },
                set: { if !$0 { pendingUploadTip = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(pendingUploadTip ?? "")
            }
    }

    private var contentWithSyncAlerts: some View {
        contentWithSaveAlerts
            // b118（P0① 先探后写）：新增时探测到云端已有同房号记录 → 三选一，不再静默覆盖他人数据
            .alert("云端已存在该房号", isPresented: $showCloudConflictAlert) {
                Button("同步到本地", role: .none) {
                    applyCloudToForm(cloudConflictRec)
                    cloudConflictRec = nil
                }
                Button("仍然覆盖", role: .destructive) {
                    performSave()
                    cloudConflictRec = nil
                }
                Button("取消", role: .cancel) { cloudConflictRec = nil }
            } message: {
                if let rec = cloudConflictRec {
                    Text("云端已有「\(rec.roomKey)」（房东：\(rec.landlord.isEmpty ? "未填" : rec.landlord)、户型：\(rec.layout.isEmpty ? "未填" : rec.layout)、租金：\(rec.price)、更新于 \(rec.updatedAt.formatted(date: .abbreviated, time: .shortened))）。\n该记录可能由其他设备录入，为避免覆盖他人数据请选择操作。")
                } else {
                    Text("云端已有该房号记录。")
                }
            }
            // b118（P0③ CAS）：上传被写前校验拦截（读-写窗口内云端被他人更新）→ 独立提示
            .alert("云端数据已更新", isPresented: Binding(
                get: { conflictUploadTip != nil },
                set: { if !$0 { conflictUploadTip = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(conflictUploadTip ?? "")
            }
            .alert("改动未保存", isPresented: Binding(
                get: { draftTip != nil },
                set: { if !$0 { draftTip = nil } }
            )) {
                Button("好", role: .cancel) { dismiss() }
            } message: {
                Text(draftTip ?? "")
            }
    }

    private var contentWithSheet: some View {
        contentWithSyncAlerts
            // v2.40：剪贴板识别结果确认卡（只填空白字段，不覆盖已输入内容）
            .sheet(isPresented: $showClipboardSheet) {
                HouseClipboardImportSheet(rawText: clipboardRawText, fallbackTower: tower) { latest in
                    applyParsed(latest)
                }
            }
            .onAppear {
                loadFromHouse()
                refreshClipboardAvailability()
                // v2.41：深链进来 → 页面就绪后自动读取剪贴板并弹识别卡（只做一次，避免重复弹）
                if autoImportClipboard && !autoImportHandled {
                    autoImportHandled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        self.attemptClipboardImport()
                    }
                }
            }
    }

    /// v1.42：Form 主体拆分为独立计算属性——body 的导航栏/多个 alert 链叠加在超大 Form 类型上
    /// 触发编译器「unable to type-check this expression in reasonable time」（报错 49:25），
    /// 拆分后 body 与各链的类型推断负担大幅下降。
    private var formContent: some View {
        Form {
                // v2.40：新增房源时，剪贴板里有文字就直接给入口（只探测有无，不读取、不弹系统粘贴授权）
                if showPasteBanner && !isEditing {
                    Section {
                        Button {
                            attemptClipboardImport()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("从剪贴板导入房源")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.primary)
                                    Text("在微信里复制房号 / 租金 / 户型后点这里，自动识别填入")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } footer: {
                        Text("纯本地解析，文字不会上传，也不会覆盖你已填的内容。")
                    }
                }

                if let tip = pasteAppliedTip {
                    Section {
                        Label(tip, systemImage: tip.hasPrefix("已填入") ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundColor(tip.hasPrefix("已填入") ? .green : .orange)
                    }
                }

                Section("基本信息") {
                    HStack {
                        Text("房号")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        // v1.13 需求18：房号输入不允许含空格（避免不小心加空格导致信息重复/查重失效）
                        TextField("如 1-2334上 或 2-1418下", text: Binding(
                            get: { roomNo },
                            set: { roomNo = $0.replacingOccurrences(of: " ", with: "") }
                        ))
                            .keyboardType(.numbersAndPunctuation)
                            .foregroundColor(showDuplicateHint ? .red : .primary)
                            .onChange(of: roomNo) { _, newValue in
                                guard !towerTouched else { return }
                                if newValue.hasPrefix("2-") || newValue.hasPrefix("2－") {
                                    tower = 2
                                } else if !newValue.isEmpty {
                                    tower = 1
                                }
                            }
                            .onChange(of: roomNo) { _, newValue in
                                // v1.7：输入房号时实时查重（同座同房号视为重复，变红提示）
                                checkDuplicate(for: newValue)
                            }
                    }
                    // v1.7：重复房号实时提示（类似注册账号检测是否可用）
                    if showDuplicateHint, let dup = duplicateHint {
                        Text("该房号已收录：\(dup.tower == 2 ? "2-" : "")\(dup.roomNo)（\(dup.layout.isEmpty ? "户型未填" : dup.layout)，\(dup.status.label)）\n同一座同一房号不能重复添加")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.leading, 64)
                    }
                    // v1.69：新增时房号未带座号前缀 → 红提示
                    if noPrefixHint {
                        Text("房号必须以座号前缀开头：1- 或 2-（如 1-2334上、2-1418下）")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.leading, 64)
                    }

                    HStack {
                        Text("座号")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Picker("座号", selection: $tower) {
                            Text("1座").tag(1)
                            Text("2座").tag(2)
                        }
                        .labelsHidden()
                        .onChange(of: tower) {
                            towerTouched = true
                        }
                    }

                    HStack {
                        Text("房东")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("房东姓名", text: $landlord)
                        // v2.7（P2⑭）：房东历史下拉辅助选择（不强制，可手动输入新值）
                        if !knownLandlords.isEmpty {
                            Menu {
                                ForEach(knownLandlords, id: \.self) { name in
                                    Button(name) { landlord = name }
                                }
                            } label: {
                                Image(systemName: "chevron.down.circle")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    HStack {
                        Text("户型")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("如 单间 / 复式", text: $layout)
                        // v2.7（P2⑭）：户型历史下拉辅助选择（不强制，可手动输入新值）
                        if !knownLayouts.isEmpty {
                            Menu {
                                ForEach(knownLayouts, id: \.self) { name in
                                    Button(name) { layout = name }
                                }
                            } label: {
                                Image(systemName: "chevron.down.circle")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    HStack {
                        Text("价格")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("元/月", text: $priceText)
                            .keyboardType(.numberPad)
                        Spacer()
                        if !priceText.isEmpty {
                            Text("\(Int(priceText) ?? 0)元/月")
                                .font(.footnote)
                                .foregroundColor(AppTheme.accent)
                        }
                    }

                    HStack {
                        Text("密码")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("进门密码", text: $password)
                    }

                    // v1.23：备注行移入「基本信息」板块，放在密码下方（与上下输入框对齐）
                    HStack(alignment: .top) {
                        Text("备注")
                            .foregroundColor(.secondary)
                            .frame(width: 64, alignment: .leading)
                        TextField("如 采光好 / 带阳台 / 近电梯", text: $remark, axis: .vertical)
                            .lineLimit(1...4)
                    }
                }

                Section("状态") {
                    Picker("房源状态", selection: $status) {
                        Text("待租").tag(HouseStatus.available)
                        Text("已租").tag(HouseStatus.rented)
                    }
                    .pickerStyle(.segmented)
                    Text(status == .available ? "待租：可带看" : "已租：已租出，手动更新状态即可")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 9, matching: .images) {
                                Label("添加照片", systemImage: "photo.badge.plus")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)

                            PhotosPicker(selection: $selectedVideos, maxSelectionCount: 3, matching: .videos) {
                                Label("添加视频", systemImage: "video.badge.plus")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)

                            if loadingMedia {
                                ProgressView()
                                    .padding(.leading, 4)
                            }
                        }

                        if mediaItems.isEmpty {
                            Text("还没添加照片或视频，添加后可实时预览")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                                // 用唯一的 fileName 作标识（不用 MediaItem.id：SwiftData 新对象 id 不可靠）
                                ForEach(mediaItems, id: \.fileName) { media in
                                    ZStack(alignment: .topTrailing) {
                                        // 固定正方形格子，内容缩放裁切填满，横屏照片不重叠
                                        Color.clear
                                            .aspectRatio(1, contentMode: .fit)
                                            .overlay(
                                                MediaThumbView(media: media, roomKey: originalRoomKey.isEmpty ? currentRoomKey : originalRoomKey)
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .contentShape(RoundedRectangle(cornerRadius: 8))

                                        // 删除按钮：必须限定尺寸 + borderless 样式，防止点击区域扩大到整格
                                        // （此前 Button 直接放 ZStack 无约束，Form+LazyVGrid 下整格都会被判定为按钮，
                                        //   导致「点图片任意区域就触发删除」）
                                        Button {
                                            // 单条删除：只移除 fileName 完全匹配的这一条，其余不受影响
                                            removeMedia(fileName: media.fileName)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundColor(.white)
                                                .shadow(radius: 2)
                                        }
                                        .buttonStyle(.borderless)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Rectangle())
                                        .padding(3)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("照片 / 视频")
                } footer: {
                    Text("照片和视频保存在本机，分享时随房源信息一起发送。")
                }
            }
    }

    // MARK: - 载入 / 保存

    /// 当前房号对应的媒体目录 key（新增时用临时 key，保存后正式按房号）
    /// v1.71：与 House.mediaRoomKey 完全一致——1 座也强制「1-」前缀。
    /// 修复根因：此前 1 座返回无前缀（如「2059」），编辑页新图落盘 media/2059/，
    /// 上传却按带前缀 1-2059 找文件 → 找不到全失败 → 云端无新图、旧图已删 → 刷新缺媒体死循环。
    private var currentRoomKey: String {
        let trimmed = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
            .replacingOccurrences(of: "1－", with: "1-")
        let clean: String
        if trimmed.hasPrefix("2-") {
            clean = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("1-") {
            clean = String(trimmed.dropFirst(2))
        } else {
            clean = trimmed
        }
        let key = tower == 2 ? "2-\(clean)" : (clean.hasPrefix("1-") ? clean : "1-\(clean)")
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return key.components(separatedBy: illegal).joined(separator: "-")
    }

    private func loadFromHouse() {
        guard let house else { return }
        // v2.6：编辑时房号显示带座号前缀（如"1-1238上"），与新增输入框一致；保存时 cleanRoomNo 会自动去前缀
        let rawRoom = house.roomNo
        if house.tower == 2 {
            roomNo = rawRoom.hasPrefix("2-") ? rawRoom : "2-\(rawRoom)"
        } else {
            roomNo = rawRoom.hasPrefix("1-") ? rawRoom : "1-\(rawRoom)"
        }
        tower = house.tower
        landlord = house.landlord
        layout = house.layout
        priceText = house.price > 0 ? "\(house.price)" : ""
        password = house.password
        remark = house.remark
        status = house.status
        // 关键：拷贝构造新数组，与 house.mediaItems（SwiftData 关系数组，引用语义）彻底断开共享，
        // 避免编辑期间的任何增删直接改动数据库关系，导致删除行为异常
        mediaItems = Array(house.mediaItems)
        towerTouched = true
        originalRoomKey = house.mediaRoomKey
    }

    // MARK: - v1.7 房号查重（实时提示 + 保存校验同一口径）

    /// 房号归一化：剥离「2- / 2－ / 1-」座号前缀，只留房号本体（2座保留前缀语义由 tower 承载）
    private func normalizedRoom(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
        if t.hasPrefix("2-") { t = String(t.dropFirst(2)) }
        if t.hasPrefix("1-") { t = String(t.dropFirst(2)) }
        return t
    }

    /// 查重：同座同房号视为重复；排除自己与已进回收站的房源
    private func duplicateCheck(for rawRoomNo: String, tower: Int = 0) -> House? {
        let clean = normalizedRoom(rawRoomNo)
        guard !clean.isEmpty else { return nil }
        guard let ctx = houseModelContext else { return nil }
        let effectiveTower = tower > 0 ? tower : self.tower
        let all = (try? ctx.fetch(FetchDescriptor<House>())) ?? []
        return all.first { other in
            if other.isDeleted == true { return false }
            let isSelf = house.map { other.id == $0.id } ?? false
            guard !isSelf else { return false }
            return other.tower == effectiveTower && normalizedRoom(other.roomNo) == clean
        }
    }

    /// 输入时实时检测：命中重复 → 变红提示；清空或无重复 → 复位
    private func checkDuplicate(for rawRoomNo: String) {
        // v1.69：新增时房号必须带 1-/2- 座号前缀，否则实时红提示（不触发查重）
        let trimmedPrefix = rawRoomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
            .replacingOccurrences(of: "1－", with: "1-")
        if house == nil && !trimmedPrefix.isEmpty && !trimmedPrefix.hasPrefix("1-") && !trimmedPrefix.hasPrefix("2-") {
            noPrefixHint = true
            showDuplicateHint = false
            duplicateHint = nil
            return
        }
        noPrefixHint = false
        guard !normalizedRoom(rawRoomNo).isEmpty else {
            showDuplicateHint = false
            duplicateHint = nil
            return
        }
        if let dup = duplicateCheck(for: rawRoomNo) {
            showDuplicateHint = true
            duplicateHint = dup
        } else {
            showDuplicateHint = false
            duplicateHint = nil
        }
    }

    private func save() {
        // v2.39：编辑已收录房源 → 先做「保存前强校验」（不走缓存）。
        // 新增房源仍走原流程（它本身有先探后写的三选一）。
        if let house, isEditing {
            Task { await guardedSave(house: house) }
        } else {
            saveRaw()
        }
    }

    /// v2.39 保存前拦截：本地旧值 vs 云端现值逐字段比对
    /// - 字段被改过 → 拦下，不落任何正式数据，提示先返回详情页同步；
    /// - 校验不了（断网/弱网/权限）→ 本次改动整体存草稿箱，正式数据一个字不动。
    @MainActor
    private func guardedSave(house: House) async {
        let reachable = await NetworkMonitor.shared.awaitReachable(timeout: 2.5)
        guard reachable else {
            stashDraft(house: house, reason: "断网，改动未保存")
            return
        }
        guard let config = CosConfig.load(), config.isValid else {
            // 没配云存储：无从校验，也谈不上覆盖别人，按原流程存本机
            saveRaw()
            return
        }
        let state = await HouseSyncGuard.check(house: house, config: config, useCache: false)
        switch state {
        case .updated(_, let diffs):
            conflictUploadTip = "这套房在另一台设备被改过：\n" + diffs.joined(separator: "\n")
                + "\n\n本次改动没有保存，也没有上传。请返回房源详情页，点「更新」同步云端最新数据后，再重新编辑。"
        case .unknown(let msg):
            stashDraft(house: house, reason: "云端校验失败（\(msg)）")
        case .fresh, .mediaOnly, .missing:
            saveRaw()
        }
    }

    /// 把本次改动整体存进草稿箱（不写 SwiftData、不传云端、不删任何文件）
    private func stashDraft(house: House, reason: String) {
        let price = Int(priceText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? house.price
        let base = HouseDraftFields(roomNo: house.roomNo, tower: house.tower,
                                    landlord: house.landlord, layout: house.layout,
                                    price: house.price, password: house.password,
                                    remark: house.remark, statusRaw: house.statusRaw)
        let fields = HouseDraftFields(roomNo: cleanRoomNoText(), tower: tower,
                                      landlord: landlord, layout: layout,
                                      price: price, password: password,
                                      remark: remark, statusRaw: status.rawValue)
        // 新增媒体 = 本次新导入、还没挂到房源上的（house == nil），文件已在 currentRoomKey 目录里
        let added = mediaItems.filter { $0.house == nil }
            .map { HouseDraftMedia(fileName: $0.fileName, kind: $0.kind) }
        // 删除媒体 = 编辑前有、现在被移出编辑列表的
        let currentNames = Set(mediaItems.map { $0.fileName })
        let removed = house.mediaItems.map { $0.fileName }.filter { !currentNames.contains($0) }

        let draft = HouseDraft(
            id: UUID().uuidString,
            houseID: house.id.uuidString,
            roomKey: computeNewRoomKey(),
            sourceRoomKey: currentRoomKey,
            fields: fields,
            base: base,
            addedMedia: added,
            removedMedia: removed,
            baseRevision: CloudRevisionStore.seen(house.mediaRoomKey),
            reason: reason,
            createdAt: Date()
        )
        HouseDraftStore.shared.add(draft)
        draftTip = "因网络问题，本次改动失败，已存进「同步任务中心（\(draft.changeSummary)）」。\n"
            + "正式数据没有被改动。网络恢复后，在房源页顶部的任务条里点重试即可提交。"
        BackupLogStore.log(category: "房源", action: "存草稿", result: "成功",
                          detail: "\(draft.displayRoomNo)：\(reason)",
                          room: house.mediaRoomKey, cloud: false)
    }

    /// b118（P0① 先探后写 + P0⑤ 房号改名竞态加固）：
    private func saveRaw() {
        // v1.40 第10点：无稳定网络 → 先提示「仅存本机」，用户确认后再保存（避免静默只存本地造成误解）
        // v1.66：改为异步确认（最多等 1.2s），避免 NWPathMonitor 未就绪/路径切换瞬间误报离线——
        // 此前「有网络但保存提示没网络、取消再保存就好了」即瞬态误报
        // b118（P0① 先探后写 + P0⑤ 房号改名竞态加固）：
        //   新增 → 保存前先查云端同房号，云端已有他人记录 → 弹三选一（同步到本地/仍然覆盖/取消），不再静默覆盖；
        //   改名 → 保存前先把云端旧房号目录删干净（await），避免保存后立刻下拉刷新把旧房号拉回本地。
        Task {
            let ok = await NetworkMonitor.shared.awaitReachable()
            if ok {
                await MainActor.run {
                    // 服务器模式：查重口径以服务器库为准，不再读旧 COS 桶做先探后写，直接落库
                    guard !HouseServerMode.ready,
                          let config = CosConfig.load(), config.isValid else {
                        performSave()
                        return
                    }
                    // 先探后写：新增时云端已有同房号记录 → 三选一
                    if house == nil {
                        let clean = cleanRoomNoText()
                        guard !clean.isEmpty else {
                            errorMessage = "请填写房号"
                            showError = true
                            return
                        }
                        let key = tower == 2 ? "2-\(clean)" : "1-\(clean)"
                        Task {
                            if let rec = try? await CloudHouseSync.fetchOne(roomKey: key, config: config) {
                                await MainActor.run {
                                    cloudConflictRec = rec
                                    showCloudConflictAlert = true
                                }
                            } else {
                                await MainActor.run { performSave() }
                            }
                        }
                    } else {
                        // 房号改名（v2.37 #3 重排顺序）：
                        // 先校验新名云端是否已被别的房占用——占用就报错中止，旧目录原样保留；
                        // 确认无冲突才落盘，旧目录改到「新名建好、确认成功之后」再删（见 performSave 内的协调推送）。
                        let newKey = computeNewRoomKey()
                        if newKey != originalRoomKey && !originalRoomKey.isEmpty {
                            Task {
                                do {
                                    if let occupied = try await CloudHouseSync.fetchOne(roomKey: newKey, config: config) {
                                        await MainActor.run {
                                            errorMessage = "目标房号 \(occupied.roomKey) 云端已存在，不能改名过去；请换一个房号"
                                            showError = true
                                        }
                                        return
                                    }
                                    await MainActor.run { performSave() }
                                } catch {
                                    // 网络失败、无法确定新名是否冲突：保守起见不删旧、不强行改名，提示稍后重试
                                    await MainActor.run {
                                        errorMessage = "云端校验失败（\(error.localizedDescription)），本次未改动，请网络正常后重试"
                                        showError = true
                                    }
                                }
                            }
                        } else {
                            performSave()
                        }
                    }
                }
            } else {
                await MainActor.run { showOfflineAlert = true }
            }
        }
    }

    // MARK: - v2.40 剪贴板导入

    /// 只探测「剪贴板里有没有文本」，不读取内容——hasStrings 不会触发系统「允许粘贴」弹窗，
    /// 用户点了入口才真正读，授权弹窗也才有上下文，不会一进页面就骚扰。
    private func refreshClipboardAvailability() {
        guard !isEditing else {
            showPasteBanner = false
            return
        }
        showPasteBanner = UIPasteboard.general.hasStrings
    }

    private func attemptClipboardImport() {
        let text = UIPasteboard.general.string ?? ""
        let parsed = HouseClipboardParser.parse(text, fallbackTower: tower)
        guard parsed.isMeaningful else {
            withAnimation { pasteAppliedTip = "剪贴板里没识别到房源信息（要含房号或租金）" }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                withAnimation { pasteAppliedTip = nil }
            }
            return
        }
        clipboardRawText = text
        showClipboardSheet = true
    }

    /// 回填：只写空白字段，已填内容一律不动；识别到状态时以识别结果为准（确认卡里可见，可改）
    private func applyParsed(_ result: HouseClipboardParseResult) {
        func blank(_ s: String) -> Bool {
            s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let v = result.roomNo, blank(roomNo) { roomNo = v }
        if let t = result.tower, !towerTouched { tower = t; towerTouched = true }
        if let v = result.layout, blank(layout) { layout = v }
        if let p = result.price, blank(priceText) { priceText = "\(p)" }
        if let v = result.landlord, blank(landlord) { landlord = v }
        if let s = result.statusRaw { status = HouseStatus(rawValue: s) ?? status }
        if let v = result.password, blank(password) { password = v }
        if let v = result.remark, blank(remark) { remark = v }
        showPasteBanner = false
        withAnimation { pasteAppliedTip = "已填入 \(result.fieldCount) 项，请核对后保存" }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation { pasteAppliedTip = nil }
        }
    }

    /// 与 performSave 相同口径：清洗前缀后返回规范房号（去 2-/1- 前缀）
    private func cleanRoomNoText() -> String {
        roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
            .replacingOccurrences(of: "1－", with: "1-")
            .replacingOccurrences(of: "2-", with: "")
            .replacingOccurrences(of: "1-", with: "")
    }

    /// 与 performSave 相同口径：计算本次将写入的云端房号目录 key（与 House.mediaRoomKey 派生规则一致）
    private func computeNewRoomKey() -> String {
        let clean = cleanRoomNoText()
        // v2.36（#42）：必须用表单里当前选的 tower，不能用旧 house.tower——否则只改座号时
        // 算出的 key 还是旧座，媒体目录迁错、云端媒体永久读不到。
        let raw = tower == 2 ? "2-\(clean)" : "1-\(clean)"
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return raw.components(separatedBy: illegal).joined(separator: "-")
    }

    /// v2.37（#3）：改名时的旧目录清理——只在「新名媒体传完、新账本确认成功」之后调用，
    /// 中途任何一步失败都不会走到这里，旧目录原样保留。删账本失败不再用 try? 吞掉，
    /// 整个清理失败也不致命（新名已建好），留痕后下次同步再清。
    private func purgeOldCloudRoom(oldRoomKey: String, config: CosConfig) async {
        do {
            try await CloudHouseSync.delete(roomKey: oldRoomKey, config: config)
            let objs = try await CosUploader.listObjects(prefix: "h/\(oldRoomKey)/", config: config)
            await withTaskGroup(of: Void.self) { group in
                for obj in objs {
                    group.addTask { _ = try? await CloudBackupService.deleteRemoteObject(name: obj.name, config: config) }
                }
            }
            BackupLogStore.log(category: "房源", action: "房号迁移", result: "成功",
                               detail: "房号迁移（\(oldRoomKey) → \(computeNewRoomKey())）：云端旧目录已清理，含媒体 \(objs.count) 个", cloud: true)
        } catch {
            BackupLogStore.log(category: "房源", action: "房号迁移", result: "部分失败",
                               detail: "房号迁移（\(oldRoomKey) → \(computeNewRoomKey())）：新名已建好，旧目录清理失败：\(error.localizedDescription)（下次同步再清）", cloud: true)
        }
    }

    /// b118（P0① 先探后写）：用户选「同步到本地」——把云端记录填回编辑表单，可继续编辑后再保存
    private func applyCloudToForm(_ rec: CloudHouseRecord?) {
        guard let rec else { return }
        roomNo = rec.roomNo
        tower = rec.tower
        landlord = rec.landlord
        layout = rec.layout
        priceText = rec.price > 0 ? "\(rec.price)" : ""
        password = rec.password
        remark = rec.remark
        status = HouseStatus(rawValue: rec.status) ?? .available
        towerTouched = true
    }

    private func performSave() {
        let trimmedRoomNo = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "2－", with: "2-")
            .replacingOccurrences(of: "1－", with: "1-")

        // v1.69：新增房源房号必须以 1-/2- 座号前缀开头，否则无法添加（防止无前缀脏数据/座号归属歧义）
        if house == nil && !trimmedRoomNo.hasPrefix("1-") && !trimmedRoomNo.hasPrefix("2-") {
            errorMessage = "房号必须以座号前缀开头：1- 或 2-（如 1-2334上、2-1418下）"
            showError = true
            return
        }

        let cleanRoomNo: String
        if trimmedRoomNo.hasPrefix("2-") {
            cleanRoomNo = String(trimmedRoomNo.dropFirst(2))
        } else if trimmedRoomNo.hasPrefix("1-") {
            cleanRoomNo = String(trimmedRoomNo.dropFirst(2))
        } else {
            cleanRoomNo = trimmedRoomNo
        }

        guard !cleanRoomNo.isEmpty else {
            errorMessage = "请填写房号"
            showError = true
            return
        }

        // v1.30：登记查重——以房号为唯一标准（同一座、同一房号视为同一套，禁止重复收录）。
        // v1.7：实时提示与保存校验统一走 duplicateCheck（归一化房号 + 排除自身 + 排除回收站房源）。
        if let duplicate = duplicateCheck(for: roomNo, tower: tower) {
            errorMessage = "这套房源已收录过：\(duplicate.tower == 2 ? "2-" : "")\(duplicate.roomNo)（\(duplicate.layout.isEmpty ? "户型未填" : duplicate.layout)，\(duplicate.status.label)）\n同一座同一房号不能重复添加"
            showError = true
            return
        }

        let target: House
        if let house {
            target = house
        } else {
            target = House()
            modelContext.insert(target)
        }

        // 编辑时：真正删除「已被移除」的旧媒体（文件 + 记录 + 云端对象）
        // 只在保存时执行 → 点「取消」不会落盘，删除可完整回滚
        // v1.41：删除媒体同时删云端对象（图片原名 / 视频 .mp4 + 用户区首帧图），
        //        并清除该文件的上传队列——保证「我删了照片，别人也看不到」（此前只删本地是致命缺陷）
        // v1.72（#7）：编辑前字段快照——日志动作按实际改动字段命名（修改租金同步等）
        let before = house.map { h in
            (roomNo: h.roomNo, tower: h.tower, landlord: h.landlord, layout: h.layout,
             price: h.price, password: h.password, remark: h.remark, status: h.status)
        }
        // v1.71：编辑前的媒体文件名快照（用于「仅新增才上传」判定；在删除媒体逻辑之前取）
        let originalMediaNames = Set(house?.mediaItems.map { $0.fileName } ?? [])
        // v2.36（#8）：先只算出「被移除媒体」清单，不执行任何文件删除——文件操作一律推迟到
        // modelContext.save() 成功之后，避免「文件删了、数据库却没存上」的不可逆状态。
        let removedMediaItems: [MediaItem] = (house?.mediaItems ?? []).filter { old in
            !mediaItems.contains { $0.fileName == old.fileName }
        }
        // 模型改动（先做）：删除 MediaItem 记录 + 清上传队列；文件本身先不动
        for old in removedMediaItems {
            let rk = originalRoomKey.isEmpty ? (house?.mediaRoomKey ?? "") : originalRoomKey
            modelContext.delete(old)
            HouseMediaUploadQueue.remove(roomKey: rk, fileName: old.fileName)
        }

        // 编辑时房号/座号变更的新目录 key——v2.36（#42）：用表单 tower + 统一 1-/2- 前缀，
        // 不再用旧 house.tower，也不再让 1 座漏加前缀
        let newRoomKey: String = {
            let raw = tower == 2 ? "2-\(cleanRoomNo)" : "1-\(cleanRoomNo)"
            let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            return raw.components(separatedBy: illegal).joined(separator: "-")
        }()

        target.roomNo = cleanRoomNo
        target.tower = tower
        target.landlord = landlord.trimmingCharacters(in: .whitespacesAndNewlines)
        target.layout = layout.trimmingCharacters(in: .whitespacesAndNewlines)
        target.price = Int(priceText) ?? 0
        target.password = password
        target.remark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        target.status = status
        target.updatedAt = Date()
        // v1.19：最后更新时间（首次录入 / 编辑保存时刷新）
        target.lastUpdatedAt = Date()

        // v1.72（#7）：按编辑前后字段差异生成详细同步动作（修改租金同步 / 修改户型同步 …）
        // v2.6：日志细化到字段值对比——如「租金1100→1200」「房东业主→康」
        // v2.28：日志拆成「动作 + 变化」两段——动作只写改了哪几项（修改租金同步），
        //       变化单独写「修改租金 700 改 900」，日志里房号单独一行。
        var syncAction = "新增房源"
        var syncChange = ""
        // v2.45：账本字段级变化（与文本 diff 同源，供账本视图结构化展示）
        var ledgerChanges: [HouseLedgerFieldChange] = []
        if let before {
            var fields: [String] = []
            var changes: [String] = []
            let blank = "（空）"
            if before.roomNo != target.roomNo || before.tower != target.tower {
                fields.append("房号")
                changes.append("修改房号 \(before.tower)座\(before.roomNo) 改 \(target.tower)座\(target.roomNo)")
                ledgerChanges.append(HouseLedgerFieldChange(
                    field: "房号",
                    oldValue: "\(before.tower)座\(before.roomNo)",
                    newValue: "\(target.tower)座\(target.roomNo)"))
            }
            if before.landlord != target.landlord {
                fields.append("房东")
                changes.append("修改房东 \(before.landlord.isEmpty ? blank : before.landlord) 改 \(target.landlord.isEmpty ? blank : target.landlord)")
                ledgerChanges.append(HouseLedgerFieldChange(
                    field: "房东",
                    oldValue: before.landlord,
                    newValue: target.landlord))
            }
            if before.layout != target.layout {
                fields.append("户型")
                changes.append("修改户型 \(before.layout.isEmpty ? blank : before.layout) 改 \(target.layout.isEmpty ? blank : target.layout)")
                ledgerChanges.append(HouseLedgerFieldChange(
                    field: "户型",
                    oldValue: before.layout,
                    newValue: target.layout))
            }
            if before.price != target.price {
                fields.append("租金")
                changes.append("修改租金 \(before.price) 改 \(target.price)")
                ledgerChanges.append(HouseLedgerFieldChange(
                    field: "租金",
                    oldValue: String(before.price),
                    newValue: String(target.price)))
            }
            if before.password != target.password {
                fields.append("密码")
                changes.append("修改密码 \(before.password.isEmpty ? blank : before.password) 改 \(target.password.isEmpty ? blank : target.password)")
                ledgerChanges.append(HouseLedgerFieldChange(
                    field: "密码",
                    oldValue: before.password,
                    newValue: target.password))
            }
            if before.remark != target.remark {
                fields.append("备注")
                changes.append("修改备注 \(before.remark.isEmpty ? blank : before.remark) 改 \(target.remark.isEmpty ? blank : target.remark)")
                ledgerChanges.append(HouseLedgerFieldChange(
                    field: "备注",
                    oldValue: before.remark,
                    newValue: target.remark))
            }
            if before.status != target.status {
                fields.append("状态")
                changes.append("修改状态 \(before.status.label) 改 \(target.status.label)")
                ledgerChanges.append(HouseLedgerFieldChange(
                    field: "状态",
                    oldValue: before.status.label,
                    newValue: target.status.label))
            }
            // v2.46：去掉「同步」后缀；fields 为空（纯媒体改动）时这个动作在成功日志里会被跳过，避免空泛记录
            syncAction = fields.isEmpty ? "修改房源" : "修改" + fields.joined(separator: "、")
            syncChange = changes.joined(separator: "\n")
        }

        for item in mediaItems where item.house == nil {
            item.house = target
            modelContext.insert(item)
        }

        // v2.36（#8）：先把数据库存成功（do-catch），失败则提示并返回，绝不碰任何文件
        do {
            try modelContext.save()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            showError = true
            return
        }

        // 数据库已落盘，再做文件操作（此时即使文件操作出错，账本已正确，可下次对账修复）
        if let house {
            let rk = originalRoomKey.isEmpty ? house.mediaRoomKey : originalRoomKey
            for old in removedMediaItems {
                MediaStore.delete(fileName: old.fileName, roomKey: rk)
            }
            if let config = CosConfig.load(), config.isValid, !removedMediaItems.isEmpty {
                let removed = removedMediaItems.map { (name: $0.fileName, kind: $0.kind) }
                Task {
                    var succeeded: [(name: String, kind: String)] = []
                    var failed: [(name: String, kind: String, error: String)] = []
                    for item in removed {
                        do {
                            try await CosUploader.deleteRemoteMedia(fileName: item.name, kind: item.kind, roomKey: rk, config: config)
                            succeeded.append(item)
                        } catch {
                            failed.append((name: item.name, kind: item.kind, error: error.localizedDescription))
                        }
                    }
                    let successSplit = HouseLedgerFormat.split(succeeded)
                    let failSplit = HouseLedgerFormat.split(failed.map { (name: $0.name, kind: $0.kind) })
                    let summary = HouseLedgerFormat.mediaSummary(images: successSplit.images.count, videos: successSplit.videos.count)
                    let failSummary = HouseLedgerFormat.mediaSummary(images: failSplit.images.count, videos: failSplit.videos.count)
                    if failed.isEmpty {
                        BackupLogStore.log(category: "房源", action: "删除媒体（本地→云端）", result: "成功",
                                           detail: "已删除\(summary)", room: rk, cloud: true)
                    } else {
                        let failedFiles = failed.map { $0.name }
                        let failureDetail = summary.isEmpty
                            ? "\(failSummary) 删除失败，已挂任务中心"
                            : "已删除\(summary)；\(failSummary) 删除失败，已挂任务中心"
                        // 断网/超时：本地已删、云端对象还在别人能看到的旧内容——
                        // 挂任务中心待处理，联网后手动点重试补删；files 只供内部重试，日志不展示文件名。
                        SyncTaskCenter.shared.reportFailure(
                            kind: .mediaDelete,
                            title: "删云端媒体",
                            roomKeys: [rk],
                            failure: "\(rk) 有 \(failed.count) 个媒体没从云端删掉；点重试",
                            files: failedFiles)
                        BackupLogStore.log(category: "房源", action: "删除媒体（本地→云端）", result: "失败",
                                           detail: failureDetail, room: rk, cloud: true)
                    }
                }
            }
            // 房号/座号变更 → 数据库已存好，再整体迁移本地媒体目录（文件不丢）
            if isEditing && !originalRoomKey.isEmpty && originalRoomKey != newRoomKey {
                MediaStore.migrateHouseDirectory(from: originalRoomKey, to: newRoomKey)
            }
        }
        // v1.71：编辑保存只在「媒体有变化」时才触发上传——纯文字修改（价格/户型/房东/备注等）
        // 不再全量重传媒体（此前每次保存都触发、失败日志吓人）；新增媒体才上传，删除媒体已走
        // deleteRemoteMedia 同步删云端。新增房源（无原始快照）全部上传。
        // 联动：编辑改房号时本地媒体目录已迁移到新房号目录，云端新房号目录还没有任何媒体——
        // 此时不做文件名过滤（全传），否则新目录媒体要等下次同步对账才补。
        // v1.41 语义保持：上传失败自动入队，启动/回前台自动补传
        let roomChanged = isEditing && !originalRoomKey.isEmpty && originalRoomKey != target.mediaRoomKey
        // v2.24：房号改了之后，未读红框 / 未同步标记跟着新房号走，旧 key 顺手清掉（不再残留脏数据）
        if roomChanged {
            let oldKey = originalRoomKey
            let newKey = target.mediaRoomKey
            if UnreadCloudHouseStore.isUnread(oldKey) { UnreadCloudHouseStore.mark([newKey]) }
            UnreadCloudHouseStore.clear(oldKey)
            SyncFailStore.clear(oldKey)
        }
        // v2.37：云端推送统一收口——先在主线程把要传的东西抽成「值类型小抄」（#22 防后台读 SwiftData 崩溃），
        // 再由 launchCloudPush 按场景排序执行（#3 改名先建后删 / #23 新增先媒体后账本）。
        let isNewHouse = house == nil
        let mediaToUpload: [MediaItem] = (roomChanged || isNewHouse)
            ? target.mediaItems
            : target.mediaItems.filter { !originalMediaNames.contains($0.fileName) }
        let mediaSnapshots = mediaToUpload.map {
            MediaUploadSnapshot(fileName: $0.fileName, kind: $0.kind, roomKey: target.mediaRoomKey)
        }
        let cloudPushKind: CloudPushKind = isNewHouse ? .newHouse : (roomChanged ? .rename : .plainEdit)
        let oldRoomKeyForPurge = originalRoomKey
        // v1.54：保存后自动生成/更新该房源的脱敏版 H5（删旧生成新）——
        //        保证「新增了房源就自动有分享页」，选房链接里点卡片即可打开完整详情；
        //        编辑保存时旧 H5 立即失效、生成新 H5（内容与最新房源信息一致）
        if let config = CosConfig.load(), config.isValid {
            let files = target.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
            let profile = CosUploader.loadShareProfile()
            let info = ShareHouseInfo(
                displayRoomNo: target.displayRoomNo,
                towerLabel: target.towerLabel,
                layout: target.layout,
                statusLabel: target.status.label,
                priceText: target.priceText,
                landlord: target.landlord,
                password: target.password,
                remark: target.remark,
                name: profile.name,
                phone: profile.phone
            )
            let roomKey = target.mediaRoomKey
            Task {
                _ = try? await CosUploader.autoRegenerateMaskedShare(mediaFiles: files, roomKey: roomKey, info: info, config: config)
            }
        }
        // v1.72（#6）：本地账本镜像（media/<房号>/info.json，与云端同构）——保存即写，删除随目录一步到位
        LocalHouseLedger.save(target)
        // v1.19：新增 / 编辑保存后同步到云端账本（共享房源）
        // v1.72（#7）：日志动作按实际改动命名（修改租金同步等）；（#8）账本上传也驱动卡片进度条
        // v2.6：传 removedMedia（编辑前快照 − 当前媒体），让合并写正确排除本次显式删除的媒体
        let currentMediaNames = Set(target.mediaItems.map { $0.fileName })
        let removedMedia = originalMediaNames.subtracting(currentMediaNames)
        // v2.45：单套房账本事件（改名时本地 ledger.json 已随目录迁移，直接写新 key）
        // v2.46：媒体按 图片/视频 分型并带文件名；纯媒体改动动作名直接写「新增/删除图片/视频」
        let addedMedia = currentMediaNames.subtracting(originalMediaNames)
        let addedSplit = HouseLedgerFormat.split(
            target.mediaItems.filter { addedMedia.contains($0.fileName) }.map { (name: $0.fileName, kind: $0.kind) })
        // v2.58：新增房源的操作日志与单房账本同写法——动作下方只写「图片 x 个、视频 y 个」，
        // 不再单写一条「新增媒体」、也不再列文件名；没有媒体时保持为空，页面自然不显示第三行。
        if isNewHouse {
            syncChange = HouseLedgerFormat.mediaSummary(images: addedSplit.images.count, videos: addedSplit.videos.count)
        }
        let removedSplit = HouseLedgerFormat.split(
            removedMediaItems.map { (name: $0.fileName, kind: $0.kind) })
        // v2.62：单房账本明细也只记数量，不再拼接文件名（与操作日志同一口径）
        let addedParts = HouseLedgerFormat.mediaParts(images: addedSplit.images, videos: addedSplit.videos, includeNames: false)
        let removedParts = HouseLedgerFormat.mediaParts(images: removedSplit.images, videos: removedSplit.videos, includeNames: false)
        let ledgerDetailParts = addedParts.map { "新增\($0)" } + removedParts.map { "删除\($0)" }
        let hasFieldChanges = !ledgerChanges.isEmpty
        // v2.53：收集本次账本事件 id，供「彻底取消」全量撤回时按 id 移除
        var ledgerEventIds: [String] = []
        if isNewHouse {
            let initial = HouseLedgerFormat.mediaSummary(images: addedSplit.images.count, videos: addedSplit.videos.count)
            let ev = HouseLedgerStore.append(
                roomKey: target.mediaRoomKey,
                action: "新增房源",
                detail: "新建房源，" + (initial.isEmpty ? "无媒体" : initial))
            ledgerEventIds.append(ev.id)
        } else if hasFieldChanges {
            // 有字段变化（无论是否同时动媒体）：动作名「编辑保存」，媒体变化放明细
            let ev = HouseLedgerStore.append(
                roomKey: target.mediaRoomKey,
                action: "编辑保存",
                detail: ledgerDetailParts.joined(separator: "；"),
                fieldChanges: ledgerChanges)
            ledgerEventIds.append(ev.id)
        } else {
            // 纯媒体改动：按真实动作分别记录，动作名直接说清新增/删除、图片/视频，
            // 绝不写「媒体更新」这种看不懂的笼统动作；只加一个视频时就只有一条记录
            if !addedParts.isEmpty {
                let addAction = addedSplit.videos.isEmpty ? "新增图片"
                    : (addedSplit.images.isEmpty ? "新增视频" : "新增媒体")
                let ev = HouseLedgerStore.append(
                    roomKey: target.mediaRoomKey,
                    action: addAction,
                    detail: addedParts.map { "新增\($0)" }.joined(separator: "；"))
                ledgerEventIds.append(ev.id)
            }
            if !removedParts.isEmpty {
                let removeAction = removedSplit.videos.isEmpty ? "删除图片"
                    : (removedSplit.images.isEmpty ? "删除视频" : "删除媒体")
                let ev = HouseLedgerStore.append(
                    roomKey: target.mediaRoomKey,
                    action: removeAction,
                    detail: removedParts.map { "删除\($0)" }.joined(separator: "；"))
                ledgerEventIds.append(ev.id)
            }
        }
        // v2.53：构造全量撤回载荷（彻底取消时本地+云端、媒体+账本全部恢复原样）
        let rollbackScene: HouseUploadRollback.Scene = isNewHouse ? .newHouse
            : (roomChanged ? .rename : .plainEdit)
        let beforeSnapshot: HouseUploadBeforeSnapshot? = before.map {
            HouseUploadBeforeSnapshot(roomNo: $0.roomNo, tower: $0.tower, landlord: $0.landlord,
                                     layout: $0.layout, price: $0.price, password: $0.password,
                                     remark: $0.remark, statusRaw: $0.status.rawValue)
        }
        let addedRefs = target.mediaItems
            .filter { addedMedia.contains($0.fileName) }
            .map { HouseUploadMediaRef(fileName: $0.fileName, kind: $0.kind) }
        let removedRefs = removedMediaItems.map {
            HouseUploadMediaRef(fileName: $0.fileName, kind: $0.kind)
        }
        let rollback = HouseUploadRollback(
            scene: rollbackScene, roomKey: target.mediaRoomKey,
            oldRoomKey: oldRoomKeyForPurge, before: beforeSnapshot,
            added: addedRefs, removed: removedRefs, ledgerEventIds: ledgerEventIds)
        // 账本记录在主线程抽好（值类型），连同媒体小抄一起进后台协调推送
        let ledgerRecord = CloudHouseSync.record(from: target, username: CloudUser.username)
        if HouseServerMode.ready {
            launchServerPush(target: target, mediaSnapshots: mediaSnapshots,
                             kind: cloudPushKind, oldRoomKey: oldRoomKeyForPurge)
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
            dismiss()
            return
        }
        launchCloudPush(mediaSnapshots: mediaSnapshots,
                        record: ledgerRecord,
                        removedMedia: removedMedia,
                        kind: cloudPushKind,
                        oldRoomKey: oldRoomKeyForPurge,
                        action: syncAction,
                        changeText: syncChange,
                        rollback: rollback)
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        dismiss()
    }

    // MARK: - v2.37 云端推送（值类型小抄 + 顺序保证）

    /// 后台上传用的「值类型小抄」：进后台前在主线程抽好，后台只看它、不碰 SwiftData 对象（#22 防跨线程崩溃）。
    private struct MediaUploadSnapshot {
        let fileName: String
        let kind: String
        let roomKey: String
    }

    /// 本次保存属于哪种场景，决定后台推送的先后顺序
    private enum CloudPushKind {
        case newHouse   // 新增房源（#23：先媒体后账本）
        case rename     // 改名（#3：先建新名、确认成功后才删旧）
        case plainEdit  // 普通编辑（保持原行为）
    }

    /// performSave 落盘后唯一的云端推送入口：在主线程抽好小抄，再进一个后台 Task 按场景顺序执行。
    /// 后台全程只看值类型（小抄 + CloudHouseRecord），不读 SwiftData 模型对象。
    /// 服务器模式推送：媒体文件继续传 COS（P3 切临时凭证），文本与媒体引用走服务器权威接口。
    /// 本机沿用现有本地通知文案；服务器再向其他接入设备广播。
    private func launchServerPush(target: House, mediaSnapshots: [MediaUploadSnapshot],
                                  kind: CloudPushKind, oldRoomKey: String) {
        let taskID = UUID()
        if !mediaSnapshots.isEmpty {
            Task { @MainActor in
                SyncTaskCenter.shared.begin(
                    id: taskID, kind: .media, title: "上传媒体",
                    roomKeys: [target.mediaRoomKey], total: mediaSnapshots.count,
                    note: "准备上传", files: mediaSnapshots.map { $0.fileName },
                    isHouseUpload: true, rollback: nil)
            }
        }
        let work = Task {
            // 媒体实体仍在 COS：服务器模式下用服务器签发的临时凭证上传，App 不持永久密钥；
            // 媒体失败不阻塞文本权威同步，未传成功的文件由媒体补传队列后续重试。
            if !mediaSnapshots.isEmpty {
                await MediaActivityGate.shared.beginUpload()
                defer { Task { await MediaActivityGate.shared.endUpload() } }
                if let cred = try? await HouseCosCredentialStore.shared.credential() {
                    let stsConfig = CosConfig.sts(cred)
                    _ = try? await uploadMedia(snapshots: mediaSnapshots, config: stsConfig,
                                               writeSuccessLog: false, taskID: taskID)
                }
            }
            do {
                let remote = try await HouseSyncEngine.shared.pushHouse(target)
                await MainActor.run {
                    if !mediaSnapshots.isEmpty { SyncTaskCenter.shared.discard(id: taskID) }
                    let roomKey = remote.roomKey
                    switch kind {
                    case .newHouse:
                        HouseActionNotifier.shared.send(key: "new.\(roomKey)",
                            title: "房源已上传", body: "\(roomKey) 已保存并同步到服务器")
                    case .rename:
                        HouseActionNotifier.shared.send(key: "rename.\(roomKey)",
                            title: "房号已迁移", body: "\(oldRoomKey) → \(roomKey)，已同步到服务器")
                    case .plainEdit:
                        HouseActionNotifier.shared.send(key: "edit.\(roomKey)",
                            title: "修改已同步", body: "\(roomKey) 的改动已保存并同步")
                    }
                }
            } catch {
                await MainActor.run {
                    if !mediaSnapshots.isEmpty { SyncTaskCenter.shared.discard(id: taskID) }
                    // 标记待补传，联网后自动重试，不丢改动
                    HousePendingUploader.shared.markPending(target.mediaRoomKey)
                    HouseActionNotifier.shared.send(
                        key: "fail.\(target.mediaRoomKey)",
                        title: "已存本机",
                        body: "服务器同步失败：\(error.localizedDescription)，联网后自动补传")
                }
            }
        }
        Task { @MainActor in UploadTaskRegistry.shared.register(taskID, task: work) }
    }

    private func launchCloudPush(
        mediaSnapshots: [MediaUploadSnapshot],
        record: CloudHouseRecord,
        removedMedia: Set<String>,
        kind: CloudPushKind,
        oldRoomKey: String,
        action: String,
        changeText: String,
        rollback: HouseUploadRollback
    ) {
        let uploadTaskID = UUID()
        let hasMedia = !mediaSnapshots.isEmpty
        if hasMedia {
            // v2.52：媒体上传先在任务中心建一条可见任务（带取消按钮）；v2.53 带撤回载荷
            Task { @MainActor in
                SyncTaskCenter.shared.begin(
                    id: uploadTaskID, kind: .media, title: "上传媒体",
                    roomKeys: [record.roomKey], total: mediaSnapshots.count,
                    note: "准备上传", files: mediaSnapshots.map { $0.fileName },
                    isHouseUpload: true, rollback: rollback)
            }
        }
        let work = Task {
            guard let config = CosConfig.load(), config.isValid else {
                if hasMedia {
                    await MainActor.run { SyncTaskCenter.shared.discard(id: uploadTaskID) }
                }
                return
            }
            await MediaActivityGate.shared.beginUpload()
            defer { Task { await MediaActivityGate.shared.endUpload() } }

            do {
                switch kind {
                case .newHouse:
                    // #23：先把媒体全部传完（成功或已入队），最后才传账本，别的设备不会在媒体没齐时拉到半成品。
                    // 仅适用于「新增房源且一并带了媒体」；没带媒体的新增 mediaSnapshots 为空，直接传账本。
                    // v2.58：新增房源的媒体成功日志并入「新增房源」一条，不再单独写「新增媒体」。
                    let mediaResult = try await uploadMedia(snapshots: mediaSnapshots, config: config, writeSuccessLog: false, taskID: uploadTaskID, isNewHouse: true)
                    do {
                        // v2.57（P0-1）：没传上去的文件名不写入云端账本——否则另一台设备同步时会把
                        // 这些「账本有、桶里没有」的引用当成失效剔除，补传成功后反而成桶孤儿；
                        // 等补传成功（retryHouseUpload/retryMedia）再按本地记录重写账本补上。
                        var recordToPush = record
                        if !mediaResult.failedFiles.isEmpty {
                            let failedSet = Set(mediaResult.failedFiles)
                            recordToPush.mediaNames = record.mediaNames.filter { !failedSet.contains($0) }
                        }
                        _ = try await uploadLedger(record: recordToPush, removedMedia: removedMedia, config: config, action: action, changeText: changeText, isNewHouse: true, writeSuccessLog: mediaResult.failed == 0)
                        notifySaved(roomKey: record.roomKey, oldRoomKey: "", kind: .newHouse, mediaResult: mediaResult, snapshots: mediaSnapshots)
                    } catch {
                        // 失败通知由 uploadLedger 统一发出
                    }

                case .rename:
                    // #3：先建新名（媒体 → 账本），账本确认成功且媒体无失败，最后才删旧目录；任一步失败旧目录保留。
                    let mediaResult = try await uploadMedia(snapshots: mediaSnapshots, config: config, taskID: uploadTaskID)
                    do {
                        // v2.57（P0-1）：改名场景同样不把没传上的文件名写进新房账本，补传成功后再补写
                        var recordToPush = record
                        if !mediaResult.failedFiles.isEmpty {
                            let failedSet = Set(mediaResult.failedFiles)
                            recordToPush.mediaNames = record.mediaNames.filter { !failedSet.contains($0) }
                        }
                        _ = try await uploadLedger(record: recordToPush, removedMedia: removedMedia, config: config, action: action, changeText: changeText, isNewHouse: false, writeSuccessLog: mediaResult.failed == 0)
                        if mediaResult.failed == 0 {
                            // v2.45：删旧目录前先把旧远端账本并进新 key 并同步，账本不丢历史
                            do {
                                try await HouseLedgerStore.adoptRemoteLedger(from: oldRoomKey, to: record.roomKey, config: config)
                                try await HouseLedgerStore.sync(roomKey: record.roomKey, config: config)
                            } catch {
                                HouseLedgerStore.markDirty(record.roomKey)
                            }
                            await purgeOldCloudRoom(oldRoomKey: oldRoomKey, config: config)
                        } else {
                            // 有媒体没传成功：旧目录先留着兜底，等补传成功、下次同步再清，绝不丢数据
                            BackupLogStore.log(category: "房源", action: "房号迁移", result: "部分失败",
                                              detail: "房号迁移（\(oldRoomKey) → \(record.roomKey)）：新名已建好，\(mediaResult.failed) 个媒体未传成功，旧目录暂留，补传后再清", cloud: true)
                        }
                        notifySaved(roomKey: record.roomKey, oldRoomKey: oldRoomKey, kind: .rename, mediaResult: mediaResult, snapshots: mediaSnapshots)
                    } catch {
                        // 账本失败：新名未完全建立，旧目录原样保留
                    }

                case .plainEdit:
                    // 普通编辑：媒体（仅新增）与账本照旧推送
                    let mediaResult = try await uploadMedia(snapshots: mediaSnapshots, config: config, taskID: uploadTaskID)
                    do {
                        // v2.57（P0-1）：没传上的文件名不写入云端账本，防止他端同步剔除造成跨设备丢媒体
                        var recordToPush = record
                        if !mediaResult.failedFiles.isEmpty {
                            let failedSet = Set(mediaResult.failedFiles)
                            recordToPush.mediaNames = record.mediaNames.filter { !failedSet.contains($0) }
                        }
                        _ = try await uploadLedger(record: recordToPush, removedMedia: removedMedia, config: config, action: action, changeText: changeText, isNewHouse: false, writeSuccessLog: mediaResult.failed == 0)
                        notifySaved(roomKey: record.roomKey, oldRoomKey: "", kind: .plainEdit, mediaResult: mediaResult, snapshots: mediaSnapshots)
                    } catch {
                        // 失败通知由 uploadLedger 统一发出
                    }
                }
                if hasMedia {
                    await MainActor.run {
                        let center = SyncTaskCenter.shared
                        guard center.running.contains(where: { $0.id == uploadTaskID }) else { return }
                        let pending = HouseMediaUploadQueue.pendingItems().filter { $0.roomKey == record.roomKey }
                        if pending.isEmpty {
                            center.finish(id: uploadTaskID, success: true, note: "媒体已全部上传")
                        } else {
                            center.finish(id: uploadTaskID, success: false,
                                         failure: "\(pending.count) 个媒体没传上，点重试")
                        }
                        UploadTaskRegistry.shared.unregister(uploadTaskID)
                    }
                }
            } catch {
                // 手动取消：任务转「已取消」，可重试或彻底删除
                if HouseEditView.isCancellation(error) {
                    await MainActor.run {
                        SyncTaskCenter.shared.finishCancelled(id: uploadTaskID)
                        UploadTaskRegistry.shared.unregister(uploadTaskID)
                    }
                } else if hasMedia {
                    await MainActor.run {
                        let center = SyncTaskCenter.shared
                        let pending = HouseMediaUploadQueue.pendingItems().filter { $0.roomKey == record.roomKey }
                        center.finish(id: uploadTaskID, success: false,
                                     failure: pending.isEmpty ? error.localizedDescription
                                                            : "\(pending.count) 个媒体没传上，点重试")
                        UploadTaskRegistry.shared.unregister(uploadTaskID)
                    }
                }
            }
        }
        if hasMedia {
            // 注册工作 Task 句柄，取消按钮靠它真正中断上传/转码
            Task { @MainActor in UploadTaskRegistry.shared.register(uploadTaskID, task: work) }
        }
    }

    /// v2.44：保存类动作的系统通知（新增/编辑/改名共用；失败在 uploadLedger 的 catch 里发）
    private func notifySaved(
        roomKey: String,
        oldRoomKey: String,
        kind: CloudPushKind,
        mediaResult: (success: Int, failed: Int, failedFiles: [String], lastError: String),
        snapshots: [MediaUploadSnapshot]
    ) {
        var mediaSuffix = ""
        let images = snapshots.filter { $0.kind == "image" }.count
        let videos = snapshots.filter { $0.kind == "video" }.count
        if images > 0 || videos > 0 {
            mediaSuffix = "（照片\(images)、视频\(videos)）"
        }
        switch kind {
        case .newHouse:
            if mediaResult.failed > 0 {
                HouseActionNotifier.shared.send(
                    key: "save.\(roomKey)",
                    title: "房源已保存，媒体待补传",
                    body: "\(roomKey) 已存本机，\(mediaResult.failed) 个媒体没传上，联网后在同步任务中心点重试",
                    silent: true
                )
            } else {
                HouseActionNotifier.shared.send(
                    key: "save.\(roomKey)",
                    title: "房源已上传",
                    body: "\(roomKey) 已同步到云端\(mediaSuffix)"
                )
            }
        case .rename:
            if mediaResult.failed > 0 {
                HouseActionNotifier.shared.send(
                    key: "rename.\(roomKey)",
                    title: "房号已迁移，媒体待补传",
                    body: "\(oldRoomKey) → \(roomKey)，\(mediaResult.failed) 个媒体没传上，已挂同步任务中心，可点重试",
                    silent: true
                )
            } else {
                HouseActionNotifier.shared.send(
                    key: "rename.\(roomKey)",
                    title: "房号已迁移",
                    body: "\(oldRoomKey) → \(roomKey)，云端已同步"
                )
            }
        case .plainEdit:
            if mediaResult.failed > 0 {
                HouseActionNotifier.shared.send(
                    key: "save.\(roomKey)",
                    title: "修改已保存，媒体待补传",
                    body: "\(roomKey) 的改动已存本机，\(mediaResult.failed) 个媒体没传上，联网后在同步任务中心点重试",
                    silent: true
                )
            } else {
                HouseActionNotifier.shared.send(
                    key: "save.\(roomKey)",
                    title: "修改已同步",
                    body: "\(roomKey) 的改动已同步到云端\(mediaSuffix)"
                )
            }
        }
    }

    /// 媒体上传（值类型小抄版）：保留原有的幂等、失败重试 1 次、再失败入队、卡片进度与日志逻辑。
    /// 返回 (成功数, 失败数, 最后错误)。调用方负责 MediaActivityGate。
    /// 判断错误是否为手动取消（Task 取消 / URLSession 任务取消）
    fileprivate static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func uploadMedia(snapshots: [MediaUploadSnapshot], config: CosConfig, writeSuccessLog: Bool = true, taskID: UUID? = nil, isNewHouse: Bool = false) async throws -> (success: Int, failed: Int, failedFiles: [String], lastError: String) {
        guard !snapshots.isEmpty else { return (0, 0, [], "") }
        let compress = shareCompressionEnabled
        var success = 0, failed = 0, lastError = ""
        var failedFiles: [String] = []
        let total = snapshots.count
        let roomKey = snapshots[0].roomKey
        HouseSyncProgress.shared.begin(roomKey: roomKey, direction: .upload, progress: 0)
        for (idx, snap) in snapshots.enumerated() {
            let url = MediaStore.url(for: snap.fileName, roomKey: snap.roomKey)
            guard FileManager.default.fileExists(atPath: url.path) else {
                HouseMediaUploadQueue.enqueue(roomKey: snap.roomKey, fileName: snap.fileName, kind: snap.kind)
                failed += 1
                failedFiles.append(snap.fileName)
                HouseSyncProgress.shared.update(roomKey: snap.roomKey, direction: .upload, progress: Double(idx + 1) / Double(total))
                HouseSyncProgress.shared.updateSpeed(bytesPerSecond: 0)
                if let taskID {
                    await MainActor.run {
                        SyncTaskCenter.shared.advance(id: taskID, done: idx + 1,
                                                      note: "已处理 \(idx + 1)/\(total)")
                    }
                }
                continue
            }
            let base = Double(idx) / Double(total)
            let span = 1.0 / Double(total)
            do {
                try await CosUploader.uploadHouseMedia(
                    fileName: snap.fileName, kind: snap.kind, roomKey: snap.roomKey,
                    config: config, compress: compress,
                    onStage: { stage in
                        HouseSyncProgress.shared.updateStage(roomKey: snap.roomKey, direction: .upload, label: stage)
                    },
                    onTranscodeProgress: { p in
                        let fraction = max(0, min(1, p.isFinite ? p : 0))
                        HouseSyncProgress.shared.updateTranscodeProgress(
                            roomKey: snap.roomKey,
                            direction: .upload,
                            progress: base + span * fraction,
                            fraction: fraction
                        )
                        if let taskID {
                            Task { @MainActor in
                                SyncTaskCenter.shared.advanceWithinFile(id: taskID, fileIndex: idx,
                                                                        fraction: fraction,
                                                                        note: "正在转码 \(snap.fileName)")
                            }
                        }
                    },
                    onBytes: { p in
                        HouseSyncProgress.shared.update(roomKey: snap.roomKey, direction: .upload,
                                                       progress: base + span * p)
                        if let taskID {
                            Task { @MainActor in
                                SyncTaskCenter.shared.advanceWithinFile(id: taskID, fileIndex: idx,
                                                                        fraction: p,
                                                                        note: "正在上传 \(snap.fileName)")
                            }
                        }
                    },
                    onSpeed: { bytesPerSecond in
                        HouseSyncProgress.shared.updateSpeed(bytesPerSecond: bytesPerSecond)
                        if let taskID {
                            Task { @MainActor in
                                SyncTaskCenter.shared.updateSpeed(id: taskID, bytesPerSecond: bytesPerSecond)
                            }
                        }
                    })
                HouseMediaUploadQueue.remove(roomKey: snap.roomKey, fileName: snap.fileName)
                success += 1
            } catch {
                // 手动取消：立即向上抛，不进失败计数、不入补传队列
                if HouseEditView.isCancellation(error) {
                    HouseSyncProgress.shared.end()
                    throw error
                }
                // v2.52：按用户口径取消自动重试，失败直接挂任务中心，只能手动重试
                HouseMediaUploadQueue.enqueue(roomKey: snap.roomKey, fileName: snap.fileName, kind: snap.kind)
                failed += 1
                failedFiles.append(snap.fileName)
                lastError = error.localizedDescription
            }
            HouseSyncProgress.shared.update(roomKey: snap.roomKey, direction: .upload, progress: Double(idx + 1) / Double(total))
            HouseSyncProgress.shared.updateSpeed(bytesPerSecond: 0)
            if let taskID {
                await MainActor.run {
                    SyncTaskCenter.shared.advance(id: taskID, done: idx + 1,
                                                  note: "已上传 \(idx + 1)/\(total)")
                    SyncTaskCenter.shared.updateSpeed(id: taskID, bytesPerSecond: nil)
                }
            }
        }
        HouseSyncProgress.shared.end()
        let upSplit = HouseLedgerFormat.split(snapshots.map { (name: $0.fileName, kind: $0.kind) })
        // v2.60：新增房源保存只留一条日志——媒体有失败时，这里写「新增房源 + 失败原因」，
        // 账本成功日志由 uploadLedger 的 writeSuccessLog 抑制；重试成功再由任务中心写最终成功日志。
        // v2.62：日志只记数量，不再拼文件名（用户口径：文件只分别记数量）
        let upParts = HouseLedgerFormat.mediaParts(images: upSplit.images, videos: upSplit.videos, includeNames: false)
        if failed > 0 {
            let upAction = isNewHouse ? "新增房源" : "新增媒体（本地→云端）"
            let upResult = isNewHouse && failed >= total ? "失败" : "部分失败"
            let upDetail = isNewHouse
                ? HouseMediaLogFormat.failureDetail(images: upSplit.images.count, videos: upSplit.videos.count, error: lastError)
                : upParts.joined(separator: "；") + "；成功 \(success) 失败 \(failed)（已入队自动补传）" + (lastError.isEmpty ? "" : "；错误：\(lastError)")
            BackupLogStore.log(category: "房源", action: upAction, result: upResult,
                              detail: upDetail, room: roomKey, cloud: true)
            await MainActor.run {
                if pendingUploadTip == nil {
                    pendingUploadTip = "房源已保存到本机；媒体上传云端失败（共 \(failed) 个），已挂到「同步任务中心」，联网后在任务条里点重试。"
                }
            }
        } else if success > 0 && writeSuccessLog {
            // 单一类型时动作名直接写「新增图片/新增视频」，混合时写「新增媒体」
            let upAction: String
            if upSplit.videos.isEmpty { upAction = "新增图片（本地→云端）" }
            else if upSplit.images.isEmpty { upAction = "新增视频（本地→云端）" }
            else { upAction = "新增媒体（本地→云端）" }
            BackupLogStore.log(category: "房源", action: upAction, result: "成功",
                              detail: upParts.joined(separator: "；"), room: roomKey, cloud: true)
        }
        return (success, failed, failedFiles, lastError)
    }

    /// 账本上传（值类型版）：走 uploadGuarded 合并写 + CAS 冲突处理，保留 SyncFail 标记与全部日志。
    /// 成功返回合并后的记录；失败抛错（由调用方决定是否继续后续步骤，如改名时是否删旧）。
    @discardableResult
    private func uploadLedger(record: CloudHouseRecord, removedMedia: Set<String>, config: CosConfig, action: String, changeText: String, isNewHouse: Bool, writeSuccessLog: Bool = true) async throws -> CloudHouseRecord {
        HouseSyncProgress.shared.begin(roomKey: record.roomKey, direction: .upload, progress: 0.2, label: "同步账本")
        do {
            let (merged, hadExisting) = try await CloudHouseSync.uploadGuarded(record: record, removedMedia: removedMedia, config: config)
            HouseSyncProgress.shared.end()
            // 回主线程按房号找模型更新状态（不依赖后台捕获的 SwiftData 对象）
            await MainActor.run {
                let all = (try? modelContext.fetch(FetchDescriptor<House>())) ?? []
                if let h = all.first(where: { $0.mediaRoomKey == record.roomKey }) {
                    h.cloudStatus = .both
                    SyncFailStore.clear(record.roomKey)
                    try? modelContext.save()
                }
            }
            // v2.62：只有云端真正多出「本次没提交的媒体」才算合并了别人的更新。
            // 旧判定用数组 != 比较，并集后顺序变化（媒体 4 个→4 个、8 个→8 个）也会误写一条
            // 「合并云端更新」，导致一次补媒体留下两条日志。这里改为集合差，
            // 且合并提示优先并入主日志，保证「一个动作一条」。
            let cloudOnly = Set(merged.mediaNames).subtracting(Set(record.mediaNames))
            let mergeNote = (hadExisting && !cloudOnly.isEmpty)
                ? "；已合并云端原有 \(cloudOnly.count) 个媒体"
                : ""
            // v2.46：纯媒体改动（无字段变化、明细为空）时不再写空泛的「修改房源」，媒体条目本身已说明操作
            let mainLogged = writeSuccessLog && (isNewHouse || !changeText.isEmpty)
            if mainLogged {
                BackupLogStore.log(category: "房源", action: action, result: "成功",
                                  detail: changeText + mergeNote, room: record.roomKey, cloud: true)
            } else if !mergeNote.isEmpty {
                BackupLogStore.log(category: "同步", action: "合并云端更新", result: "成功",
                                  detail: "云端有别人的更新，已合并：媒体 \(record.mediaNames.count) 个 → \(merged.mediaNames.count) 个", room: record.roomKey, cloud: true)
            }
            return merged
        } catch {
            HouseSyncProgress.shared.end()
            await MainActor.run { SyncFailStore.mark(record.roomKey) }
            BackupLogStore.log(category: "房源", action: action, result: "失败", detail: "云端更新失败：\(error.localizedDescription)", room: record.roomKey, cloud: true)
            if error is CloudSyncConflict {
                await MainActor.run {
                    if conflictUploadTip == nil {
                        conflictUploadTip = "「\(record.roomKey)」刚被其他设备更新（\(error.localizedDescription)）。本次修改仅保存在本机，未覆盖云端数据；请刷新同步后再编辑。"
                    }
                    HouseActionNotifier.shared.send(
                        key: "conflict.\(record.roomKey)",
                        title: "修改没传上去",
                        body: "\(record.roomKey) 刚被其他设备更新，本次改动只存本机；请刷新同步后再编辑",
                        silent: true
                    )
                }
            } else {
                await MainActor.run {
                    if pendingUploadTip == nil {
                        pendingUploadTip = "房源已保存到本机；同步云端失败（网络不通），已挂到「同步任务中心」，联网后在任务条里点重试。"
                    }
                    HouseActionNotifier.shared.send(
                        key: "syncfail.\(record.roomKey)",
                        title: "同步失败",
                        body: "\(record.roomKey) 云端同步失败：已挂同步任务中心，联网后点重试",
                        silent: true
                    )
                }
            }
            throw error
        }
    }

    // MARK: - 媒体处理

    /// 删除单条媒体：用「重建数组」方式移除，绝不修改任何共享数组引用，也不依赖模型对象引用
    /// - 已有记录（在 house.mediaItems 里）：只从暂存数组移除，点「保存」才真正删除，点「取消」完整回滚
    /// - 新增媒体（不在 house.mediaItems 里）：立即清理已写盘的文件
    private func removeMedia(fileName target: String) {
        // 判断是否为「已有记录」
        let isExisting = house?.mediaItems.contains(where: { $0.fileName == target }) ?? false
        // 记录被移除条目的文件名（若存在）
        let removedFile = mediaItems.first(where: { $0.fileName == target })?.fileName

        // 重建数组：只排除 fileName 完全匹配的这一条，其余原样保留
        mediaItems = mediaItems.filter { $0.fileName != target }

        // 新增媒体：文件已写盘但尚未关联房源 → 立即清理该文件，避免残留孤儿文件
        if let removedFile, !isExisting {
            MediaStore.delete(fileName: removedFile, roomKey: originalRoomKey.isEmpty ? currentRoomKey : originalRoomKey)
        }
    }

    private func loadPhotos(from items: [PhotosPickerItem]) async {
        loadingMedia = true
        defer { loadingMedia = false }

        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data),
               let jpeg = image.jpegData(compressionQuality: 0.85) {
                let fileName = MediaStore.save(data: jpeg, ext: "jpg", roomKey: currentRoomKey)
                mediaItems.append(MediaItem(fileName: fileName, kind: "image"))
            }
        }
        selectedPhotos = []
    }

    private func loadVideos(from items: [PhotosPickerItem]) async {
        loadingMedia = true
        defer { loadingMedia = false }

        for item in items {
            var savedName: String?

            // 方式一：URL（安全作用域访问后拷贝临时文件）
            if let url = try? await item.loadTransferable(type: URL.self) {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                if FileManager.default.fileExists(atPath: url.path) {
                    savedName = MediaStore.saveFile(from: url, roomKey: currentRoomKey)
                }
            }

            // 方式二：直接读数据（URL 方式拿不到时兜底）
            // v2.37（#9）：不写死 .mov，先看数据真实容器格式再命名，避免「内容 mp4 却套 mov 后缀」
            if savedName == nil,
               let data = try? await item.loadTransferable(type: Data.self) {
                let realExt = MediaNaming.videoExtension(for: data)
                savedName = MediaStore.save(data: data, ext: realExt, roomKey: currentRoomKey)
            }

            if let savedName {
                mediaItems.append(MediaItem(fileName: savedName, kind: "video"))
            }
        }
        selectedVideos = []
    }
}
