import Foundation
import Combine

// This replacement records lifecycle requests and never starts Core Location.
final class KeepAlive {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var active = false
    func start() { starts += 1; active = true }
    func stop() { stops += 1; active = false }
    func refreshStatus() {}
}

final class MemoryStore: ConfigStore {
    var value: String?
    var loadFails = false
    var loadInvalidData = false
    var saveFails = false
    var failReadAfterNextSave = false
    // Model a provider accepting one write, reporting failure, then rejecting
    // the attempted rollback. The independently verified backup must survive.
    var acceptNextWriteThenFail = false
    private var readFailuresRemaining = 0
    var loadFailureStatus: Int32 = -25308
    var recoveryValue: String?
    var recoveryLoadFails = false
    var recoverySaveFails = false
    var discardRecoveryWrites = false
    // A successful API return is not enough to permit deleting legacy data:
    // model a storage provider that does not commit the requested value.
    var discardWrites = false
    private(set) var writes = 0
    private(set) var recoveryWrites = 0
    private(set) var operations: [String] = []
    init(_ value: String? = "test-profile") { self.value = value }
    func load() throws -> String? {
        operations.append("load")
        if loadInvalidData { throw ConfigStoreError.invalidData }
        if readFailuresRemaining > 0 {
            readFailuresRemaining -= 1
            throw ConfigStoreError.keychain(loadFailureStatus)
        }
        if loadFails { throw ConfigStoreError.keychain(loadFailureStatus) }
        return value
    }
    func save(_ value: String) throws {
        operations.append("save")
        if saveFails { throw ConfigStoreError.keychain(-25308) }
        writes += 1
        if !discardWrites { self.value = value }
        if acceptNextWriteThenFail {
            acceptNextWriteThenFail = false
            saveFails = true
            throw ConfigStoreError.keychain(-25308)
        }
        if failReadAfterNextSave {
            failReadAfterNextSave = false
            readFailuresRemaining = 1
        }
    }
    func loadRecovery() throws -> String? {
        operations.append("loadRecovery")
        if recoveryLoadFails { throw ConfigStoreError.keychain(-25308) }
        return recoveryValue
    }
    func saveRecovery(_ value: String) throws {
        operations.append("saveRecovery")
        if recoverySaveFails { throw ConfigStoreError.keychain(-25308) }
        recoveryWrites += 1
        if !discardRecoveryWrites { recoveryValue = value }
    }
}

