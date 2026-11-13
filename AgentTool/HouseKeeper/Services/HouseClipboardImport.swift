import Foundation
import SwiftUI
import UIKit

// MARK: - v2.43 剪贴板房源解析（纯本地，不联网、不外传）

/// 从微信等 App 复制来的房源文字解析结果。
/// 只记录「识别到了什么」，不直接写库；回填时只填空白字段，绝不覆盖用户已输入的内容。
struct HouseClipboardParseResult: Identifiable {
    /// 供 sheet 稳定标识这一次解析结果
    let id = UUID()
    /// 规范化后的房号（带座号前缀，如 2-1418下），与表单/保存口径一致
    var roomNo: String?
    var tower: Int?
    /// 原文没写座号，按当前座号兜底（界面上要标黄提示）
    var towerGuessed = false
    var layout: String?
    var price: Int?
    var landlord: String?
    var statusRaw: String?
    var password: String?
    var remark: String?
    /// 识别成备注的原片段（押二付一、房子很差等）
    var remarkSources: [String] = []
    /// 明确忽略的片段（包物业等）
    var ignored: [String] = []

    var isMeaningful: Bool {
        roomNo != nil || price != nil || layout != nil || landlord != nil || password != nil
    }

    var fieldCount: Int {
        [roomNo != nil, layout != nil, price != nil, landlord != nil,
         statusRaw != nil, password != nil, remark != nil].filter { $0 }.count
    }
}

/// 规则解析器：按中介口语里高频出现的短格式（「1234 上层 900 12345678」）
/// 与带标签长文本（「租金900、密码66668888」）两套写法设计，识别不到就留空，不硬凑。
enum HouseClipboardParser {

    /// 与打单页一致的户型词库（长词优先，避免「单间上层」被「单间」先吃掉）
    private static let unitTypes: [String] = [
        "复式独立厨房", "中空复式", "独立厨房上层", "独立厨房下层",
        "单间上层", "单间下层", "双钥匙一套", "一房一厅", "两房一厅",
        "三房两厅", "单间", "复式", "平层", "三房", "两房"
    ]

    /// 短格式里最后一个单字房东的固定取值（一般只有这四个）
    private static let shortLandlords = ["汇", "罗", "何", "康"]

    /// 上下层独立成段时（如「1234 上层 900」），这些词已体现在房号后缀，不进备注
    private static let floorWords = ["一层", "二层", "上层", "下层", "上", "下"]

    /// 明确忽略、不进任何字段更不进备注的词
    private static let ignorePhrases = ["包物业费", "包物业"]

    /// 租态词：先判待租类，避免「未租出」被「租出」误吃
    private static let availableWords = [
        "已退租", "退租", "未出租", "未租出", "空置", "待租", "未租", "还没租",
        "可租", "可带看", "招租", "空房", "吉屋", "空出"
    ]
    private static let rentedWords = [
        "已出租", "已租出", "已租", "租出去了", "租出", "已签", "签了",
        "已成交", "成交", "已定", "已订", "已售", "租掉",
        "已收定金", "定金已收"
    ]

    /// 租赁行话：出现这些词的整段不进备注
    private static let rentJargon = [
        "出租", "招租", "直租", "放租", "转租", "合租", "整租", "租房",
        "看房", "带看", "入住", "免佣", "急租", "可看"
    ]

    private static let fieldKeywords = [
        "房东", "业主", "联系人", "密码", "备注", "户型", "租金", "月租",
        "房租", "价格", "房号", "房间", "座", "门锁"
    ]

    // MARK: 入口

