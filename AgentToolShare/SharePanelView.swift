import SwiftUI

/// v2.68 分享面板：选已有房号追加媒体 / 填表新增房源。
/// v2.69：Action Extension（com.apple.ui-services）承载 → 落在共享菜单下方动作列表
/// （与「保存到美柚」并排），并可在「编辑操作」里开关/排序。
struct SharePanelView: View {
    let staged: [ShareUploadCoordinator.StagedItem]
    let onFinish: () -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator = ShareUploadCoordinator()

    private enum Phase { case loading, ready, saving, result }
    @State private var phase: Phase = .loading
    @State private var loadError: String?
    @State private var rooms: [CloudHouseRecord] = []
    @State private var tab = 0                 // 0 已有房源 / 1 新增房源
    @State private var search = ""
    @State private var selectedKey: String?
    @State private var form = ShareUploadCoordinator.NewRoomForm()
    @State private var outcome: ShareUploadCoordinator.Outcome?

    private var imageCount: Int { staged.filter { $0.kind == "image" }.count }
    private var videoCount: Int { staged.filter { $0.kind == "video" }.count }

    private var filteredRooms: [CloudHouseRecord] {
        let t = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = rooms.sorted { ($0.tower, $0.roomNo) < ($1.tower, $1.roomNo) }
        guard !t.isEmpty else { return base }
        return base.filter { $0.roomNo.contains(t) || $0.roomKey.contains(t) || $0.landlord.contains(t) }
    }

    private var selectedRoom: CloudHouseRecord? {
        rooms.first { $0.roomKey == selectedKey }
    }

    /// 新增表单房号已存在 → 提示改追加（防重复建账）
    private var duplicateRoom: CloudHouseRecord? {
        guard tab == 1, !form.roomKey.isEmpty else { return nil }
        return rooms.first { $0.roomKey == form.roomKey }
    }

    private var canSave: Bool {
        if tab == 0 { return selectedRoom != nil }
        return form.validationError == nil && duplicateRoom == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(Color(.systemBackground))
        .task { await loadAll() }
    }

    private var header: some View {
        HStack {
            Button("取消") { onCancel() }
                .disabled(phase == .saving)
            Spacer()
            Text("保存到公寓管家")
                .font(.headline)
            Spacer()
            Text("\(imageCount)图 \(videoCount)视频")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 12) {
                if let err = loadError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("重试") { Task { await loadAll() } }
                } else {
                    ProgressView("正在读取云端房源…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        case .ready:
            readyContent
        case .saving:
            savingContent
        case .result:
            resultContent
        }
    }

    private var readyContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("存到已有房源").tag(0)
                Text("新增房源").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if tab == 0 {
                TextField("搜索房号 / 房东", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                List(filteredRooms, id: \.roomKey) { room in
                    Button {
                        selectedKey = room.roomKey
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.roomKey)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("\(room.landlord.isEmpty ? "房东未填" : room.landlord) · \(room.layout.isEmpty ? "户型未填" : room.layout)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("¥\(room.price)")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(room.status == HouseStatus.rented.rawValue ? "已租" : "待租")
                                    .font(.caption2)
                                    .foregroundStyle(room.status == HouseStatus.rented.rawValue ? .orange : .green)
                            }
                            if selectedKey == room.roomKey {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                newForm
            }
        }
    }

    private var newForm: some View {
        Form {
            Section {
                Picker("座号", selection: $form.tower) {
                    Text("1座").tag(1)
                    Text("2座").tag(2)
                }
                TextField("房号（如 2334上）", text: $form.roomNo)
                TextField("租金（数字）", text: $form.priceText)
                    .keyboardType(.numberPad)
                TextField("房东", text: $form.landlord)
                TextField("户型（如 单间 / 复式）", text: $form.layout)
                TextField("密码（可空）", text: $form.password)
            } footer: {
                if let err = form.validationError {
                    Text(err).foregroundStyle(.orange)
                } else if let dup = duplicateRoom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("「\(dup.roomKey)」已存在，不能重复新增。")
                            .foregroundStyle(.orange)
                        Button("改为追加到该房") {
                            selectedKey = dup.roomKey
                            tab = 0
                        }
                    }
                } else {
                    Text("状态默认待租；保存后媒体直传上云，与 App 内新增完全一致。")
                }
            }
        }
    }

    private var savingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(coordinator.phaseText)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            List(coordinator.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: row.kind == "video" ? "video" : "photo")
                            .foregroundStyle(.secondary)
                        Text(row.fileName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        switch row.state {
                        case "success":
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case "failed":
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        default:
                            Text(row.stage).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if row.state == "uploading" {
                        ProgressView(value: row.percent)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var resultContent: some View {
        VStack(spacing: 12) {
            if let o = outcome {
                Image(systemName: o.failed == 0 && o.ledgerOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(o.failed == 0 && o.ledgerOK ? .green : .orange)
                Text(o.title)
                    .font(.headline)
                Text(o.body)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if o.success > 0 || o.failed > 0 || o.skipped > 0 {
                    Text("成功 \(o.success) · 失败 \(o.failed)" + (o.skipped > 0 ? " · 跳过 \(o.skipped)" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if o.failed > 0 {
                    Text("失败的媒体已挂到主 App「同步任务中心」，打开 App 点重试即可，文件不会丢。")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            if phase == .result {
                Spacer()
                Button("完成") { onFinish() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            } else if phase == .ready {
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    Text(tab == 0 ? "保存并上传" : "新增并上传")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                Spacer()
            } else {
                Spacer()
                Text(phase == .saving ? "上传中，请勿关闭…" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func loadAll() async {
        loadError = nil
        phase = .loading
        do {
            _ = try await CosConfig.fetchForExtension()
            rooms = try await CloudHouseSync.fetchAll(config: CosConfig.load()!)
            HouseActionNotifier.shared.prepare()
            phase = .ready
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        phase = .saving
        let existing = tab == 0 ? selectedRoom : nil
        let o = await coordinator.run(staged: staged, existing: existing, form: form)
        outcome = o
        phase = .result
    }
}
