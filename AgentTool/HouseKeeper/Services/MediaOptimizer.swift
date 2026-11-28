import Foundation
import UIKit
import AVFoundation
import CoreImage

/// 房源媒体上传前的本地压缩/转码工具。
/// 只做本地处理，不包含任何云端存储 SDK、签名或上传逻辑；
/// 处理结果由 HouseRemoteClient 走服务器 HTTP 上传。

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

// MARK: - v2.52 上传超时与看门狗


// MARK: - 图片压缩 / 视频转码

enum MediaOptimizer {
    static func scaledJPEG(_ image: UIImage, target: CGSize, quality: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.jpegData(withCompressionQuality: quality) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - 视频转码入口

    static func compressedVideoData(from url: URL, onProgress: ((Double) -> Void)? = nil) async -> Data? {
        let asset = AVURLAsset(url: url)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        guard let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first else { return nil }
        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1280, height: 720)
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let duration = (try? await asset.load(.duration)) ?? CMTime(value: 1, timescale: 1)
        let durationSeconds = CMTimeGetSeconds(duration)
        let safeDuration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : 1
        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)) ?? 30
        let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first

        let longSide = max(naturalSize.width, naturalSize.height)
        guard longSide > 0 else { return nil }
        let shrink = min(960.0 / Double(longSide), 1.0)
        var outW = Int((Double(naturalSize.width) * shrink).rounded())
        var outH = Int((Double(naturalSize.height) * shrink).rounded())
        outW -= outW % 2
        outH -= outH % 2
        outW = max(outW, 2)
        outH = max(outH, 2)

        // 码率按像素面积等比缩放：960×540 = 1.0 Mbps，更小的片子相应降低，下限 400 kbps
        let pixelRatio = min(Double(outW * outH) / Double(960 * 540), 1.0)
        let videoBitrate = max(Int(1_000_000 * pixelRatio), 400_000)
        let fps = nominalFPS > 1 ? max(Int(nominalFPS.rounded()), 15) : 30

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: true
            ] as [String: Any]
        ]

        guard let writer = try? AVAssetWriter(outputURL: temp, fileType: .mp4),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { return nil }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outW,
                kCVPixelBufferHeightKey as String: outH
            ] as [String: Any]
        )

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { return nil }
        reader.add(videoOutput)

        // 音频同样按样本参数重编码：解成 PCM → AAC 96 kbps
        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 96_000
            ]
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            out.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out)
                writer.add(input)
                audioOutput = out
                audioInput = input
            }
        }

        guard writer.startWriting(), reader.startReading() else { return nil }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)

        let cancelFlag = CancellationFlag()
        let finished: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue(label: "media.video.compress").async {
                var ok = true
                let deadline = Date().addingTimeInterval(170)
                var lastProgressAt = Date.distantPast

                func drainAudio() {
                    guard let input = audioInput, let output = audioOutput else { return }
                    while input.isReadyForMoreMediaData, let sample = output.copyNextSampleBuffer() {
                        if !input.append(sample) {
                            ok = false
                            return
                        }
                    }
                }

                while ok {
                    if cancelFlag.isCancelled {
                        ok = false
                        break
                    }
                    if Date() > deadline {
                        ok = false
                        break
                    }
                    if !videoInput.isReadyForMoreMediaData {
                        drainAudio()
                        Thread.sleep(forTimeInterval: 0.002)
                        continue
                    }
                    guard let sample = videoOutput.copyNextSampleBuffer() else { break }
                    // v2.60：按帧时间戳推进转码百分比；每 100ms 最多回调一次，避免主线程被刷屏。
                    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    let fraction = pts.isFinite ? min(max(pts / safeDuration, 0), 1) : 0
                    let now = Date()
                    if now.timeIntervalSince(lastProgressAt) >= 0.1 {
                        lastProgressAt = now
                        onProgress?(fraction)
                    }
                    autoreleasepool {
                        guard let srcBuffer = CMSampleBufferGetImageBuffer(sample),
                              let pool = adaptor.pixelBufferPool else {
                            ok = false
                            return
                        }
                        var dstRef: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstRef) == kCVReturnSuccess,
                              let dst = dstRef else {
                            ok = false
                            return
                        }
                        let sourceImage = CIImage(cvPixelBuffer: srcBuffer)
                        let scaleX = CGFloat(outW) / CGFloat(CVPixelBufferGetWidth(srcBuffer))
                        let scaleY = CGFloat(outH) / CGFloat(CVPixelBufferGetHeight(srcBuffer))
                        let scaled = sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                        ciContext.render(scaled, to: dst, bounds: outRect, colorSpace: colorSpace)
                        if !adaptor.append(dst, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample)) {
                            ok = false
                        }
                    }
                    drainAudio()
                }

                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                if ok, writer.status == .writing {
                    writer.endSession(atSourceTime: duration)
                    writer.finishWriting {
                        let completed = writer.status == .completed
                        if completed { onProgress?(1.0) }
                        cont.resume(returning: completed)
                    }
                } else {
                    writer.cancelWriting()
                    reader.cancelReading()
                    cont.resume(returning: false)
                }
            }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
        guard finished, let data = try? Data(contentsOf: temp) else { return nil }
        return data
    }

    static func uploadVideoData(from url: URL, compress: Bool, onProgress: ((Double) -> Void)? = nil) async -> Data? {
        if !compress, url.pathExtension.lowercased() == "mp4" {
            onProgress?(1.0)
            return try? Data(contentsOf: url)
        }
        if compress {
            if let data = await compressedVideoData(from: url, onProgress: onProgress) {
                return data
            }
            if Task.isCancelled { return nil }
            if let data = await exportedCompressedVideoData(from: url, onProgress: onProgress) {
                return data
            }
            if Task.isCancelled { return nil }
            return await mp4ContainerData(from: url, onProgress: onProgress)
        }
        return await mp4ContainerData(from: url, onProgress: onProgress)
    }

    /// v2.60 兜底：手动 AVAssetReader/Writer 对部分 HEVC/可变帧率素材不稳时，回到旧版系统导出预设。
    /// 系统导出会完成容器重封装与兼容性转码，宁可体积略大，也不能让视频必然上传失败。
    static func exportedCompressedVideoData(from url: URL, onProgress: ((Double) -> Void)? = nil) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        export.outputURL = temp
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await runExportWithProgress(export, from: 0, to: 1, onProgress: onProgress)
        guard export.status == .completed, let data = try? Data(contentsOf: temp) else { return nil }
        return data
    }

    /// 原质量转 mp4 封装：先 passthrough（不重编码，mov→mp4 秒级，画质零损失），
    /// 不适用时回退 AVAssetExportPresetHighestQuality 原质量重编码。全失败返回 nil，调用方保留原文件。
    static func mp4ContainerData(from url: URL, onProgress: ((Double) -> Void)? = nil) async -> Data? {
        let asset = AVURLAsset(url: url)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) {
            export.outputURL = temp
            export.outputFileType = .mp4
            await runExportWithProgress(export, from: 0, to: 0.5, onProgress: onProgress)
            if export.status == .completed, let data = try? Data(contentsOf: temp) {
                onProgress?(1.0)
                return data
            }
            if Task.isCancelled { return nil }
        }

        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) {
            export.outputURL = temp
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true
            await runExportWithProgress(export, from: 0.5, to: 1.0, onProgress: onProgress)
            if export.status == .completed, let data = try? Data(contentsOf: temp) {
                return data
            }
        }
        return nil
    }

    /// v2.60：AVAssetExportSession 没有逐帧回调，用 100ms 轮询 progress 把转码百分比送给卡片；
    /// `from/to` 用于 passthrough → 原质量重编码的两次尝试，避免回退时进度归零。
    static func runExportWithProgress(_ export: AVAssetExportSession,
                                              from start: Double,
                                              to end: Double,
                                              onProgress: ((Double) -> Void)?) async {
        let poll = Task {
            while !Task.isCancelled {
                let status = export.status
                guard status == .exporting || status == .waiting else { break }
                let p = min(max(Double(export.progress), 0), 1)
                onProgress?(start + (end - start) * p)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { cont.resume() }
            }
        } onCancel: {
            export.cancelExport()
        }
        poll.cancel()
        onProgress?(end)
    }

    static func optimizedImageDataForUpload(_ data: Data, compress: Bool) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        if !compress {
            return image.jpegData(compressionQuality: 0.85)
        }
        let maxSide: CGFloat = 1600
        let scale = min(maxSide / max(w, h), 1)
        if scale >= 1 {
            return image.jpegData(compressionQuality: 0.8)
        }
        let target = CGSize(width: max(Int(w * scale), 1), height: max(Int(h * scale), 1))
        return scaledJPEG(image, target: target, quality: 0.8)
    }

    /// 视频：统一转 mp4（H.264/AAC）。
    /// 压缩开关开 → 长边 960 / 约 1 Mbps；关 → 原质量转封装，画质不损失。
    static func optimizedVideoDataForUpload(from url: URL, compress: Bool) async -> Data? {
        await uploadVideoData(from: url, compress: compress)
    }

    /// 内存里的视频数据（旧版本已落盘的 .mov 补传路径）先落临时文件，再走同一套转码。
    static func optimizedVideoDataForUpload(from data: Data, compress: Bool) async -> Data? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? data.write(to: temp)) != nil else { return nil }
        return await optimizedVideoDataForUpload(from: temp, compress: compress)
    }
}
