import SwiftUI
import UIKit

/// 分享页水印设置与预览（只影响分享图渲染，不写原图）。
/// 不依赖对象存储或服务器配置。
struct WatermarkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var text: String
    @State private var fontSize: Double
    @State private var opacity: Double
    @State private var position: WatermarkPosition
    @State private var offsetX: Double
    @State private var offsetY: Double
    @State private var showPreview = false
    @State private var savedFlash = false

    init() {
        let wm = WatermarkSettingsStore.current
        _enabled = State(initialValue: wm.enabled)
        _text = State(initialValue: wm.text)
        _fontSize = State(initialValue: wm.fontSize)
        _opacity = State(initialValue: wm.opacity)
        _position = State(initialValue: wm.position)
        _offsetX = State(initialValue: wm.offsetX)
        _offsetY = State(initialValue: wm.offsetY)
    }

    private var draft: WatermarkSettings {
        WatermarkSettings(enabled: enabled, text: text, fontSize: fontSize, opacity: opacity, position: position, offsetX: offsetX, offsetY: offsetY)
    }

    var body: some View {
        Form {
            Section {
                // v1.41：Toggle 改用显式 Binding——set 时立即用新值写 store，
                // 不再依赖 onChange 的闭包捕获时序，开关「即拨即生效、返回即显示最新状态」
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        enabled = newValue
                        var wm = WatermarkSettingsStore.current
                        wm.enabled = newValue
                        WatermarkSettingsStore.current = wm
                    }
                )) {
                    Text("分享页加水印")
                }
            } footer: {
                Text("开启后，新生成的分享 H5 会在每张图片右下角叠加水印；已分享出去的旧链接不受影响。关闭即保存，下次分享不带水印。")
            }

            Section("水印内容") {
                TextField("水印文本", text: $text)
                    .textInputAutocapitalization(.never)
                Text("默认：\(WatermarkSettings.defaultText)").font(.footnote).foregroundStyle(.secondary)
            }

            Section("样式") {
                VStack(alignment: .leading) {
                    Text("字号：\(Int(fontSize)) px")
                    Slider(value: $fontSize, in: 10...28, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("透明度：\(Int(opacity * 100))%")
                    Slider(value: $opacity, in: 0.1...0.9, step: 0.05)
                }
                Picker("位置", selection: $position) {
                    ForEach(WatermarkPosition.allCases, id: \.self) { p in
                        Text(p.label).tag(p)
                    }
                }
                VStack(alignment: .leading) {
                    Text("水平偏移：\(Int(offsetX)) pt")
                    Slider(value: $offsetX, in: 0...40, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("垂直偏移：\(Int(offsetY)) pt")
                    Slider(value: $offsetY, in: 0...40, step: 1)
                }
            }

            Section {
                Button("预览效果") { showPreview = true }
                Button("保存") {
                    WatermarkSettingsStore.current = draft
                    savedFlash = true
                    dismiss()
                }
                Button("恢复默认样式", role: .destructive) {
                    // v1.40 第1点：只重置文本与样式，不强制打开开关（此前「清除」把开关强制开成 true，用户以为关不掉）
                    text = WatermarkSettings.defaultText
                    fontSize = 14
                    opacity = 0.5
                    position = .bottomRight
                    offsetX = 12
                    offsetY = 12
                    WatermarkSettingsStore.current = draft
                    savedFlash = true
                    dismiss()
                }
            } footer: {
                Text("恢复默认 = 重置水印文本与样式；开关状态保持不变。")
            }
        }
        .navigationTitle("分享水印")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPreview) {
            WatermarkPreviewView(settings: draft)
        }
    }
}

/// 水印预览：模拟分享页里的多张实拍图（利保米兰公馆 · 2-2334），
/// v1.17 需求4：水印叠加在【每张图片】的右下角（与真实 H5 的 mediaBlockHTML 一致），而非页面右下角
struct WatermarkPreviewView: View {
    let settings: WatermarkSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        // 模拟分享页头
                        HStack {
                            Text("利保米兰公馆").font(.headline)
                            Spacer()
                            Text("2-2334").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.white)
                        // 模拟图片区：三张实拍图，每张各自叠加水印
                        VStack(spacing: 12) {
                            sampleImageCard
                            sampleImageCard
                            sampleImageCard
                        }
                        .padding()
                        Text("水印叠加在每张图片的\(settings.position.label)（与真实分享页一致）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom)
                    }
                    .background(Color.white)
                }
            }
            .navigationTitle("水印预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 单张模拟实拍图（右下/四角按设置叠加水印）
    private var sampleImageCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.6, blue: 0.8), Color(red: 0.25, green: 0.4, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 220)
            Text("实拍图示意").font(.caption).foregroundStyle(.white.opacity(0.7)).padding(12)
            watermarkLayer
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var watermarkLayer: some View {
        if settings.enabled && !settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let x = max(0, settings.offsetX)
            let y = max(0, settings.offsetY)
            let align: Alignment = switch settings.position {
            case .bottomRight: .bottomTrailing
            case .bottomLeft: .bottomLeading
            case .topRight: .topTrailing
            case .topLeft: .topLeading
            }
            Text(settings.text)
                .font(.system(size: CGFloat(settings.fontSize), weight: .medium))
                .foregroundStyle(.white.opacity(settings.opacity))
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                .padding(.trailing, settings.position == .bottomRight || settings.position == .topRight ? CGFloat(x) : 0)
                .padding(.leading, settings.position == .bottomLeft || settings.position == .topLeft ? CGFloat(x) : 0)
                .padding(.bottom, settings.position == .bottomRight || settings.position == .bottomLeft ? CGFloat(y) : 0)
                .padding(.top, settings.position == .topRight || settings.position == .topLeft ? CGFloat(y) : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
                .allowsHitTesting(false)
        }
    }
}
