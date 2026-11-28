import SwiftUI
import UIKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import Photos

// MARK: - v2.20 云端同步未读标记

/// 云端同步把房源「新增」或「被云端覆盖修改」后，卡片画红框提示；打开一次详情页即清除。
/// 存 UserDefaults（房号 key 数组），不占 SwiftData schema，升级无需迁移。
enum UnreadCloudHouseStore {
    private static let storageKey = "unread_cloud_house_keys"
    static let didChange = Notification.Name("unreadCloudHouseKeysChanged")

    static func all() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    static func isUnread(_ roomKey: String) -> Bool {
        all().contains(roomKey)
    }

    static func mark(_ roomKeys: [String]) {
        guard !roomKeys.isEmpty else { return }
        var set = all()
        for key in roomKeys where !key.isEmpty { set.insert(key) }
        UserDefaults.standard.set(Array(set), forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func clear(_ roomKey: String) {
        var set = all()
        guard set.contains(roomKey) else { return }
        set.remove(roomKey)
        UserDefaults.standard.set(Array(set), forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

// MARK: - v2.24 同步失败标记

/// 房源「推送服务器失败」的轻量标记——已收编进统一待补传登记簿 HousePendingRegistry，
/// 本类型保留为兼容门面：任务中心与卡片红点继续走原接口，底层与 HousePendingUploader 同一份集合。
enum SyncFailStore {
    static let didChange = HousePendingRegistry.didChange

    static func all() -> Set<String> { HousePendingRegistry.keys() }
    static func isFailed(_ roomKey: String) -> Bool { all().contains(roomKey) }

    static func mark(_ roomKey: String) {
        HousePendingRegistry.insert(roomKey)
    }

    static func clear(_ roomKey: String) {
        HousePendingRegistry.remove(roomKey)
    }
}

// MARK: - 主题色（合体后统一跟随主 App 深绿主题：主题绿主色 + 主题绿强调 + 统一底色）

enum AppTheme {
    /// 深绿主色（对齐主板块 themeSidebar）
    static let primary = Color.themeSidebar
    /// 统一底色（对齐主板块 themeBg）
    static let background = Color.themeBg
    /// 价格强调（对齐主板块 themeAccent）
    static let accent = Color.themeAccent
}

// MARK: - 状态徽章

struct StatusBadge: View {
    let status: HouseStatus
    var large: Bool = false

    var body: some View {
        Text(status.label)
            .font(large ? .subheadline.weight(.bold) : .caption.weight(.semibold))
            .padding(.horizontal, large ? 14 : 8)
            .padding(.vertical, large ? 7 : 3)
            .foregroundColor(.white)
            .background(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch status {
        case .available: return Color(red: 0.24, green: 0.58, blue: 0.34)
        case .rented: return Color(red: 0.47, green: 0.49, blue: 0.55)
        }
    }
}

// MARK: - 视频首帧缩略图（异步提取第一帧，避免灰色占位）

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.gray.opacity(0.2)
                    ProgressView()
                }
            }
        }
        .onAppear(perform: loadFirstFrame)
    }

    private func loadFirstFrame() {
        guard thumbnail == nil else { return }
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
            guard let cgImage else { return }
            DispatchQueue.main.async {
                thumbnail = UIImage(cgImage: cgImage)
            }
        }
    }
}

// MARK: - 媒体缩略图

struct MediaThumbView: View {
    let media: MediaItem
    let roomKey: String

    var body: some View {
        if media.kind == "video" {
            ZStack {
                VideoThumbnailView(url: MediaStore.url(for: media.fileName, roomKey: roomKey))
                // 播放三角：缩小 + 半透明，不遮挡画面
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.72))
                    .shadow(radius: 2)
            }
        } else {
            thumbImage
        }
    }

    private var thumbImage: some View {
        Group {
            if let image = UIImage(contentsOfFile: MediaStore.url(for: media.fileName, roomKey: roomKey).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                }
            }
        }
    }
}

// MARK: - v1.42 房源上传/同步动态进度（卡片底部细进度条）
// 单例发布器：保存上传媒体、云端同步下载/补传时写入进度，房源卡片按房号匹配后显示细进度条。
@MainActor
final class HouseSyncProgress: ObservableObject {
    static let shared = HouseSyncProgress()
    @Published var roomKey: String?
    @Published var direction: Direction = .upload
    @Published var progress: Double = 0     // 0...1
    @Published var label: String = ""
    /// v2.59：实时上传网速（字节/秒）；0 表示当前没有可显示的传输速度（如视频转码阶段）
    @Published var bytesPerSecond: Double = 0
    /// v2.52：无确定百分比的阶段（如视频转码），界面显示滚动条而非百分比
    @Published var indeterminate: Bool = false

