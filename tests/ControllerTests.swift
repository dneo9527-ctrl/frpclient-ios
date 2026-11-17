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
            ("Slot switch invalidates queued logs and previous health state", testSlotCallbackIsolation),
            ("Background preference survives cold launch and opt-out stops location", testBackgroundPreference),
            ("Unreadable store only allows retry and never recovery writes", testUnavailableRecoveryGate),
            ("Nontext Keychain data stays protected without destructive recovery", testNontextRecoveryGate),
            ("Corrupt and unsupported storage have distinct recovery reasons", testRecoveryClassification),
            ("Recovery backup is verified before reset removes legacy", testRecoveryResetSuccess),
            ("Backup failures never replace protected main or legacy data", testRecoveryBackupFailures),
            ("Existing different or invalid recovery copies are never overwritten", testRecoveryBackupConflict),
            ("Reset write failure retains backup and can be retried idempotently", testRecoveryResetWriteFailure),
            ("Reset readback mismatch retains source and backup", testRecoveryResetMismatch),
            ("Reset post-write read failure restores the original main data", testRecoveryResetPostWriteReadFailure),
            ("Recovery copy survives cold launch and restores exact protected values", testRecoveryColdRestore),
            ("Restoration refuses unsaved form or TOML drafts", testRecoveryDraftBarrier),
            ("Restoration refuses new saved credentials in any slot", testRecoverySavedConfigBarrier),
            ("Restoration refuses externally changed main or recovery copy", testRecoveryExternalChange),
            ("Failed restoration never loses recovery data or empty current slots", testRecoveryRestoreFailures),
            ("Recovery reset and restore respect underlying runtime ownership", testRecoveryRuntimeBarrier),
            ("Running task is distinct from an unverified model interface", testRunningPhase),
            ("HTTP and schema errors do not claim tunnel reconnection", testAPIUnavailablePhase),
            ("Network recovery returns to verification without restarting live task", testNetworkPhaseRecovery),
            ("Probe result queued before network loss cannot mark offline ready", testNetworkRejectsOldProbe),
            ("Oversized protected configuration never permits reset", testRecoverySizeLimit),
            ("Legacy TOML beginning with an auth table remains migratable", testTableFirstLegacyMigration),
            ("Failed reset and rollback keep an independently recoverable original", testRecoveryRollbackDoubleFailure),
            ("Recovery reset rechecks an externally changed protected original", testRecoveryResetExternalChange),
            ("Encoded snapshot size limits are enforced before enabling recovery", testRecoveryEncodedSizeLimit),
            ("Offline gate rejects new manual and timer-driven probes", testOfflineProbeGate),
            ("Missing signing entitlement has an accurate non-destructive hint", testMissingKeychainEntitlement)
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
        try assertNoPrivatePreferences(f)
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
        try assertNoPrivatePreferences(f)
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
    static let brokenConfig = "{recovery-synthetic-private-broken"
    static let futureConfig = #"{"schemaVersion":99,"selectedSlot":2,"slots":[]}"#
    static let recoveryLegacy = "reliability-secret-fixture-legacy"

    static func assertNoPrivatePreferences(_ f: Fixture) throws {
        let preferences = f.defaults.persistentDomain(forName: f.suite) ?? [:]
        try check(Set(preferences.keys).isSubset(of: [FrpcController.backgroundPreferenceKey]),
                  "private configuration or draft entered UserDefaults")
        if let value = preferences[FrpcController.backgroundPreferenceKey] {
            try check(value is Bool || value is NSNumber, "background preference is not a boolean")
        }
    }
    static func recoveryDocument(_ store: MemoryStore) throws -> [String: Any] {
        guard let value = store.recoveryValue, let data = value.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(description: "recovery snapshot is absent or invalid")
        }
        return root
    }
    static func emptyAfterRecovery(_ f: Fixture) throws {
        try check(f.controller.storageState == .available && f.controller.canEdit,
                  "successful recovery did not permit editing")
        try check(f.controller.selectedSlot == 0 && f.controller.phase == .stopped,
                  "reset retained selection or connection state")
        for index in 0..<3 {
            try check(storedTOML(f.store, index) == FrpcController.sampleConfig,
                      "reset did not protect all three empty defaults")
        }
        try check(f.controller.profile.serverAddr.isEmpty && f.controller.profile.token.isEmpty && f.controller.profile.secretKey.isEmpty,
                  "reset profile contains old credentials")
        try check(f.controller.recoveryAvailable && f.controller.canRestoreRecovery,
                  "protected recovery copy unavailable after reset")
    }
    static func testBackgroundPreference() throws {
        let f = Fixture(); defer { f.cleanup() }
        try check(f.controller.backgroundEnabled, "first launch changed compatible default")
        try check(f.location.starts == 0, "initialization started location")
        try startAndWait(f)
        try check(f.location.active, "default background assistance not active")
        f.controller.backgroundEnabled = false
        try check(!f.location.active, "opting out left location active")
        try check(f.defaults.object(forKey: FrpcController.backgroundPreferenceKey) as? Bool == false,
                  "opt-out not saved as a boolean")
        f.controller.stop()
        try check(waitFor { f.controller.phase == .stopped }, "first controller did not stop")
        let again = Fixture(store: f.store, defaultsSuite: f.suite); defer { again.cleanup() }
        try check(!again.controller.backgroundEnabled && again.location.starts == 0,
                  "cold launch forgot opt-out or started location")
        try startAndWait(again)
        try check(!again.location.active && again.location.starts == 0,
                  "reconnecting after cold launch ignored opt-out")
        again.controller.backgroundEnabled = true
        try check(again.location.active, "explicit opt-in did not resume assistance")
        try assertNoPrivatePreferences(again)
    }
    static func testUnavailableRecoveryGate() throws {
        let store = MemoryStore(brokenConfig); store.loadFails = true
        let f = Fixture(store: store, legacy: recoveryLegacy); defer { f.cleanup() }
        try check(f.controller.storageState == .temporarilyUnavailable && f.controller.canRetryConfigRead,
                  "locked Keychain reason not exposed")
        try check(!f.controller.canPrepareRecovery && !f.controller.preserveAndResetConfig(),
                  "temporary read failure allowed replacing unknown data")
        f.controller.retryConfigRead()
        try check(store.writes == 0 && store.recoveryWrites == 0 && store.value == brokenConfig,
                  "retry while locked wrote configuration")
        try check(f.defaults.string(forKey: FrpcController.legacyKey) == recoveryLegacy,
                  "locked retry deleted plaintext fallback")
        store.loadFails = false
        f.controller.retryConfigRead()
        try check(f.controller.storageState == .corrupt && f.controller.canPrepareRecovery,
                  "successful retry did not classify actual protected data")
        try check(store.writes == 0 && store.recoveryWrites == 0, "classification retry wrote data")
    }
    static func testNontextRecoveryGate() throws {
        let store = MemoryStore("opaque-nontext-data"); store.loadInvalidData = true
        let f = Fixture(store: store); defer { f.cleanup() }
        try check(f.controller.storageState == .corrupt && f.controller.canRetryConfigRead,
                  "nontext data lost protection")
        try check(!f.controller.canPrepareRecovery && !f.controller.preserveAndResetConfig(),
                  "unreadable original bytes were treated as backed-up text")
        try check(store.writes == 0 && store.recoveryWrites == 0, "nontext recovery altered storage")
    }
    static func testRecoveryClassification() throws {
        for (payload, expected) in [(brokenConfig, ConfigStorageState.corrupt),
                                    ("[invalid array", .corrupt),
                                    (futureConfig, .unsupportedVersion)] {
            let store = MemoryStore(payload)
            let f = Fixture(store: store); defer { f.cleanup() }
            try check(f.controller.storageState == expected && f.controller.canPrepareRecovery,
                      "protected storage classification is inaccurate")
            try check(!f.controller.canEdit && !f.controller.configEditMessage.contains("停止连接"),
                      "idle storage failure still asks the user to stop a nonexistent tunnel")
            try check(store.value == payload && store.writes == 0, "classification rewrote protected data")
        }
    }
    static func testRecoveryResetSuccess() throws {
        let store = MemoryStore(brokenConfig)
        let f = Fixture(store: store, legacy: recoveryLegacy); defer { f.cleanup() }
        let before = store.operations.count
        try check(f.controller.preserveAndResetConfig(), "backup and reset failed")
        try emptyAfterRecovery(f)
        let backup = try recoveryDocument(store)
        try check(backup["protected"] as? String == brokenConfig && backup["legacy"] as? String == recoveryLegacy,
                  "recovery snapshot failed to preserve exact original values")
        try check(backup["schemaVersion"] as? Int == 1, "unsupported recovery schema written")
        try check(f.defaults.object(forKey: FrpcController.legacyKey) == nil,
                  "verified reset retained plaintext fallback")
        let operations = Array(store.operations.dropFirst(before))
        guard let backupWrite = operations.firstIndex(of: "saveRecovery"),
              let backupRead = operations[operations.index(after: backupWrite)...].firstIndex(of: "loadRecovery"),
              let mainWrite = operations.firstIndex(of: "save") else {
            throw TestFailure(description: "recovery operations missing")
        }
        try check(backupWrite < backupRead && backupRead < mainWrite,
                  "main data replaced before backup readback verification")
        try check(!f.controller.logText.contains(recoveryLegacy) && !f.controller.logText.contains(brokenConfig),
                  "recovery values entered diagnostics")
    }
    static func testRecoveryBackupFailures() throws {
        for failure in 0..<3 {
            let store = MemoryStore(brokenConfig)
            let f = Fixture(store: store, legacy: recoveryLegacy); defer { f.cleanup() }
            if failure == 0 { store.recoverySaveFails = true }
            else if failure == 1 { store.discardRecoveryWrites = true }
            else { store.recoveryLoadFails = true }
            try check(!f.controller.preserveAndResetConfig(), "failed backup reported success")
            try check(store.value == brokenConfig && store.writes == 0,
                      "backup failure replaced the main original")
            try check(f.defaults.string(forKey: FrpcController.legacyKey) == recoveryLegacy,
                      "backup failure removed legacy original")
            try check(f.controller.storageState == .corrupt && !f.controller.canEdit,
                      "backup failure unlocked UI")
        }
    }
    static func testRecoveryBackupConflict() throws {
        for previous in ["{corrupt recovery snapshot", #"{"schemaVersion":1,"protected":"another-original","legacy":"another-legacy"}"#] {
            let store = MemoryStore(brokenConfig); store.recoveryValue = previous
            let f = Fixture(store: store, legacy: recoveryLegacy); defer { f.cleanup() }
            try check(!f.controller.preserveAndResetConfig(), "different recovery copy was silently replaced")
            try check(store.recoveryValue == previous && store.recoveryWrites == 0 && store.value == brokenConfig && store.writes == 0,
                      "recovery conflict changed either protected copy")
            try check(f.defaults.string(forKey: FrpcController.legacyKey) == recoveryLegacy,
                      "recovery conflict removed legacy")
        }
    }
    static func testRecoveryResetWriteFailure() throws {
        let store = MemoryStore(brokenConfig)
        let f = Fixture(store: store, legacy: recoveryLegacy); defer { f.cleanup() }
        store.saveFails = true
        try check(!f.controller.preserveAndResetConfig(), "failed main write reported reset success")
        let backup = store.recoveryValue
        try check(backup != nil && store.value == brokenConfig && f.controller.storageState == .corrupt,
                  "failed reset lost source, recovery copy or protected UI")
        try check(f.defaults.string(forKey: FrpcController.legacyKey) == recoveryLegacy,
                  "failed reset removed legacy")
        store.saveFails = false
        try check(f.controller.preserveAndResetConfig(), "verified existing same backup could not retry")
        try check(store.recoveryWrites == 1 && store.recoveryValue == backup, "idempotent retry rewrote protected backup")
        try emptyAfterRecovery(f)
    }
    static func testRecoveryResetMismatch() throws {
        let store = MemoryStore(brokenConfig); store.discardWrites = true
        let f = Fixture(store: store, legacy: recoveryLegacy); defer { f.cleanup() }
        try check(!f.controller.preserveAndResetConfig(), "uncommitted reset reported success")
        try check(store.value == brokenConfig && store.recoveryValue != nil && !f.controller.canEdit,
                  "main mismatch lost source or unlocked editor")
        try check(f.defaults.string(forKey: FrpcController.legacyKey) == recoveryLegacy,
                  "main mismatch removed fallback")
    }
    static func testRecoveryResetPostWriteReadFailure() throws {
        let store = MemoryStore(brokenConfig)
        let f = Fixture(store: store, legacy: recoveryLegacy); defer { f.cleanup() }
        store.failReadAfterNextSave = true
        try check(!f.controller.preserveAndResetConfig(), "failed post-write read reported success")
        try check(store.value == brokenConfig && store.recoveryValue != nil && store.writes >= 2,
                  "accepted reset write was not rolled back after unverified read")
        try check(f.controller.storageState == .corrupt && f.defaults.string(forKey: FrpcController.legacyKey) == recoveryLegacy,
                  "post-write read failure discarded protected state or legacy")
    }
    static func testRecoveryColdRestore() throws {
        for original in [brokenConfig, futureConfig] {
            let store = MemoryStore(original)
            let f = Fixture(store: store, legacy: recoveryLegacy); defer { f.cleanup() }
            try check(f.controller.preserveAndResetConfig(), "reset failed")
            let backup = store.recoveryValue
            let again = Fixture(store: store, defaultsSuite: f.suite); defer { again.cleanup() }
            try check(again.controller.recoveryAvailable && again.controller.canRestoreRecovery,
                      "cold launch lost access to recovery snapshot")
            try check(again.controller.restoreRecoveryConfig(), "explicit restore failed")
            try check(store.value == original && store.recoveryValue == backup,
                      "restore did not preserve exact source and backup")
            try check(again.defaults.string(forKey: FrpcController.legacyKey) == recoveryLegacy,
                      "restoration lost legacy original")
            let expected: ConfigStorageState = original == futureConfig ? .unsupportedVersion : .corrupt
            try check(again.controller.storageState == expected && !again.controller.canEdit,
                      "restored unreadable original was incorrectly marked repaired")
        }
    }
    static func testRecoveryDraftBarrier() throws {
        for kind in 0..<2 {
            let store = MemoryStore(brokenConfig)
            let f = Fixture(store: store); defer { f.cleanup() }
            try check(f.controller.preserveAndResetConfig(), "reset failed")
            let before = store.value
            if kind == 0 { f.controller.profile.token = "new-unsaved-reliability-secret-fixture" }
            else { f.controller.configText += "\n# unsaved raw edits" }
            try check(!f.controller.canRestoreRecovery && !f.controller.restoreRecoveryConfig(),
                      "recovery overwrote an unsaved draft")
            try check(store.value == before, "blocked draft recovery touched main storage")
        }
    }
    static func testRecoverySavedConfigBarrier() throws {
        let store = MemoryStore(brokenConfig)
        let f = Fixture(store: store); defer { f.cleanup() }
        try check(f.controller.preserveAndResetConfig() && f.controller.selectSlot(2), "reset or selection failed")
        f.controller.profile.serverAddr = "new-computer.example.invalid"
        f.controller.profile.token = "new-saved-reliability-secret-fixture"
        try check(f.controller.saveConfig() && f.controller.selectSlot(0), "new profile save failed")
        let before = store.value
        try check(!f.controller.canRestoreRecovery && !f.controller.restoreRecoveryConfig(),
                  "recovery replaced a new configuration in another slot")
        try check(store.value == before && store.recoveryValue != nil, "new credentials or backup lost")
    }
    static func testRecoveryExternalChange() throws {
        for target in 0..<2 {
            let store = MemoryStore(brokenConfig)
            let f = Fixture(store: store); defer { f.cleanup() }
            try check(f.controller.preserveAndResetConfig(), "reset failed")
            let expected = store.value
            if target == 0 { store.value = "externally-saved-reliability-secret-fixture" }
            else { store.recoveryValue = #"{"schemaVersion":1,"protected":"different-external-original"}"# }
            let externalMain = store.value, externalBackup = store.recoveryValue, writes = store.writes
            try check(!f.controller.restoreRecoveryConfig(), "stale recovery snapshot overwrote external changes")
            try check(store.value == externalMain && store.recoveryValue == externalBackup && store.writes == writes,
                      "recovery failed to preserve externally changed data")
            if target == 1 { try check(store.value == expected, "changed backup affected main slots") }
        }
    }
    static func testRecoveryRestoreFailures() throws {
        for failure in 0..<3 {
            let store = MemoryStore(brokenConfig)
            let f = Fixture(store: store); defer { f.cleanup() }
            try check(f.controller.preserveAndResetConfig(), "reset failed")
            let empty = store.value, backup = store.recoveryValue
            if failure == 0 { store.saveFails = true }
            else if failure == 1 { store.discardWrites = true }
            else { store.failReadAfterNextSave = true }
            try check(!f.controller.restoreRecoveryConfig(), "unverified restore reported success")
            try check(store.value == empty && store.recoveryValue == backup,
                      "restore failure lost empty current slots or original backup")
            try check(f.controller.storageState == .available && f.controller.canRestoreRecovery,
                      "failed restore lost retry path")
        }
    }
    static func testRecoveryRuntimeBarrier() throws {
        let store = MemoryStore(brokenConfig)
        let f = Fixture(store: store); defer { f.cleanup() }
        f.runtime.forceOwnership(running: true, stopping: true)
        try check(!f.controller.canPrepareRecovery && !f.controller.preserveAndResetConfig(),
                  "underlying run allowed replacing protected configuration")
        f.runtime.forceOwnership(running: false, stopping: false)
        try check(f.controller.preserveAndResetConfig(), "released runtime did not allow reset")
        let empty = store.value
        f.runtime.forceOwnership(running: true, stopping: true)
        try check(!f.controller.canRestoreRecovery && !f.controller.restoreRecoveryConfig() && store.value == empty,
                  "underlying run allowed restoring configuration")
        f.runtime.forceOwnership(running: false, stopping: false)
    }
    static func testRunningPhase() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        try check(f.controller.phase == .running && !f.controller.statusDetail.contains("中继已连接"),
                  "task startup implies an authenticated/verified endpoint")
        try check(f.controller.models.isEmpty && f.runtime.startCount == 1, "running task inherited health")
    }
    static func testAPIUnavailablePhase() throws {
        for (status, body) in [(500, "synthetic service error"), (200, "<html>wrong service</html>")] {
            let f = Fixture(); defer { f.cleanup() }
            try startAndWait(f)
            f.controller.testTunnel()
            try check(waitFor { ProbeProtocol.count == 1 }, "probe absent")
            ProbeProtocol.complete(0, status: status, body: body)
            try check(waitFor { !f.controller.isTesting }, "probe did not finish")
            try check(f.controller.phase == .apiUnavailable && f.controller.isRunning,
                      "API failure claimed tunnel reconnection or stopped run")
            drain(0.08)
            try check(f.runtime.startCount == 1 && f.runtime.stopCount == 0,
                      "API failure restarted the physical tunnel")
            f.controller.testTunnel()
            try check(waitFor { ProbeProtocol.count == 2 }, "recovery probe absent")
            ProbeProtocol.complete(1, body: #"{"models":[{"name":"recovery-model"}]}"#)
            try check(waitFor { f.controller.phase == .ready }, "API health did not recover")
        }
    }
    static func testNetworkPhaseRecovery() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        f.controller.networkChanged(available: false)
        try check(f.controller.phase == .reconnecting, "physical offline state not identified")
        f.controller.networkChanged(available: true)
        try check(f.controller.phase == .running, "network recovery did not return to verification")
        try check(waitFor { ProbeProtocol.count == 1 }, "recovered network did not verify API")
        ProbeProtocol.complete(0, body: #"{"models":[]}"#)
        try check(waitFor { f.controller.phase == .ready }, "recovered API remained offline")
        try check(f.runtime.startCount == 1, "network recovery duplicated a living tunnel")
    }
    static func testNetworkRejectsOldProbe() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        f.controller.testTunnel()
        try check(waitFor { ProbeProtocol.count == 1 }, "probe absent")
        ProbeProtocol.complete(0, body: #"{"models":[{"name":"late-success"}]}"#)
        f.controller.networkChanged(available: false)
        drain()
        try check(f.controller.phase == .reconnecting && f.controller.models.isEmpty,
                  "queued pre-offline success overrode network loss")
    }
    static func testRecoverySizeLimit() throws {
        let oversized = "{" + String(repeating: "x", count: 1_048_576)
        let store = MemoryStore(oversized)
        let f = Fixture(store: store); defer { f.cleanup() }
        try check(f.controller.storageState == .corrupt && !f.controller.canPrepareRecovery,
                  "oversized protected data permits unbounded backup/reset")
        try check(!f.controller.preserveAndResetConfig() && store.value == oversized && store.writes == 0 && store.recoveryWrites == 0,
                  "oversized configuration changed protected storage")
    }

    static func testTableFirstLegacyMigration() throws {
        let legacy = "[auth]\nmethod = \"token\"\ntoken = \"synthetic-table-first-token\"\n"
        let store = MemoryStore(legacy)
        let f = Fixture(store: store); defer { f.cleanup() }
        try check(f.controller.storageState == .available && f.controller.canEdit,
                  "valid legacy TOML table was classified as corrupt JSON")
        try check(storedTOML(store) == legacy && storedTOML(store, 1) == FrpcController.sampleConfig,
                  "legacy table config did not migrate exactly into slot one")
        try check(store.recoveryWrites == 0, "valid legacy migration created a destructive recovery flow")
    }

    static func testRecoveryRollbackDoubleFailure() throws {
        let store = MemoryStore(brokenConfig)
        let f = Fixture(store: store, legacy: recoveryLegacy); defer { f.cleanup() }
        store.acceptNextWriteThenFail = true
        try check(!f.controller.preserveAndResetConfig(), "partially accepted reset reported success")
        let backup = try recoveryDocument(store)
        try check(backup["protected"] as? String == brokenConfig && backup["legacy"] as? String == recoveryLegacy,
                  "a failed reset/rollback lost the independently verified original")
        try check(f.defaults.string(forKey: FrpcController.legacyKey) == recoveryLegacy && !f.controller.canEdit,
                  "partial reset removed legacy or marked UI successful")
        // The store may contain the accepted blank write. Reopen after it
        // becomes writable, then restore from the separate backup explicitly.
        store.saveFails = false
        let again = Fixture(store: store, defaultsSuite: f.suite); defer { again.cleanup() }
        try check(again.controller.recoveryAvailable && again.controller.canRestoreRecovery,
                  "partial reset left no cold-launch recovery path")
        try check(again.controller.restoreRecoveryConfig() && store.value == brokenConfig,
                  "verified backup could not recover after main and rollback failures")
    }
    static func testRecoveryResetExternalChange() throws {
        let store = MemoryStore(brokenConfig)
        let f = Fixture(store: store); defer { f.cleanup() }
        store.value = "externally-updated-reliability-secret-fixture"
        try check(!f.controller.preserveAndResetConfig(), "stale reset overwrote a different original")
        try check(store.recoveryWrites == 0 && storedTOML(store) == "externally-updated-reliability-secret-fixture",
                  "external configuration was reset rather than reread")
        try check(f.controller.storageState == .available && f.controller.configText == "externally-updated-reliability-secret-fixture",
                  "external original not loaded for review")
    }
    static func testRecoveryEncodedSizeLimit() throws {
        // The raw text fits, but JSON escaping doubles these bytes. Backup
        // capacity must be checked before a recovery button is enabled.
        let escaped = "{" + String(repeating: "\n", count: 600_000)
        let store = MemoryStore(escaped)
        let f = Fixture(store: store); defer { f.cleanup() }
        try check(escaped.utf8.count < 1_048_576 && f.controller.storageState == .corrupt,
                  "encoded-size fixture does not represent protected malformed text")
        try check(!f.controller.canPrepareRecovery && !f.controller.preserveAndResetConfig(),
                  "raw-size-only check enabled an impossible recovery snapshot")
        try check(store.value == escaped && store.writes == 0 && store.recoveryWrites == 0,
                  "oversized encoded backup touched either storage item")
        try check(f.controller.configEditMessage.contains("容量") || f.controller.configEditMessage.contains("上限"),
                  "backup size restriction not explained")
    }

    static func testMissingKeychainEntitlement() throws {
        let store = MemoryStore(nil)
        store.loadFails = true
        store.loadFailureStatus = -34018
        let f = Fixture(store: store); defer { f.cleanup() }
        try check(f.controller.storageState == .temporarilyUnavailable, "access error misclassified")
        try check(f.controller.configEditMessage.contains("签名") && f.controller.configEditMessage.contains("权限"),
                  "signing problem was described as an unlock-only problem")
        try check(!f.controller.canPrepareRecovery && !f.controller.preserveAndResetConfig(), "access failure allowed replacement")
        try check(store.writes == 0 && store.recoveryWrites == 0, "access failure modified storage")
    }

    static func testOfflineProbeGate() throws {
        let f = Fixture(); defer { f.cleanup() }
        try startAndWait(f)
        f.controller.networkChanged(available: false)
        f.controller.testTunnel()
        f.controller.refreshOnForeground()
        drain(0.15)
        try check(ProbeProtocol.count == 0 && !f.controller.isTesting,
                  "offline manual/foreground checks sent a loopback health request")
        try check(f.controller.phase == .reconnecting && f.controller.testResult.contains("网络"),
                  "offline probe claimed API readiness or obscured physical network state")
        f.controller.networkChanged(available: true)
        try check(waitFor { ProbeProtocol.count == 1 }, "network recovery did not reopen probe gate")
        ProbeProtocol.complete(0, body: #"{"models":[]}"#)
        try check(waitFor { f.controller.phase == .ready }, "recovered valid probe rejected")
    }

}
