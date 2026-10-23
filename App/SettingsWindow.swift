import CcRouterCore
import ServiceManagement
import SwiftUI

// MARK: - 草稿与校验定位（纯值类型，UI 状态）

/// 设置窗口里单个 Provider 的可编辑形态：字段全部先落在草稿上，
/// 点「保存」时才组装回 `Provider` 交 `AppModel.applySettings` →
/// `ConfigStore.save` 校验落盘；校验被拒时草稿与已保存配置都不变。
struct ProviderDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var baseUrl: String
    var apiKey: String
    /// 一行一个模型名（模型归属路由按精确匹配，无通配）。
    var modelsText: String
    var enabled: Bool

    /// 由已保存的 Provider 载入。
    init(provider: Provider) {
        id = provider.id
        name = provider.name
        baseUrl = provider.baseUrl
        apiKey = provider.apiKey
        modelsText = provider.models.joined(separator: "\n")
        enabled = provider.enabled
    }

    /// 「+」新增的空白草稿（新 id 保证与现有项在 UI 内不重复）。
    init() {
        id = UUID()
        name = ""
        baseUrl = ""
        apiKey = ""
        modelsText = ""
        enabled = true
    }

    /// 提交形态：模型按行拆分、去行首尾空白、去空行。
    var asProvider: Provider {
        Provider(
            id: id,
            name: name,
            baseUrl: baseUrl,
            apiKey: apiKey,
            models: modelsText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            enabled: enabled
        )
    }
}

/// 一个 Provider 表单内需要标红的字段集合（保存被拒时由校验错误定位而来）。
struct ProviderFieldFlags: Equatable {
    var name = false
    var baseUrl = false
    var apiKey = false
    var models = false
}

/// 把 `ConfigValidationError` 定位回「哪个 provider 的哪个字段」，
/// 供设置窗口标红（错误描述里的 provider 即提交时的草稿，按 id 对应）。
enum ValidationLocator {
    static func fieldFlags(for errors: [ConfigValidationError]) -> [UUID: ProviderFieldFlags] {
        var flags: [UUID: ProviderFieldFlags] = [:]
        func flag(_ id: UUID, _ mutate: (inout ProviderFieldFlags) -> Void) {
            mutate(&flags[id, default: ProviderFieldFlags()])
        }
        for error in errors {
            switch error {
            case .emptyModels(let provider):
                flag(provider.id) { $0.models = true }
            case .invalidBaseUrl(let provider):
                flag(provider.id) { $0.baseUrl = true }
            case .emptyApiKey(let provider):
                flag(provider.id) { $0.apiKey = true }
            case .modelClaimedByMultipleProviders(_, let providers):
                // 冲突的每个声明方都标红，便于定位。
                for provider in providers { flag(provider.id) { $0.models = true } }
            case .duplicateProviderId(let id, _):
                flag(id) { $0.name = true }
            }
        }
        return flags
    }
}

// MARK: - 设置窗口

/// 设置窗口（从 popover「设置…」打开的独立窗口）：Provider 增删改排序、
/// 监听地址端口编辑、「登录时启动」开关。所有修改先落在本地草稿，
/// 点「保存」经 `AppModel.applySettings` → `ConfigStore.save` 原子落盘热生效；
/// 校验被拒时按错误标红定位，配置与内存快照保持不变。
@MainActor
struct SettingsWindow: View {
    @State var model: AppModel

    // MARK: 草稿（提交前的全部可编辑状态）

    @State private var drafts: [ProviderDraft]
    @State private var selectedDraftID: UUID?
    @State private var listenAddress: String
    @State private var listenPort: String

    // MARK: 保存/登录项的反馈状态

    @State private var listenPortInvalid = false
    @State private var loginItemEnabled: Bool
    @State private var loginItemHint: String?
    @State private var fieldFlags: [UUID: ProviderFieldFlags] = [:]
    @State private var errorTexts: [String] = []
    @State private var savedAcknowledgement = false

