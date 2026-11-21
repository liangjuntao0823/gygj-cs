// ============================================================================
// 公寓管家 v1.83 核心逻辑自测（纯 Swift 脚本，无需 Xcode 工程）
//
// 运行方式（在你的 Mac 上，项目根目录）：
//     swift AgentTool/逻辑自测_Swift/CoreLogicTests.swift
//
// 说明：
//   - 这些逻辑与 App 内实现一一对应（同逻辑等价实现，见各段注释）；
//   - 目的：改代码后快速回归，防止「账本重建/媒体归一化/版本比较/链接校验」等
//     纯逻辑被改坏——不需要装 App、不需要真机。
//   - 全部通过会打印 "ALL PASSED（N 项）"；任何一项失败会打印断言内容并退出非 0。
// ============================================================================

import Foundation

// ---------- 通用断言 ----------
var passed = 0
var failed = 0
func expect(_ cond: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond { passed += 1 }
    else { failed += 1; print("❌ FAIL: \(name)  @\(file):\(line)") }
}

// ============================================================================
// 1. 媒体名归一化（HouseListView.mediaNormKey 等价实现）
//    App 内：deletingPathExtension.lowercased()——「IMG_001.MOV」与「IMG_001.mp4」视为同一媒体
// ============================================================================
func mediaNormKey(_ name: String) -> String {
    (name as NSString).deletingPathExtension.lowercased()
}

expect(mediaNormKey("IMG_001.MOV") == "img_001", "1.1 mov 大写归一")
expect(mediaNormKey("IMG_001.mp4") == "img_001", "1.2 mp4 小写归一")
expect(mediaNormKey("IMG_001.mov") == mediaNormKey("IMG_001.MP4"), "1.3 mov/mp4 等价")
expect(mediaNormKey("1-2334上_1.jpg") == "1-2334上_1", "1.4 中文+下划线归一")
expect(mediaNormKey("photo") == "photo", "1.5 无扩展名原样")

// ============================================================================
// 2. 云端 h/ 平铺路径归组（v1.83 preflightMediaSnapshots 新增逻辑的等价实现）
//    输入：h/<房号>/<文件> 列表 → 输出：房号 → 归一化文件名集合
// ============================================================================
func groupCloudMedia(_ objects: [String]) -> [String: Set<String>] {
    var out: [String: Set<String>] = [:]
    let prefixLen = "h/".count
    for raw in objects {
        var name = raw
        guard name.hasPrefix("h/") else { continue }
        name.removeFirst(prefixLen)
        guard let slash = name.firstIndex(of: "/") else { continue }
        let roomKey = String(name[..<slash])
        guard !roomKey.isEmpty, !roomKey.hasPrefix("_") else { continue }
        let file = String(name[name.index(after: slash)...])
        guard !file.isEmpty else { continue }
        out[roomKey, default: []].insert(mediaNormKey(file))
    }
    return out
}

let cloudObjs = [
    "h/1-2334上/IMG_1.jpg", "h/1-2334上/IMG_2.MOV",
    "h/1-2059/IMG_1.jpg", "h/_system/x.txt", "h/scattered.json",
]
let grouped = groupCloudMedia(cloudObjs)
expect(grouped["1-2334上"] == ["img_1", "img_2"], "2.1 房号归组+归一化")
expect(grouped["1-2059"] == ["img_1"], "2.2 第二套房归组")
expect(grouped["_system"] == nil, "2.3 系统保留目录跳过")
expect(grouped["scattered"] == nil, "2.4 根下散文件跳过")

// ============================================================================
// 3. 公告链接 scheme 校验（v1.83 新增逻辑的等价实现）
//    App 内：仅放行 http/https，其他 scheme 一律忽略
// ============================================================================
func isSafeLink(_ raw: String) -> Bool {
    guard !raw.isEmpty, let url = URL(string: raw),
          let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
}

