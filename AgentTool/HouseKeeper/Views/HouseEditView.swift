import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct HouseEditView: View {
    @Environment(\.dismiss) private var dismiss

    /// 传入房源 = 编辑；nil = 新增
    let house: House?
    /// v2.41：由快捷指令深链唤起时（gongyuguanjia-fwq://paste），进页面即自动解析剪贴板并弹确认卡
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
    /// v2.72（#3）：断网编辑改为「本地先落库 + 挂 pending 待补传」。
    /// 用户确认仅存本机后置 true，performSave 不再重复弹网络确认。
    @State private var offlineSaveConfirmed = false
    // v1.42：保存后云端上传失败 → 提示「已存本机，待网络恢复自动补传」（此前静默入队，用户无感知）
    @State private var pendingUploadTip: String?
    @State private var conflictTip: String?

    /// 用户是否手动改过座号（改过后不再被房号前缀自动覆盖）
    @State private var towerTouched = false
    /// 编辑前原房号目录 key（房号变更时迁移媒体目录）
    @State private var originalRoomKey = ""
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
        let all = (try? HouseRepository.shared.fetchAll(includeTrashed: true)) ?? []
        return Array(Set(all.compactMap { $0.landlord.isEmpty ? nil : $0.landlord })).sorted()
    }
    private var knownLayouts: [String] {
        let all = (try? HouseRepository.shared.fetchAll(includeTrashed: true)) ?? []
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
                Button("仅存本机", role: .destructive) {
                    offlineSaveConfirmed = true
                    performSave()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("检测不到网络连接，本次保存会先存在本机并挂待补传；联网后自动同步到服务器。")
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
            // 字段级合并：同字段两边都改，服务器拒绝覆盖并返回明细
            .alert("有字段被其他设备改过", isPresented: Binding(
                get: { conflictTip != nil },
                set: { if !$0 { conflictTip = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(conflictTip ?? "")
            }
    }

    private var contentWithSyncAlerts: some View {
        contentWithSaveAlerts
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
        let effectiveTower = tower > 0 ? tower : self.tower
        let all = (try? HouseRepository.shared.fetchAll(includeTrashed: true)) ?? []
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

    /// v2.39 保存前拦截：断网时不再只塞进没有出口的草稿箱。
    /// v2.72（#3）：直接本地落库并挂 pending，联网后任务中心/自动补传会继续提交。
    @MainActor
    private func guardedSave(house: House) async {
        let reachable = await NetworkMonitor.shared.awaitReachable(timeout: 2.5)
        guard reachable else {
            offlineSaveConfirmed = true
            performSave()
            return
        }
        // 冲突校验由服务器字段级合并承接；旧云账本守卫链已下线，未接入直接存本机
        saveRaw()
    }

    /// 落库入口：联网直接保存，断网提示仅存本机；旧桶先探后写三选一已下线
    private func saveRaw() {
        // v1.40 第10点：无稳定网络 → 先提示「仅存本机」，用户确认后再保存（避免静默只存本地造成误解）
        // v1.66：改为异步确认（最多等 1.2s），避免 NWPathMonitor 未就绪/路径切换瞬间误报离线——
        // 此前「有网络但保存提示没网络、取消再保存就好了」即瞬态误报
        Task {
            let ok = await NetworkMonitor.shared.awaitReachable()
            if !ok && !offlineSaveConfirmed {
                await MainActor.run { showOfflineAlert = true }
                return
            }
            if !ok {
                // 用户已确认「仅存本机」：跳过服务器探重，直接落本地并挂 pending
                await MainActor.run {
                    offlineSaveConfirmed = false
                    performSave()
                }
                return
            }
            // 新增房源先查服务器：本机没有、但别的设备已收录同一座同一房号时，
            // 不能落成本地新房再推送覆盖；本地查重只能看到本机缓存，挡不住多设备重复。
            if house == nil, HouseServerMode.ready {
                let key = computeNewRoomKey()
                do {
                    if let remote = try await HouseRepository.shared.getHouse(key) {
                        await MainActor.run {
                            let layout = remote.layout.isEmpty ? "户型未填" : remote.layout
                            let status = HouseStatus(rawValue: remote.status)?.label ?? remote.status
                            errorMessage = "这套房源已在服务器收录过：\(remote.roomKey)（\(layout)，\(status)）\n同一座同一房号不能重复添加"
                            showError = true
                        }
                        return
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = "无法连接服务器确认房号是否重复：\(error.localizedDescription)\n请联网后重试，避免重复收录"
                        showError = true
                    }
                    return
                }
            }
            await MainActor.run {
                // 本地 duplicateCheck + 服务器 createOnly 双保险；旧桶先探后写已下线
                performSave()
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
            HouseRepository.shared.insert(target)
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
        // HouseRepository.save() 成功之后，避免「文件删了、数据库却没存上」的不可逆状态。
        let removedMediaItems: [MediaItem] = (house?.mediaItems ?? []).filter { old in
            !mediaItems.contains { $0.fileName == old.fileName }
        }
        // 模型改动（先做）：删除 MediaItem 记录 + 清上传队列；文件本身先不动
        for old in removedMediaItems {
            let rk = originalRoomKey.isEmpty ? (house?.mediaRoomKey ?? "") : originalRoomKey
            HouseRepository.shared.delete(old)
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
            HouseRepository.shared.insert(item)
        }

        // v2.36（#8）：先把数据库存成功（do-catch），失败则提示并返回，绝不碰任何文件
        do {
            try HouseRepository.shared.save()
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
            if !removedMediaItems.isEmpty {
                let removed = removedMediaItems.map { (name: $0.fileName, kind: $0.kind) }
                if HouseServerMode.ready {
                    Task {
                        var succeeded: [(name: String, kind: String)] = []
                        var failed: [(name: String, kind: String, error: String)] = []
                        for item in removed {
                            do {
                                try await HouseRepository.shared.deleteMedia(roomKey: rk, fileName: item.name)
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
                            BackupLogStore.log(category: "房源", action: "删除媒体（本地→服务器）", result: "成功",
                                               detail: "已删除\(summary)", room: rk, cloud: false)
                        } else {
                            let failedFiles = failed.map { $0.name }
                            SyncTaskCenter.shared.reportFailure(
                                kind: .mediaDelete,
                                title: "删服务器媒体",
                                roomKeys: [rk],
                                failure: "\(rk) 有 \(failed.count) 个媒体没从服务器删掉；点重试",
                                files: failedFiles)
                            BackupLogStore.log(category: "房源", action: "删除媒体（本地→服务器）", result: "失败",
                                               detail: "\(failSummary) 删除失败，已挂任务中心", room: rk, cloud: false)
                        }
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
        // 云端推送统一收口——先在主线程把要传的东西抽成「值类型小抄」（防后台读 SwiftData 崩溃），
        // 再由 launchServerPush 按场景排序执行（改名先建后删 / 新增先媒体后账本）。
        let isNewHouse = house == nil
        let mediaToUpload: [MediaItem] = (roomChanged || isNewHouse)
            ? target.mediaItems
            : target.mediaItems.filter { !originalMediaNames.contains($0.fileName) }
        let mediaSnapshots = mediaToUpload.map {
            MediaUploadSnapshot(fileName: $0.fileName, kind: $0.kind, roomKey: target.mediaRoomKey)
        }
        let cloudPushKind: CloudPushKind = isNewHouse ? .newHouse : (roomChanged ? .rename : .plainEdit)
        let oldRoomKeyForPurge = originalRoomKey
        // 用户重新在本机新建/编辑同一房号时，清掉“仅删本地”的隐藏标记，
        // 否则下一次同步又会把用户刚建好的房当成需隐藏对象。
        HouseLocalDeletionStore.remove(target.mediaRoomKey)
        // v1.72（#6）：本地账本镜像（media/<房号>/info.json，与云端同构）——保存即写，删除随目录一步到位
        LocalHouseLedger.save(target)
        // v1.72（#7）：日志动作按实际改动命名（修改租金同步等）；（#8）账本上传也驱动卡片进度条
        let currentMediaNames = Set(target.mediaItems.map { $0.fileName })
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
        // 旧正式版操作日志口径：动作名写「新增房源 / 修改备注 / 修改租金…」，明细写
        // 「修改备注 旧 改 新」。账本动作（编辑保存等）只进单房账本，不再冒充操作日志。
        var opAction = ""
        var opDetail = ""
        if isNewHouse {
            opAction = "新增房源"
            opDetail = syncChange   // 旧版只写「图片 x 个、视频 y 个」，没有媒体时为空
        } else if hasFieldChanges {
            opAction = syncAction
            opDetail = syncChange
        }
        // v2.53：收集本次账本事件 id，供「彻底取消」全量撤回时按 id 移除
        var ledgerEventIds: [String] = []
        if isNewHouse {
            let initial = HouseLedgerFormat.mediaSummary(images: addedSplit.images.count, videos: addedSplit.videos.count)
            let ev = HouseLedgerStore.append(
                roomKey: target.mediaRoomKey,
                action: "新增房源",
                detail: "新建房源，" + (initial.isEmpty ? "无媒体" : initial),
                writeOpLog: false)
            ledgerEventIds.append(ev.id)
        } else if hasFieldChanges {
            // 有字段变化（无论是否同时动媒体）：账本动作仍是「编辑保存」，媒体变化放账本明细
            let ev = HouseLedgerStore.append(
                roomKey: target.mediaRoomKey,
                action: "编辑保存",
                detail: ledgerDetailParts.joined(separator: "；"),
                fieldChanges: ledgerChanges,
                writeOpLog: false)
            ledgerEventIds.append(ev.id)
        } else {
            // 纯媒体改动：账本按真实动作分别记录；操作日志由上传/删除完成后的那条负责，
            // 不在保存瞬间提前写“成功”（旧版也是传完/删完才落日志）。
            if !addedParts.isEmpty {
                let addAction = addedSplit.videos.isEmpty ? "新增图片"
                    : (addedSplit.images.isEmpty ? "新增视频" : "新增媒体")
                let ev = HouseLedgerStore.append(
                    roomKey: target.mediaRoomKey,
                    action: addAction,
                    detail: addedParts.map { "新增\($0)" }.joined(separator: "；"),
                    writeOpLog: false)
                ledgerEventIds.append(ev.id)
            }
            if !removedParts.isEmpty {
                let removeAction = removedSplit.videos.isEmpty ? "删除图片"
                    : (removedSplit.images.isEmpty ? "删除视频" : "删除媒体")
                let ev = HouseLedgerStore.append(
                    roomKey: target.mediaRoomKey,
                    action: removeAction,
                    detail: removedParts.map { "删除\($0)" }.joined(separator: "；"),
                    writeOpLog: false)
                ledgerEventIds.append(ev.id)
            }
        }
        if HouseServerMode.ready {
            launchServerPush(target: target, mediaSnapshots: mediaSnapshots,
                             kind: cloudPushKind, oldRoomKey: oldRoomKeyForPurge,
                             opAction: opAction, opDetail: opDetail)
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
            dismiss()
            return
        }
        // 未接入服务器：本地落库已在上文完成，挂待补传；绑定令牌后自动补传
        let offlineChange = opDetail.isEmpty ? (opAction.isEmpty ? "房源改动" : opAction) : opDetail
        HouseRepository.shared.markPending(target.mediaRoomKey,
                                             action: opAction.isEmpty ? "上传房源改动" : opAction,
                                             detail: offlineChange)
        if !opAction.isEmpty {
            BackupLogStore.log(category: "房源", action: opAction, result: "待同步",
                               detail: "\(offlineChange)；仅存本机（未绑定服务器账号），绑定后自动补传",
                               room: target.mediaRoomKey, cloud: false)
        }
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
    /// 后台全程只看值类型小抄，不读 SwiftData 模型对象。
    /// 服务器模式推送：媒体文件经服务器 HTTP 落服务器磁盘，文本与媒体引用走服务器权威接口。
    /// 本机沿用现有本地通知文案；服务器再向其他接入设备广播。
    private func launchServerPush(target: House, mediaSnapshots: [MediaUploadSnapshot],
                                  kind: CloudPushKind, oldRoomKey: String,
                                  opAction: String, opDetail: String) {
        let taskID = UUID()
        let logRoomKey = target.mediaRoomKey
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
            // 媒体实体落服务器磁盘：服务器模式下直传服务器 HTTP；
            // 媒体失败不阻塞文本权威同步，未传成功的文件由媒体补传队列后续重试。
            var uploadResult: (success: Int, failed: Int, failedFiles: [String],
                               uploaded: [(old: String, new: String)], lastError: String)?
            if !mediaSnapshots.isEmpty {
                await MediaActivityGate.shared.beginUpload()
                defer { Task { await MediaActivityGate.shared.endUpload() } }
                // 新增房源的媒体成功并入「新增房源」一条；普通编辑/改名仍按旧版
                // 单独写「新增图片/新增视频（本地→服务器）」。
                uploadResult = try? await uploadMedia(snapshots: mediaSnapshots,
                                                       writeSuccessLog: (kind != .newHouse),
                                                       taskID: taskID)
                // 服务器可能把同名/无后缀文件唯一化；把真实落盘名回写到本地记录，
                // 后续 pushHouse 的 media_refs 才能和服务器磁盘对得上。
                if let pairs = uploadResult?.uploaded, !pairs.isEmpty {
                    await MainActor.run {
                        for pair in pairs where pair.old != pair.new {
                            for item in target.mediaItems where item.fileName == pair.old {
                                item.fileName = pair.new
                            }
                        }
                        try? HouseRepository.shared.save()
                    }
                }
            }
            do {
                // 上传失败的媒体不写进服务器引用；否则服务器账本指向不存在的文件，刷新必 404。
                let allowedNames: Set<String>? = {
                    guard let uploadResult, !mediaSnapshots.isEmpty else { return nil }
                    let failed = Set(uploadResult.failedFiles)
                    return Set(target.mediaItems.map { $0.fileName }).subtracting(failed)
                }()
                let remote = try await HouseRepository.shared.push(
                    target, mediaFileNames: allowedNames)
                // 新房先有房源、后有账本：append 时的上行会因“房源不存在”失败，
                // 权威房源落库后立刻补一次账本上行，避免新收房源账本要等下次启动才出现。
                await HouseLedgerStore.syncPending(roomKey: remote.roomKey)
                // 改名：清理服务器上旧房号的记录与磁盘媒体（后端级联删除；失败不阻断，留待对账清理）
                var renamePurgeError: String?
                if kind == .rename, !oldRoomKey.isEmpty, oldRoomKey != remote.roomKey {
                    do { try await HouseRepository.shared.deleteRemote(oldRoomKey) }
                    catch { renamePurgeError = error.localizedDescription }
                }
                // 旧正式版规则：服务器推送成功后才落操作日志（本机+云端同一条），
                // 动作名直接用「新增房源 / 修改备注 / 修改租金…」，失败不再先留一条假成功。
                let mediaFailed = uploadResult?.failed ?? 0
                if !opAction.isEmpty {
                    // 一次动作只写一条最终结果：媒体没传全记“部分失败”，不再先写假成功
                    let result = mediaFailed > 0 ? "部分失败" : "成功"
                    let detail = mediaFailed > 0
                        ? opDetail + "；\(mediaFailed) 个媒体待补传（已挂同步任务中心）"
                        : opDetail
                    BackupLogStore.log(category: "房源", action: opAction, result: result,
                                       detail: detail, room: remote.roomKey, cloud: true)
                }
                if kind == .rename && !oldRoomKey.isEmpty && oldRoomKey != remote.roomKey {
                    if let renamePurgeError {
                        BackupLogStore.log(category: "房源", action: "房号迁移", result: "部分失败",
                                           detail: "房号迁移（\(oldRoomKey) → \(remote.roomKey)）：新名已建好，旧记录清理失败：\(renamePurgeError)（下次同步再清）",
                                           room: remote.roomKey, cloud: true)
                    } else {
                        BackupLogStore.log(category: "房源", action: "房号迁移", result: "成功",
                                           detail: "房号迁移（\(oldRoomKey) → \(remote.roomKey)）：服务器旧记录已清理",
                                           room: remote.roomKey, cloud: true)
                    }
                }
                await MainActor.run {
                    if !mediaSnapshots.isEmpty { SyncTaskCenter.shared.discard(id: taskID) }
                    let roomKey = remote.roomKey
                    switch kind {
                    case .newHouse:
                        HouseActionNotifier.shared.send(key: "new.\(roomKey)",
                            title: "房源已保存", body: "\(roomKey) 台账已保存到服务器")
                    case .rename:
                        HouseActionNotifier.shared.send(key: "rename.\(roomKey)",
                            title: "房号已迁移", body: "\(oldRoomKey) → \(roomKey)，已同步到服务器")
                    case .plainEdit:
                        HouseActionNotifier.shared.send(key: "edit.\(roomKey)",
                            title: "修改已同步", body: "\(roomKey) 的改动已保存并同步到服务器")
                    }
                }
            } catch {
                let isFieldConflict = (error as? HouseAPIError)?.fieldConflict == true
                // b29：待同步日志必须写清“改了什么”。此前只写 error.localizedDescription，
                // 用户只看到“已断开网络”，完全不知道哪一项没传上去。
                let changeText = opDetail.isEmpty ? (opAction.isEmpty ? "房源改动" : opAction) : opDetail
                let failureDetail = isFieldConflict
                    ? "\(changeText)；同字段冲突，本次未上传，本机内容保留"
                    : "\(changeText)；已存本机，待补传（\(error.localizedDescription)）"
                // 失败只先写本机日志，不写云端；补传成功时把这条“待同步”就地改成“成功”，
                // 这样云端不会出现“待同步 + 成功”两条并列记录。
                BackupLogStore.log(category: "房源",
                                   action: opAction.isEmpty ? "房源同步" : opAction,
                                   result: isFieldConflict ? "冲突" : "待同步",
                                   detail: failureDetail,
                                   room: logRoomKey, cloud: false)
                await MainActor.run {
                    if !mediaSnapshots.isEmpty { SyncTaskCenter.shared.discard(id: taskID) }
                    if let api = error as? HouseAPIError, api.fieldConflict {
                        // 同字段冲突不挂自动补传（否则每轮都撞同一冲突），只保留本机改动并给明细
                        let lines = api.fieldConflicts.map { c in
                            "\(c["label"] ?? c["field"] ?? "字段")：服务器「\(c["server"] ?? "")」/ 本机「\(c["client"] ?? "")」"
                        }.joined(separator: "\n")
                        conflictTip = lines.isEmpty
                            ? "服务器已有另一版改动，本次未上传；本机内容已保留。"
                            : "本次未上传，本机内容已保留。冲突字段：\n\(lines)\n\n请按服务器现值决定是否重填，再保存。"
                        HouseRepository.shared.clearPending(logRoomKey)
                    } else {
                        // 标记待补传，并把“动作 + 字段变化”一并登记，任务中心和补传成功日志都能显示具体改动
                        HouseRepository.shared.markPending(
                            logRoomKey,
                            action: opAction.isEmpty ? "上传房源改动" : opAction,
                            detail: changeText)
                        HouseActionNotifier.shared.send(
                            key: "fail.\(target.mediaRoomKey)",
                            title: "已存本机",
                            body: "服务器同步失败：\(error.localizedDescription)，联网后自动补传")
                    }
                }
            }
        }
        Task { @MainActor in UploadTaskRegistry.shared.register(taskID, task: work) }
    }



    /// 媒体上传（值类型小抄版）：保留原有的幂等、失败重试 1 次、再失败入队、卡片进度与日志逻辑。
    /// 返回 (成功数, 失败数, 最后错误)。调用方负责 MediaActivityGate。
    /// 判断错误是否为手动取消（Task 取消 / URLSession 任务取消）
    fileprivate static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func uploadMedia(snapshots: [MediaUploadSnapshot], writeSuccessLog: Bool = true, taskID: UUID? = nil, isNewHouse: Bool = false) async throws -> (success: Int, failed: Int, failedFiles: [String], uploaded: [(old: String, new: String)], lastError: String) {
        guard !snapshots.isEmpty else { return (0, 0, [], [], "") }
        var success = 0, failed = 0, lastError = ""
        var failedFiles: [String] = []
        var uploaded: [(old: String, new: String)] = []
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
            do {
                let data = try Data(contentsOf: url)
                HouseSyncProgress.shared.updateStage(roomKey: snap.roomKey, direction: .upload, label: "正在上传")
                let result = try await HouseRepository.shared.uploadMedia(
                    roomKey: snap.roomKey, fileName: snap.fileName,
                    kind: snap.kind, data: data)
                // 本地文件名/后缀保持不动（原名原后缀），服务器唯一化/转码后的真实名
                // 已由 HouseRemoteClient 写入 HouseMediaNameMap；media_refs 照映射取。
                // 这里不再改本地文件或模型文件名，避免磁盘与账本对不上。
                _ = result
                uploaded.append((old: snap.fileName, new: snap.fileName))
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
        return (success, failed, failedFiles, uploaded, lastError)
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
               let jpeg = MediaOptimizer.optimizedImageDataForUpload(
                    data, compress: shareCompressionEnabled)
                    ?? image.jpegData(compressionQuality: 0.85) {
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
                    // 压缩开关开 → 720p H.264 mp4；关 → 原质量转 mp4 封装。
                    // 本地仍沿用 .mov 名（与旧账本/服务器引用映射一致），上传时统一改成 .mp4。
                    if let optimized = await MediaOptimizer.optimizedVideoDataForUpload(
                        from: url, compress: shareCompressionEnabled) {
                        savedName = MediaStore.save(data: optimized, ext: "mov", roomKey: currentRoomKey)
                    } else {
                        savedName = MediaStore.saveFile(from: url, roomKey: currentRoomKey)
                    }
                }
            }

            // 方式二：直接读数据（URL 方式拿不到时兜底）
            // v2.37（#9）：不写死 .mov，先看数据真实容器格式再命名，避免「内容 mp4 却套 mov 后缀」
            if savedName == nil,
               let data = try? await item.loadTransferable(type: Data.self) {
                if let optimized = await MediaOptimizer.optimizedVideoDataForUpload(
                    from: data, compress: shareCompressionEnabled) {
                    savedName = MediaStore.save(data: optimized, ext: "mov", roomKey: currentRoomKey)
                } else {
                    // 兜底也统一用 .mov 本地名：服务器引用按 .mp4 换算，本地不再出现两套后缀。
                    savedName = MediaStore.save(data: data, ext: "mov", roomKey: currentRoomKey)
                }
            }

            if let savedName {
                mediaItems.append(MediaItem(fileName: savedName, kind: "video"))
            }
        }
        selectedVideos = []
    }
}
