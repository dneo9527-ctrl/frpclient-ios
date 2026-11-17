import Combine
import Foundation
import Network
import Security
#if !FRPCLIENT_TESTS
import Frpclib
#endif

enum TunnelPhase: Equatable {
    case stopped, connecting, running, ready, apiUnavailable, reconnecting, stopping, failed
    var title: String {
        switch self {
        case .stopped: return "未连接"
        case .connecting: return "正在连接"
        case .running: return "隧道任务运行中"
        case .apiUnavailable: return "模型接口暂不可用"
        case .ready: return "模型接口可用"
        case .reconnecting: return "正在恢复连接"
        case .stopping: return "正在停止"
        case .failed: return "连接失败"
        }
    }
}

enum ConfigStorageState: Equatable {
    case available, temporarilyUnavailable, corrupt, unsupportedVersion
}

private struct ConfigRecoverySnapshot: Codable, Equatable {
    var schemaVersion = 1
    var protected: String
    var legacy: String?
}

struct ConnectionProfile: Codable, Equatable {
    var serverAddr = ""
    var serverPort = "7000"
    var token = ""
    var secretKey = ""
    var visitorName = "ollama-visitor-ios"
    var serverName = "ollama"
    var bindPort = "11434"
    var serverUser = ""
    var useSystemCA = false
    var trustedCaFile = ""
    var isComplete: Bool {
        !serverAddr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !token.isEmpty && !secretKey.isEmpty &&
        Int(serverPort).map { (1...65535).contains($0) } == true &&
        Int(bindPort).map { (1...65535).contains($0) } == true
    }
}

private struct StoredProfile: Codable, Equatable {
    var configText: String
    var profile: ConnectionProfile
    var formMode: Bool
    var isCustomConfig: Bool
}

private struct StoredProfiles: Codable, Equatable {
    static let currentSchema = 1
    var schemaVersion = Self.currentSchema
    var selectedSlot = 0
    var slots: [StoredProfile]

    static func empty(sampleConfig: String) -> StoredProfiles {
        let empty = StoredProfile(configText: sampleConfig, profile: ConnectionProfile(), formMode: true, isCustomConfig: false)
        return StoredProfiles(slots: [empty, empty, empty])
    }

    var isValid: Bool {
        schemaVersion == Self.currentSchema && slots.count == 3 && (0..<3).contains(selectedSlot)
    }
}

struct ConfigInfo: Codable {
    var serverAddr: String
    var serverPort: Int
    var token: String
    var secretKey: String
    var visitorName: String
    var serverName: String
    var bindAddr: String
    var bindPort: Int
    var testURL: String
    var tlsVerified: Bool
    var useSystemCA: Bool
    var trustedCaFile: String
    var serverUser: String
    var customConfig: Bool
    var profile: ConnectionProfile {
        ConnectionProfile(serverAddr: serverAddr == "example.invalid" ? "" : serverAddr,
                          serverPort: String(serverPort), token: token, secretKey: secretKey,
                          visitorName: visitorName, serverName: serverName,
                          bindPort: String(bindPort), serverUser: serverUser,
                          useSystemCA: useSystemCA, trustedCaFile: trustedCaFile)
    }
}

protocol FrpRuntime: AnyObject {
    var version: String { get }
    func configInfo(_ text: String) throws -> ConfigInfo
    func buildConfig(_ json: String) throws -> String
    func start(_ text: String) throws
    func stop()
    var isRunning: Bool { get }
    var isStopping: Bool { get }
    var lastError: String { get }
    func setLogHandler(_ handler: @escaping (String) -> Void)
}

protocol ConfigStore {
    func load() throws -> String?
    func save(_ value: String) throws
    func loadRecovery() throws -> String?
    func saveRecovery(_ value: String) throws
}
extension ConfigStore {
    // Old/injected stores must opt into recovery; unsupported storage never
    // permits a destructive fallback without a verified protected backup.
    func loadRecovery() throws -> String? { throw ConfigStoreError.recoveryUnavailable }
    func saveRecovery(_ value: String) throws { throw ConfigStoreError.recoveryUnavailable }
}
enum ConfigStoreError: Error { case keychain(OSStatus), invalidData, recoveryUnavailable, recoveryConflict }

/// Advanced settings may also contain secrets, so protect the entire TOML.
final class KeychainConfigStore: ConfigStore {
    private func identity(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.doc.frpclient.configuration",
         kSecAttrAccount as String: account]
    }
    func load() throws -> String? { try load(account: "frpcConfigTOML") }
    func save(_ value: String) throws { try save(value, account: "frpcConfigTOML") }
    func loadRecovery() throws -> String? { try load(account: "frpcConfigRecoveryV1") }
    func saveRecovery(_ value: String) throws { try save(value, account: "frpcConfigRecoveryV1") }

    private func load(account: String) throws -> String? {
        var query = identity(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ConfigStoreError.keychain(status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw ConfigStoreError.invalidData
        }
        return text
    }
    private func save(_ value: String, account: String) throws {
        let query = identity(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConfigStoreError.keychain(status) }
    }
}