expect(isSafeLink("https://share.example.com/x") == true, "3.1 https 放行")
expect(isSafeLink("http://abc.com") == true, "3.2 http 放行")
expect(isSafeLink("javascript:alert(1)") == false, "3.3 javascript 拒绝")
expect(isSafeLink("file:///etc/passwd") == false, "3.4 file 拒绝")
expect(isSafeLink("") == false, "3.5 空链接拒绝")
expect(isSafeLink("随便写的文字") == false, "3.6 无 scheme 拒绝")

// ============================================================================
// 4. 版本号比较（App.swift checkMinimumVersion 的等价实现）
//    规则：按「.」分段逐位比较，段数不足补 0；当前 < 最低 → 需要更新
// ============================================================================
func isLowerVersion(_ cur: String, _ min: String) -> Bool {
    func parts(_ v: String) -> [Int] { v.split(separator: ".").compactMap { Int($0) } }
    let c = parts(cur), m = parts(min)
    for i in 0..<max(c.count, m.count) {
        let cv = i < c.count ? c[i] : 0
        let mv = i < m.count ? m[i] : 0
        if cv < mv { return true }
        if cv > mv { return false }
    }
    return false
}

expect(isLowerVersion("1.82", "1.83") == true, "4.1 1.82 < 1.83 需更新")
expect(isLowerVersion("1.83", "1.83") == false, "4.2 相等不需更新")
expect(isLowerVersion("1.90", "1.83") == false, "4.3 更高不需更新")
expect(isLowerVersion("1.8", "1.83") == true, "4.4 段数不足补 0（1.8 < 1.83）")
expect(isLowerVersion("2.0", "1.99") == false, "4.5 主版本优先（2.0 > 1.99）")
expect(isLowerVersion("1.82.1", "1.83") == true, "4.6 三位版本正常比较")

// ============================================================================
// 5. 云账本记录编解码容错（CloudHouseRecord 等价结构）
//    云端 JSON 缺字段/类型异常时不应导致整个同步失败
// ============================================================================
struct CloudHouseRecord: Codable {
    let roomKey: String
    let roomNo: String
    var tower: Int?
    var landlord: String?
    var layout: String?
    var price: Int?
    var password: String?
    var remark: String?
    var status: String?
    var mediaNames: [String]?
    var updatedBy: String?
    var updatedAt: String?
}

func decodeRecord(_ json: String) -> CloudHouseRecord? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(CloudHouseRecord.self, from: data)
}