    static func parse(_ raw: String, fallbackTower: Int) -> HouseClipboardParseResult {
        var result = HouseClipboardParseResult()
        let text = normalize(raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        let flat = text.replacingOccurrences(of: "\n", with: " ")

        // 1) 房号（含座号、上/下层后缀）
        if let hit = matchRoom(flat, fallbackTower: fallbackTower) {
            result.roomNo = hit.roomNo
            result.tower = hit.tower
            result.towerGuessed = hit.guessed
        }
        let roomDigits = roomDigits(of: result.roomNo)

        // 2) 租态（整段文本判，待租优先）
        result.statusRaw = matchStatus(flat)

        // 3) 租金
        result.price = matchPrice(flat, roomDigits: roomDigits)

        // 4) 密码（标签优先，再认独立数字串）
        result.password = matchPassword(flat, roomDigits: roomDigits, price: result.price)

        // 5) 户型
        result.layout = matchLayout(flat)

        // 6) 分段扫描：单字房东、带标签房东、备注、忽略词
        var remarks: [String] = []
        if let labeledRemark = matchRemark(text) { remarks.append(labeledRemark) }

        for seg in splitSegments(text) {
            let t = seg.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }

            // 6.1 包物业：整词忽略；段内剩余内容再判一次
            if let ig = ignorePhrases.first(where: { t.contains($0) }) {
                if !result.ignored.contains(ig) { result.ignored.append(ig) }
                var rest = t
                for p in ignorePhrases { rest = rest.replacingOccurrences(of: p, with: "") }
                if let rm = classifyRemark(rest) { remarks.append(rm) }
                continue
            }
            // 6.2 独立成段的上下层词：已体现在房号后缀，跳过
            if floorWords.contains(t) { continue }
            // 6.3 单字房东（汇/罗/何/康）
            if let name = matchShortLandlord(t), result.landlord == nil {
                result.landlord = name
                continue
            }
            // 6.3 带标签房东（房东：康 / 房东叫阿强）
            if let name = matchLabeledLandlord(t), result.landlord == nil {
                result.landlord = name
                continue
            }
            // 6.4 其余不沾边的成词 → 备注
            if let rm = classifyRemark(t) { remarks.append(rm) }
        }

        // 7) 业主直租/业主自租等明确说法
        if result.landlord == nil,
           firstMatch("业主\\s*(直租|自租|出租|放租|自住)", in: flat) != nil {
            result.landlord = "业主"
        }
        // 8) 规则兜底：没识别到房东一律默认业主
        if result.landlord == nil { result.landlord = "业主" }

        // 9) 备注去重后落字段
        var seen = Set<String>()
        remarks = remarks.filter { seen.insert($0).inserted }
        if !remarks.isEmpty {
            result.remarkSources = remarks
            result.remark = remarks.joined(separator: " / ")
        }
        return result
    }

    // MARK: 房号

    private struct RoomHit {
        let roomNo: String
        let tower: Int
        /// 原文没写座号，座号是兜底出来的
        let guessed: Bool
    }

    private static let floorSuffix = "(一层|二层|上层|下层|上|下)?"