    init(model: AppModel) {
        self.model = model
        let snapshot = model.snapshot
        _drafts = State(initialValue: snapshot.providers.map(ProviderDraft.init(provider:)))
        _selectedDraftID = State(initialValue: snapshot.providers.first?.id)
        _listenAddress = State(initialValue: snapshot.listen.address)
        _listenPort = State(initialValue: String(snapshot.listen.port))
        let loginItemStatus = SMAppService.mainApp.status
        _loginItemEnabled = State(initialValue: loginItemStatus == .enabled)
        if loginItemStatus == .requiresApproval {
            _loginItemHint = State(
                initialValue: "已在系统「登录项」中注册，等待在系统设置中批准。"
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerSection
            Divider()
            listenSection
            Divider()
            loginItemSection
            if !errorTexts.isEmpty { errorSection }
            footer
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 540)
        .onChange(of: drafts) { _, _ in savedAcknowledgement = false }
        .onChange(of: listenAddress) { _, _ in savedAcknowledgement = false }
        .onChange(of: listenPort) { _, _ in savedAcknowledgement = false }
    }

    // MARK: Provider 列表 + 编辑表单

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Provider").font(.headline)
                Spacer()
                Button {
                    addProvider()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新增 Provider")
                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedDraftID == nil)
                .help("删除所选 Provider")
            }

