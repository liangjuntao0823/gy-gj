import Foundation
import SwiftData

/// 房源状态：纯房源管理，只有「待租 / 已租」两档，由用户手动切换
enum HouseStatus: String, Codable, CaseIterable, Identifiable {
    case available = "available"
    case rented = "rented"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .available: return "待租"
        case .rented: return "已租"
        }
    }
}

/// 房源模型
@Model
final class House {
    @Attribute(.unique) var id: UUID
    var roomNo: String
    var tower: Int              // 1 = 1座，2 = 2座
    var landlord: String
    var layout: String
    var price: Int
    var password: String
    var remark: String
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date
    /// 软删除标记（语义明确，勿作他用）：
    ///  - nil / false = 正常房源（旧版本数据库没有此列，nil 一律按未删除处理）
    ///  - true = 已移入回收站：记录与媒体文件都保留，仅在列表/查重/同步中被过滤；配合 deletedAt 记录入站时间
    ///  - 只有在回收站里「彻底删除」才会物理移除该模型及其级联媒体
    /// v1.8：改为可选字段——旧版本数据库没有此列，可选属性添加无需迁移、直接兼容（iOS 17 自动迁移对
    /// 带 unique 属性的模型加「非可选」字段会打不开库，这是 v1.7 存储异常的根因）
    var isDeleted: Bool?
    /// 移入回收站的时间（仅 isDeleted == true 时有意义；恢复房源时清空）
    var deletedAt: Date?
    /// v1.19：云端状态——该房源在云端的存在情况
    ///  local = 仅本地（尚未上传 / 云端已删）
    ///  cloud = 纯云端（本机无完整数据，来自另一台设备）
    ///  both  = 本地 + 云端双份（已同步过）
    /// 可选字段避免旧库迁移问题（与 isDeleted 同策略）；nil 视为 local
    var cloudStatusRaw: String?
    /// v1.19：最后更新时间（首次录入取录入时间；改已租/待租状态或编辑时刷新）
    var lastUpdatedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \MediaItem.house)
    var mediaItems: [MediaItem]

    /// 是否已移入回收站（旧数据无此字段 → nil 视为未删除）
    var isTrashed: Bool { isDeleted ?? false }

    var status: HouseStatus {
        get { HouseStatus(rawValue: statusRaw) ?? .available }
        set { statusRaw = newValue.rawValue }
    }

    init(
        roomNo: String = "",
        tower: Int = 1,
        landlord: String = "",
        layout: String = "",
        price: Int = 0,
        password: String = "",
        remark: String = "",
        status: HouseStatus = .available
    ) {
        self.id = UUID()
        self.roomNo = roomNo
        self.tower = tower
        self.landlord = landlord
        self.layout = layout
        self.price = price
        self.password = password
        self.remark = remark
        self.statusRaw = status.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isDeleted = false
        self.deletedAt = nil
        self.cloudStatusRaw = nil
        self.lastUpdatedAt = Date()
        self.mediaItems = []
    }
}

// MARK: - v1.19 云端状态辅助

extension House {
    /// 房源云端三态
    enum CloudStatus: String {
        case local = "local"   // 仅本地
        case cloud = "cloud"   // 纯云端
        case both = "both"     // 本地 + 云端双份
    }
    var cloudStatus: CloudStatus {
        get { CloudStatus(rawValue: cloudStatusRaw ?? "") ?? .local }
        set { cloudStatusRaw = newValue.rawValue }
    }
    /// 是否已存在于云端（云端或双端都算）
    var isInCloud: Bool { cloudStatus == .cloud || cloudStatus == .both }
}

/// 房源媒体（照片 / 视频），文件存 Documents/Media，模型只存文件名
@Model
final class MediaItem {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var kind: String            // "image" / "video"
    var house: House?

    init(fileName: String, kind: String) {
        self.id = UUID()
        self.fileName = fileName
        self.kind = kind
    }
}

// MARK: - 展示与分享辅助

extension House {
    var towerLabel: String { "\(tower)座" }

    /// 剥掉房号上已有的任何座号前缀（1- / 2-，含全角 1－ / 2－，可重复叠了多层），只留纯房号。
    /// v2.37（#29）：跨座迁移的脏数据（如 roomNo 已带「1-」又被归到 2 座）先靠它剥干净，
    /// 再按当前座号重拼，从根上杜绝「2-1-xxxx」这种双前缀。
    private var roomNoWithoutTowerPrefix: String {
        var s = roomNo.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["2-", "1-", "2－", "1－"]
        var changed = true
        while changed {
            changed = false
            for p in prefixes where s.hasPrefix(p) {
                s = String(s.dropFirst(p.count))
                changed = true
            }
        }
        return s
    }