    private static func matchRoom(_ text: String, fallbackTower: Int) -> RoomHit? {
        // 带明确座号的三种写法
        let towered = [
            "(?:米兰公馆|利保米兰公馆)?\\s*([12])\\s*座\\s*([0-9]{3,4})\\s*" + floorSuffix,
            "([12])\\s*-\\s*([0-9]{3,4})\\s*" + floorSuffix,
            "(?:房号|房间)\\s*[:：]?\\s*([12])\\s*-\\s*([0-9]{3,4})\\s*" + floorSuffix
        ]
        for p in towered {
            guard let g = firstMatch(p, in: text), g.count >= 2 else { continue }
            let digits = g[1].replacingOccurrences(of: " ", with: "")
            guard let tower = Int(g[0]), !digits.isEmpty else { continue }
            let suffix = g.count > 2 ? normalizeSuffix(g[2]) : ""
            return RoomHit(roomNo: "\(tower)-\(digits)\(suffix)", tower: tower, guessed: false)
        }
        // 裸房号：段首 3~4 位数字 + 可选上下层（如「1234 上层」「1234下层900...」）
        guard let re = try? NSRegularExpression(
            pattern: "(?:^|[\\s,，。；;、])([0-9]{3,4})\\s*" + floorSuffix
        ) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let digitsRange = m.range(at: 1)
            // 可选捕获组未参与匹配时，NSRegularExpression 返回 {NSNotFound, 0}；
            // 直接 substring(with:) 会抛 NSRangeException（崩溃日志 Range {9223372036854775807, 0}）。
            guard digitsRange.location != NSNotFound else { continue }
            let digits = ns.substring(with: digitsRange)
            // 排除「租金900」「密码6666」这类标签后的数字
            let preStart = max(0, m.range.location - 6)
            let prefix = ns.substring(with: NSRange(location: preStart, length: m.range.location - preStart))
            if ["租金", "月租", "房租", "价格", "密码", "门锁"].contains(where: { prefix.contains($0) }) {
                continue
            }
            let suffixRange = m.numberOfRanges > 2 ? m.range(at: 2) : NSRange(location: NSNotFound, length: 0)
            let suffix = suffixRange.location == NSNotFound ? "" : normalizeSuffix(ns.substring(with: suffixRange))
            return RoomHit(roomNo: "\(fallbackTower)-\(digits)\(suffix)",
                           tower: fallbackTower, guessed: true)
        }
        return nil
    }

    /// 一层/下层 → 下；二层/上层 → 上
    private static func normalizeSuffix(_ s: String) -> String {
        switch s {
        case "上层", "二层": return "上"
        case "下层", "一层": return "下"
        default: return s
        }
    }

    private static func roomDigits(of roomNo: String?) -> String? {
        guard let roomNo else { return nil }
        // 去掉座号前缀再取数字（"2-1418下" → "1418"），避免把座号算进房号数字里
        let core = roomNo.split(separator: "-").last.map(String.init) ?? roomNo
        var digits = ""
        for ch in core where ch.isNumber { digits.append(ch) }
        return digits
    }

    // MARK: 租金

    private static func matchPrice(_ text: String, roomDigits: String?) -> Int? {
        let patterns = [
            "(?:租金|月租|房租|价格)\\s*[:：]?\\s*[约]?\\s*([0-9]{3,5})",
            "([0-9]{3,5})\\s*(?:元/月|元每月|元/月租|元|块)\\s*(?:/月|每月)?",
            "([0-9]{3,5})\\s*/\\s*月"
        ]
        for p in patterns {
            guard let groups = firstMatch(p, in: text), let g = groups.first,
                  let value = Int(g), (300...30000).contains(value) else { continue }
            // 不把房号数字当租金
            if let roomDigits, value.description == roomDigits, p != patterns[0] { continue }
            return value
        }
        // 兜底：独立 3~4 位数字（前后不连数字，自动排除房号与 8 位密码串）
        guard roomDigits != nil else { return nil }
        if let re = try? NSRegularExpression(pattern: "(?<![0-9])([0-9]{3,4})(?![0-9])") {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let digits = ns.substring(with: m.range(at: 1))
                guard let value = Int(digits), (300...30000).contains(value) else { continue }
                if let roomDigits, digits == roomDigits { continue }
                return value
            }
        }
        return nil
    }

    // MARK: 户型

    private static func matchLayout(_ text: String) -> String? {
        let flat = text.replacingOccurrences(of: " ", with: "")
        for type in unitTypes where flat.contains(type) { return type }
        return nil
    }

    // MARK: 房东

    private static func matchShortLandlord(_ t: String) -> String? {
        let s = t.trimmingCharacters(in: .whitespaces)
        return shortLandlords.contains(s) ? s : nil
    }

    private static func matchLabeledLandlord(_ t: String) -> String? {
        let patterns = [
            "(?:房东|业主|联系人)\\s*[:：]\\s*([\\p{Han}A-Za-z]{1,4})",
            "(?:房东|业主|联系人)\\s*(?:是|叫|为)\\s*([\\p{Han}A-Za-z]{1,4})"
        ]
        for p in patterns {
            guard let g = firstMatch(p, in: t), let name = g.first, !name.isEmpty else { continue }
            // 标签后跟的是租赁行话/噪声词时不认人名
            let noise = rentJargon + ["电话", "微信", "诚心", "诚意", "联系", "本人"]
            if noise.contains(where: { name.contains($0) }) { continue }
            return name
        }
        return nil
    }

    // MARK: 租态

    private static func matchStatus(_ text: String) -> String? {
        for w in availableWords where text.contains(w) { return HouseStatus.available.rawValue }
        for w in rentedWords where text.contains(w) { return HouseStatus.rented.rawValue }
        return nil
    }

    // MARK: 密码

    private static func matchPassword(_ text: String, roomDigits: String?, price: Int?) -> String? {
        // 带标签：密码66668888 / 门锁密码：A1234#
        if let g = firstMatch(
            "(?:门锁密码|房门密码|锁密码|密码)\\s*[:：]?\\s*([0-9A-Za-z#*]{4,12})", in: text
        ), let v = g.first, !v.isEmpty {
            return v
        }
        // 无标签：独立 4~12 位数字串（如 12345678），排除房号、租金，多个候选取最长
        guard let re = try? NSRegularExpression(
            pattern: "(?<![0-9A-Za-z])([0-9]{4,12})(?![0-9A-Za-z])"
        ) else { return nil }
        let ns = text as NSString
        var candidates: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let cand = ns.substring(with: m.range(at: 1))
            if let roomDigits, cand == roomDigits { continue }
            if let price, cand == String(price) { continue }
            candidates.append(cand)
        }
        return candidates.max(by: { $0.count < $1.count })
    }

    // MARK: 备注

    private static func matchRemark(_ text: String) -> String? {
        for line in text.components(separatedBy: CharacterSet.newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("备注") else { continue }
            let rest = t.replacingOccurrences(of: "备注", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " :：-"))
            if !rest.isEmpty { return rest }
        }
        return nil
    }

    /// 与房东、户型、租态都不沾边的成词 → 备注（押二付一、房子很差等）
    private static func classifyRemark(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 40 else { return nil }
        // 必须含汉字（纯数字/纯标点/表情不要）
        guard s.range(of: "\\p{Han}", options: .regularExpression) != nil else { return nil }
        if fieldKeywords.contains(where: { s.contains($0) }) { return nil }
        if floorWords.contains(s) { return nil }
        if (availableWords + rentedWords).contains(where: { s.contains($0) }) { return nil }
        if unitTypes.contains(where: { s.contains($0) }) { return nil }
        if rentJargon.contains(where: { s.contains($0) }) { return nil }
        // 含 3~4 位连续数字的是房号/租金残留，不进备注
        if s.range(of: "[0-9]{3,4}", options: .regularExpression) != nil { return nil }
        if s.filter({ $0.isLetter || $0.isNumber }).isEmpty { return nil }
        return s
    }

    // MARK: 分段 / 工具

    /// 按空白与常见中英文标点切段（保留段内中文，便于在段内做子串识别）
    private static func splitSegments(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: " \t\n\r,，。；;、|")
        return text.components(separatedBy: separators).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }

    /// 全角转半角数字、统一破折号/冒号
    private static func normalize(_ raw: String) -> String {
        var s = ""
        for ch in raw.unicodeScalars {
            switch ch.value {
            case 0xFF10...0xFF19:
                s.unicodeScalars.append(Unicode.Scalar(ch.value - 0xFEE0)!)
            case 0x3000:
                s.append(" ")
            default:
                s.unicodeScalars.append(ch)
            }
        }
        return s
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "　", with: " ")
    }
}