    var speedText: String { UploadSpeedText.format(bytesPerSecond) }

    enum Direction {
        case upload      // 本机 → 云端（上传）
        case download    // 云端 → 本机（同步下载）
        var text: String { self == .upload ? "上传中" : "同步中" }
    }

    /// 活跃任务计数：并发上传/同步各自 begin 一次 +1，全部结束（end 归零）才清空显示。
    /// v2.4 修复：此前「保存上传媒体」与「同步云端账本」两个并发 Task 共用单例，
    /// 先完成的 Task 调 clear() 会把仍在进行中的媒体上传进度误清 → 卡片底部进度条「不见了」。
    private var activeTasks = 0
    /// v1.1：每个任务独立令牌，避免媒体下载完成后迟到的进度回调把已结束的任务重新点亮。
    private var nextTaskToken = 0
    private var activeTokens: Set<Int> = []

    /// 任务开始：计数 +1 并写入初始值；返回令牌，结束/推进时带上它可防止迟到回调复活进度条。
    @discardableResult
    func begin(roomKey: String?, direction: Direction, progress: Double = 0, label: String = "") -> Int {
        nextTaskToken += 1
        let token = nextTaskToken
        activeTokens.insert(token)
        activeTasks += 1
        self.roomKey = roomKey
        self.direction = direction
        self.progress = max(0, min(1, progress))
        self.label = label
        self.bytesPerSecond = 0
        self.indeterminate = false
        return token
    }

    /// 推进：写入最新进度。若无活跃任务则视为任务开始（自动计数 1），保证旧调用点语义兼容。
    /// 带 token 的调用若任务已结束则直接忽略，避免“下载完 4/4 后进度条还挂着”。
    func update(roomKey: String?, direction: Direction, progress: Double, label: String = "", token: Int? = nil) {
        Task { @MainActor in
            if let token {
                guard self.activeTokens.contains(token) else { return }
            } else if self.activeTasks == 0 {
                self.activeTasks = 1
            }
            self.roomKey = roomKey
            self.direction = direction
            self.progress = max(0, min(1, progress))
            self.label = label
            self.indeterminate = false
        }
    }

    /// v2.59：实时网速单独更新，不覆盖当前进度/阶段文案；0 或负值直接隐藏，避免转码时误显示 0 MB/s。
    func updateSpeed(bytesPerSecond: Double) {
        Task { @MainActor in
            self.bytesPerSecond = max(0, bytesPerSecond)
        }
    }

    /// v2.52：无确定百分比的阶段提示（转码中），显示滚动条 + 阶段文案
    /// v2.59：只有「视频转码中」走不确定进度；「图片上传中 / 视频上传中」保持确定进度，才能显示实时网速
    func updateStage(roomKey: String?, direction: Direction, label: String) {
        Task { @MainActor in
            if activeTasks == 0 { activeTasks = 1 }
            self.roomKey = roomKey
            self.direction = direction
            self.label = label
            let transcoding = label.contains("转码")
            self.indeterminate = transcoding
            if transcoding { self.bytesPerSecond = 0 }
        }
    }

    /// v2.60：视频转码的确定百分比。progress 是整条上传链路的进度（多文件时保留文件序号），
    /// fraction 是当前视频转码自身的 0...1，文案直接显示「视频转码中 42%」。
    func updateTranscodeProgress(roomKey: String?, direction: Direction, progress: Double, fraction: Double) {
        Task { @MainActor in
            if activeTasks == 0 { activeTasks = 1 }
            self.roomKey = roomKey
            self.direction = direction
            self.progress = max(0, min(1, progress.isFinite ? progress : 0))
            let pct = Int(max(0, min(1, fraction.isFinite ? fraction : 0)) * 100)
            self.label = "视频转码中 \(pct)%"
            self.indeterminate = false
            self.bytesPerSecond = 0
        }
    }

    /// 任务结束：计数 -1；仅当全部活跃任务都结束时才真正清空（并发的另一任务进度不被误清）
    /// v1.1：可带 begin 返回的 token；任务已结束时重复 end 不再重复扣计数。
    func end(token: Int? = nil) {
        Task { @MainActor in
            if let token {
                guard self.activeTokens.remove(token) != nil else { return }
            }
            self.activeTasks = max(0, self.activeTasks - 1)
            if self.activeTasks == 0 {
                self.activeTokens.removeAll()
                self.roomKey = nil
                self.label = ""
                self.bytesPerSecond = 0
                self.indeterminate = false
            }
        }
    }