            HStack(alignment: .top, spacing: 12) {
                List(selection: $selectedDraftID) {
                    ForEach(drafts) { draft in
                        row(for: draft).tag(draft.id)
                    }
                    .onMove(perform: moveDrafts)
                    .onDelete(perform: removeDrafts)
                }
                .listStyle(.inset)
                .frame(maxHeight: 330)
                .frame(width: 190)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
                detailView
            }
        }
    }

    private func row(for draft: ProviderDraft) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(draft.name.isEmpty ? "（未命名）" : draft.name)
                .foregroundStyle(
                    fieldFlags[draft.id] == nil
                        ? AnyShapeStyle(.primary)
                        : AnyShapeStyle(.red)
                )
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("上移") { move(draft.id, by: -1) }
            Button("下移") { move(draft.id, by: 1) }
            Divider()
            Button("删除", role: .destructive) { removeDraft(id: draft.id) }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let selectedID = selectedDraftID,
           let index = drafts.firstIndex(where: { $0.id == selectedID }) {
            ProviderForm(
                draft: $drafts[index],
                flags: fieldFlags[selectedID] ?? ProviderFieldFlags()
            )
            .frame(maxWidth: .infinity, maxHeight: 330)
        } else {
            Text("选择左侧 Provider 进行编辑，或点「+」新增。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: 330)
        }
    }

    // MARK: 监听地址/端口

    private var listenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("监听").font(.headline)
            HStack {
                Text("地址")
                TextField("127.0.0.1", text: $listenAddress)
                    .frame(width: 180)
                Text("端口")
                TextField("8317", text: $listenPort)
                    .frame(width: 70)
                    .foregroundStyle(
                        listenPortInvalid
                            ? AnyShapeStyle(.red)
                            : AnyShapeStyle(.primary)
                    )
                if listenPortInvalid {
                    Text("端口须为 1–65535 的整数")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            Text("保存后如监听配置有变，网关会以新地址重启监听；端口被占用时明确报错并将主开关回落为关。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 登录时启动（SMAppService.mainApp，macOS 13+ 标准 Login Item API）

    private var loginItemSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("登录时启动", isOn: loginItemBinding)
            if let hint = loginItemHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("开启后经系统「登录项」注册本 App；登录即自动启动并恢复上次主开关状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItemEnabled },
            set: { newValue in
                loginItemEnabled = newValue
                Task { await applyLoginItem(newValue) }
            }
        )
    }

    private func applyLoginItem(_ on: Bool) async {
        do {
            if on {
                // register 只有同步 throwing 变体，无需 await。
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
            loginItemHint = nil
        } catch {
            loginItemEnabled = !on
            loginItemHint = "登录项设置失败：\(error.localizedDescription)"
        }
    }

    // MARK: 校验错误区 + 底部操作

    private var errorSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(errorTexts, id: \.self) { text in
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            if savedAcknowledgement {
                Label("已保存并热生效", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            Button("还原未保存的修改") {
                reloadFromSnapshot()
            }
            Button("保存") {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasUnsavedChanges)
        }
    }

    private var hasUnsavedChanges: Bool {
        let savedDrafts = model.snapshot.providers.map(ProviderDraft.init(provider:))
        return drafts != savedDrafts
            || listenAddress != model.snapshot.listen.address
            || Int(listenPort) != model.snapshot.listen.port
    }

    // MARK: 动作

    private func save() async {
        guard let port = Int(listenPort), (1...65535).contains(port) else {
            listenPortInvalid = true
            return
        }
        listenPortInvalid = false
        let providers = drafts.map(\.asProvider)
        let listen = ListenConfig(
            address: listenAddress.trimmingCharacters(in: .whitespaces),
            port: port
        )
        let outcome = await model.applySettings(providers: providers, listen: listen)
        switch outcome {
        case .saved:
            fieldFlags = [:]
            errorTexts = []
            savedAcknowledgement = true
        case .rejected(let errors):
            fieldFlags = ValidationLocator.fieldFlags(for: errors)
            errorTexts = errors.map(\.description)
            savedAcknowledgement = false
        case .failed(let message):
            errorTexts = [message]
            savedAcknowledgement = false
        }
    }

    private func reloadFromSnapshot() {
        drafts = model.snapshot.providers.map(ProviderDraft.init(provider:))
        selectedDraftID = drafts.first?.id
        listenAddress = model.snapshot.listen.address
        listenPort = String(model.snapshot.listen.port)
        fieldFlags = [:]
        errorTexts = []
        listenPortInvalid = false
        savedAcknowledgement = false
    }

    private func addProvider() {
        let draft = ProviderDraft()
        drafts.append(draft)
        selectedDraftID = draft.id
    }

    private func removeSelected() {
        guard let id = selectedDraftID else { return }
        removeDraft(id: id)
    }

    private func removeDraft(id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts.remove(at: index)
        if selectedDraftID == id {
            selectedDraftID = drafts.first?.id
        }
    }

    private func removeDrafts(at offsets: IndexSet) {
        drafts.remove(atOffsets: offsets)
        if let id = selectedDraftID, !drafts.contains(where: { $0.id == id }) {
            selectedDraftID = drafts.first?.id
        }
    }

    private func moveDrafts(from source: IndexSet, to destination: Int) {
        drafts.move(fromOffsets: source, toOffset: destination)
    }

    /// 上下文菜单的上移/下移（拖动排序之外的兜底入口）。
    /// `move` 的语义是「先移除再插入」：上移一位 → toOffset = i - 1，下移一位 → toOffset = i + 2。
    private func move(_ id: UUID, by offset: Int) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let target = offset < 0 ? index - 1 : index + 2
        guard target >= 0, target <= drafts.count else { return }
        drafts.move(fromOffsets: IndexSet(integer: index), toOffset: target)
    }
}

// MARK: - 单个 Provider 编辑表单

/// 名称、baseUrl、apiKey（掩码显示）、模型列表（一行一个，精确匹配无通配）。
/// `flags` 来自上次保存被拒时 `ConfigStore` 的校验定位，对应字段标红。
private struct ProviderForm: View {
    @Binding var draft: ProviderDraft
    let flags: ProviderFieldFlags

    var body: some View {
        Form {
            LabeledContent {
                highlighted(flags.name) {
                    TextField("名称", text: $draft.name)
                }
            } label: {
                labelText("名称", flagged: flags.name)
            }
            LabeledContent {
                highlighted(flags.baseUrl) {
                    TextField("https://api.example.com", text: $draft.baseUrl)
                }
            } label: {
                labelText("baseUrl", flagged: flags.baseUrl)
            }
            LabeledContent {
                highlighted(flags.apiKey) {
                    // 掩码显示：不因打开设置窗口而泄露明文（spec 17）。
                    SecureField("apiKey", text: $draft.apiKey)
                }
            } label: {
                labelText("apiKey", flagged: flags.apiKey)
            }
            LabeledContent {
                highlighted(flags.models) {
                    TextEditor(text: $draft.modelsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                }
            } label: {
                labelText("模型列表（一行一个）", flagged: flags.models)
            }
        }
        .padding(2)
    }

    private func labelText(_ text: String, flagged: Bool) -> some View {
        Text(text)
            .foregroundStyle(
                flagged ? AnyShapeStyle(.red) : AnyShapeStyle(.primary)
            )
    }

    private func highlighted<Content: View>(
        _ flagged: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        flagged ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.clear),
                        lineWidth: 1
                    )
            )
    }
}