#if !FRPCLIENT_TESTS
private final class GoRuntime: FrpRuntime {
    private let listener = FrpLogListener()
    var version: String { FrpclibVersion() }
    var isRunning: Bool { FrpclibIsRunning() }
    var isStopping: Bool { FrpclibIsStopping() }
    var lastError: String { FrpclibLastError() }
    func configInfo(_ text: String) throws -> ConfigInfo {
        var error: NSError?
        let result = FrpclibConfigInfo(text, &error)
        if let error { throw error }
        return try JSONDecoder().decode(ConfigInfo.self, from: Data(result.utf8))
    }
    func buildConfig(_ json: String) throws -> String {
        var error: NSError?
        let result = FrpclibBuildVisitorConfig(json, &error)
        if let error { throw error }
        return result
    }
    func start(_ text: String) throws {
        var error: NSError?
        guard FrpclibStart(text, &error) else {
            throw error ?? NSError(domain: "FrpClient", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "start failed"])
        }
    }
    func stop() { FrpclibStop() }
    func setLogHandler(_ handler: @escaping (String) -> Void) {
        listener.onLog = handler
        FrpclibSetLogListener(listener)
    }
}
private final class FrpLogListener: NSObject, FrpclibLogListenerProtocol {
    var onLog: ((String) -> Void)?
    func log(_ msg: String?) { if let msg, !msg.isEmpty { onLog?(msg) } }
}
#endif

private final class LocalProbeDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ModelList: Decodable {
    struct Model: Decodable { let name: String?; let model: String? }
    let models: [Model]
    static func names(from data: Data) throws -> [String] {
        guard data.count <= 1_048_576 else { throw ConfigStoreError.invalidData }
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return try list.models.map {
            guard let name = $0.name ?? $0.model, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigStoreError.invalidData
            }
            return name
        }
    }
}

