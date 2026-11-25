import SwiftUI
import SwiftData
import AVKit
import AVFoundation
import Photos

struct HouseDetailView: View {
    /// 房源板块专属 context（独立 HouseStore 容器，由 App 注入）
    @Environment(\.houseModelContext) private var houseModelContext
    /// v1.17 需求1：主容器 context（DealRecord/Property 等经营数据所在容器）。
    /// 闪退根因：成交/在租/退租的关联查询此前误用了 houseModelContext（HouseStore 只注册 House/MediaItem），
    /// 在独立容器查未注册模型触发 SwiftData 崩溃——必须用主容器查。
    @Environment(\.modelContext) private var mainCtx
    @Environment(\.dismiss) private var dismiss

    /// 当前可用的房源数据上下文（App 内必然已注入；缺失属程序 bug，崩溃前留痕便于定位）
    private var modelContext: ModelContext {
        guard let ctx = houseModelContext else {
            CrashLogCollector.logFatal(title: "HouseDetailView 缺少 houseModelContext 注入", body: "house 房号：\(house.roomNo)")
            fatalError("houseModelContext 未注入")
        }
        return ctx
    }

    let house: House

    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    /// v2.45：单套房账本弹窗
    @State private var showLedger = false
    @State private var showStatusConfirm = false
    @State private var showShareModePicker = false    // v1.21：分享前先选「脱敏 / 完整」
    @State private var previewRoute: PhotoPreviewRoute? = nil
    @State private var shareItems: [Any] = []
    /// v2.29：视频/卡片分享统一走 sheet 呈现（与 2.17 一致）
    @State private var detailShareStep: ShareStep? = nil
    // v2.26：视频逐个发送队列（微信扩展单次只认 1 个视频，多视频塞一个面板会整条失败）
    @State private var videoShareQueue: [[Any]] = []
    @State private var videoShareIndex = 0
    @State private var videoShareRemaining = 0
    @State private var showContinueVideoShare = false
    @State private var isSelecting = false          // 多选模式
    @State private var selectedMediaNames = Set<String>()   // 用唯一 fileName 标记选中
    @State private var saveTip: String?
    @State private var isSharing = false           // 生成分享卡片中
    @State private var shareProgress = 0.0         // v1.13 需求13：上传百分比进度
    @State private var shareError: String?
    // v2.17：只分享视频——准备中（转 mp4 + 相册留副本）
    @State private var isPreparingVideo = false
    // v1.15 需求1：一键保存到相册（独立状态，避免与多选「保存选中」的 saveTip/alert 冲突）
    @State private var showSaveConfirm = false
    @State private var isSavingMedia = false
    @State private var saveAllTip: String?
    // v1.36 需求2：详情页「成交/在租/退租」关联查看（只读）
    @State private var recordViewItem: RecordViewItem? = nil
    @State private var recordPickKind: RecordPickKind? = nil
    @State private var recordPickList: [RecordViewItem] = []
    // v1.36 需求1：彻底删除（本地+云端）
    @State private var isDeletingCloud = false
    // v1.19：纯云端房源下载到本地
    @State private var isDownloading = false
    @State private var cloudDeleteMessage: String?
    @State private var deleteResultMessage: String?   // v1.19 补全：删除成功提示（区分 本地/本地+云端/云端）
    // v1.44：媒体区刷新信号——自动补缺/下载完成后 post houseStoreChanged，用 .id() 强制重建媒体区，
    //        修复「文件已下载但详情页仍显示空白占位，需重进 App 才显示」的问题
    @State private var mediaRefreshTick = 0

    // MARK: - v2.39 多设备同步防护
    /// 最近一次单房检测结果（进详情自动检测 + 右上角手动刷新共用）
    @State private var cloudState: HouseCloudState?
    @State private var isCheckingCloud = false
    /// 检测失败（弱网/断网）时的顶部提示，不等于「没有更新」
    @State private var cloudCheckHint: String?
    @State private var showCloudUpdateAlert = false
    @State private var cloudUpdateDiffs: [String] = []
    @State private var pendingCloudRecord: CloudHouseRecord?
    @State private var showCannotEditAlert = false
    @State private var cloudToast: String?

