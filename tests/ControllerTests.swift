import Foundation

@main struct ControllerTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("Stop during delayed Start is asynchronous and clears ownership", testStopDuringStart),
            ("Stop while waiting cancels retry", testCancelRetry),
            ("Authentication failure never retries", testAuthenticationFailure),
            ("Transient failure retries are bounded", testBoundedRetry),
            ("Asynchronous exit releases location", testLocationCleanup),
            ("Stop rejects an in-flight health response", testStopRejectsResponse),
            ("Repeated Test uses only the latest response", testLatestResponse),
            ("Probe follows the active non-default bind port", testActualEndpoint),
            ("HTTP 200 invalid JSON is not model health", testInvalidJSON),
            ("Empty model list is a valid reachable API", testEmptyModels),
            ("Migration failure retains legacy copy", testMigrationFailure),
            ("Successful migration removes legacy copy", testMigrationSuccess),
            ("Migration read-back mismatch retains legacy copy", testMigrationReadbackMismatch),
            ("Locked store prevents overwrite and reloads on foreground", testLockedStore),
            ("Raw TOML edits require an explicit basic form replacement", testRawConfigDirty),
            ("Network recovery after user Stop never starts", testNetworkAfterStop),
            ("Fresh install has three empty private profiles", testEmptySlots),
            ("Single Keychain configuration migrates only into slot one", testSingleKeychainMigration),
            ("Incomplete drafts, credentials and certificates stay in their own slots", testIndependentDrafts),
            ("Invalid advanced TOML survives switches without affecting other slots", testAdvancedSlotIsolation),
            ("Failed slot switch preserves current selection and unsaved draft", testSlotWriteFailure),
            ("Unverified slot write never switches", testSlotReadbackMismatch),
            ("Unknown or corrupt schema never overwrites protected data", testUnknownSchema),
            ("Starting, running and stopping block slot switching", testSwitchLifecycleBarrier),
            ("Retry delay blocks slot switching until user Stop", testSwitchRetryBarrier),
            ("Runtime ownership blocks switching even if UI appears idle", testRuntimeOwnershipBarrier),
            ("Slot switch invalidates queued logs and previous health state", testSlotCallbackIsolation)
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("Controller regression tests: \(tests.count - failures)/\(tests.count) passed")
        exit(failures == 0 ? 0 : 1)
    }
    static func startAndWait(_ f: Fixture) throws {
        f.controller.start()
        try check(waitFor { f.controller.isRunning && !f.controller.isBusy }, "worker did not become running")
    }
    static func testStopDuringStart() throws {
        let runtime = FakeRuntime()
        let gate = DispatchSemaphore(value: 0)
        runtime.startGate = gate
        runtime.stopGate = DispatchSemaphore(value: 0)
        let f = Fixture(runtime: runtime); defer { f.cleanup() }
        f.controller.start()
        try check(runtime.startEntered.wait(timeout: .now() + 1) == .success, "start worker not entered")
        let began = Date()
        f.controller.stop()
        try check(Date().timeIntervalSince(began) < 0.05, "Stop blocked caller")
        try check(f.controller.phase == .stopping, "Stopping not immediate")
        var mainRan = false
        DispatchQueue.main.async { mainRan = true }
        try check(waitFor { mainRan }, "main queue was blocked")
        gate.signal()
        try check(waitFor { runtime.stopCount == 1 }, "Stop was not queued after Start")
        try check(f.controller.phase == .stopping, "late Start overrode Stop")
        runtime.stopGate?.signal()
        try check(waitFor { f.controller.phase == .stopped }, "Stop completion absent")
        try check(!f.location.active, "location remains active")
        try check(runtime.startCount == 1, "duplicate Start occurred")
    }
    static func testCancelRetry() throws {
        let runtime = FakeRuntime(errors: ["connection refused"])
        let f = Fixture(runtime: runtime, retryDelays: [0.15]); defer { f.cleanup() }
        f.controller.start()
        try check(waitFor { f.controller.phase == .reconnecting && !f.controller.isBusy }, "retry not scheduled")
        f.controller.stop()
        try check(waitFor { f.controller.phase == .stopped }, "stop did not complete")
        drain(0.2)
        try check(runtime.startCount == 1, "cancelled retry started again")
    }
    static func testAuthenticationFailure() throws {
        let runtime = FakeRuntime(errors: ["token in login doesn't match token from configuration"])
        let f = Fixture(runtime: runtime); defer { f.cleanup() }
        f.controller.start()
        try check(waitFor { f.controller.phase == .failed }, "authentication not terminal")
        drain()
        try check(runtime.startCount == 1, "authentication was retried")
        try check(!f.controller.canStop, "failed service still owned")
        try check(f.controller.lastError.contains("认证"), "authentication not explained")
    }
    static func testBoundedRetry() throws {
        let runtime = FakeRuntime(errors: Array(repeating: "connection refused", count: 8))
        let f = Fixture(runtime: runtime, retryDelays: [0.01, 0.01]); defer { f.cleanup() }
        f.controller.start()
        try check(waitFor { f.controller.phase == .failed }, "transient retry did not terminate")
        try check(runtime.startCount == 3, "retry count is not initial plus two retries")
        drain()
        try check(runtime.startCount == 3, "retry continued after terminal state")
    }
    static func testLocationCleanup() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        try check(f.location.active, "location not requested for running session")
        f.runtime.failAsynchronously("token authentication failed")
        try check(waitFor { f.controller.phase == .failed }, "async exit not detected")
        try check(!f.location.active && f.location.stops > 0, "exit did not release location")
    }
    static func testStopRejectsResponse() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        f.controller.testTunnel()
        try check(waitFor { ProbeProtocol.count == 1 }, "probe not created")
        // Finish at transport level, then stop before the main-queue completion can publish.
        ProbeProtocol.complete(0, body: #"{"models":[{"name":"old"}]}"#)
        f.controller.stop()
        try check(waitFor { f.controller.phase == .stopped }, "stop did not complete")
        drain()
        try check(f.controller.phase == .stopped && f.controller.models.isEmpty, "old health response overwrote Stop")
        try check(!f.controller.testResult.contains("可用"), "stopped session displays old success")
        try startAndWait(f)
        try check(f.controller.phase != .ready && f.controller.models.isEmpty, "new session inherited old success")
    }
    static func testLatestResponse() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        f.controller.testTunnel()
        try check(waitFor { ProbeProtocol.count == 1 }, "first probe absent")
        ProbeProtocol.complete(0, body: #"{"models":[{"name":"old"}]}"#)
        f.controller.testTunnel()
        try check(waitFor { ProbeProtocol.count == 2 }, "second probe absent")
        ProbeProtocol.complete(1, body: #"{"models":[{"name":"new"}]}"#)
        try check(waitFor { !f.controller.isTesting }, "latest probe never finished")
        try check(f.controller.models == ["new"], "older probe published a result")
    }
    static func testActualEndpoint() throws {
        let f = Fixture(store: MemoryStore("alternate-profile")); defer { f.cleanup() }
        try startAndWait(f)
        f.controller.testTunnel()
        try check(waitFor { ProbeProtocol.count == 1 }, "probe absent")
        try check(ProbeProtocol.url(at: 0)?.port == 11435, "probe uses hardcoded port")
        try check(f.controller.endpoint == "http://127.0.0.1:11435", "displayed endpoint differs")
        ProbeProtocol.complete(0, body: #"{"models":[]}"#)
        try check(waitFor { f.controller.phase == .ready }, "valid endpoint result rejected")
    }
    static func testInvalidJSON() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        f.controller.testTunnel()
        try check(waitFor { ProbeProtocol.count == 1 }, "probe absent")
        ProbeProtocol.complete(0, body: "<html>not Ollama</html>")
        try check(waitFor { !f.controller.isTesting }, "probe never completed")
        try check(f.controller.phase != .ready, "HTTP200 non-JSON accepted")
        try check(f.controller.testResult.contains("模型列表"), "schema failure not explained")
    }
    static func testEmptyModels() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        f.controller.testTunnel()
        try check(waitFor { ProbeProtocol.count == 1 }, "probe absent")
        ProbeProtocol.complete(0, body: #"{"models":[]}"#)
        try check(waitFor { f.controller.phase == .ready }, "empty array not reachable API")
        try check(f.controller.models.isEmpty && f.controller.testResult.contains("没有"), "empty-model feedback inaccurate")
    }
    static func testMigrationFailure() throws {
        let store = MemoryStore(nil); store.saveFails = true
        let f = Fixture(store: store, legacy: "legacy-test-profile"); defer { f.cleanup() }
        try check(f.defaults.string(forKey: FrpcController.legacyKey) == "legacy-test-profile", "failed migration deleted legacy")
        try check(f.controller.configText == "legacy-test-profile", "legacy not loaded")
        try check(!f.controller.saveConfig(), "failed store reports save success")
        try check(f.defaults.object(forKey: FrpcController.legacyKey) != nil, "failed save deleted legacy")
        store.saveFails = false
        try check(f.controller.saveConfig(), "later save did not recover")
        try check(f.defaults.object(forKey: FrpcController.legacyKey) == nil, "successful later save didn't remove legacy")
    }
    static func testMigrationSuccess() throws {
        let store = MemoryStore(nil)
        let f = Fixture(store: store, legacy: "legacy-test-profile"); defer { f.cleanup() }
        try check(storedTOML(store) == "legacy-test-profile" && store.writes == 1, "migration not committed to store")
        try check(f.defaults.object(forKey: FrpcController.legacyKey) == nil, "successful migration kept legacy")
    }
    static func testMigrationReadbackMismatch() throws {
        let store = MemoryStore(nil); store.discardWrites = true
        let f = Fixture(store: store, legacy: "legacy-test-profile"); defer { f.cleanup() }
        try check(f.controller.configText == "legacy-test-profile", "read-back mismatch lost loaded legacy")
        try check(f.defaults.string(forKey: FrpcController.legacyKey) == "legacy-test-profile", "unverified migration deleted legacy")
        try check(!f.controller.saveConfig(), "read-back mismatch reports save success")
        try check(f.defaults.object(forKey: FrpcController.legacyKey) != nil, "unverified save deleted legacy")
        store.discardWrites = false
        try check(f.controller.saveConfig(), "verified later write did not recover")
        try check(storedTOML(store) == "legacy-test-profile", "later write committed wrong configuration")
        try check(f.defaults.object(forKey: FrpcController.legacyKey) == nil, "verified later write kept legacy")
    }
    static func testRawConfigDirty() throws {
        let f = Fixture(); defer { f.cleanup() }
        try check(!f.controller.isCustomConfig, "basic initial configuration marked custom")
        let custom = "test-profile\n# custom options\ntransport.tcpMux = false"
        f.controller.formMode = false
        f.controller.configText = custom
        try check(f.controller.isCustomConfig, "raw edits did not activate replacement guard")
        f.controller.formMode = true
        try check(f.controller.isCustomConfig && f.controller.configText == custom, "mode switch silently replaced raw edits")
        try check(f.controller.saveConfig(), "explicit save failed")
        try check(f.controller.isCustomConfig && storedTOML(f.store) == custom, "save lost raw configuration or replacement guard")
        try check(f.controller.applyForm(), "explicit basic-form replacement failed")
        try check(!f.controller.isCustomConfig && f.controller.configText == "test-profile", "explicit form replacement did not reset authority")
    }
    static func testLockedStore() throws {
        let store = MemoryStore("protected-test-profile"); store.loadFails = true
        let f = Fixture(store: store, legacy: "legacy-test-profile"); defer { f.cleanup() }
        try check(!f.controller.canEdit, "locked read permits editing")
        f.controller.configText = "would-overwrite"
        try check(!f.controller.saveConfig(), "locked read permits overwrite")
        f.controller.start()
        drain()
        try check(f.runtime.startCount == 0 && store.writes == 0, "locked store started or overwrote")
        try check(f.defaults.object(forKey: FrpcController.legacyKey) != nil, "locked read deleted legacy")
        store.loadFails = false
        f.controller.refreshOnForeground()
        try check(f.controller.canEdit && f.controller.configText == "protected-test-profile", "foreground didn't recover protected profile")
        try check(f.defaults.object(forKey: FrpcController.legacyKey) == nil, "recovered write didn't finish migration")
    }
    static func testNetworkAfterStop() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        f.controller.networkChanged(available: false)
        f.controller.stop()
        try check(waitFor { f.controller.phase == .stopped }, "stop failed")
        f.controller.networkChanged(available: true)
        drain()
        try check(f.runtime.startCount == 1 && f.controller.phase == .stopped, "network recovery undid user Stop")
    }

    static func testEmptySlots() throws {
        let f = Fixture(store: MemoryStore(nil)); defer { f.cleanup() }
        try check(f.store.writes == 0, "fresh launch wrote defaults unnecessarily")
        for slot in 0..<3 {
            try check(f.controller.selectSlot(slot), "empty slot selection failed")
            try check(f.controller.profile.serverAddr.isEmpty && f.controller.profile.token.isEmpty && f.controller.profile.secretKey.isEmpty,
                      "fresh profile contains server or credentials")
            try check(f.controller.formMode && !f.controller.isCustomConfig, "empty slot is not a basic form")
            f.controller.start()
            try check(f.runtime.startCount == 0, "empty draft started a tunnel")
            try check(f.controller.configText.contains("auth.token = \"\"") && f.controller.configText.contains("secretKey = \"\""),
                      "default TOML contains credentials")
        }
        try check((f.defaults.persistentDomain(forName: f.suite) ?? [:]).isEmpty, "private profile data leaked into preferences")
    }
    static func testSingleKeychainMigration() throws {
        let store = MemoryStore("protected-test-profile")
        let f = Fixture(store: store, legacy: "older-test-profile"); defer { f.cleanup() }
        try check(storedTOML(store) == "protected-test-profile", "newer protected configuration lost")
        try check(storedTOML(store, 1) == FrpcController.sampleConfig && storedTOML(store, 2) == FrpcController.sampleConfig,
                  "legacy credentials copied into empty slots")
        try check(f.defaults.object(forKey: FrpcController.legacyKey) == nil, "verified migration retained plaintext")
        try check(f.controller.selectSlot(1) && f.controller.profile.token.isEmpty, "slot two inherited credentials")
    }
    static func testIndependentDrafts() throws {
        let store = MemoryStore(nil)
        let f = Fixture(store: store); defer { f.cleanup() }
        f.controller.profile.serverAddr = "slot-one.example.invalid"
        f.controller.profile.serverPort = ""
        f.controller.profile.bindPort = ""
        f.controller.profile.token = "synthetic-slot-one-token"
        let draft = f.controller.profile
        try check(f.controller.selectSlot(1), "incomplete draft prevented switching")
        try check(f.controller.profile.serverAddr.isEmpty && f.controller.profile.token.isEmpty, "draft crossed slots")
        f.controller.profile.serverAddr = "slot-two.example.invalid"
        f.controller.profile.token = "synthetic-slot-two-token"
        f.controller.profile.secretKey = "synthetic-slot-two-secret"
        f.controller.profile.trustedCaFile = "/synthetic-test-ca/slot-two.pem"
        f.controller.profile.useSystemCA = true
        let second = f.controller.profile
        try check(f.controller.selectSlot(2), "slot three switch failed")
        try check(f.controller.profile.trustedCaFile.isEmpty, "certificate crossed slots")
        try check(f.controller.selectSlot(0) && f.controller.profile == draft, "incomplete draft did not round trip")
        f.controller.start()
        try check(f.runtime.startCount == 0, "incomplete restored draft started stale TOML")
        try check(f.controller.selectSlot(1) && f.controller.profile == second, "second profile lost independent values")
        let reloaded = Fixture(store: store); defer { reloaded.cleanup() }
        try check(reloaded.controller.selectedSlot == 1 && reloaded.controller.profile == second, "restart lost selected slot or credentials")
        try check(reloaded.controller.selectSlot(0) && reloaded.controller.profile == draft, "restart lost other slot draft")
        try check((f.defaults.persistentDomain(forName: f.suite) ?? [:]).isEmpty, "draft saved to preferences")
    }
    static func testAdvancedSlotIsolation() throws {
        let f = Fixture(); defer { f.cleanup() }
        let first = f.controller.profile
        try check(f.controller.selectSlot(1), "second slot unavailable")
        let advanced = "invalid-profile\n# custom Unicode: 测试\n\u{0000}"
        f.controller.formMode = false
        f.controller.configText = advanced
        try check(f.controller.selectSlot(2), "invalid TOML blocked saving a draft")
        try check(f.controller.formMode && !f.controller.isCustomConfig, "custom mode crossed slots")
        try check(f.controller.selectSlot(0) && f.controller.profile == first, "invalid slot damaged first slot")
        try check(f.controller.selectSlot(1) && f.controller.configText == advanced, "invalid advanced draft was destroyed")
        try check(!f.controller.formMode && f.controller.isCustomConfig, "advanced source guard not restored")
        f.controller.start()
        try check(f.runtime.startCount == 0, "invalid TOML reached runtime start")
    }
    static func testSlotWriteFailure() throws {
        let f = Fixture(); defer { f.cleanup() }
        f.controller.profile.serverAddr = "unsaved.example.invalid"
        let draft = f.controller.profile, protected = f.store.value
        f.store.saveFails = true
        try check(!f.controller.selectSlot(1), "failed save switched slots")
        try check(f.controller.selectedSlot == 0 && f.controller.profile == draft && f.store.value == protected, "failed save lost selection or draft")
        f.store.saveFails = false
        try check(f.controller.selectSlot(1), "recovered save did not switch")
        try check(f.controller.selectSlot(0) && f.controller.profile == draft, "recovered save lost old draft")
    }
    static func testSlotReadbackMismatch() throws {
        let f = Fixture(); defer { f.cleanup() }
        f.store.discardWrites = true
        try check(!f.controller.selectSlot(2) && f.controller.selectedSlot == 0, "unverified save switched slots")
        f.store.discardWrites = false
        try check(f.controller.selectSlot(2), "verified save did not recover")
    }
    static func testUnknownSchema() throws {
        for payload in [#"{"schemaVersion":999,"selectedSlot":0,"slots":[]}"#, "{corrupt protected JSON"] {
            let store = MemoryStore(payload)
            let f = Fixture(store: store, legacy: "must-retain-legacy"); defer { f.cleanup() }
            try check(!f.controller.canEdit && !f.controller.selectSlot(1) && !f.controller.saveConfig(), "unsupported data allowed writes")
            try check(store.writes == 0 && store.value == payload, "unsupported data overwritten")
            try check(f.defaults.object(forKey: FrpcController.legacyKey) != nil, "unsupported schema deleted fallback")
        }
    }
    static func testSwitchLifecycleBarrier() throws {
        let runtime = FakeRuntime()
        runtime.startGate = DispatchSemaphore(value: 0)
        runtime.stopGate = DispatchSemaphore(value: 0)
        let f = Fixture(runtime: runtime); defer { f.cleanup() }
        f.controller.start()
        try check(runtime.startEntered.wait(timeout: .now() + 1) == .success, "start did not enter")
        try check(!f.controller.selectSlot(1) && f.controller.selectedSlot == 0, "switched while starting")
        runtime.startGate?.signal()
        try check(waitFor { f.controller.isRunning && !f.controller.isBusy }, "start not complete")
        try check(!f.controller.selectSlot(1), "switched while running")
        f.controller.stop()
        try check(!f.controller.selectSlot(1), "switched while stopping")
        runtime.stopGate?.signal()
        try check(waitFor { f.controller.phase == .stopped }, "stop not complete")
        try check(f.controller.selectSlot(1), "stopped service still blocks selection")
    }
    static func testSwitchRetryBarrier() throws {
        let runtime = FakeRuntime(errors: ["connection refused"])
        let f = Fixture(runtime: runtime, retryDelays: [0.3]); defer { f.cleanup() }
        f.controller.start()
        try check(waitFor { f.controller.phase == .reconnecting && !f.controller.isBusy }, "retry not scheduled")
        try check(!f.controller.selectSlot(2), "retry allowed selection")
        f.controller.stop()
        try check(waitFor { f.controller.phase == .stopped }, "retry stop incomplete")
        try check(f.controller.selectSlot(2), "stopped retry blocked selection")
        drain(0.35)
        try check(runtime.startCount == 1 && f.controller.selectedSlot == 2, "old retry affected new slot")
    }
    static func testRuntimeOwnershipBarrier() throws {
        let f = Fixture(); defer { f.cleanup() }
        f.runtime.forceOwnership(running: true, stopping: true)
        try check(!f.controller.canEdit && !f.controller.selectSlot(1), "runtime owner ignored")
        f.runtime.forceOwnership(running: false, stopping: false)
        try check(f.controller.selectSlot(1), "released runtime still blocks selection")
    }
    static func testSlotCallbackIsolation() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        f.controller.testTunnel()
        try check(waitFor { ProbeProtocol.count == 1 }, "probe absent")
        ProbeProtocol.complete(0, body: #"{"models":[{"name":"old-slot-model"}]}"#)
        f.runtime.emitLog("queued old-slot log")
        f.controller.stop()
        try check(waitFor { f.controller.phase == .stopped }, "stop absent")
        try check(f.controller.selectSlot(1), "slot switch failed")
        drain()
        try check(f.controller.models.isEmpty && f.controller.logText.isEmpty && f.controller.testResult == "尚未测试", "old state crossed slots")
        f.controller.formMode = false
        f.controller.configText = "alternate-profile"
        try startAndWait(f)
        try check(f.controller.endpoint == "http://127.0.0.1:11435", "new slot inherited old endpoint")
        f.runtime.emitLog("test-token test-secret fresh-log")
        try check(waitFor { f.controller.logText.contains("fresh-log") }, "new session logs not rebound")
        try check(!f.controller.logText.contains("test-token") && !f.controller.logText.contains("test-secret"), "new log leaked credentials")
    }
}