/// UI state is confined to the main queue; Go lifecycle calls share one worker queue.
final class FrpcController: ObservableObject {
    static let legacyKey = "frpcConfigTOML"
    static let backgroundPreferenceKey = "frpcBackgroundEnabled"
    static let sampleConfig = """
    serverAddr = ""
    serverPort = 7000
    auth.method = "token"
    auth.token = ""

    [[visitors]]
    name = "ollama-visitor-ios"
    type = "stcp"
    serverName = "ollama"
    secretKey = ""
    bindAddr = "127.0.0.1"
    bindPort = 11434
    """
    @Published var phase: TunnelPhase = .stopped
    @Published var configText: String {
        didSet {
            // Editing raw TOML changes the source of truth. Switching to the
            // basic form must ask before discarding any unparsed edits.
            if configText != oldValue { isCustomConfig = true }
        }
    }
    @Published var profile = ConnectionProfile()
    @Published private(set) var selectedSlot = 0
    @Published var formMode = true
    @Published var isCustomConfig = false
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var isTesting = false
    @Published private(set) var statusDetail = "填写配置后，点击连接。"
    @Published private(set) var lastError = ""
    @Published private(set) var testResult = "尚未测试"
    @Published private(set) var models: [String] = []
    @Published private(set) var endpoint = "http://127.0.0.1:11434"
    @Published private(set) var storageMessage = ""
    @Published private(set) var logText = ""
    @Published private(set) var storageState: ConfigStorageState = .available
    @Published private(set) var recoveryAvailable = false
    @Published var backgroundEnabled = true {
        didSet {
            defaults.set(backgroundEnabled, forKey: Self.backgroundPreferenceKey)
            updateLocation()
        }
    }
    @Published private var desiredRunning = false
    let keepAlive: KeepAlive
    let frpVersion: String
    var canStop: Bool { desiredRunning || isRunning || isBusy || phase == .stopping }
    private var runtimeIsIdle: Bool { !canStop && !runtime.isRunning && !runtime.isStopping }
    var canEdit: Bool { runtimeIsIdle && !storageReadBlocked }
    var canRetryConfigRead: Bool { runtimeIsIdle && storageReadBlocked }
    var canPrepareRecovery: Bool {
        runtimeIsIdle && (storageState == .corrupt || storageState == .unsupportedVersion) && recoverySnapshotFits
    }
    var canRestoreRecovery: Bool {
        runtimeIsIdle && !storageReadBlocked && recoveryAvailable && currentSlotsAreEmpty &&
            defaults.string(forKey: Self.legacyKey) == nil
    }
    var configEditMessage: String {
        if !runtimeIsIdle { return "停止连接并等待任务退出后可修改配置。" }
        switch storageState {
        case .available: return ""
        case .temporarilyUnavailable: return storageMessage
        case .corrupt:
            return recoverySnapshotFits ? "配置数据无法解析，原数据已保护；可重新读取或保护后重新配置。"
                : "配置数据无法解析或超出恢复容量；原记录未覆盖，请使用兼容版本或保留的配置来源。"
        case .unsupportedVersion:
            return recoverySnapshotFits ? "配置由其他版本写入，请优先使用兼容版本；也可保护后重新配置。"
                : "配置格式与本版本不兼容，且超出恢复容量；原记录未覆盖，请使用兼容版本。"
        }
    }
    private let runtime: FrpRuntime
    private let store: ConfigStore
    private let defaults: UserDefaults
    private let worker = DispatchQueue(label: "com.doc.frpclient.lifecycle", qos: .userInitiated)
    private let probeSession: URLSession
    private var pollTimer: Timer?
    private var pollPending = false
    private let pollInterval: TimeInterval
    private let retryDelays: [TimeInterval]
    private var retryItem: DispatchWorkItem?
    private var attempt = 0
    private var generation: UInt64 = 0
    private var testGeneration: UInt64 = 0
    private var testTask: URLSessionDataTask?
    private var activeInfo: ConfigInfo?
    private var activeConfig = ""
    private var nextProbe = Date.distantPast
    private var monitor: NWPathMonitor?
    private var lastPathAvailable: Bool?
    private var storageReadBlocked: Bool { storageState != .available }
    private var blockedProtected: String?
    private var recoverySnapshot: ConfigRecoverySnapshot?
    private var recoveryEncoded: String?
    private var storedProfiles: StoredProfiles
    private var currentSlotsAreEmpty: Bool {
        currentStoredProfiles().slots == StoredProfiles.empty(sampleConfig: Self.sampleConfig).slots
    }
    private var recoverySnapshotFits: Bool {
        guard let original = blockedProtected else { return false }
        return Self.encodeRecovery(ConfigRecoverySnapshot(protected: original,
                              legacy: defaults.string(forKey: Self.legacyKey))) != nil
    }
    private static func encodeRecovery(_ snapshot: ConfigRecoverySnapshot) -> String? {
        guard snapshot.protected.utf8.count <= 1_048_576,
              (snapshot.legacy?.utf8.count ?? 0) <= 1_048_576,
              let data = try? JSONEncoder().encode(snapshot), data.count <= 1_048_576 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    init(runtime: FrpRuntime? = nil, store: ConfigStore = KeychainConfigStore(),
         defaults: UserDefaults = .standard, keepAlive: KeepAlive = KeepAlive(),
         probeSession: URLSession? = nil, monitorNetwork: Bool = true,
         pollInterval: TimeInterval = 1, retryDelays: [TimeInterval] = [1, 2, 4, 8, 16]) {
        #if FRPCLIENT_TESTS
        guard let selectedRuntime = runtime else { fatalError("Tests require an injected runtime") }
        #else
        let selectedRuntime = runtime ?? GoRuntime()
        #endif
        self.runtime = selectedRuntime
        self.store = store
        self.defaults = defaults
        self.keepAlive = keepAlive
        self.frpVersion = selectedRuntime.version
        self.pollInterval = pollInterval
        self.retryDelays = retryDelays
        if let probeSession { self.probeSession = probeSession }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 8
            self.probeSession = URLSession(configuration: configuration, delegate: LocalProbeDelegate(), delegateQueue: nil)
        }
        configText = Self.sampleConfig
        storedProfiles = StoredProfiles.empty(sampleConfig: Self.sampleConfig)
        // Initialization does not invoke didSet: restore the non-secret choice
        // before any lifecycle path is allowed to start location updates.
        backgroundEnabled = defaults.object(forKey: Self.backgroundPreferenceKey) as? Bool ?? true
        restoreConfig()
        reloadRecoveryAvailability()
        bindRuntimeLogs()
        if monitorNetwork {
            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { [weak self] path in
                DispatchQueue.main.async { self?.networkChanged(available: path.status == .satisfied) }
            }
            pathMonitor.start(queue: DispatchQueue(label: "com.doc.frpclient.network"))
            monitor = pathMonitor
        }
    }
    deinit {
        pollTimer?.invalidate()
        retryItem?.cancel()
        testTask?.cancel()
        monitor?.cancel()
        probeSession.invalidateAndCancel()
    }