    /// 房号展示：1 座、2 座都保留座号前缀（恢复清单/媒体文件夹均带 1-/2- 前缀，显示保持一致）。
    /// v2.37（#29）：先剥旧前缀再按当前 tower 重拼，数据再脏也只会有一个前缀，不会叠成「2-1-xxxx」。
    var displayRoomNo: String {
        (tower == 2 ? "2-" : "1-") + roomNoWithoutTowerPrefix
    }

    /// 媒体存储目录名（1 座带「1-」前缀，与 2 座「2-」对称；与用户文件夹/清单命名一致）。
    /// v2.37（#29）：与 displayRoomNo 同一套「先剥后拼」规则，保证目录名与显示房号口径一致。
    var mediaRoomKey: String {
        let raw = (tower == 2 ? "2-" : "1-") + roomNoWithoutTowerPrefix
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\u{22}<>")
        return raw.components(separatedBy: illegal).joined(separator: "-")
    }

    /// 房号数字串（兼容「1-2334」「2-1006」「634上」「2355下」等写法：
    /// 从末尾开始提取第一段连续数字，忽略座号前缀与「上/下/层」等后缀文字）
    private var sortDigits: String {
        var collected = ""
        for ch in roomNo.reversed() {
            if ch.isNumber {
                collected.append(ch)
            } else if !collected.isEmpty {
                break
            }
        }
        return String(collected.reversed())
    }

    /// 楼层（用于首页按「座号 + 楼层 + 房号」升序排序）：
    ///  - 3 位房号（如 634）：第 1 位是楼层 → 6楼34号
    ///  - 4 位房号（如 1420）：前 2 位是楼层 → 14楼20号
    /// 统一规则：数字最后 2 位是房号，前面剩余位是楼层
    var floorNumber: Int {
        let s = sortDigits
        guard s.count >= 3 else { return Int(s) ?? 0 }
        return Int(s.dropLast(2)) ?? 0
    }

    /// 房号数字（数字部分最后 2 位，如 634 → 34，1420 → 20）
    var roomNumber: Int {
        let s = sortDigits
        guard s.count >= 2 else { return Int(s) ?? 0 }
        return Int(s.suffix(2)) ?? 0
    }

    /// v2.36（#32）：租金为 0 时不再显示「0元/月」，改为「租金面议」，避免误导租客
    var priceText: String { price > 0 ? "\(price)元/月" : "租金面议" }

    /// 卡片租金展示（v2.2：只显示金额数字，不带「元/月」；分享文本仍用 priceText）
    var priceAmountText: String { "\(price)" }

    var hasPhoto: Bool { mediaItems.contains { $0.kind == "image" } }
    var hasVideo: Bool { mediaItems.contains { $0.kind == "video" } }
    var photos: [MediaItem] { mediaItems.filter { $0.kind == "image" } }
    var videos: [MediaItem] { mediaItems.filter { $0.kind == "video" } }

    /// 分享给客户的核心信息：房号 + 租金 + 房东
    /// v2.37（#31）：房号统一走 displayRoomNo，和完整版文案/卡片同一口径，不再自己拼「towerLabel+roomNo」
    /// （旧写法遇到跨座脏数据会出「2座1-xxxx」双前缀）。
    var briefShareText: String {
        var text = "【房源】\(displayRoomNo)  \(priceText)"
        if !landlord.isEmpty { text += "  房东：\(landlord)" }
        return text
    }

    /// 完整房源信息
    var fullShareText: String {
        var lines: [String] = []
        lines.append("房源信息")
        lines.append("房号：\(displayRoomNo)")
        lines.append("座号：\(towerLabel)")
        lines.append("房东：\(landlord.isEmpty ? "—" : landlord)")
        lines.append("户型：\(layout.isEmpty ? "—" : layout)")
        lines.append("价格：\(priceText)")
        if !password.isEmpty { lines.append("密码：\(password)") }
        if !remark.isEmpty { lines.append("备注：\(remark)") }
        lines.append("状态：\(status.label)\(status == .available ? "（可带看）" : "")")
        return lines.joined(separator: "\n")
    }
}
