import Foundation

/// 配置存储（design「5.1」）：actor 持有当前不可变快照，读路径 `current()` 无锁；
/// 修改一律经 `save` —— 校验通过后原子落盘、再原子替换内存快照，
/// 校验失败不落盘、不改内存快照。
public actor ConfigStore {
    /// `save` 校验失败时抛出；`errors` 汇总全部问题，供 UI 一次性标红（任务 06/07）。
    public struct SaveError: Error, Equatable, Sendable {
        public let errors: [ConfigValidationError]
    }

    private let fileURL: URL
    private var snapshot: ConfigSnapshot

    /// - Parameters:
    ///   - fileURL: 配置文件位置（真实 App 用 `.defaultFileURL()`，测试注入临时目录）。
    ///   - snapshot: 初始内存快照；未指定时为 `ConfigSnapshot.default`。
    public init(fileURL: URL, snapshot: ConfigSnapshot = .default) {
        self.fileURL = fileURL
        self.snapshot = snapshot
    }

    /// 读取配置文件并返回持有该快照的 store；文件不存在视为首次启动，
    /// 得到默认快照（主开关关闭、监听 `127.0.0.1:8317`）。
    public static func load(from fileURL: URL) throws -> ConfigStore {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ConfigStore(fileURL: fileURL)
        }
        let snapshot = try JSONDecoder().decode(ConfigSnapshot.self, from: data)
        return ConfigStore(fileURL: fileURL, snapshot: snapshot)
    }

    /// 真实配置文件位置：Application Support/cc-router-mac/config.json（design「数据设计」）。
    public static func defaultFileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("cc-router-mac", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// 当下实时快照：请求入口取它并全程使用（design 5.1 热生效）。
    public func current() -> ConfigSnapshot {
        snapshot
    }

    /// 保存配置：校验失败 → 抛出 `SaveError`，不落盘、不改内存快照；
    /// 校验通过 → 原子落盘（临时文件 + rename，权限 `0600`）→ 原子替换内存快照。
    public func save(_ newSnapshot: ConfigSnapshot) throws {
        let errors = newSnapshot.validationErrors()
        if !errors.isEmpty {
            throw SaveError(errors: errors)
        }
        try persist(newSnapshot)
        snapshot = newSnapshot
    }

    /// 崩溃不产生半写文件：写到同目录临时文件，rename 原子替换目标；
    /// apiKey 明文存 `0600`（design「数据设计」）。
    private func persist(_ snapshot: ConfigSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory
            .appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        // replaceItemAt 在个别文件系统上可能沿用被替换项的权限，落位后重申 0600。
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