    private func restoreConfig() {
        do {
            let protected = try store.load()
            let legacy = defaults.string(forKey: Self.legacyKey)
            storageState = .available
            blockedProtected = nil
            if let protected {
                guard protected.utf8.count <= 1_048_576 else {
                    blockConfig(.corrupt, protected: nil, message: "配置超过恢复上限，原数据未覆盖。请使用原版本或可信备份恢复。")
                    return
                }
                if let bundle = Self.decodeStoredProfiles(protected), bundle.isValid {
                    storedProfiles = bundle
                    selectedSlot = bundle.selectedSlot
                    loadSelectedSlot()
                    storageMessage = "3 组配置保存在本机钥匙串。"
                    if legacy != nil {
                        do {
                            try persist(bundle)
                        } catch { storageMessage = "旧存储仍被保留，等待钥匙串保存验证成功。" }
                    }
                    return
                }
                let trimmed = protected.trimmingCharacters(in: .whitespacesAndNewlines)
                // Legacy TOML can start with a table header such as [auth].
                // A leading '[' alone is not evidence of a JSON document.
                let validTableLedTOML = trimmed.hasPrefix("[") && (try? runtime.configInfo(protected)) != nil
                if trimmed.hasPrefix("{") || (trimmed.hasPrefix("[") && !validTableLedTOML) {
                    if let data = protected.data(using: .utf8),
                       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let schema = root["schemaVersion"] as? Int, schema != StoredProfiles.currentSchema {
                        blockConfig(.unsupportedVersion, protected: protected,
                                    message: "配置格式与本版本不兼容；原数据未覆盖，请优先使用兼容版本。")
                    } else {
                        blockConfig(.corrupt, protected: protected,
                                    message: "钥匙串中的多配置数据无法解析，原数据未覆盖。")
                    }
                    return
                }
                migrateLegacyConfig(protected, removeUserDefaults: legacy != nil)
                return
            }
            if let legacy {
                migrateLegacyConfig(legacy, removeUserDefaults: true)
                return
            }
            storedProfiles = StoredProfiles.empty(sampleConfig: Self.sampleConfig)
            selectedSlot = 0
            loadSelectedSlot()
            storageMessage = "3 组配置保存在本机钥匙串。"
        } catch ConfigStoreError.invalidData {
            blockConfig(.corrupt, protected: nil,
                        message: "钥匙串内容无法读取为配置文字，原数据未覆盖。请使用兼容版本恢复。")
        } catch ConfigStoreError.keychain(let status) {
            let message: String
            if status == errSecMissingEntitlement {
                message = "当前签名缺少钥匙串访问权限，请核对安装或签名方式后重试；原配置未覆盖。"
            } else if status == errSecAuthFailed {
                message = "钥匙串访问被拒绝，请核对设备与签名权限后重试；原配置未覆盖。"
            } else {
                message = "钥匙串暂不可读取。请解锁设备后重试；若仍失败，请检查安装与签名方式。原配置未覆盖。"
            }
            blockConfig(.temporarilyUnavailable, protected: nil, message: message)
        } catch {
            blockConfig(.temporarilyUnavailable, protected: nil,
                        message: "钥匙串暂不可读取。请解锁设备后重新读取；旧配置不会被覆盖。")
        }
    }

    private func blockConfig(_ state: ConfigStorageState, protected: String?, message: String) {
        storageState = state
        blockedProtected = protected
        storageMessage = message
    }

    func retryConfigRead() {
        guard canRetryConfigRead else { return }
        restoreConfig()
        reloadRecoveryAvailability()
    }

    private static func decodeRecovery(_ text: String) -> ConfigRecoverySnapshot? {
        guard text.utf8.count <= 1_048_576, let data = text.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(ConfigRecoverySnapshot.self, from: data),
              snapshot.schemaVersion == 1,
              snapshot.protected.utf8.count <= 1_048_576,
              (snapshot.legacy?.utf8.count ?? 0) <= 1_048_576 else { return nil }
        return snapshot
    }

    private func reloadRecoveryAvailability() {
        recoveryAvailable = false
        recoverySnapshot = nil
        recoveryEncoded = nil
        guard let value = try? store.loadRecovery(), let decoded = Self.decodeRecovery(value) else { return }
        recoverySnapshot = decoded
        recoveryEncoded = value
        recoveryAvailable = true
    }

    /// UI confirmation is required before this action. The complete original
    /// text and legacy value are verified in a separate Keychain item first.
    /// No recovery item is ever overwritten with different data or removed.
    @discardableResult func preserveAndResetConfig() -> Bool {
        guard canPrepareRecovery, let expected = blockedProtected else { return false }
        let previousState = storageState
        do {
            guard try store.load() == expected else {
                restoreConfig()
                storageMessage = "存储在操作前发生变化，已重新读取；请检查后再操作。"
                return false
            }
            let original = ConfigRecoverySnapshot(protected: expected,
                                                   legacy: defaults.string(forKey: Self.legacyKey))
            guard let encoded = Self.encodeRecovery(original) else { throw ConfigStoreError.invalidData }
            if let previous = try store.loadRecovery() {
                guard Self.decodeRecovery(previous) == original else { throw ConfigStoreError.recoveryConflict }
            } else {
                try store.saveRecovery(encoded)
            }
            guard let protectedBackup = try store.loadRecovery(), Self.decodeRecovery(protectedBackup) == original else {
                throw ConfigStoreError.invalidData
            }
            recoverySnapshot = original
            recoveryEncoded = protectedBackup
            recoveryAvailable = true
            let empty = StoredProfiles.empty(sampleConfig: Self.sampleConfig)
            let emptyValue = String(decoding: try JSONEncoder().encode(empty), as: UTF8.self)
            do { try writeVerifiedConfig(emptyValue) }
            catch {
                // Some stores fail after accepting a write. Attempt restoration;
                // the verified recovery item remains the authoritative fallback.
                try? writeVerifiedConfig(expected)
                throw error
            }
            defaults.removeObject(forKey: Self.legacyKey)
            storedProfiles = empty
            selectedSlot = 0
            storageState = .available
            blockedProtected = nil
            loadSelectedSlot()
            generation &+= 1
            activeInfo = nil; activeConfig = ""
            invalidateTest(); clearLog(); lastError = ""
            phase = .stopped
            statusDetail = "原数据已保护，填写新配置后可连接。"
            storageMessage = "原配置已保存在独立钥匙串恢复项；当前载入空白配置，恢复项未删除。"
            return true
        } catch ConfigStoreError.recoveryConflict {
            storageState = previousState
            storageMessage = "已存在另一份恢复数据，未覆盖它，也未改动当前配置。请保留两份来源并使用兼容版本处理。"
        } catch {
            storageState = previousState
            storageMessage = "恢复保护或新配置写入未验证成功，操作未完成；原数据与已写入的恢复项均保留。请解锁后重试。"
        }
        return false
    }