    // v1.19：把滚动主体拆为独立子视图，避免 Swift 编译器对整个 body 一次类型检查超时
    private var detailScroll: some View {
        ScrollView {
            VStack(spacing: 14) {
                // v2.39：检测失败（弱网/断网）时的常驻提示——不能把「检测不了」当成「没有更新」
                if let hint = cloudCheckHint {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundColor(.orange)
                        Text(hint)
                            .font(.footnote)
                            .foregroundColor(.orange)
                        Spacer()
                        Button("重试") { Task { await refreshSingleHouse() } }
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                // v1.44：mediaRefreshTick 变化时强制重建媒体区（自动补缺下载完成后即时显示）
                mediaSection.id(mediaRefreshTick)
                infoCard
                actionCard
            }
            .padding(16)
        }
    }

    // v1.19 补全：把两个大块 overlay 提出为独立 @ViewBuilder，避免 body 一次类型检查超时
    @ViewBuilder private var shareOverlayView: some View {
        if isSharing {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView(value: shareProgress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                    Text("正在上传照片和视频…")
                        .font(.footnote)
                        .foregroundColor(.white)
                    Text("\(Int(shareProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(20)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
    /// v2.17：只分享视频准备中（转 mp4 + 相册留副本，通常 1～3 秒）
    @ViewBuilder private var videoPrepareOverlay: some View {
        if isPreparingVideo {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("正在准备视频…")
                        .font(.footnote)
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder private var saveOverlayView: some View {
        if isSavingMedia {            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("正在保存到相册…")
                        .font(.footnote)
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        } else if let tip = saveAllTip {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                    Text(tip)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Button("好") { saveAllTip = nil }
                        .font(.footnote)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                        .background(Color.white)
                        .foregroundColor(.black)
                        .clipShape(Capsule())
                }
                .padding(20)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var sheetLayer: some View {
        detailScroll
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(house.displayRoomNo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        // v2.39：单房刷新——只拉这一套的 info.json，不碰其他房源
                        Button {
                            Task { await refreshSingleHouse() }
                        } label: {
                            if isCheckingCloud {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(isCheckingCloud)
                        .accessibilityLabel("刷新本房云端数据")

                        Button("编辑") { openEditor() }
                    }
                }
            }
            // v2.29：分享面板走 sheet（2.17 可用版本的做法），关闭后问「继续发送下一个」
            .sheet(item: $detailShareStep, onDismiss: {
                if !videoShareQueue.isEmpty, videoShareIndex < videoShareQueue.count - 1 {
                    videoShareRemaining = videoShareQueue.count - videoShareIndex - 1
                    showContinueVideoShare = true
                } else if !videoShareQueue.isEmpty {
                    videoShareQueue = []
                    videoShareIndex = 0
                }
            }) { step in
                HouseShareSheet(items: step.items)
            }
            .sheet(isPresented: $showEdit) {
                HouseEditView(house: house)
            }
    }

    private var dialogLayer: some View {
        sheetLayer
            .confirmationDialog("切换房源状态", isPresented: $showStatusConfirm, titleVisibility: .visible) {
                if house.status == .available {
                    Button("标记为已租", role: .destructive) { setStatus(.rented) }
                } else {
                    Button("标记为待租") { setStatus(.available) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(house.status == .available ? "确认这套已租出？" : "确认这套恢复可带看？")
            }
            .confirmationDialog("删除这套房源？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("彻底删除", role: .destructive) { deleteHouse() }
                Button("取消", role: .cancel) {}
            } message: {
                // v1.19 补全：删除确认提示按当前存储位置动态显示（是否删云端一目了然）
                Text(deleteConfirmMessage)
            }
            .confirmationDialog("选择分享方式", isPresented: $showShareModePicker, titleVisibility: .visible) {
                // v1.21：脱敏版隐藏房号/价格/房东，发给找房客户；完整版显示全部信息，发给同事
                Button("发给客户（隐藏版）") { startShare(mode: .masked) }
                Button("发给同事（完整版）") { startShare(mode: .full) }
                // v2.17：只分享视频——不生成云端卡片，直接把视频按「视频消息」发出去（微信收到可播放）
                Button("只分享视频") { startVideoOnlyShare() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("隐藏版只显示户型、位置和您的联系方式；完整版额外显示房号、价格、房东和密码；只分享视频 = 直接把视频发到微信，好友收到即可播放，不需要备案域名。")
            }
            // v1.15 需求1：一键保存确认（显示将保存的照片/视频数量）
            .confirmationDialog("保存到手机相册？", isPresented: $showSaveConfirm, titleVisibility: .visible) {
                Button("保存", role: .destructive) { saveAllToAlbum() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将把本房源全部 \(house.photos.count) 张照片、\(house.videos.count) 个视频保存到系统相册。")
            }
            .fullScreenCover(item: $previewRoute) { route in
                PhotoPreviewView(photos: house.photos, startIndex: route.index, roomKey: house.mediaRoomKey)
            }
            .overlay {
                shareOverlayView
            }
            // v1.15 需求1：一键保存中 + 保存完成提示（overlay 卡片，不占 alert 链，避开 iOS 17 多弹窗覆盖问题）
            .overlay {
                saveOverlayView
            }
            // v2.17：只分享视频的准备中提示
            .overlay {
                videoPrepareOverlay
            }
    }

    var body: some View {
        dialogLayer
        // v1.43：打开详情自动补缺——记录在但磁盘文件缺失且云端有 → 自动下载回补（用户手删 media 文件夹后重开不再空白）
        .onAppear {
            repairMissingMediaIfNeeded()
            // v2.20：进来一次就算已读，房源卡片红框消失
            UnreadCloudHouseStore.clear(house.mediaRoomKey)
            // v2.39：进详情自动检测云端是否有更新（有更新弹「更新/忽略」，无更新不提示）
            Task { await checkCloudOnEnter() }
        }
        // v1.44：收到房源数据变更通知（下载完成/编辑保存等）→ 触发媒体区重建，下载后立即显示
        .onReceive(NotificationCenter.default.publisher(for: HouseListView.houseStoreChanged)) { _ in
            mediaRefreshTick += 1
        }
        .alert("无法分享", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
        // v1.36 需求2：多条关联记录时弹窗选择打开哪条
        .confirmationDialog("选择记录", isPresented: Binding(
            get: { recordPickKind != nil },
            set: { if !$0 { recordPickKind = nil } }
        ), titleVisibility: .visible) {
            ForEach(recordPickList) { item in
                Button(item.title) { recordViewItem = item }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该房号关联到多条记录，选择要查看的一条")
        }
        .sheet(item: $recordViewItem) { item in
            NavigationStack {
                RecordViewerContainer(item: item)
            }
            .presentationDetents([.medium, .large])
        }
        // v1.36 需求1：本地已删、云端删除失败的分开提示（下载/自动下载提示也走这里，不关闭页面）
        .alert("提示", isPresented: Binding(
            get: { cloudDeleteMessage != nil },
            set: { if !$0 { cloudDeleteMessage = nil } }
        )) {
            Button("好") {}
        } message: {
            Text(cloudDeleteMessage ?? "")
        }
        // v1.19 补全：删除成功提示（区分 本地 / 本地+云端 / 云端），点「好」返回列表
        .alert("删除房源", isPresented: Binding(
            get: { deleteResultMessage != nil },
            set: { if !$0 { deleteResultMessage = nil } }
        )) {
            Button("好") { dismiss() }
        } message: {
            Text(deleteResultMessage ?? "")
        }
        // v2.26：视频逐个发送——发完一个问「继续下一个 / 结束」
        .alert("还有 \(videoShareRemaining) 个视频没发", isPresented: $showContinueVideoShare) {
            Button("继续发送下一个") {
                if videoShareIndex < videoShareQueue.count - 1 {
                    videoShareIndex += 1
                    presentDetailVideoBatch()
                }
            }
            Button("结束", role: .cancel) { videoShareQueue = []; videoShareIndex = 0 }
        }
        // v2.53：有变化（含仅媒体变化）→ 详细「本地 vs 云端」差异，确认同步 / 取消
        // v2.57（P1-6）：本机有改动还没传上（SyncFail）时一并警告——此时按云端覆盖会把
        // 没传上去的本机改动（含没传上的媒体）一并丢掉，必须先补传或明确放弃再同步。
        .alert("本地 vs 云端有差异", isPresented: $showCloudUpdateAlert) {
            Button("确认同步") { applyCloudUpdate() }
            Button("取消", role: .cancel) { pendingCloudRecord = nil }
        } message: {
            Text(cloudUpdateDiffs.joined(separator: "\n")
                 + (SyncFailStore.isFailed(house.mediaRoomKey)
                    ? "\n\n⚠️ 这套房本机还有改动没传上云端（同步失败待补传）。现在按云端覆盖，这些改动和没传上的媒体会被丢掉。建议先到同步任务中心把本机改动补传成功，再回来同步。"
                    : "")
                 + "\n\n点「确认同步」按云端更新本地；点「取消」保持本机现状。")
        }
        // v2.39：旧数据不许进编辑（保存前还有第二道强校验）
        .alert("请先同步云端", isPresented: $showCannotEditAlert) {
            Button("立即同步") { Task { await refreshSingleHouse() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这套房的云端数据已被其他设备更新，直接编辑会在保存时被拦下。\n请先点「立即同步」拉取最新数据，再重新编辑。")
        }
        // v2.39：单房刷新/更新结果轻提示
        .overlay(alignment: .bottom) {
            if let t = cloudToast {
                Text(t)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.82))
                    .clipShape(Capsule())
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        // v2.45：单套房账本
        .sheet(isPresented: $showLedger) {
            HouseLedgerView(roomKey: house.mediaRoomKey, displayRoomNo: house.displayRoomNo)
        }
        .overlay {
            if isDeletingCloud {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("本地已删除，正在同步删除云端…")
                            .font(.footnote)
                            .foregroundColor(.white)
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    // MARK: - 媒体预览

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text("实拍照片与视频")
                        .font(.headline)
                } icon: {
                    Image(systemName: "camera.fill")
                        .foregroundColor(AppTheme.primary)
                }
                Spacer()
                if house.hasPhoto || house.hasVideo {
                    if isSelecting {
                        // 多选模式：全选（已全选时点击清空）+ 取消按钮（同款品牌色胶囊）
                        HStack(spacing: 8) {
                            Button {
                                toggleSelectAll()
                            } label: {
                                Label(selectedMediaNames.count == house.mediaItems.count ? "取消全选" : "全选", systemImage: "checkmark.circle")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(AppTheme.primary)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            Button {
                                exitSelecting()
                            } label: {
                                Label("取消", systemImage: "xmark")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(AppTheme.primary)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        HStack(spacing: 8) {
                            // 多选入口（胶囊形，大小随文字自适应）
                            Button {
                                isSelecting = true
                            } label: {
                                Label("多选", systemImage: "checkmark.circle")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(AppTheme.primary)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if house.photos.isEmpty && house.videos.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundColor(.secondary)
                    Text("暂无照片和视频，点「编辑」添加")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                if !house.photos.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        // 用唯一 fileName 作标识（MediaItem.id 在 SwiftData 新对象上可能相同）
                        ForEach(Array(house.photos.enumerated()), id: \.element.fileName) { index, media in
                            // 固定正方形格子，内容缩放裁切填满，横屏照片也不会溢出重叠
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    MediaThumbView(media: media, roomKey: house.mediaRoomKey)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topLeading) {
                                    if isSelecting {
                                        Image(systemName: selectedMediaNames.contains(media.fileName) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                            .padding(5)
                                    }
                                }
                                .onTapGesture {
                                    if isSelecting {
                                        toggleSelect(media)
                                    } else {
                                        previewRoute = PhotoPreviewRoute(index: index)
                                    }
                                }
                        }
                    }
                }

                if !house.videos.isEmpty {
                    ForEach(house.videos, id: \.fileName) { media in
                        if isSelecting {
                            // 多选模式下视频显示为缩略图，点击选中
                            Color.clear
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .overlay(
                                    MediaThumbView(media: media, roomKey: house.mediaRoomKey)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topLeading) {
                                    Image(systemName: selectedMediaNames.contains(media.fileName) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(.white)
                                        .shadow(radius: 2)
                                        .padding(5)
                                }
                                .onTapGesture {
                                    toggleSelect(media)
                                }
                        } else {
                            // 视频条目：缩略图 + 播放三角（竖版视频完整显示首帧，不再被误认成图片），点击全屏播放
                            HouseDetailVideoItem(media: media, roomKey: house.mediaRoomKey)
                                .frame(height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }

                // 多选模式：底部保存按钮
                if isSelecting {
                    Button {
                        saveSelectedToAlbum()
                    } label: {
                        Label(selectedMediaNames.isEmpty ? "请选择要保存的照片或视频" : "保存到相册（\(selectedMediaNames.count)）", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .disabled(selectedMediaNames.isEmpty)
                }
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .alert("保存到相册", isPresented: Binding(
            get: { saveTip != nil },
            set: { if !$0 { saveTip = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveTip ?? "")
        }
    }

    // MARK: - 多选 / 保存到相册

    /// v1.30：多选模式一键全选 / 取消全选（已全选时再点则清空）
    private func toggleSelectAll() {
        let all = Set(house.mediaItems.map { $0.fileName })
        if !all.isEmpty, selectedMediaNames.count == all.count {
            selectedMediaNames.removeAll()
        } else {
            selectedMediaNames = all
        }
    }

    private func toggleSelect(_ media: MediaItem) {
        if selectedMediaNames.contains(media.fileName) {
            selectedMediaNames.remove(media.fileName)
        } else {
            selectedMediaNames.insert(media.fileName)
        }
    }

    private func exitSelecting() {
        isSelecting = false
        selectedMediaNames.removeAll()
    }

    private func saveSelectedToAlbum() {
        let selected = house.mediaItems.filter { selectedMediaNames.contains($0.fileName) }
        guard !selected.isEmpty else { return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    for media in selected {
                        let url = MediaStore.url(for: media.fileName, roomKey: house.mediaRoomKey)
                        if media.kind == "image",
                           let image = UIImage(contentsOfFile: url.path) {
                            let imgReq = PHAssetChangeRequest.creationRequestForAsset(from: image)
                            imgReq.creationDate = Date()
                        } else if media.kind == "video",
                                  FileManager.default.fileExists(atPath: url.path) {
                            let vidReq = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                            vidReq?.creationDate = Date()
                        }
                    }
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        if success {
                            saveTip = "已保存 \(selected.count) 个到相册"
                            exitSelecting()
                        } else {
                            saveTip = "保存失败：\(error?.localizedDescription ?? "未知错误")"
                        }
                    }
                }
            default:
                DispatchQueue.main.async {
                    saveTip = "没有相册写入权限，请在 设置 → 隐私与安全 → 照片 中允许"
                }
            }
        }
    }

    // MARK: - 房源信息

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(house.displayRoomNo)
                        .font(.title2.weight(.bold))
                        .foregroundColor(AppTheme.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("\(house.towerLabel) · \(house.layout.isEmpty ? "户型未填" : house.layout)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                // v2.47 修正：账本按钮还原到下方操作区（分享按钮下面），这里只留状态胶囊
                StatusBadge(status: house.status, large: true)
                    .fixedSize()
                    .layoutPriority(1)
            }
            .padding(.bottom, 12)

            Divider()

            infoRow(icon: "person.fill", title: "房东", value: house.landlord.isEmpty ? "—" : house.landlord)
            infoRow(icon: "yensign", title: "价格", value: house.priceText)
            infoRow(icon: "key.fill", title: "密码", value: house.password.isEmpty ? "—" : house.password)
            infoRow(icon: "text.alignleft", title: "备注", value: house.remark.isEmpty ? "—" : house.remark)
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(AppTheme.primary)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
    }

    // MARK: - 操作区（三个按钮上下继续缩窄）

    private var actionCard: some View {
        VStack(spacing: 8) {
            Button {
                showStatusConfirm = true
            } label: {
                Label {
                    Text(house.status == .available ? "标记为已租" : "标记为待租")
                } icon: {
                    Image(systemName: house.status == .available ? "checkmark.circle" : "arrow.uturn.backward.circle")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(house.status == .available ? Color(red: 0.24, green: 0.58, blue: 0.34) : Color(red: 0.47, green: 0.49, blue: 0.55))

            Button {
                ensureLocalMedia {
                    shareHouseCard()
                }
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)

            // v2.47 修正：账本按钮还原到「分享」按钮下面（操作区），底色与「分享」完全一致（去掉原来的 tint）
            Button {
                showLedger = true
            } label: {
                Label("账本", systemImage: "books.vertical")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)

            // v1.19：纯云端房源 → 下载到本地（下载后可编辑/分享/保存）
            if house.cloudStatus == .cloud {
                Button {
                    downloadHouseToLocal()
                } label: {
                    Label(isDownloading ? "下载中…" : "下载到本地", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .disabled(isDownloading)
            }

            // v1.15 需求1：一键保存（全部图片+视频保存到手机相册，先弹确认）
            Button {
                ensureLocalMedia {
                    confirmSaveToAlbum()
                }
            } label: {
                // v1.15 需求1：转存到微信 → 一键保存（全部图片+视频保存到手机相册）
                Label("一键保存", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .disabled(isSavingMedia)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("删除房源", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)

            // v1.36 需求2：成交/在租/退租（按房号关联；无记录置灰；多条弹窗选择；打开只读表单）
            HStack(spacing: 8) {
                recordButton("成交", kind: .deal, icon: "doc.text")
                recordButton("在租", kind: .renting, icon: "house")
                recordButton("退租", kind: .terminated, icon: "arrow.backward.circle")   // v1.37b：door.left.handled 是 iOS16+ 符号，旧系统显示空白 → 换 iOS13+ 就有
            }
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 操作

    private func setStatus(_ newStatus: HouseStatus) {
        let oldStatus = house.status
        let roomKey = house.mediaRoomKey
        house.status = newStatus
        house.updatedAt = Date()
        // v1.19：切换状态也刷新最后更新时间并同步云端
        house.lastUpdatedAt = Date()
        try? modelContext.save()
        LocalHouseLedger.save(house)
        // v2.45：状态变化写账本（状态没变不写）
        if oldStatus != newStatus {
            HouseLedgerStore.append(
                roomKey: roomKey,
                action: "切换状态",
                fieldChanges: [HouseLedgerFieldChange(field: "状态", oldValue: oldStatus.label, newValue: newStatus.label)])
        }
        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
        let displayNo = house.displayRoomNo
        if HouseServerMode.ready {
            // 服务器模式：状态切换直接推服务器权威库，不走旧 COS 账本链路；失败入待补传队列
            Task {
                do {
                    _ = try await HouseSyncEngine.shared.pushHouse(house)
                    await MainActor.run {
                        HouseActionNotifier.shared.send(
                            key: "status.\(roomKey)",
                            title: "状态已同步",
                            body: "\(displayNo) 已改为\(newStatus.label)，服务器已更新")
                    }
                } catch {
                    await MainActor.run {
                        HousePendingUploader.shared.markPending(roomKey)
                        HouseActionNotifier.shared.send(
                            key: "statusfail.\(roomKey)",
                            title: "状态同步失败",
                            body: "\(displayNo) 已改本机，服务器没同步上：\(error.localizedDescription)",
                            silent: true)
                    }
                }
            }
        }
    }

    // MARK: - v2.39 单房云端检测 / 更新 / 编辑入口

    /// 进详情自动检测：只判断「有没有更新」，无更新不弹任何东西
    @MainActor
    private func checkCloudOnEnter() async {
        // 服务器模式：房源权威库在 8082，进详情不再跑旧 COS 字段对比检测，避免弹旧链路覆盖告警
        guard !HouseServerMode.ready else { return }
        guard CosConfig.load()?.isValid == true else { return }
        await runCloudCheck(useCache: true, silentWhenFresh: true)
    }

    /// 右上角单房刷新：只拉这一套的 info.json，强制不走缓存
    @MainActor
    private func refreshSingleHouse() async {
        guard !HouseServerMode.ready else {
            showCloudToast("服务器模式：以服务器房源为准")
            return
        }
        guard CosConfig.load()?.isValid == true else {
            showCloudToast("未配置云存储，无法检测")
            return
        }
        await runCloudCheck(useCache: false, silentWhenFresh: false)
    }

    @MainActor
    private func runCloudCheck(useCache: Bool, silentWhenFresh: Bool) async {
        if HouseServerMode.ready { return }
        guard let config = CosConfig.load(), config.isValid else { return }
        guard !isCheckingCloud else { return }
        isCheckingCloud = true
        let state = await HouseSyncGuard.check(house: house, config: config, useCache: useCache)
        isCheckingCloud = false
        cloudState = state
        switch state {
        case .updated(let rec, let diffs):
            cloudCheckHint = nil
            pendingCloudRecord = rec
            cloudUpdateDiffs = cloudChangeLines(rec: rec, fieldDiffs: diffs)
            showCloudUpdateAlert = true
        case .unknown(let msg):
            // 检测失败 ≠ 没有更新：常驻提示 + 可重试
            cloudCheckHint = "云端检测失败（\(msg)），本机数据可能不是最新。"
        case .fresh:
            cloudCheckHint = nil
            if !silentWhenFresh { showCloudToast("已是最新") }
        case .mediaOnly(let rec):
            cloudCheckHint = nil
            if silentWhenFresh {
                // 进详情自动检测：仅媒体变化不阻断编辑、保存时自动合并，保持静默不弹窗
            } else {
                // v2.53：手动刷新时仅媒体变化也弹详细差异 + 确认同步/取消，不再只 toast
                pendingCloudRecord = rec
                cloudUpdateDiffs = cloudChangeLines(rec: rec, fieldDiffs: [])
                showCloudUpdateAlert = true
            }
        case .missing:
            cloudCheckHint = nil
            if !silentWhenFresh { showCloudToast("云端没有这套房（仅本机）") }
        }
    }

    /// v2.53：构造「本地 vs 云端」详细差异行：字段差异 + 媒体（云端有本地无 / 本地有云端无）
    @MainActor
    private func cloudChangeLines(rec: CloudHouseRecord, fieldDiffs: [String]) -> [String] {
        var lines: [String] = []
        if !fieldDiffs.isEmpty {
            lines.append("【字段差异】（本地 → 云端）")
            lines.append(contentsOf: fieldDiffs)
        }
        let md = HouseSyncGuard.mediaDiff(record: rec, house: house)
        if !md.added.isEmpty {
            lines.append("【云端有、本地没有，同步后会下载】")
            lines.append(contentsOf: md.added.map { "＋\($0)" })
        }
        if !md.removed.isEmpty {
            lines.append("【本地有、云端没有，同步后会移除】")
            lines.append(contentsOf: md.removed.map { "－\($0)" })
        }
        if lines.isEmpty { lines.append("内容一致，无差异") }
        return lines
    }

    /// 点「更新」：字段覆盖 + 媒体补缺/删除
    private func applyCloudUpdate() {
        if HouseServerMode.ready { pendingCloudRecord = nil; return }
        guard let rec = pendingCloudRecord,
              let config = CosConfig.load(), config.isValid else { return }
        pendingCloudRecord = nil
        Task { @MainActor in
            do {
                let summary = try await HouseSyncGuard.apply(record: rec, to: house,
                                                             ctx: modelContext, config: config)
                mediaRefreshTick += 1
                showCloudToast(summary)
                // v2.45：云端账本历史一并拉到本机
                try? await HouseLedgerStore.pull(roomKey: house.mediaRoomKey, config: config)
            } catch {
                cloudCheckHint = "更新失败：\(error.localizedDescription)"
            }
        }
    }

    /// 编辑入口：字段有冲突就先拦下（保存时还有第二道强校验兜底）
    private func openEditor() {
        if let st = cloudState, st.hasFieldConflict {
            showCannotEditAlert = true
            return
        }
        showEdit = true
    }

    @MainActor
    private func showCloudToast(_ text: String) {
        withAnimation { cloudToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation {
                if cloudToast == text { cloudToast = nil }
            }
        }
    }

    // MARK: - v1.19 纯云端房源：下载到本地 / 操作前自动下载

    /// 手动下载：把服务器/云端 h/<房号>/ 的媒体拉到本地（纯云端房源专用）
    private func downloadHouseToLocal() {
        isDownloading = true
        let roomKey = house.mediaRoomKey
        if HouseServerMode.ready {
            Task {
                let records = await serverMediaRecords()
                let files = await HouseRemoteClient.shared.downloadMissingMedia(roomKey: roomKey, records: records)
                await MainActor.run {
                    for f in files {
                        let item = MediaItem(fileName: f.fileName, kind: f.kind)
                        item.house = house
                        modelContext.insert(item)
                    }
                    house.cloudStatus = .both
                    try? modelContext.save()
                    NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                    isDownloading = false
                    cloudDeleteMessage = files.isEmpty ? "服务器上暂无可下载媒体。" : "已下载 \(files.count) 个媒体到本地，现在可以编辑、分享或一键保存了。"
                    if !files.isEmpty {
                        let images = files.filter { $0.kind == "image" }.count
                        let videos = files.filter { $0.kind == "video" }.count
                        HouseActionNotifier.shared.send(
                            key: "download.\(roomKey)",
                            title: "房源已下载",
                            body: "\(house.displayRoomNo) 的照片\(images)、视频\(videos) 已存到本机，可编辑分享"
                        )
                    }
                }
            }
            return
        }
        guard let config = CosConfig.load() else {
            isDownloading = false
            cloudDeleteMessage = "未配置云存储，无法下载云端房源"
            return
        }
        Task {
            do {
                // v1.43：只下载云端账本名单内的媒体（避免把首帧图/分享页等非账本对象混入本地记录）
                let names = await cloudMediaNames(for: roomKey, config: config)
                guard !names.isEmpty else {
                    await MainActor.run {
                        isDownloading = false
                        cloudDeleteMessage = "云端账本未找到该房源媒体，无法下载。"
                    }
                    return
                }
                let files = try await CosUploader.downloadHouseMedia(roomKey: roomKey, expectedNames: names, config: config)
                await MainActor.run {
                    for f in files {
                        let item = MediaItem(fileName: f.fileName, kind: f.kind)
                        item.house = house
                        modelContext.insert(item)
                    }
                    house.cloudStatus = .both
                    try? modelContext.save()
                    // v2.45：下载到本机写账本；v2.46：图片/视频分型
                    let dlSplit = HouseLedgerFormat.split(files.map { (name: $0.fileName, kind: $0.kind) })
                    HouseLedgerStore.append(
                        roomKey: roomKey,
                        action: "云端房源下载到本机",
                        detail: HouseLedgerFormat.mediaParts(images: dlSplit.images, videos: dlSplit.videos, includeNames: false).joined(separator: "、"))
                    Task { try? await HouseLedgerStore.pull(roomKey: roomKey, config: config) }
                    // v1.44：下载完成立即通知刷新媒体区
                    NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                    isDownloading = false
                    cloudDeleteMessage = "已下载 \(files.count) 个媒体到本地，现在可以编辑、分享或一键保存了。";
                    // v2.44：纯云端房源下载完成系统通知
                    let images = files.filter { $0.kind == "image" }.count
                    let videos = files.filter { $0.kind == "video" }.count
                    HouseActionNotifier.shared.send(
                        key: "download.\(roomKey)",
                        title: "房源已下载",
                        body: "\(house.displayRoomNo) 的照片\(images)、视频\(videos) 已存到本机，可编辑分享"
                    )
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    cloudDeleteMessage = "下载失败：\(error.localizedDescription)";
                }
            }
        }
    }

    /// 服务器模式回补名单：本地记录优先；本地为空时从服务器房源详情取 media。
    private func serverMediaRecords() async -> [(fileName: String, kind: String)] {
        let local = house.mediaItems.map { ($0.fileName, $0.kind) }
        guard local.isEmpty, HouseServerMode.ready else { return local }
        if let remote = try? await HouseRemoteClient.shared.getHouse(house.mediaRoomKey) {
            return remote.media?.map { ($0.fileName, $0.kind) } ?? []
        }
        return []
    }

    /// v1.43：拉取云端账本里该房号的媒体名单（下载/补缺统一以账本为准，避免桶内非账本对象混入）
    private func cloudMediaNames(for roomKey: String, config: CosConfig) async -> [String] {
        // v1.71（方案 A）：单套账本已是一房一文件，直接读单套 info.json，不再全量拉取
        guard let rec = try? await CloudHouseSync.fetchOne(roomKey: roomKey, config: config) else { return [] }
        return rec.mediaNames
    }

    /// 详情页打开时补缺——记录还在但磁盘文件缺失（用户手删/意外丢失）且服务器/云端有 → 自动下载回补
    private func repairMissingMediaIfNeeded() {
        guard !house.mediaItems.isEmpty else { return }
        let roomKey = house.mediaRoomKey
        // 按规范键判断磁盘是否已有等价文件（视频 mov/mp4 等价、图片保留后缀）
        let diskNorm = Set(MediaStore.existingFileNames(roomKey: roomKey).map { MediaNaming.canonicalKey($0) })
        let missing = house.mediaItems.map { $0.fileName }.filter { !diskNorm.contains(MediaNaming.canonicalKey($0)) }
        guard !missing.isEmpty else { return }
        isDownloading = true
        Task {
            if HouseServerMode.ready {
                let records = house.mediaItems.map { ($0.fileName, $0.kind) }
                let files = await HouseRemoteClient.shared.downloadMissingMedia(roomKey: roomKey, records: records)
                await MainActor.run {
                    for f in files where !house.mediaItems.contains(where: { $0.fileName == f.fileName }) {
                        let item = MediaItem(fileName: f.fileName, kind: f.kind)
                        item.house = house
                        modelContext.insert(item)
                    }
                    try? modelContext.save()
                    NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                    isDownloading = false
                }
                return
            }
            guard let config = CosConfig.load() else {
                await MainActor.run { isDownloading = false }
                return
            }
            let names = await cloudMediaNames(for: roomKey, config: config)
            guard !names.isEmpty else {
                await MainActor.run { isDownloading = false }
                return
            }
            if let files = try? await CosUploader.downloadHouseMedia(roomKey: roomKey, expectedNames: names, config: config), !files.isEmpty {
                await MainActor.run {
                    for f in files where !house.mediaItems.contains(where: { $0.fileName == f.fileName }) {
                        let item = MediaItem(fileName: f.fileName, kind: f.kind)
                        item.house = house
                        modelContext.insert(item)
                    }
                    try? modelContext.save()
                    // 下载完成立即通知刷新媒体区（否则详情页仍显示空白占位，需重进 App）
                    NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                    isDownloading = false
                }
            } else {
                await MainActor.run { isDownloading = false }
            }
        }
    }

    /// 操作前自动下载：分享 / 一键保存 / 编辑前若为纯云端房源，先自动拉到本地
    private func ensureLocalMedia(_ action: @escaping () -> Void) {
        if !house.mediaItems.isEmpty || house.cloudStatus != .cloud {
            action()
            return
        }
        isDownloading = true
        let roomKey = house.mediaRoomKey
        Task {
            if HouseServerMode.ready {
                let records = await serverMediaRecords()
                let files = await HouseRemoteClient.shared.downloadMissingMedia(roomKey: roomKey, records: records)
                await MainActor.run {
                    for f in files {
                        let item = MediaItem(fileName: f.fileName, kind: f.kind)
                        item.house = house
                        modelContext.insert(item)
                    }
                    house.cloudStatus = .both
                    try? modelContext.save()
                    NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                    isDownloading = false
                    if files.isEmpty {
                        action()
                    } else {
                        cloudDeleteMessage = "云端房源已自动下载到本地，请再点一次刚才的操作。"
                    }
                }
                return
            }
            guard let config = CosConfig.load() else {
                await MainActor.run { isDownloading = false }
                action()
                return
            }
            do {
                // 只下载云端账本名单内的媒体（避免把首帧图/分享页等非账本对象混入本地记录）
                let names = await cloudMediaNames(for: roomKey, config: config)
                guard !names.isEmpty else {
                    await MainActor.run { isDownloading = false }
                    action()
                    return
                }
                let files = try await CosUploader.downloadHouseMedia(roomKey: roomKey, expectedNames: names, config: config)
                await MainActor.run {
                    for f in files {
                        let item = MediaItem(fileName: f.fileName, kind: f.kind)
                        item.house = house
                        modelContext.insert(item)
                    }
                    house.cloudStatus = .both
                    try? modelContext.save()
                    // 下载完成立即通知刷新媒体区
                    NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                    isDownloading = false
                    cloudDeleteMessage = "云端房源已自动下载到本地，请再点一次刚才的操作。";
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    cloudDeleteMessage = "下载失败：\(error.localizedDescription)";
                }
            }
        }
    }

    /// v1.19 补全：删除确认文案按当前存储位置动态生成（本地/云端/双端一目了然）
    private var deleteConfirmMessage: String {
        switch house.cloudStatus {
        case .both:
            return "将删除「本地 + 云端」：本地照片视频、数据库记录，以及云端 h/\(house.mediaRoomKey)/ 目录一并清除，不可恢复。备份镜像 backups/media 保留。"
        case .local:
            return "将删除本地房源（未上传云端）：本地照片视频、数据库记录一并清除，不可恢复。备份镜像 backups/media 保留。"
        case .cloud:
            return "将删除云端同步副本：该房本机无媒体，将从云端 h/\(house.mediaRoomKey)/ 清除，不可恢复。"
        }
    }

    private func deleteHouse() {
        // v1.36 需求1：删除 = 彻底删除（本地文件+数据库记录+云端桶 h/<房号>/ 一并删除，不可恢复）
        // 保留二次确认弹窗；backups/media 镜像保留（自动备份 zip 引用，删了旧备份恢复缺图）
        // v2.57（P1-2）：改为「先删云端、成功再删本地」——旧顺序在云端删除失败期间，任何设备一同步
        // 就把已删的房原样拉回来（“删了又复活”）；现在云端删失败时本地不动，改挂任务中心重试（P1-3）。
        guard let ctx = houseModelContext else { return }
        let roomKey = house.mediaRoomKey
        let config = CosConfig.load()
        let wasCloud = house.cloudStatus   // v1.19 补全：记录删除前存储位置，用于成功提示
        // v2.45：删除事件先写账本（目录随后整体删除；云端删除前会先同步一次留证）
        let deleteDetail = HouseServerMode.ready
            ? "彻底删除服务器记录与本地房源（桶内媒体保留）"
            : "彻底删除本地房源" + (config?.isValid == true ? "，并尝试删除云端" : "")
        HouseLedgerStore.append(roomKey: roomKey, action: "删除房源", detail: deleteDetail)
        // 服务器模式：硬删——先删服务器权威库，成功后删本机记录；不进回收站，COS 桶文件夹与媒体本轮保留。
        if HouseServerMode.ready {
            isDeletingCloud = true
            Task {
                do {
                    try await HouseSyncEngine.shared.pushDelete(house)
                    await MainActor.run {
                        MediaStore.deleteHouseDirectory(roomKey: roomKey)
                        SyncFailStore.clear(roomKey)
                        UnreadCloudHouseStore.clear(roomKey)
                        HouseMediaUploadQueue.removeRoom(roomKey)
                        modelContext.delete(house)
                        try? modelContext.save()
                        isDeletingCloud = false
                        deleteResultMessage = "已删除服务器与本地房源"
                        NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                        dismiss()
                    }
                } catch {
                    await MainActor.run {
                        isDeletingCloud = false
                        cloudDeleteMessage = "删除失败：\(error.localizedDescription)，本机记录保留"
                    }
                }
            }
            return
        }
        // 未配置云端：云端本来就没有，直接删本地（原逻辑）
        guard let config = config, config.isValid else {
            MediaStore.deleteHouseDirectory(roomKey: roomKey)
            SyncFailStore.clear(roomKey)
            UnreadCloudHouseStore.clear(roomKey)
            // v2.57（P1-5）：待传队列残留一并清，防幽灵任务
            HouseMediaUploadQueue.removeRoom(roomKey)
            ctx.delete(house)
            try? ctx.save()
            NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
            BackupLogStore.log(category: "删除", action: "彻底删除（本地+云端）", result: "跳过", detail: "未配置云存储，仅删本地", room: roomKey, cloud: true)
            deleteResultMessage = wasCloud == .both ? "已删除本地 + 云端房源" : "已删除本地房源"
            return
        }
        // 配置了云端：先删云端，成功后再删本地；失败挂任务中心（带环节说明），点重试云端成功后自动清本地
        isDeletingCloud = true
        Task {
            do {
                // v1.69：日志统一一条「彻底删除（本地+云端）」
                var objCount = 0
                try await CloudBackupService.deleteHouseRemoteFolder(roomKey: roomKey, config: config, writeLog: false, reportCount: { objCount = $0 })
                // v2.38（#62）：禁止裸 try? 吞错——账本移除失败必须抛出，走下面 catch，否则账本还在、
                // 文件夹已删，下次同步会把这套「删了又回来」。404（本就没账本）deleteRemoteObject 内部已当成功。
                try await CloudHouseSync.delete(roomKey: roomKey, config: config)
                BackupLogStore.log(category: "删除", action: "彻底删除（本地+云端）", result: "成功", detail: "删除房源（云端桶文件夹\(objCount)个对象 + 云端账本已移除）", room: roomKey, cloud: true)
                // 云端删成功 → 本地删除（整个房号目录 + 分享缓存 + 状态标记 + 待传队列 + 数据库记录）
                await MainActor.run {
                    isDeletingCloud = false
                    MediaStore.deleteHouseDirectory(roomKey: roomKey)
                    SyncFailStore.clear(roomKey)
                    UnreadCloudHouseStore.clear(roomKey)
                    HouseMediaUploadQueue.removeRoom(roomKey)
                    ctx.delete(house)
                    try? ctx.save()
                    NotificationCenter.default.post(name: HouseListView.houseStoreChanged, object: nil)
                    deleteResultMessage = wasCloud == .cloud ? "已删除云端房源" : "已删除本地 + 云端房源"
                    // v2.44：删除完成系统通知
                    HouseActionNotifier.shared.send(
                        key: "delete.\(roomKey)",
                        title: "房源已删除",
                        body: "\(roomKey) 本地与云端均已删除"
                    )
                }
            } catch {
                // 云端删除失败：本地保留（防“复活”），挂任务中心重试；重试成功后 retryCloudDelete 自动清本地
                BackupLogStore.log(category: "删除", action: "彻底删除（本地+云端）", result: "失败", detail: "云端删除失败（本地保留未删）：\(String(describing: error))", room: roomKey, cloud: true)
                await MainActor.run {
                    isDeletingCloud = false
                    // v2.57（P1-3）：失败不再只 toast，挂任务中心 cloudDelete 任务可重试
                    SyncTaskCenter.shared.finish(id: SyncTaskCenter.shared.begin(kind: .cloudDelete, title: "删云端", roomKeys: [roomKey], total: 1),
                                                  success: false,
                                                  failure: "\(roomKey) 云端没删掉（本地保留未删）：\(error.localizedDescription)，点重试；云端删除成功后自动清掉本地")
                    cloudDeleteMessage = "云端删除失败：\(error.localizedDescription)。本地已保留，已挂任务中心，点重试；删除云端成功后会自动清理本地"
                    HouseActionNotifier.shared.send(
                        key: "deletefail.\(roomKey)",
                        title: "云端没删掉",
                        body: "\(roomKey) 云端删除失败（本地保留）：\(error.localizedDescription)，可到任务中心重试",
                        silent: true
                    )
                }
            }
        }
    }

    // MARK: - v1.36 需求2：成交/在租/退租 关联查看（只读）

    private func recordButton(_ title: String, kind: RecordPickKind, icon: String) -> some View {
        let count = recordCount(kind)
        return Button {
            openRecord(kind)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            // v1.37b：恢复「有记录/无记录」颜色区分（有记录深底、无记录浅底置灰），形状统一胶囊
            .background(count > 0 ? Color(.secondarySystemBackground) : Color(.tertiarySystemFill))
            .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
    }

    /// 按房号统计关联记录数（成交 / 在租 / 退租；单小区按房号精确匹配，去空格容错）
    private func recordCount(_ kind: RecordPickKind) -> Int {
        switch kind {
        case .deal: return fetchDeals(room: house.displayRoomNo).count
        case .renting: return fetchProperties(room: house.displayRoomNo, terminated: false).count
        case .terminated: return fetchProperties(room: house.displayRoomNo, terminated: true).count
        }
    }

    private func openRecord(_ kind: RecordPickKind) {
        let items: [RecordViewItem]
        switch kind {
        case .deal: items = fetchDeals(room: house.displayRoomNo).map { RecordViewItem(kind: .deal($0)) }
        case .renting: items = fetchProperties(room: house.displayRoomNo, terminated: false).map { RecordViewItem(kind: .property($0)) }
        case .terminated: items = fetchProperties(room: house.displayRoomNo, terminated: true).map { RecordViewItem(kind: .property($0)) }
        }
        if items.isEmpty { return }
        if items.count == 1 { recordViewItem = items[0] }
        else { recordPickList = items; recordPickKind = kind }
    }

    private func fetchDeals(room: String) -> [DealRecord] {
        let normalized = Self.normalizedRoom(room)
        let desc = FetchDescriptor<DealRecord>(predicate: #Predicate<DealRecord> { $0.isDeleted == false })
        // v1.17 需求1：用主容器查询（DealRecord 在主容器；HouseStore 无此模型）
        let all = (try? mainCtx.fetch(desc)) ?? []
        return all.filter { Self.normalizedRoom($0.roomNumber) == normalized }
    }

    private func fetchProperties(room: String, terminated: Bool) -> [Property] {
        let normalized = Self.normalizedRoom(room)
        let desc = FetchDescriptor<Property>(predicate: #Predicate<Property> { $0.isDeleted == false })
        // v1.17 需求1：用主容器查询（Property 在主容器）
        let all = (try? mainCtx.fetch(desc)) ?? []
        return all.filter { $0.isTerminated == terminated && Self.normalizedRoom($0.roomNumber) == normalized }
    }

    private static func normalizedRoom(_ s: String) -> String {
        s.filter { !$0.isWhitespace }
    }

    /// 分享入口（v1.21）：先做前置校验（配置 / 素材），再弹「脱敏 / 完整」选择器
    private func shareHouseCard() {
        guard let config = CosConfig.load(), config.isValid else {
            shareError = "请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS），再分享卡片链接"
            return
        }
        guard !house.mediaItems.isEmpty else {
            shareError = "这套房源还没有照片或视频，先编辑添加素材再分享"
            return
        }
        showShareModePicker = true
    }

    /// v2.26：逐个弹出视频分享面板，发完一个问是否继续
    private func presentDetailVideoBatch() {
        guard videoShareIndex < videoShareQueue.count else { return }
        detailShareStep = ShareStep(items: videoShareQueue[videoShareIndex])
    }

    /// v2.17：只分享视频——不走云端卡片（无需备案域名、无需 COS 配置）。
    /// 把本地视频转成 mp4 后以「视频素材」交给系统分享面板，微信按视频消息接收（有缩略图、可播放）；
    /// 同时在相册留一份副本，万一某个微信版本仍按文件接收，可从相册再发一次。
    private func startVideoOnlyShare() {
        ensureLocalMedia {
            let urls = house.videos
                .map { MediaStore.url(for: $0.fileName, roomKey: house.mediaRoomKey) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else {
                shareError = "这套房源没有可分享的视频"
                return
            }
            isPreparingVideo = true
            Task {
                do {
                    let files = try await VideoOnlyShare.prepareFiles(from: urls)
                    await MainActor.run {
                        isPreparingVideo = false
                        guard !files.isEmpty else {
                            shareError = "视频文件缺失，无法分享"
                            return
                        }
                        shareItems = []
                        videoShareQueue = files.map { VideoOnlyShare.movieItems(from: [$0]) }
                        videoShareIndex = 0
                        presentDetailVideoBatch()
                    }
                } catch {
                    await MainActor.run {
                        isPreparingVideo = false
                        shareError = error.localizedDescription
                    }
                }
            }
        }
    }

    /// 按模式生成分享内容并弹系统分享面板
    /// 注意：Task 内只传值类型（fileName/kind 数组 + 字符串字段），绝不直接访问 SwiftData @Model，
    /// 否则跨线程读取模型会闪退（分享闪退修复根因）
    private func startShare(mode: ShareMode) {
        // 先在主线程把所有数据拷成值类型，Task 里不再触碰 SwiftData 模型
        let files = house.mediaItems.map { ShareMediaFile(name: $0.fileName, kind: $0.kind) }
        let roomKey = house.mediaRoomKey
        let profile = CosUploader.loadShareProfile()
        let info = ShareHouseInfo(
            displayRoomNo: house.displayRoomNo,
            towerLabel: house.towerLabel,
            layout: house.layout,
            statusLabel: house.status.label,
            priceText: house.priceText,
            landlord: house.landlord,
            password: house.password,
            remark: house.remark,
            name: profile.name,
            phone: profile.phone
        )
        // 服务器模式：App 内分享——本地媒体文件 + 服务器 H5 链接 + 纯文字，直接系统面板
        if HouseServerMode.ready {
            let urls: [URL] = files.compactMap { f in
                let u = MediaStore.url(for: f.name, roomKey: roomKey)
                return FileManager.default.fileExists(atPath: u.path) ? u : nil
            }
            var items: [Any] = urls
            if let h5 = HouseRemoteClient.h5URL(roomKey: roomKey) { items.append(h5) }
            items.append(info.shareText)
            detailShareStep = ShareStep(items: items)
            Task { try? await HouseRemoteClient.shared.addShareRecord(roomKey: roomKey, channel: "app内分享", summary: info.shareText) }
            return
        }
        guard let config = CosConfig.load(), config.isValid else {
            shareError = "请先到「设置 → 房源分享 → 远程配置」填写云存储配置（腾讯云 COS），再分享卡片链接"
            return
        }
        isSharing = true
        shareProgress = 0
        Task {
            do {
                let url = try await CosUploader.shareCard(mediaFiles: files, roomKey: roomKey, info: info, mode: mode, config: config) { p in
                    Task { @MainActor in self.shareProgress = p }
                }
                await MainActor.run {
                    isSharing = false
                    shareItems = [url]
                    detailShareStep = ShareStep(items: shareItems)
                }
            } catch {
                await MainActor.run {
                    isSharing = false
                    shareError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - v1.15 需求1：一键保存（全部图片+视频保存到手机相册）

    /// 确认弹窗：统计本房源可保存的照片/视频数量，弹窗确认后写入相册
    private func confirmSaveToAlbum() {
        guard !house.mediaItems.isEmpty else {
            shareError = "这套房源还没有照片或视频，先编辑添加素材再保存"
            return
        }
        showSaveConfirm = true
    }

    /// 一键保存：全部照片 + 全部视频（不再是前 9 张）保存到系统相册。
    /// 用 Photos 框架的 performChanges 批量创建资源（add-only 权限即可，无需读图占内存）。
    private func saveAllToAlbum() {
        let imageURLs = house.photos
            .map { MediaStore.url(for: $0.fileName, roomKey: house.mediaRoomKey) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let videoURLs = house.videos
            .map { MediaStore.url(for: $0.fileName, roomKey: house.mediaRoomKey) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let urls = imageURLs + videoURLs
        guard !urls.isEmpty else {
            shareError = "照片或视频文件不存在，请重新添加"
            return
        }
        isSavingMedia = true
        Task {
            do {
                try await saveMediaUrls(urls)
                await MainActor.run {
                    isSavingMedia = false
                    saveAllTip = "已保存到相册：\(imageURLs.count) 张照片、\(videoURLs.count) 个视频"
                }
            } catch {
                await MainActor.run {
                    isSavingMedia = false
                    shareError = "保存失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 请求相册写入权限（add-only 仅需「添加照片」权限），通过后批量写入
    private func saveMediaUrls(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw BackupV5Error.invalidBackup("未获得相册权限，请到「设置 → 隐私 → 照片」允许本 App 添加照片")
        }
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                if url.pathExtension.lowercased() == "mp4" || url.pathExtension.lowercased() == "mov" || url.pathExtension.lowercased() == "m4v" {
                    let vReq = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    vReq?.creationDate = Date()
                } else {
                    let iReq = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    iReq?.creationDate = Date()
                }
            }
        }
    }
}

// MARK: - 分享值类型（v2.68 起搬至 ShareModels.swift，主 App 与分享扩展共用）

// MARK: - 照片大图预览路由

struct PhotoPreviewRoute: Identifiable {
    let id = UUID()
    let index: Int
}

// MARK: - 照片大图预览

struct PhotoPreviewView: View {
    let photos: [MediaItem]
    let startIndex: Int
    let roomKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var saveMessage: String?

    init(photos: [MediaItem], startIndex: Int, roomKey: String) {
        self.photos = photos
        self.startIndex = startIndex
        self.roomKey = roomKey
        _currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(photos.enumerated()), id: \.element.fileName) { index, media in
                    if let image = UIImage(contentsOfFile: MediaStore.url(for: media.fileName, roomKey: roomKey).path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .tag(index)
                            // 长按弹出菜单：保存到相册（和微信一致）
                            .contextMenu {
                                Button {
                                    saveImageToAlbum(image)
                                } label: {
                                    Label("保存到相册", systemImage: "square.and.arrow.down")
                                }
                            }
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(18)
            }
        }
        .statusBarHidden()
        .alert("保存到相册", isPresented: Binding(
            get: { saveMessage != nil },
            set: { if !$0 { saveMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveMessage ?? "")
        }
    }

    /// 保存当前图片到系统相册（仅新增写入权限）
    private func saveImageToAlbum(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    let imgReq = PHAssetChangeRequest.creationRequestForAsset(from: image)
                    imgReq.creationDate = Date()
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        saveMessage = success
                            ? "已保存到相册"
                            : "保存失败：\(error?.localizedDescription ?? "未知错误")"
                    }
                }
            default:
                DispatchQueue.main.async {
                    saveMessage = "没有相册写入权限，请在 设置 → 隐私与安全 → 照片 中允许"
                }
            }
        }
    }
}

// MARK: - v1.36 需求2：成交/在租/退租 只读记录查看

/// 记录查看目标（成交记录 / 收租记录），sheet(item:) 需要 Identifiable
struct RecordViewItem: Identifiable {
    let id = UUID()
    let kind: Kind
    enum Kind { case deal(DealRecord), property(Property) }

    var title: String {
        switch kind {
        case .deal(let d): return "成交记录 · \(d.roomNumber)"
        case .property(let p): return "收租记录 · \(p.roomNumber)（\(p.isTerminated ? "退租" : "在租")）"
        }
    }
}

enum RecordPickKind { case deal, renting, terminated }

/// 只读记录表单容器（按类型渲染；不可编辑）
struct RecordViewerContainer: View {
    let item: RecordViewItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch item.kind {
            case .deal(let d): DealRecordViewer(deal: d)
            case .property(let p): PropertyViewer(property: p)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
    }
}

/// 成交记录只读表单
struct DealRecordViewer: View {
    let deal: DealRecord

    private func yuan(_ v: Double) -> String {
        v == 0 ? "—" : "¥\(String(format: "%.0f", v))"
    }

    var body: some View {
        Form {
            Section("成交记录") {
                LabeledContent("房号", value: deal.roomNumber)
                LabeledContent("成交日期", value: deal.date.formatted(date: .numeric, time: .omitted))
                LabeledContent("房东", value: deal.landlord.isEmpty ? "—" : deal.landlord)
                LabeledContent("户型", value: deal.unitType.isEmpty ? "—" : deal.unitType)
            }
            Section("租约") {
                LabeledContent("起租日期", value: deal.leaseStart.formatted(date: .numeric, time: .omitted))
                LabeledContent("到期日期", value: deal.leaseEnd.formatted(date: .numeric, time: .omitted))
                LabeledContent("租期", value: deal.leaseDuration.isEmpty ? "—" : deal.leaseDuration)
                if let due = deal.rentDueDay {
                    LabeledContent("交租日", value: "每月 \(due) 号")
                }
            }
            Section("费用") {
                LabeledContent("月租金", value: yuan(deal.rent))
                LabeledContent("押金", value: yuan(deal.deposit))
                LabeledContent("业主中介费", value: yuan(deal.agentFeeLandlord))
                LabeledContent("租客中介费", value: yuan(deal.agentFeeTenant))
                LabeledContent("总费用", value: yuan(deal.totalFee))
            }
            Section("其他") {
                LabeledContent("经纪人", value: deal.manager.isEmpty ? "—" : deal.manager)
                LabeledContent("来源", value: deal.source.isEmpty ? "—" : deal.source)
                if !deal.notes.isEmpty {
                    LabeledContent("备注", value: deal.notes)
                }
            }
        }
        .navigationTitle("成交记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 收租房源（在租/退租）只读表单
struct PropertyViewer: View {
    let property: Property

    private func yuan(_ v: Double) -> String {
        v == 0 ? "—" : "¥\(String(format: "%.0f", v))"
    }

    var body: some View {
        Form {
            Section("状态") {
                LabeledContent("状态", value: property.isTerminated ? "已退租" : "在租中")
                if property.isTerminated {
                    if let date = property.terminationDate {
                        LabeledContent("退租日期", value: date.formatted(date: .numeric, time: .omitted))
                    }
                    LabeledContent("退租原因", value: property.terminationReason.isEmpty ? "—" : property.terminationReason)
                }
            }
            Section("基本信息") {
                LabeledContent("房号", value: property.roomNumber)
                LabeledContent("房东", value: property.landlord.isEmpty ? "—" : property.landlord)
                LabeledContent("户型", value: property.unitType.isEmpty ? "—" : property.unitType)
                LabeledContent("管理类型", value: property.typeDisplayName)
            }
            Section("租约与费用") {
                LabeledContent("月租金", value: yuan(property.rent))
                LabeledContent("押金", value: yuan(property.deposit))
                LabeledContent("预付", value: yuan(property.prepayment))
                LabeledContent("起租日期", value: property.leaseStart.isEmpty ? "—" : property.leaseStart)
                LabeledContent("到期日期", value: property.leaseEnd.isEmpty ? "—" : property.leaseEnd)
                LabeledContent("租期", value: property.leaseDuration.isEmpty ? "—" : property.leaseDuration)
                LabeledContent("交租日", value: "每月 \(property.rentDueDay) 号")
            }
            Section("计量底数") {
                LabeledContent("水表底数", value: "\(property.waterMeterBase)")
                LabeledContent("电表底数", value: "\(property.electricMeterBase)")
            }
            if !property.notes.isEmpty {
                Section("备注") {
                    Text(property.notes)
                }
            }
        }
        .navigationTitle("收租记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}