    /// 直接清空（兼容旧调用；新代码统一用 begin/end）
    func clear() {
        Task { @MainActor in
            self.activeTasks = 0
            self.activeTokens.removeAll()
            self.roomKey = nil
            self.label = ""
            self.bytesPerSecond = 0
            self.indeterminate = false
        }
    }
}

// MARK: - 房源卡片
// 布局：左上封面 + 右侧信息
//  第一行：房号（加大加粗）+ 价格（加大加粗），状态徽章在右上角
//  第二行：户型 + 实拍图情况
//  第三行：密码
//  第四行：备注

struct HouseCardView: View {
    let house: House

    // v1.42：卡片底部上传/同步进度条——订阅全局进度发布器，仅当正在操作本房源时显示
    @ObservedObject private var sync = HouseSyncProgress.shared

    @State private var previewRoute: PhotoPreviewRoute? = nil
    @State private var playingVideo: MediaItem? = nil
    /// 媒体文件落盘/补下载后强制重建封面，避免视频首帧只在重启后才出现
    @State private var coverReloadToken = 0
    // v2.20：云端同步新增/修改过、还没点开详情 → 红框
    @State private var isUnread = false
    // v2.24：账本推云端失败的房源 → 标「未同步」
    @State private var syncFailed = false

    /// 本房源是否正在上传/同步（匹配房号）
    private var isSyncingThis: Bool {
        sync.roomKey == house.mediaRoomKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
            // 封面：有视频 → 视频缩略图 + 播放；无视频 → 首图，点击放大左右滑动浏览全部照片
            Button {
                openCover()
            } label: {
                coverView
                    .id(coverReloadToken)
            }
            .buttonStyle(.plain)
            .frame(width: 92, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                // 第一行：房号 + 价格（b106：自适应胶囊，不破坏原布局），最右侧是状态徽章（已租/待租）
                HStack(alignment: .center, spacing: 6) {
                    Text(house.displayRoomNo)
                        .font(.title3.weight(.bold))
                        .foregroundColor(.primary)
                        // v2.2（需求①）：房号强制不换行，过长时缩放兜底
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                    // v2.2（需求①）：租金只显示金额数字（去掉「元/月」）
                    Text(house.priceAmountText)
                        // v1.72（#3）：租金恢复 headline 加粗 + 主题色（v1.71 #96 曾改 title3，用户要求回退）
                        .font(.headline.weight(.bold))
                        .foregroundColor(AppTheme.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(AppTheme.accent.opacity(0.1))
                        .clipShape(Capsule())
                    Spacer(minLength: 0)
                    StatusBadge(status: house.status)
                }

                // 第二行：户型 + 有无实拍图，最右侧是双端标识（本地/云端/双端）
                HStack(spacing: 6) {
                    Text(house.layout.isEmpty ? "户型未填" : house.layout)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if house.hasPhoto || house.hasVideo {
                        Image(systemName: "photo.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(mediaSummary)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        Text("无实拍图")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if syncFailed {
                        Text("未同步")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.red)
                    }
                    Spacer(minLength: 0)
                    CloudBadge(status: house.cloudStatus)
                }

                // v1.19 补全：第三行 = 备注（备注与密码互换位置）
                Text("备注：\(house.remark.isEmpty ? "—" : house.remark)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // v1.19 补全：第四行 = 密码（左）+ 更新于（右下角）
                HStack(alignment: .center, spacing: 8) {
                    Text("密码：\(house.password.isEmpty ? "—" : house.password)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Text("更新于 \(HouseCardView.timeText(house.lastUpdatedAt ?? house.updatedAt))")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            .padding(.vertical, 2)
            }
            // v1.42：卡片最底部动态进度条——上传到云端 / 云端同步到本地，细条从左到右跑进度
            if isSyncingThis {
                VStack(spacing: 3) {
                    if sync.indeterminate {
                        // 转码等无确定百分比阶段：滚动条，避免看起来卡死
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(height: 4)
                            .tint(AppTheme.accent)
                            .scaleEffect(x: 1, y: 0.55, anchor: .center)
                    } else {
                        ProgressView(value: sync.progress)
                            .progressViewStyle(.linear)
                            .frame(height: 4)
                            .tint(AppTheme.accent)
                            .scaleEffect(x: 1, y: 0.55, anchor: .center)   // 压细
                    }
                    HStack {
                        if sync.indeterminate {
                            Text("\(sync.direction.text)\(sync.label.isEmpty ? "" : " · \(sync.label)")")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        } else if sync.label.hasPrefix("视频转码中") {
                            // 转码阶段 label 已带「视频转码中 NN%」，不再重复显示整条链路的百分比
                            Text("\(sync.direction.text) · \(sync.label)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        } else {
                            Text("\(sync.direction.text) \(Int(sync.progress * 100))%\(sync.speedText.isEmpty ? "" : " · \(sync.speedText)")\(sync.label.isEmpty ? "" : " · \(sync.label)")")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
        // v2.20：云端同步带来过变更、还没点开详情 → 红框提示（点开详情后自动消失）
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.85), lineWidth: isUnread ? 2 : 0)
        )
        .onAppear {
            isUnread = UnreadCloudHouseStore.isUnread(house.mediaRoomKey)
            syncFailed = SyncFailStore.isFailed(house.mediaRoomKey)
        }
        .onChange(of: house.mediaRoomKey) { _, newKey in
            isUnread = UnreadCloudHouseStore.isUnread(newKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: UnreadCloudHouseStore.didChange)) { _ in
            isUnread = UnreadCloudHouseStore.isUnread(house.mediaRoomKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: SyncFailStore.didChange)) { _ in
            syncFailed = SyncFailStore.isFailed(house.mediaRoomKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: HouseListView.houseStoreChanged)) { _ in
            // 媒体下载完成会先落文件、再广播；封面按文件重新生成，不能等重启
            coverReloadToken += 1
        }
        .fullScreenCover(item: $previewRoute) { route in
            PhotoPreviewView(photos: house.photos, startIndex: route.index, roomKey: house.mediaRoomKey)
        }
        .fullScreenCover(item: $playingVideo) { media in
            FullScreenVideoPlayer(media: media, roomKey: house.mediaRoomKey)
        }
    }

    private var mediaSummary: String {
        if house.hasPhoto && house.hasVideo { return "照片+视频" }
        return house.hasPhoto ? "有实拍图" : "有视频"
    }

    private var coverView: some View {
        Group {
            if let firstVideo = house.videos.first {
                ZStack {
                    MediaThumbView(media: firstVideo, roomKey: house.mediaRoomKey)
                    // 播放三角：缩小 + 半透明，不遮挡画面
                    Image(systemName: "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.72))
                        .shadow(radius: 2)
                }
            } else if let first = house.photos.first {
                MediaThumbView(media: first, roomKey: house.mediaRoomKey)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AppTheme.primary.opacity(0.08))
                    Image(systemName: "house.fill")
                        .font(.system(size: 26))
                        .foregroundColor(AppTheme.primary.opacity(0.35))
                }
            }
        }
    }

    /// 点封面：优先播放视频；没有视频则放大首图，可左右滑动浏览全部照片
    private func openCover() {
        if let firstVideo = house.videos.first {
            playingVideo = firstVideo
        } else if !house.photos.isEmpty {
            previewRoute = PhotoPreviewRoute(index: 0)
        }
    }

    /// v1.19：最后更新时间格式化
    static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}

// MARK: - v1.19 云端三态标识徽章（本地 / 云端 / 双端）

struct CloudBadge: View {
    let status: House.CloudStatus
    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
    private var label: String {
        switch status {
        case .local: return "本地"
        case .cloud: return "云端"
        case .both: return "双端"
        }
    }
    private var color: Color {
        switch status {
        case .local: return .gray
        case .cloud: return .blue
        case .both: return .green
        }
    }
}

// MARK: - 详情页视频条目（缩略图 + 播放三角，点击全屏播放，播放界面长按可保存视频到相册）

struct HouseDetailVideoItem: View {
    let media: MediaItem
    let roomKey: String
    @State private var playing = false

    var body: some View {
        Button {
            playing = true
        } label: {
            MediaThumbView(media: media, roomKey: roomKey)
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $playing) {
            FullScreenVideoPlayer(media: media, roomKey: roomKey)
        }
    }
}

// MARK: - 全屏视频播放器（卡片点封面播放用，长按保存视频到相册）

struct FullScreenVideoPlayer: View {
    let media: MediaItem
    let roomKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var saveMessage: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    // 长按播放界面：保存视频到相册
                    .contextMenu {
                        Button {
                            saveVideoToAlbum()
                        } label: {
                            Label("保存到相册", systemImage: "square.and.arrow.down")
                        }
                    }
            }

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
        .onAppear {
            if player == nil {
                player = AVPlayer(url: MediaStore.url(for: media.fileName, roomKey: roomKey))
                player?.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    /// 保存当前视频到系统相册（仅新增写入权限）
    private func saveVideoToAlbum() {
        let url = MediaStore.url(for: media.fileName, roomKey: roomKey)
        guard FileManager.default.fileExists(atPath: url.path) else {
            saveMessage = "视频文件不存在，无法保存"
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            switch status {
            case .authorized, .limited:
                PHPhotoLibrary.shared().performChanges {
                    // v2.30：创建时间写成「现在」，相册按时间排序，保存后直接排在最前面
                    let videoReq = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    videoReq?.creationDate = Date()
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

// MARK: - 系统分享面板（UIActivityViewController 封装，可分享到微信）

struct HouseShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - v2.26：分享面板改从最顶层控制器直呈
//
// 此前用 SwiftUI 的 .sheet 包住 UIActivityViewController。第二次弹面板时，微信这类第三方
// 分享扩展拿不到有效的呈现上下文，点了没反应（「拷贝」「存储到文件」这类系统项不受影响），
// 表现为单套偶发点微信不动、多套发完第一套后第二套点微信仍不动，App 本身没卡死。
// 现改为从当前最顶层控制器直接 present，并把「面板已关闭」改成 completion 回调驱动队列。

enum SharePresenter {
    static func present(items: [Any], completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            guard !items.isEmpty else { completion?(); return }
            // 上一次面板还挂在层级上（极少数）：先关掉再弹，避免 present 被系统静默忽略
            if let top = topViewController(), top is UIActivityViewController {
                top.dismiss(animated: false) {
                    DispatchQueue.main.async { presentNow(items: items, completion: completion) }
                }
                return
            }
            presentNow(items: items, completion: completion)
        }
    }

    private static func presentNow(items: [Any], completion: (() -> Void)?) {
        guard let host = topViewController() else { completion?(); return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { completion?() }
        }
        if let pop = vc.popoverPresentationController {
            pop.sourceView = host.view
            pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        host.present(vc, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        if let nav = top as? UINavigationController { top = nav.visibleViewController ?? nav }
        if let tab = top as? UITabBarController { top = tab.selectedViewController ?? tab }
        return top
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(AppTheme.primary.opacity(0.4))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        // v1.32：恢复撑满列表区域（maxHeight: .infinity），空态占据筛选栏以下的剩余空间并居中，
        // 首页内容块不再整体收缩被居中顶到页面中间（修复「搜索无结果时空态下沉」）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}

// MARK: - v2.17：只分享视频（微信按视频消息接收，收到即显示缩略图、点开直接播放）

/// 系统分享面板把「文件地址」交给微信时，微信只当文件附件；只有给视频素材且容器是 mp4，
/// 微信才按视频消息处理。这里统一做三件事：转 mp4（mov 也能播）、组装素材、顺手在相册留一份兜底。
///
/// v2.33 重构（修「点微信闪一下就退出、什么都没收到」）：
/// 1. 交给微信的文件必须是经过校验的标准 mp4（H.264/AAC），任何 preset 都失败时直接报错，
///    不再把 .mov 原样塞给微信——微信扩展拿到不兼容的容器会静默取消，表现就是闪一下退回。
/// 2. 转码按「转封装 → 1080p → 720p → 540p」逐级兜底，每个产物都回读校验（存在、非空、
///    有视频轨、时长 > 0），失败的产物不进队列。
///
/// v2.34 再修（对照系统相册可成功、本 App 点微信闪退）：
/// 3. 根因是闭包「延迟换手」——微信扩展跨进程回调本 App 取文件时，本 App 已被挂起，回调到不了。
///    改用 NSItemProvider(contentsOf:contentType:...) 立即注册真实文件，系统在加载前就把文件
///    复制到共享位置并走文件协调，扩展直接取件、不再回调本 App，彻底消除闪一下就退出。
enum VideoShareError: LocalizedError {
    case fileMissing(String)
    case unreadable(String)
    case noVideoTrack(String)
    case allExportsFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let name): return "视频文件不存在：\(name)"
        case .unreadable(let name): return "视频无法读取，可能已损坏：\(name)"
        case .noVideoTrack(let name): return "文件里没有视频轨道：\(name)"
        case .allExportsFailed(let name): return "视频转码失败，无法分享到微信：\(name)，可先在设置页清理后重新导入"
        }
    }
}

enum VideoOnlyShare {
    /// 本地视频 → 可直接交给系统分享面板的文件地址。
    /// v2.35：不再转码。实测所有「点微信没反应」的都是 .mov，而同一个 .mov 存到相簿后从相簿
    /// 分享到微信完全正常（微信自己会转成 mp4 存回相簿），所以相簿给微信的就是**原文件本身**。
    /// 之前的转码产物（AVAssetExportSession 转封装/重编码的 mp4）是失败源：容器重写后
    /// 微信扩展解析不了，表现为面板闪一下就什么都没收到。这里改为把原文件原样复制到
    /// App 的 Documents/ShareOutbox（和能正常分享的 .mp4 同一容器、不是随时会被回收的 tmp），
    /// 扩展名、编码、容器全不动，只做可读性校验。
    static func prepareFiles(from urls: [URL]) async throws -> [URL] {
        purgeStaleShareFiles()
        var files: [URL] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VideoShareError.fileMissing(url.lastPathComponent)
            }
            // 只校验能不能读、有没有视频轨、时长是否正常，不改文件本身
            _ = try await validateVideo(url)
            files.append(try copyForShare(url))
        }
        return files
    }

    /// 把文件原样复制到分享用固定目录（保留原扩展名、原文件名），返回可直接交给扩展的地址。
    private static func copyForShare(_ url: URL) throws -> URL {
        let dir = try shareOutboxDirectory()
        var name = url.lastPathComponent
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            name = "\(base)-\(UUID().uuidString.prefix(8)).\(ext)"
        }
        let target = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    private static func shareOutboxDirectory() throws -> URL {
        // 放 Application Support：不会被系统当临时文件回收，也不会出现在「文件」App / 备份包里
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ShareOutbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 包成「影片」类型的分享项：系统按类型标签匹配微信扩展。
    /// v2.35：类型按**真实扩展名**声明（.mov → quickTimeMovie，.mp4 → mpeg4Movie），
    /// 并把 coordinated 关掉——文件不需要 NSFileCoordinator 才能读，微信扩展内部是直接
    /// copyItemAtURL，走协调反而取不到文件。
    static func movieItems(from files: [URL]) -> [Any] {
        files.map { makeMovieProvider(for: $0) }
    }

    private static func makeMovieProvider(for url: URL) -> NSItemProvider {
        let ext = url.pathExtension.lowercased()
        let type: UTType
        if ext == "mov" || ext == "qt" {
            type = .quickTimeMovie
        } else if let t = UTType(filenameExtension: ext), t.conforms(to: .movie) {
            type = t
        } else {
            type = .movie
        }
        let provider = NSItemProvider(contentsOf: url,
                                      contentType: type,
                                      openInPlace: false,
                                      coordinated: false,
                                      visibility: .all)
        // 保留原文件名（含原扩展名 .MOV/.mp4），和相簿把原文件交给微信的做法一致
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    /// 静默在系统相册留一份（只申请新增权限）。
    static func saveToAlbumQuietly(_ urls: [URL]) async {
        do {
            // v2.30 口径：创建时间必须写成「现在」，相册按时间排序，保存后直接排在最前面。
            // 批量保存时按顺序加极小时间增量，保证同一批视频都在最前且顺序稳定。
            let base = Date()
            try await PHPhotoLibrary.shared().performChanges {
                for (index, url) in urls.enumerated() {
                    let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    request?.creationDate = base.addingTimeInterval(TimeInterval(index) * 0.01)
                }
            }
        } catch {
            // 相册保存失败不影响主流程（分享），静默忽略
        }
    }

    /// 回读校验：文件存在、非空、能加载、有视频轨、时长 > 0。
    private static func validateVideo(_ url: URL) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 0 else {
            return false
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        let duration = try await asset.load(.duration)
        guard tracks.contains(where: { $0.mediaType == .video }), duration.seconds > 0 else {
            throw VideoShareError.noVideoTrack(url.lastPathComponent)
        }
        return true
    }

    /// 清理历史分享副本（share/ 目录里的旧副本 + 历史转码残留），每次开始分享前先清一遍。
    static func purgeStaleShareFiles() {
        let temp = FileManager.default.temporaryDirectory
        if let items = try? FileManager.default.contentsOfDirectory(at: temp,
                                                                   includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("share_video_") {
                try? FileManager.default.removeItem(at: item)
            }
        }
        if let dir = try? shareOutboxDirectory(),
           let olds = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in olds {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}