    /// Restoring an unreadable original deliberately re-enters its protected
    /// state. A later compatible app can read it; this app never claims repair.
    @discardableResult func restoreRecoveryConfig() -> Bool {
        guard canRestoreRecovery, let expected = recoverySnapshot, let archived = recoveryEncoded else { return false }
        do {
            guard try store.loadRecovery() == archived else {
                reloadRecoveryAvailability()
                storageMessage = "恢复项已发生变化，请重新检查后再恢复。"
                return false
            }
            guard let current = try store.load(), let bundle = Self.decodeStoredProfiles(current), bundle.isValid,
                  bundle.slots == StoredProfiles.empty(sampleConfig: Self.sampleConfig).slots,
                  currentSlotsAreEmpty, defaults.string(forKey: Self.legacyKey) == nil else {
                storageMessage = "当前存储已有配置或草稿，未用恢复项覆盖。"
                return false
            }
            do { try writeVerifiedConfig(expected.protected) }
            catch {
                try? writeVerifiedConfig(current)
                throw error
            }
            if let legacy = expected.legacy { defaults.set(legacy, forKey: Self.legacyKey) }
            restoreConfig()
            reloadRecoveryAvailability()
            storageMessage = storageReadBlocked
                ? "已恢复原始数据；其格式仍无法由本版本读取，原数据与恢复项均保留，请使用兼容版本。"
                : "原始数据已恢复，独立钥匙串恢复项仍保留。"
            lastError = ""
            return true
        } catch {
            storageMessage = "恢复写入未验证成功，操作未完成；当前数据与恢复项均保留，请解锁后重试。"
            return false
        }
    }

