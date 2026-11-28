import Foundation
import UIKit
import AVFoundation

// MARK: - v2.68 分享卡片值类型（原在 HouseDetailView，搬至独立文件供主 App 与分享扩展共用）

struct ShareMediaFile: Hashable, Codable {
    let name: String
    let kind: String
}

struct ShareHouseInfo: Equatable, Codable {
    let displayRoomNo: String
    let towerLabel: String
    let layout: String
    let statusLabel: String
    let priceText: String
    let landlord: String
    let password: String
    let remark: String
    let name: String?   // v1.21：分享名片姓名（设置页可编辑；Optional 兼容旧版缓存 JSON，缺失时按默认值渲染）
    let phone: String?  // v1.21：分享名片电话
}

extension ShareHouseInfo {
    /// App 内分享纯文字文案（不生成 H5 链接；名片姓名/电话来自本机钥匙串）。
    var shareText: String {
        var lines: [String] = []
        lines.append("\(towerLabel)\(displayRoomNo)")
        if !layout.isEmpty { lines.append("户型：\(layout)") }
        lines.append("状态：\(statusLabel)")
        if !priceText.isEmpty { lines.append("租金：\(priceText)") }
        if !landlord.isEmpty { lines.append("房东：\(landlord)") }
        if !password.isEmpty { lines.append("密码：\(password)") }
        if !remark.isEmpty { lines.append("备注：\(remark)") }
        if let name, !name.isEmpty {
            var contact = name
            if let phone, !phone.isEmpty { contact += " \(phone)" }
            lines.append(contact)
        }
        return lines.joined(separator: "\n")
    }

    /// 旧版只发 H5 链接；保留纯文字给未接服务器/分享扩展兜底，按模式真正区分。
    func shareText(mode: ShareMode) -> String {
        var lines: [String] = []
        if mode == .full {
            lines.append("\(towerLabel)\(displayRoomNo)")
            if !layout.isEmpty { lines.append("户型：\(layout)") }
            if !priceText.isEmpty { lines.append("租金：\(priceText)") }
            if !landlord.isEmpty { lines.append("房东：\(landlord)") }
            if !password.isEmpty { lines.append("密码：\(password)") }
            if !remark.isEmpty { lines.append("备注：\(remark)") }
        } else {
            if !layout.isEmpty { lines.append("户型：\(layout)") }
            lines.append("位置：利保米兰公馆")
        }
        if let name, !name.isEmpty {
            var contact = name
            if let phone, !phone.isEmpty { contact += " \(phone)" }
            lines.append(contact)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 分享前资源准备（旧 2.72：400px 封面 / 640px 视频首帧 / 400px 方形二维码）
// 仅主 App 使用；分享扩展不链接 HouseRemoteClient/HouseServerMode，避免扩展编译找不到主工程类型。

#if !APP_EXTENSION
enum ShareAssetUploader {
    static func watermarkDict() -> [String: Any] {
        let wm = WatermarkSettingsStore.current
        return ["enabled": wm.enabled, "text": wm.text, "fontSize": wm.fontSize,
                "opacity": wm.opacity, "position": wm.position.rawValue,
                "offsetX": wm.offsetX, "offsetY": wm.offsetY]
    }

    /// 上传所选房源的封面和视频首帧；失败只影响视觉封面，不阻断分享链接创建。
    static func prepare(roomKeys: [String], mediaByRoom: [[ShareMediaFile]]) async {
        guard HouseServerMode.ready else { return }
        for (index, roomKey) in roomKeys.enumerated() {
            let media = index < mediaByRoom.count ? mediaByRoom[index] : []
            if let firstImage = media.first(where: { $0.kind != "video" }),
               let data = coverJPEG(roomKey: roomKey, fileName: firstImage.name) {
                _ = try? await HouseRemoteClient.shared.uploadShareAsset(
                    roomKey: roomKey, fileName: "cover.jpg", data: data)
            }
            for item in media where item.kind == "video" {
                if let data = videoThumbJPEG(roomKey: roomKey, fileName: item.name) {
                    _ = try? await HouseRemoteClient.shared.uploadShareAsset(
                        roomKey: roomKey, fileName: item.name + ".vthumb.jpg", data: data)
                }
            }
        }
    }

    /// 把本机二维码压缩成旧版规格（居中裁方、长边 400、q0.85）并上传，随后同步名片。
    @discardableResult
    static func ensureQRCode() async -> String? {
        guard HouseServerMode.ready, let raw = QrcodeStore.loadData(),
              let image = UIImage(data: raw), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let side = min(image.size.width, image.size.height)
        let x = (image.size.width - side) / 2
        let y = (image.size.height - side) / 2
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let cropped = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { _ in image.draw(in: CGRect(x: -x, y: -y, width: image.size.width, height: image.size.height)) }
        let scale = min(400 / side, 1)
        let target = CGSize(width: max(Int(side * scale), 1), height: max(Int(side * scale), 1))
        guard let jpeg = scaledJPEG(cropped, target: target, quality: 0.85) else { return nil }
        guard let rel = try? await HouseRemoteClient.shared.uploadQRCode(fileName: "qrcode.jpg", data: jpeg) else {
            return nil
        }
        let profile = ShareProfileStore.load()
        try? await HouseRemoteClient.shared.putProfile(name: profile.name, phone: profile.phone, qrPath: rel)
        return rel
    }

    private static func coverJPEG(roomKey: String, fileName: String) -> Data? {
        let url = MediaStore.url(for: fileName, roomKey: roomKey)
        guard let image = UIImage(contentsOfFile: url.path), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(400 / max(image.size.width, image.size.height), 1)
        let target = CGSize(width: max(Int(image.size.width * scale), 1),
                            height: max(Int(image.size.height * scale), 1))
        return scaledJPEG(image, target: target, quality: 0.72)
    }

    private static func videoThumbJPEG(roomKey: String, fileName: String) -> Data? {
        let url = MediaStore.url(for: fileName, roomKey: roomKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        let image = UIImage(cgImage: cg)
        let scale = min(640 / max(image.size.width, image.size.height), 1)
        let target = CGSize(width: max(Int(image.size.width * scale), 1),
                            height: max(Int(image.size.height * scale), 1))
        return scaledJPEG(image, target: target, quality: 0.72)
    }

    private static func scaledJPEG(_ image: UIImage, target: CGSize, quality: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
#endif
