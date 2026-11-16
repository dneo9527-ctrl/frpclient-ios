# FrpClient 1.2.0

**[Download unsigned IPA](https://github.com/dneo9527-ctrl/frpclient-ios/releases/download/v1.2.0/FrpClient-1.2.0-unsigned-trimpath.ipa)** · **[Release notes and checksums](https://github.com/dneo9527-ctrl/frpclient-ios/releases/tag/v1.2.0)** · **[Clean source ZIP](https://github.com/dneo9527-ctrl/frpclient-ios/releases/download/v1.2.0/FrpClient-1.2.0-source-clean.zip)**

FrpClient is an iOS STCP visitor for reaching a computer-side Ollama service through frp. It supports three independent VPS profiles and stores each profile's TOML and credentials in an `AfterFirstUnlockThisDeviceOnly` Keychain item.

## What is included

- Three isolated profiles for server, port, token, secret key, CA choice, form drafts, and advanced TOML.
- Safe migration of one older single-profile configuration into profile 1.
- Profile switching is blocked while a connection is starting, running, retrying, stopping, or still owns a runtime handle.
- Old callbacks, health results, model lists, and logs are invalidated when a profile changes.
- The Go wrapper parses TOML in memory and redacts known secrets before logs and errors are shown.

All new profiles ship with empty server, token, and secret-key fields. The sample ports are generic defaults; the app does not contain a user's server, credentials, Keychain data, preferences, or another IPA. Do not share screenshots or TOML that contain your own secrets.

## Installation and scope

The 1.2.0 preview targets iOS 15 or newer on arm64. The IPA is unsigned: use your own authorized signing and installation method, or an existing compatible TrollStore setup. An unsigned IPA cannot be installed merely by opening it on an ordinary iPhone. This is not an App Store build.

Physical iPhone installation, screen locking, network switching, long-term background/battery behavior, and a real remote VPS/Windows/Ollama deployment have not been verified. Keep a known-good IPA and configuration source before updating; do not uninstall first.

Keychain data may survive an uninstall. If an update or reinstall shows old server information, it can come from the device's existing Keychain or migration from older preferences; the download ships empty defaults. Downgrading, changing settings in an older version, and upgrading again does not merge those changes automatically: the current Keychain record takes precedence. Preserve your configuration source before switching versions.

The app can optionally request coarse location permission as a background connection aid. Location is not stored or uploaded, and iOS may still suspend or terminate background work. Stopping the app or removing it from the multitasking view ends the tunnel.

This project does not provide a hosted relay, account, payment, membership, or AI service. App Store work and any advanced TOML membership idea are future work.

## Build from source

Requirements: macOS, Xcode, Go 1.26 or newer, and the pinned `frp v0.72.0`/`gomobile` versions in `go/go.mod`.

```sh
./build.sh --unsigned
```

The command creates `build/FrpClient-unsigned.ipa` locally. A signing team ID may be supplied for a separate development build; no signing identity or Apple account is included here.

The unsigned build uses `-trimpath`, an isolated temporary Go module, debug prefix mapping, and Mach-O debug-symbol stripping to exclude personal compilation paths. Check a rebuilt IPA before distributing it:

```sh
python3 tests/audit-ipa-defaults.py build/FrpClient-unsigned.ipa
```

## Tests

```sh
(cd go && go mod download && go test -race ./frpclib -count=1 -v)
./tests/run-controller-tests.sh
./tests/run-e2e.sh
```

The local-only E2E program in `go/e2e` creates a temporary loopback frps and synthetic credentials. It never uses a user's VPS or configuration.

## License

The FrpClient code in this repository is MIT licensed. Go dependencies retain their upstream licenses; see [`docs/THIRD-PARTY-NOTICES.md`](docs/THIRD-PARTY-NOTICES.md). The source ZIP accompanying the IPA includes the full notices and license texts; retain them when redistributing the binary.