    private static func decodeStoredProfiles(_ value: String) -> StoredProfiles? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StoredProfiles.self, from: data)
    }

    private func migrateLegacyConfig(_ value: String, removeUserDefaults: Bool) {
        var bundle = StoredProfiles.empty(sampleConfig: Self.sampleConfig)
        let info = try? runtime.configInfo(value)
        bundle.slots[0] = StoredProfile(configText: value, profile: info?.profile ?? ConnectionProfile(),
                                       formMode: !(info?.customConfig ?? true), isCustomConfig: info?.customConfig ?? true)
        storedProfiles = bundle
        selectedSlot = 0
        loadSelectedSlot()
        do {
            try persist(bundle)
            if removeUserDefaults { defaults.removeObject(forKey: Self.legacyKey) }
            storageMessage = "旧配置已迁移到配置 1，旧存储已清理。"
        } catch {
            storageMessage = "迁移失败，已保留旧配置；请解锁设备后重新保存。"
        }
    }

    private func loadSelectedSlot() {
        guard storedProfiles.slots.indices.contains(selectedSlot) else { return }
        let slot = storedProfiles.slots[selectedSlot]
        configText = slot.configText
        profile = slot.profile
        formMode = slot.formMode
        isCustomConfig = slot.isCustomConfig
        if let info = try? runtime.configInfo(slot.configText) {
            endpoint = Self.endpoint(from: info)
        } else { endpoint = "" }
    }

    private func currentStoredProfiles() -> StoredProfiles {
        var bundle = storedProfiles
        bundle.selectedSlot = selectedSlot
        bundle.slots[selectedSlot] = StoredProfile(configText: configText, profile: profile,
                                                   formMode: formMode, isCustomConfig: isCustomConfig)
        return bundle
    }

    private func persist(_ bundle: StoredProfiles) throws {
        guard bundle.isValid else { throw ConfigStoreError.invalidData }
        let data = try JSONEncoder().encode(bundle)
        guard data.count <= 1_048_576 else { throw ConfigStoreError.invalidData }
        let value = String(decoding: data, as: UTF8.self)
        try writeVerifiedConfig(value)
        storedProfiles = bundle
        defaults.removeObject(forKey: Self.legacyKey)
    }

    @discardableResult func selectSlot(_ index: Int) -> Bool {
        guard (0..<3).contains(index) else { return false }
        guard index != selectedSlot else { return true }
        guard canEdit else { lastError = configEditMessage; return false }
        let previous = storedProfiles
        var candidate = currentStoredProfiles()
        candidate.selectedSlot = index
        do {
            try persist(candidate)
            selectedSlot = index
            loadSelectedSlot()
            generation &+= 1
            cancelRetry()
            pollTimer?.invalidate(); pollTimer = nil
            invalidateTest()
            activeInfo = nil; activeConfig = ""
            logText = ""; phase = .stopped
            lastError = ""
            storageMessage = "配置 \(index + 1) 已载入，切换前的草稿已保存到本机钥匙串。"
            statusDetail = "已切换到配置 \(index + 1)，填写配置后点击连接。"
            return true
        } catch {
            storedProfiles = previous
            lastError = "配置切换未保存，仍保留当前配置。"
            return false
        }
    }

    @discardableResult func applyForm() -> Bool {
        guard canEdit else { return false }
        guard profile.isComplete, let serverPort = Int(profile.serverPort), let bindPort = Int(profile.bindPort) else {
            lastError = "请填写服务器地址和两个密钥，端口需为 1–65535。"; return false
        }
        let value: [String: Any] = [
            "serverAddr": profile.serverAddr.trimmingCharacters(in: .whitespacesAndNewlines),
            "serverPort": serverPort, "token": profile.token, "secretKey": profile.secretKey,
            "visitorName": profile.visitorName, "serverName": profile.serverName,
            "bindAddr": "127.0.0.1", "bindPort": bindPort, "serverUser": profile.serverUser,
            "useSystemCA": profile.useSystemCA, "trustedCaFile": profile.trustedCaFile
        ]
        do {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            configText = try runtime.buildConfig(json)
            isCustomConfig = false
            endpoint = "http://127.0.0.1:\(bindPort)"
            lastError = ""
            return saveConfig()
        } catch { lastError = friendlyError(error.localizedDescription); return false }
    }

    @discardableResult func importAdvancedConfig() -> Bool {
        guard canEdit else { return false }
        do {
            let info = try runtime.configInfo(configText)
            profile = info.profile
            isCustomConfig = info.customConfig
            endpoint = Self.endpoint(from: info)
            formMode = false
            lastError = ""
            return saveConfig()
        } catch { lastError = friendlyError(error.localizedDescription); return false }
    }
    @discardableResult func saveConfig() -> Bool {
        guard !storageReadBlocked else { return false }
        do {
            try persist(currentStoredProfiles())
            defaults.removeObject(forKey: Self.legacyKey)
            storageMessage = "配置 \(selectedSlot + 1) 已保存到本机钥匙串。"
            return true
        } catch {
            storageMessage = "保存到钥匙串失败。旧存储未删除；请解锁设备后重试。"
            return false
        }
    }
    private func writeVerifiedConfig(_ value: String) throws {
        try store.save(value)
        guard try store.load() == value else { throw ConfigStoreError.invalidData }
    }
    func resetConfig() {
        guard canEdit else { return }
        configText = Self.sampleConfig; profile = ConnectionProfile()
        isCustomConfig = false; formMode = true; lastError = ""
        endpoint = "http://127.0.0.1:11434"
    }
    @discardableResult func importCertificate(from url: URL) -> Bool {
        guard canEdit else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 1_048_576, let pem = String(data: data, encoding: .utf8),
                  !pem.contains("PRIVATE KEY") else { throw ConfigStoreError.invalidData }
            let blocks = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
            guard !blocks.isEmpty else { throw ConfigStoreError.invalidData }
            for block in blocks {
                guard let encoded = block.components(separatedBy: "-----END CERTIFICATE-----").first,
                      block.contains("-----END CERTIFICATE-----"),
                      let der = Data(base64Encoded: encoded.filter { !$0.isWhitespace }),
                      SecCertificateCreateWithData(nil, der as CFData) != nil else {
                    throw ConfigStoreError.invalidData
                }
            }
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
                .appendingPathComponent("TrustedCertificates", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(UUID().uuidString + ".pem")
            try data.write(to: target, options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: target.path)
            #endif
            profile.trustedCaFile = target.path
            lastError = ""; return true
        } catch { lastError = "无法导入证书。请选择有效的 PEM 公共 CA 证书文件。"; return false }
    }

    func start() {
        guard canEdit else { return }
        guard !formMode || profile.isComplete else {
            lastError = "当前配置尚未填完整，请填写服务器地址、端口和两个密钥。"; return
        }
        do {
            guard configText.utf8.count <= 131_072 else { lastError = "配置过长，请控制在 128 KB 以内。"; return }
            let info = try runtime.configInfo(configText)
            guard !info.serverAddr.isEmpty, info.serverAddr != "example.invalid",
                  !info.token.isEmpty, !info.secretKey.isEmpty,
                  info.token != "YOUR_TOKEN", info.secretKey != "YOUR_SECRET_KEY" else {
                lastError = "请先填写真实的服务器地址和密钥。"; return
            }
            guard saveConfig() else { return }
            activeInfo = info; activeConfig = configText
            endpoint = Self.endpoint(from: info)
            desiredRunning = true; attempt = 0; lastError = ""
            launchAttempt()
        } catch { lastError = friendlyError(error.localizedDescription) }
    }
    func stop() {
        guard canStop, phase != .stopping else { return }
        desiredRunning = false; generation &+= 1
        cancelRetry(); invalidateTest(); keepAlive.stop()
        phase = .stopping; statusDetail = "正在释放隧道，请稍候。"; isBusy = true
        let epoch = generation
        worker.async { [weak self] in
            guard let self else { return }
            self.runtime.stop()
            let running = self.runtime.isRunning
            DispatchQueue.main.async {
                guard epoch == self.generation else { return }
                self.isBusy = false; self.isRunning = running
                if running {
                    self.statusDetail = "停止请求已发送，正在等待网络任务退出。"
                    self.startPolling()
                } else { self.finishStopped() }
            }
        }
    }
    private func launchAttempt() {
        guard desiredRunning else { return }
        generation &+= 1
        bindRuntimeLogs()
        let epoch = generation
        invalidateTest(); attempt += 1; isBusy = true
        phase = attempt == 1 ? .connecting : .reconnecting
        statusDetail = "正在启动隧道（第 \(attempt) 次），随后自动测试模型接口。"
        let config = activeConfig
        worker.async { [weak self] in
            guard let self else { return }
            var failure: String?
            do { try self.runtime.start(config) } catch { failure = error.localizedDescription }
            let running = self.runtime.isRunning
            let error = failure ?? self.runtime.lastError
            DispatchQueue.main.async {
                guard epoch == self.generation, self.desiredRunning else { return }
                self.isBusy = false; self.isRunning = running
                if failure != nil || !running { self.handleExit(error); return }
                self.phase = self.lastPathAvailable == false ? .reconnecting : .running
                self.statusDetail = self.lastPathAvailable == false
                    ? "网络不可用，等待网络恢复。"
                    : "隧道任务已启动，正在等待模型接口验证；尚不能据此确认中继登录成功。"
                self.updateLocation()
                self.nextProbe = Date().addingTimeInterval(1)
                self.startPolling()
            }
        }
    }
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
    }
    private func poll() {
        guard !isBusy, !pollPending else { return }
        pollPending = true
        let epoch = generation
        worker.async { [weak self] in
            guard let self else { return }
            let running = self.runtime.isRunning
            let stopping = self.runtime.isStopping
            let error = self.runtime.lastError
            DispatchQueue.main.async {
                self.pollPending = false
                guard epoch == self.generation else { return }
                self.isRunning = running
                if !running {
                    if self.desiredRunning { self.handleExit(error) } else { self.finishStopped() }
                } else if stopping {
                    self.phase = .stopping; self.keepAlive.stop()
                } else if self.desiredRunning, Date() >= self.nextProbe, !self.isTesting {
                    self.testTunnel()
                }
            }
        }
    }
    private func handleExit(_ raw: String) {
        isRunning = false; keepAlive.stop(); invalidateTest()
        pollTimer?.invalidate(); pollTimer = nil
        let reason = friendlyError(raw)
        lastError = reason
        if desiredRunning, Self.isTransient(raw), attempt <= retryDelays.count {
            phase = .reconnecting
            let delay = retryDelays[attempt - 1]
            statusDetail = "\(reason) 将在 \(Int(delay)) 秒后重试。"
            let epoch = generation
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.desiredRunning, epoch == self.generation else { return }
                self.retryItem = nil; self.launchAttempt()
            }
            retryItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        } else {
            desiredRunning = false; phase = .failed
            statusDetail = Self.isTransient(raw) ? "自动重试已结束，请检查网络后重新连接。" : reason
        }
        appendLog(reason)
    }
    private func finishStopped() {
        isRunning = false; isBusy = false; desiredRunning = false
        phase = .stopped; statusDetail = "隧道已停止。"
        keepAlive.stop(); pollTimer?.invalidate(); pollTimer = nil; invalidateTest()
    }
    private func cancelRetry() { retryItem?.cancel(); retryItem = nil }
    private func invalidateTest() {
        testGeneration &+= 1
        testTask?.cancel(); testTask = nil; isTesting = false
        testResult = "尚未测试"; models = []
    }

    func testTunnel() {
        guard desiredRunning, isRunning, !isBusy, phase != .stopping,
              let info = activeInfo, let url = URL(string: info.testURL) else {
            if !canStop { testResult = "请先连接隧道。" }; return
        }
        guard lastPathAvailable != false else {
            phase = .reconnecting
            testResult = "网络不可用，等待网络恢复后再测试。"
            return
        }
        testTask?.cancel(); testGeneration &+= 1
        let ticket = testGeneration, epoch = generation
        isTesting = true; testResult = "正在测试模型接口…"; models = []
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        testTask = probeSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, epoch == self.generation, ticket == self.testGeneration,
                      self.desiredRunning, self.isRunning, self.phase != .stopping else { return }
                self.isTesting = false; self.testTask = nil
                self.nextProbe = Date().addingTimeInterval(15)
                if let error { self.probeFailed(self.friendlyError(error.localizedDescription)); return }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    self.probeFailed("接口返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。"); return
                }
                do {
                    self.models = try ModelList.names(from: data ?? Data())
                    self.phase = .ready; self.lastError = ""
                    self.testResult = self.models.isEmpty ? "接口可用，当前没有已安装模型。" : "接口可用，发现 \(self.models.count) 个模型。"
                    self.statusDetail = "将下方地址填入聊天客户端；模型推理需在聊天客户端中确认。"
                } catch { self.probeFailed("响应不是有效的 Ollama 模型列表。") }
            }
        }
        testTask?.resume()
    }
    private func probeFailed(_ message: String) {
        phase = lastPathAvailable == false ? .reconnecting : .apiUnavailable
        testResult = message
        statusDetail = lastPathAvailable == false
            ? "网络不可用，等待网络恢复。"
            : "隧道任务仍在运行，模型接口暂不可用；15 秒后再测。请检查远端电脑和 Ollama。"
    }
    func refreshOnForeground() {
        keepAlive.refreshStatus()
        if storageReadBlocked && runtimeIsIdle { retryConfigRead() }
        if desiredRunning, !isBusy { nextProbe = .distantPast; poll() }
    }
    func networkChanged(available: Bool) {
        let recovered = lastPathAvailable == false && available
        lastPathAvailable = available
        if !available, desiredRunning {
            invalidateTest(); phase = .reconnecting; statusDetail = "网络不可用，等待网络恢复。"
        } else if recovered, desiredRunning {
            if isRunning {
                phase = .running
                statusDetail = "网络已恢复，隧道任务仍在运行；正在重新验证模型接口。"
                nextProbe = .distantPast; poll()
            }
            else if !isBusy, attempt <= retryDelays.count { cancelRetry(); launchAttempt() }
        }
    }
    private func updateLocation() {
        if backgroundEnabled && isRunning && desiredRunning && phase != .stopping { keepAlive.start() }
        else { keepAlive.stop() }
    }
    func clearLog() { logText = "" }
    private func bindRuntimeLogs() {
        let epoch = generation
        runtime.setLogHandler { [weak self] text in
            DispatchQueue.main.async {
                guard let self, epoch == self.generation else { return }
                self.appendLog(text)
            }
        }
    }
    private func appendLog(_ text: String) {
        var safe = text
        let storedSecrets = storedProfiles.slots.flatMap { [$0.profile.token, $0.profile.secretKey] }
        for secret in storedSecrets + [profile.token, profile.secretKey, activeInfo?.token ?? "", activeInfo?.secretKey ?? ""] where !secret.isEmpty {
            safe = safe.replacingOccurrences(of: secret, with: "[已隐藏]")
        }
        logText = String((logText + safe + "\n").suffix(20_000))
    }
    static func isTransient(_ raw: String) -> Bool {
        let text = raw.lowercased()
        if ["token", "authentication", "certificate", "x509", "unknown authority", "invalid config", "load config", "validate config"].contains(where: text.contains) { return false }
        return ["timeout", "timed out", "deadline", "no such host", "connection refused", "network is unreachable", "network is down", "connection reset", "no route", "eof", "broken pipe", "not connected to the internet", "offline"].contains(where: text.contains)
    }
    private func friendlyError(_ raw: String) -> String {
        let text = raw.lowercased()
        if text.contains("token") && (text.contains("match") || text.contains("auth")) { return "认证失败，请核对服务器 token。" }
        if text.contains("x509") || text.contains("certificate") || text.contains("unknown authority") { return "服务器证书验证失败，请核对 CA 证书和服务器名称。" }
        if text.contains("no such host") || text.contains("resolve") { return "无法解析服务器地址，请检查地址和网络。" }
        if text.contains("timeout") || text.contains("timed out") || text.contains("deadline") { return "连接超时，请检查网络和远端服务。" }
        if text.contains("refused") { return "服务器拒绝连接，请检查地址、端口和服务状态。" }
        if text.contains("already") || text.contains("stopping") { return "上一次隧道操作尚未结束，请等待停止完成。" }
        if text.contains("config") || text.contains("toml") || text.contains("visitor") || text.contains("loopback") { return "配置无效：请检查 TOML、端口和单个 STCP 访问器设置。" }
        if text.contains("network") || text.contains("internet") || text.contains("offline") { return "网络不可用，请检查 Wi-Fi 或移动网络。" }
        return "连接未成功，请检查配置、网络与远端服务。"
    }
    private static func endpoint(from info: ConfigInfo) -> String {
        guard var components = URLComponents(string: info.testURL) else { return "" }
        components.path = ""
        return components.string ?? ""
    }
}
