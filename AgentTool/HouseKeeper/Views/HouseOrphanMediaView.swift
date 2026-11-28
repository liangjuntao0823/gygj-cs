//
//  HouseOrphanMediaView.swift
//  公寓管家 · 设置 → 存储与清理 → 服务器孤儿媒体
//
//  对应服务器 GET/DELETE /api/house/media-orphans：
//  - 只扫 media_v2/houses/，删除前服务器二次核对 media_refs；
//  - 默认跳过 1 小时内新文件，避免刚上传、事务未提交的媒体被误删；
//  - 先列完整名单（路径/大小/时间），用户确认后才删，不静默清空。
//

import SwiftUI

struct HouseOrphanMediaView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var files: [RemoteOrphanMedia] = []
    @State private var totalBytes = 0
    @State private var minAgeSeconds = 3600
    @State private var loading = false
    @State private var deleting = false
    @State private var scanned = false
    @State private var errorText: String?
    @State private var resultText: String?
    @State private var showDeleteConfirm = false

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }

    var body: some View {
        Form {
            Section {
                Text("扫描服务器 media_v2/houses 下没有被任何房源引用的图片/视频。默认跳过最近 1 小时的新文件；删除前服务器会再核对一遍引用，已引用的不会删。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button {
                    Task { await scan() }
                } label: {
                    HStack {
                        Label(loading ? "正在扫描…" : (scanned ? "重新扫描" : "扫描服务器孤儿媒体"),
                              systemImage: "magnifyingglass")
                        Spacer()
                        if loading { ProgressView() }
                    }
                }
                .disabled(loading || deleting)
            }

            if let errorText {
                Section { Text(errorText).foregroundColor(.red).font(.footnote) }
            }
            if let resultText {
                Section { Text(resultText).font(.footnote) }
            }

            if scanned {
                Section {
                    HStack {
                        Text("孤儿文件")
                        Spacer()
                        Text("\(files.count) 个 · \(sizeText)").foregroundColor(.secondary)
                    }
                    if files.isEmpty {
                        Text("没有发现孤儿媒体").foregroundColor(.secondary)
                    }
                }
                if !files.isEmpty {
                    Section("名单（确认后再删）") {
                        ForEach(files) { f in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.objectKey)
                                    .font(.caption)
                                    .lineLimit(2)
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file)) · \(f.modifiedAt)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Label(deleting ? "正在删除…" : "删除以上 \(files.count) 个孤儿文件",
                                      systemImage: "trash")
                                Spacer()
                                if deleting { ProgressView() }
                            }
                        }
                        .disabled(deleting)
                    }
                }
            }
        }
        .navigationTitle("服务器孤儿媒体")
        .alert("确认删除服务器文件？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { Task { await deleteAll() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(files.count) 个文件，共 \(sizeText)。删除后不可恢复；服务器会再核对引用，正在被房源使用的文件不会删。")
        }
    }

    @MainActor
    private func scan() async {
        loading = true
        errorText = nil
        resultText = nil
        defer { loading = false }
        do {
            let res = try await HouseRepository.shared.listOrphanMedia()
            files = res.files
            totalBytes = res.totalBytes
            minAgeSeconds = res.minAgeSeconds
            scanned = true
        } catch {
            errorText = "扫描失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func deleteAll() async {
        deleting = true
        errorText = nil
        resultText = nil
        defer { deleting = false }
        do {
            let res = try await HouseRepository.shared.deleteOrphanMedia(
                objectKeys: files.map { $0.objectKey }, minAge: minAgeSeconds)
            resultText = "已删除 \(res.deleted.count) 个；跳过 \(res.skipped.count) 个（已引用/太新/已不存在）"
            await scan()
        } catch {
            errorText = "删除失败：\(error.localizedDescription)"
        }
    }
}