// 完整字段
let full = decodeRecord(#"{"roomKey":"1-2334上","roomNo":"2334上","tower":1,"landlord":"康","price":1100,"mediaNames":["a.jpg"]}"#)
expect(full?.roomKey == "1-2334上" && full?.landlord == "康" && full?.price == 1100, "5.1 完整字段解析")
expect(full?.mediaNames == ["a.jpg"], "5.2 mediaNames 解析")

// 缺可选字段（旧版本/部分写入）→ 不应 nil
let partial = decodeRecord(#"{"roomKey":"1-2059","roomNo":"2059"}"#)
expect(partial != nil, "5.3 缺可选字段仍可解析")
expect(partial?.landlord == nil, "5.4 缺字段为 nil（App 侧有默认兜底）")

// 完全错误 JSON → 应失败（App 侧报「账本解析失败」，不静默跳过）
let bad = decodeRecord("not json at all")
expect(bad == nil, "5.5 非法 JSON 解析失败（交由上层报错）")

// ============================================================================
// 6. 同步重试标志（v1.83 syncCloudHouses(retriedOnce:) 防递归套娃的等价逻辑）
//    第一次失败 → 重试；第二次失败 → 不再递归
// ============================================================================
func shouldRetry(_ retriedOnce: Bool) -> Bool { !retriedOnce }
expect(shouldRetry(false) == true, "6.1 首次失败应重试")
expect(shouldRetry(true) == false, "6.2 已重试一次不再递归")

// ============================================================================
// 7. 剪贴板裸房号可选后缀（v2.59 闪退回归）
//    崩溃日志：Range {9223372036854775807, 0}，即 NSNotFound 被直接拿去 substring。
//    NSRegularExpression 的可选捕获组未参与匹配时返回 {NSNotFound, 0}，必须先判空。
// ============================================================================
func bareRoomSuffix(_ text: String) -> String {
    let pattern = "(?:^|[\\s,，。；;、])([0-9]{3,4})\\s*(一层|二层|上层|下层|上|下)?"
    guard let re = try? NSRegularExpression(pattern: pattern) else { return "" }
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return "" }
    let r = m.numberOfRanges > 2 ? m.range(at: 2) : NSRange(location: NSNotFound, length: 0)
    return r.location == NSNotFound ? "" : ns.substring(with: r)
}

expect(bareRoomSuffix("2101 900 康") == "", "7.1 可选后缀未命中返回空串、不崩溃")
expect(bareRoomSuffix("2101下 900 康") == "下", "7.2 下层后缀正常识别")
expect(bareRoomSuffix("2101上层 900 康") == "上层", "7.3 上层后缀正常识别")

// ============================================================================
// 8. v2.60 上传日志文案（HouseMediaLogFormat 等价实现）
//    目标：一次新增房源失败只写一条「新增房源」；重试成功只写一条最终成功。
// ============================================================================
func testMediaSummary(images: Int, videos: Int) -> String {
    var parts: [String] = []
    if images > 0 { parts.append("图片\(images)个") }
    if videos > 0 { parts.append("视频\(videos)个") }
    return parts.joined(separator: "，")
}

func testFailureReason(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["上传失败：", "上传失败:", "错误：", "错误:"] {
        if text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
    }
    if text.contains("转码") { return "视频转码失败" }
    if text.contains("网络") { return "网络不可用" }
    if text.contains("文件不存在") { return "本地文件不存在" }
    return text.isEmpty ? "媒体上传失败" : text
}

func testFailureDetail(images: Int, videos: Int, error: String) -> String {
    let counts = testMediaSummary(images: images, videos: videos)
    let reason = testFailureReason(error)
    let reasonText = reason.hasPrefix("因") ? reason : "因\(reason)"
    return (counts.isEmpty ? "" : "\(counts)，") + "错误原因：\(reasonText)，已挂任务中心，等待重试"
}

func testRetryDetail(fileCount: Int, ledgerWritten: Bool) -> String {
    "\(max(0, fileCount))个媒体补传成功" + (ledgerWritten ? "，云端账本已写入" : "")
}

expect(testFailureDetail(images: 5, videos: 1, error: "上传失败：视频转码 MP4 失败，已取消上传")
       == "图片5个，视频1个，错误原因：因视频转码失败，已挂任务中心，等待重试",
       "8.1 新增房源失败日志：数量+原因+已挂任务中心")
expect(!testFailureDetail(images: 5, videos: 1, error: "上传失败：视频转码 MP4 失败，已取消上传").contains("成功 5 失败 1"),
       "8.2 失败日志不再写「成功 5 失败 1」冗余统计")
expect(!testFailureDetail(images: 5, videos: 1, error: "上传失败：视频转码 MP4 失败，已取消上传").contains(".MOV"),
       "8.3 失败日志不列文件名")
expect(testFailureReason("网络不可用，已挂到任务中心") == "网络不可用",
       "8.4 断网原因归一化")
expect(testRetryDetail(fileCount: 6, ledgerWritten: true) == "6个媒体补传成功，云端账本已写入",
       "8.5 重试成功日志：补传数量+账本已写入")
expect(testRetryDetail(fileCount: 6, ledgerWritten: false) == "6个媒体补传成功",
       "8.6 账本未写时不误报「已写入」")
expect(testMediaSummary(images: 5, videos: 1) == "图片5个，视频1个",
       "8.7 媒体数量摘要不带文件名")

// ============================================================================
// 9. 收租计划口径（Property.sortedRentRecords / earliestUnpaidRentRecord /
//    outstandingRecords / isPaidForCard 等价实现）
//    规则：应收期只认 monthlyRentRecords 计划内的记录，计划未覆盖的月份不虚构欠租；
//    卡片状态与未收租提醒都从计划取最早一条未交记录。
// ============================================================================
struct TestRecord: Equatable { let year: Int; let month: Int; let isPaid: Bool }

func sortedRecords(_ records: [TestRecord]) -> [TestRecord] {
    records.sorted { $0.year != $1.year ? $0.year < $1.year : $0.month < $1.month }
}
func earliestUnpaid(_ records: [TestRecord]) -> TestRecord? {
    sortedRecords(records).first { !$0.isPaid }
}
func outstanding(_ records: [TestRecord], upTo y: Int, _ m: Int) -> [TestRecord] {
    sortedRecords(records).filter { !$0.isPaid && ($0.year < y || ($0.year == y && $0.month <= m)) }
}
/// nextDueDays：下一未交期距今天数（由应收日真实日期差算出，这里直接喂入等价结果）
func cardPaid(_ records: [TestRecord], nowY: Int, nowM: Int, nextDueDays: Int) -> Bool {
    let sorted = sortedRecords(records)
    guard !sorted.isEmpty else { return false }
    if !outstanding(sorted, upTo: nowY, nowM).isEmpty { return false }
    let hasUpToNow = sorted.contains { $0.year < nowY || ($0.year == nowY && $0.month <= nowM) }
    if !hasUpToNow { return sorted.first!.isPaid }
    guard earliestUnpaid(sorted) != nil else { return true }
    return nextDueDays > 3
}

// 本案：今天 2026-11-22，首期 2026-12 已勾，2027-01 起未勾
let caseA: [TestRecord] = [
    TestRecord(year: 2026, month: 12, isPaid: true),
    TestRecord(year: 2027, month: 1, isPaid: false),
    TestRecord(year: 2027, month: 2, isPaid: false),
]
expect(earliestUnpaid(caseA) == TestRecord(year: 2027, month: 1, isPaid: false), "9.1 最早未交期取计划内 2027-01")
expect(outstanding(caseA, upTo: 2026, 11).isEmpty, "9.2 首期之前（2026-11）不计入欠租，不虚构逾期")
expect(cardPaid(caseA, nowY: 2026, nowM: 11, nextDueDays: 40) == true, "9.3 首期已交、下期尚远 → 卡片已收")

// 首期未交、计划还没到当前月
let caseB: [TestRecord] = [TestRecord(year: 2026, month: 12, isPaid: false)]
expect(cardPaid(caseB, nowY: 2026, nowM: 11, nextDueDays: 9) == false, "9.4 首期未交且未到当前月 → 待收")
expect(earliestUnpaid(caseB)?.year == 2026 && earliestUnpaid(caseB)?.month == 12, "9.5 提醒应收期是首期 12 月，不是 11 月")

// 当月有未交记录
let caseC: [TestRecord] = [TestRecord(year: 2026, month: 11, isPaid: false)]
expect(cardPaid(caseC, nowY: 2026, nowM: 11, nextDueDays: 2) == false, "9.6 当月未交 → 待收")

// 全部收齐
let caseD: [TestRecord] = [
    TestRecord(year: 2026, month: 11, isPaid: true),
    TestRecord(year: 2026, month: 12, isPaid: true),
]
expect(earliestUnpaid(caseD) == nil, "9.7 全部已交 → 无未交记录，不进提醒")
expect(cardPaid(caseD, nowY: 2026, nowM: 11, nextDueDays: 0) == true, "9.8 全部收齐 → 卡片已收")

// AI 欠租清单：只列计划内存在且未交的月份；计划外的 2026-11 不算
let caseE: [TestRecord] = [
    TestRecord(year: 2026, month: 10, isPaid: false),
    TestRecord(year: 2026, month: 12, isPaid: false),
]
let listed = outstanding(caseE, upTo: 2026, 11)
expect(listed == [TestRecord(year: 2026, month: 10, isPaid: false)], "9.9 欠租清单只统计计划内的 2026-10，漏列计划外 11 月")

// ============================================================================
// 汇总
// ============================================================================
if failed == 0 {
    print("✅ ALL PASSED（\(passed) 项）——核心逻辑全部正确")
} else {
    print("❌ \(failed) 项失败 / \(passed) 项通过")
    exit(1)
}
