# FrpClient 1.2.1 build 4

Unsigned iOS 15+ preview, bundle ID `com.doc.frpclient`. Existing 1.2.0 releases are retained.

- Background assistance remembers its setting across launches.
- Protected configuration recovery saves and verifies an independent device-only Keychain copy before creating blank profiles. Restore requires all profiles empty, no new draft, and no runtime owner; it retains the recovery copy.
- Tunnel task state, API health, and actual reconnects are shown separately. Offline API probes cannot mark the connection ready.
- Legacy table-led TOML remains migratable. Keychain access/signing errors have distinct messages.

Server address, Token and access secret are blank in the shipped defaults. The IPA contains no saved profiles, preferences, or Keychain data. Existing device configuration may appear after an in-place update.

Validation: 54/54 injected Swift controller regressions, Go race, real loopback STCP integration (including authentication/TLS rejection and Stop cleanup), iPhoneOS Release and Simulator Debug builds passed. Final IPA payload/default/path audit passed. These are local checks; new GitHub CI and release verification are performed separately.

An isolated unsigned simulator installation started but encountered Keychain access denial. Physical iPhone signing/Keychain, lock-screen energy behavior, Wi-Fi/cellular switching, and remote VPS/Ollama inference are not verified. Keep the original IPA and use the existing installation method; do not uninstall the old app first.

Ag review attempts in two quota groups failed without an answer; independent local source review and the tests above were used. No new Ag review is claimed.

The application code is MIT licensed. Dependency terms accompany this archive under `third-party/licenses/`. App Store and membership work are deferred.