final class FakeRuntime: FrpRuntime {
    private let lock = NSLock()
    private var running = false
    private var stopping = false
    private var error = ""
    private var starts = 0
    private var stops = 0
    private var errors: [String]
    private var callback: ((String) -> Void)?
    var startGate: DispatchSemaphore?
    var stopGate: DispatchSemaphore?
    let startEntered = DispatchSemaphore(value: 0)
    var version: String { "test" }
    init(errors: [String] = []) { self.errors = errors }
    var isRunning: Bool { lock.withLock { running } }
    var isStopping: Bool { lock.withLock { stopping } }
    var lastError: String { lock.withLock { error } }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    func configInfo(_ text: String) throws -> ConfigInfo {
        if text.hasPrefix("invalid-profile") { throw ConfigStoreError.invalidData }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The fake accepts the legacy table fixture, but rejects JSON arrays
        // rather than treating every bracket-prefixed value as valid TOML.
        if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[auth]") {
            throw ConfigStoreError.invalidData
        }
        let port = text == "alternate-profile" ? 11435 : 11434
        return ConfigInfo(serverAddr: "relay.example.invalid", serverPort: 7000,
                          token: "test-token", secretKey: "test-secret", visitorName: "visitor-test",
                          serverName: "ollama", bindAddr: "127.0.0.1", bindPort: port,
                          testURL: "http://127.0.0.1:\(port)/api/tags", tlsVerified: false,
                          useSystemCA: false, trustedCaFile: "", serverUser: "", customConfig: false)
    }
    func buildConfig(_ json: String) throws -> String { "test-profile" }
    func start(_ text: String) throws {
        let failure: String? = lock.withLock {
            starts += 1
            error = ""
            return errors.isEmpty ? nil : errors.removeFirst()
        }
        startEntered.signal()
        _ = startGate?.wait(timeout: .now() + 2)
        if let failure {
            lock.withLock { error = failure; running = false }
            throw NSError(domain: "FakeRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        lock.withLock { running = true; stopping = false }
    }
    func stop() {
        lock.withLock { stops += 1; stopping = true }
        _ = stopGate?.wait(timeout: .now() + 2)
        lock.withLock { running = false; stopping = false }
    }
    func failAsynchronously(_ reason: String) {
        lock.withLock { running = false; error = reason }
    }
    func setLogHandler(_ handler: @escaping (String) -> Void) { lock.withLock { callback = handler } }
    func emitLog(_ text: String) { lock.withLock { callback }?(text) }
    func forceOwnership(running: Bool, stopping: Bool) { lock.withLock { self.running = running; self.stopping = stopping } }
}

func storedSlot(_ store: MemoryStore, _ index: Int = 0) -> [String: Any]? {
    guard let text = store.value, let data = text.data(using: .utf8),
          let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let slots = document["slots"] as? [[String: Any]], slots.indices.contains(index) else { return nil }
    return slots[index]
}
func storedTOML(_ store: MemoryStore, _ index: Int = 0) -> String? { storedSlot(store, index)?["configText"] as? String }

final class ProbeProtocol: URLProtocol {
    private static let registryLock = NSLock()
    private static var requests: [ProbeProtocol] = []
    private let stateLock = NSLock()
    private var stopped = false
    private var sent = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.registryLock.withLock { Self.requests.append(self) } }
    override func stopLoading() { stateLock.withLock { stopped = true } }
    static var count: Int { registryLock.withLock { requests.count } }
    static func url(at index: Int) -> URL? { registryLock.withLock { requests[index].request.url } }
    static func reset() { registryLock.withLock { requests = [] } }
    static func complete(_ index: Int, status: Int = 200, body: String) {
        let item = registryLock.withLock { requests[index] }
        item.stateLock.withLock {
            guard !item.stopped, !item.sent, let url = item.request.url else { return }
            item.sent = true
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            item.client?.urlProtocol(item, didReceive: response, cacheStoragePolicy: .notAllowed)
            item.client?.urlProtocol(item, didLoad: Data(body.utf8))
            item.client?.urlProtocolDidFinishLoading(item)
        }
    }
}

struct Fixture {
    let runtime: FakeRuntime
    let store: MemoryStore
    let defaults: UserDefaults
    let suite: String
    let location: KeepAlive
    let controller: FrpcController
    init(runtime: FakeRuntime = FakeRuntime(), store: MemoryStore = MemoryStore(), retryDelays: [TimeInterval] = [0.02, 0.03], pollInterval: TimeInterval = 0.01,
         legacy: String? = nil, defaultsSuite: String? = nil) {
        ProbeProtocol.reset()
        self.runtime = runtime; self.store = store
        suite = defaultsSuite ?? ("FrpClient.ControllerTests." + UUID().uuidString)
        defaults = UserDefaults(suiteName: suite)!
        if let legacy { defaults.set(legacy, forKey: FrpcController.legacyKey) }
        location = KeepAlive()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeProtocol.self]
        let session = URLSession(configuration: configuration)
        controller = FrpcController(runtime: runtime, store: store, defaults: defaults,
                                   keepAlive: location, probeSession: session, monitorNetwork: false,
                                   pollInterval: pollInterval, retryDelays: retryDelays)
    }
    func cleanup() {
        if controller.canStop { controller.stop() }
        runtime.startGate?.signal(); runtime.stopGate?.signal()
        _ = waitFor { !controller.canStop }
        defaults.removePersistentDomain(forName: suite)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}
@discardableResult func waitFor(timeout: TimeInterval = 1, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.004))
    } while Date() < deadline
    return condition()
}
func drain(_ interval: TimeInterval = 0.07) {
    _ = waitFor(timeout: interval) { false }
}