// MARK: - 识别结果确认卡（快递识别式：顶部可编辑原文本，改完自动重识别）

struct HouseClipboardImportSheet: View {
    /// 进入时的原始剪贴板文本（可在顶部框内直接改）
    private let initialText: String
    /// 裸房号兜底座号
    private let fallbackTower: Int
    /// 点「填入」时把最新识别结果交回
    private let onApply: (HouseClipboardParseResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editableText: String
    @FocusState private var editorFocused: Bool

    init(rawText: String, fallbackTower: Int, onApply: @escaping (HouseClipboardParseResult) -> Void) {
        self.initialText = rawText
        self.fallbackTower = fallbackTower
        self.onApply = onApply
        _editableText = State(initialValue: rawText)
    }

    /// 文本一改就重新解析，识别结果始终与框内文字一致
    private var parsed: HouseClipboardParseResult {
        HouseClipboardParser.parse(editableText, fallbackTower: fallbackTower)
    }

    private struct Row: Identifiable {
        var id: String { label }
        let label: String
        let value: String?
        let note: String?
    }

    private func rows(of r: HouseClipboardParseResult) -> [Row] {
        [
            Row(label: "房号", value: r.roomNo,
                note: r.towerGuessed ? "原文没写座号，按当前座号填入，请核对" : nil),
            Row(label: "户型", value: r.layout, note: nil),
            Row(label: "租金", value: r.price.map { "\($0) 元/月" }, note: nil),
            Row(label: "房东", value: r.landlord, note: nil),
            Row(label: "状态", value: r.statusRaw.flatMap { HouseStatus(rawValue: $0)?.label }, note: nil),
            Row(label: "密码", value: r.password, note: nil),
            Row(label: "备注", value: r.remark, note: nil)
        ]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $editableText)
                        .frame(minHeight: 100)
                        .font(.body)
                        .focused($editorFocused)
                        .overlay(alignment: .topLeading) {
                            if editableText.isEmpty {
                                Text("粘贴或修改房源文字…")
                                    .foregroundColor(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                            }
                        }
                } header: {
                    Text("原文本（可直接修改，改完自动重新识别）")
                }

                Section {
                    ForEach(rows(of: parsed)) { row in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: row.value == nil ? "minus.circle" : "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundColor(row.value == nil ? .secondary : .green)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(row.label)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Text(row.value ?? "未识别")
                                        .font(.subheadline.weight(row.value == nil ? .regular : .semibold))
                                        .foregroundColor(row.value == nil ? .secondary : .primary)
                                }
                                if let note = row.note {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("识别结果")
                } footer: {
                    Text("只填入当前空白的字段，你已经填过的内容不会被覆盖。识别不到的项目留空，可手动补。")
                }

                if !parsed.remarkSources.isEmpty {
                    Section("将写入备注") {
                        ForEach(parsed.remarkSources, id: \.self) {
                            Text($0).font(.footnote)
                        }
                    }
                }
                if !parsed.ignored.isEmpty {
                    Section("已自动忽略") {
                        ForEach(parsed.ignored, id: \.self) {
                            Label($0, systemImage: "eye.slash")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("从剪贴板导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("填入") {
                        onApply(parsed)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!parsed.isMeaningful)
                }
            }
        }
    }
}
