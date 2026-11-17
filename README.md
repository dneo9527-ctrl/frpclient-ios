# FrpClient 1.2.1

[下载 1.2.1 未签名 IPA](https://github.com/dneo9527-ctrl/frpclient-ios/releases/download/v1.2.1/FrpClient-1.2.1-unsigned.ipa) · [完整源码](https://github.com/dneo9527-ctrl/frpclient-ios/releases/download/v1.2.1/FrpClient-1.2.1-source-clean.zip) · [Release 与校验文件](https://github.com/dneo9527-ctrl/frpclient-ios/releases/tag/v1.2.1) · [历史 1.2.0](https://github.com/dneo9527-ctrl/frpclient-ios/releases/tag/v1.2.0)

**iOS 15+ arm64 开发者预览，build 4。IPA 未签名，需要自己的合法签名安装方式或已有兼容 TrollStore 环境；普通 iPhone 直接打开文件无法安装。** 尚未验收实体 iPhone 签名/钥匙串、锁屏耗电、蜂窝切换或真实远端推理；GitHub CI 和公开下载结果见本版 Release。本项目没有绑定的 Codex Skill 或独立模型服务。

iPhone 上的 frp STCP 访问器，用于经中继连接电脑上的 Ollama。与上一版保持相同 Bundle ID `com.doc.frpclient`，最低 iOS 15。此项目由 Muse 原始源码继续修复。

## 1.2.1 可靠性改进

- 后台连接辅助开关会记住上次选择；关闭后重开应用也保持关闭。首次使用延续原版默认，不自动请求新定位授权。
- 连接卡将“隧道任务运行中”“模型接口暂不可用”“模型接口可用”与网络恢复/自动重试分开显示。一次模型接口错误不会重启整个隧道；任务存活不代表已确认中继登录或推理成功。
- 钥匙串暂不可读时可解锁后重试。文本配置损坏或版本不兼容时，可在确认后先保存独立钥匙串恢复副本，读回一致后再创建空白三组配置。已有不同恢复副本不会被覆盖；保护失败不进行替换。
- 恢复副本仅在三组均为空、没有新草稿、无运行任务时允许恢复。副本会继续保留；恢复原始损坏数据并不修复格式，可能仍需对应版本或配置来源。过大或非文本数据不提供重配入口，保持原记录不动。
- 恢复副本与主配置一样保存在本机 `AfterFirstUnlockThisDeviceOnly` 钥匙串，不上传、不加入安装包。重新配置不等于抹除所有旧凭据，副本可能随钥匙串继续保留。

## 三组 VPS 配置与默认隐私

顶部可选择“配置 1 / 2 / 3”。每组独立保存服务器、端口、密钥、证书选项、基础表单草稿和高级 TOML；切换时先写入并读回验证成功，再载入另一组。未填完的草稿也能切换保存。正在连接、运行、重试或停止时，需先停止并等待底层任务退出，再切换。

旧单组配置仅迁入配置 1，配置 2/3 从空白开始。新安装三组的服务器、Token、访问密钥均为空；7000/11434 只是公开的通用端口默认值。安装包不打入用户配置、偏好、钥匙串或原 IPA 的内容。升级后看到已有服务器信息来自设备旧配置迁移，并不代表它被写进 IPA。请保留原 App 与配置来源，勿先卸载。

三组配置连同草稿存于同一 `AfterFirstUnlockThisDeviceOnly` Keychain 项，写入并读回成功后才删除旧 UserDefaults。未知/损坏的多组存储会禁止写回，保护原数据；单组高级 TOML 语法错误仍可作为草稿保存，不影响其他组。格式升级后不保证旧版 App 能读取新多组存储；不支持降级旧版、修改配置后再升级的自动合并，恢复时以钥匙串为准，请保留配置来源。
本版高级 TOML 仍是本地功能，不包含会员、支付或 App Store 逻辑；会员化和商店版另作未来方案。

切换会清空上一组的测试结果、模型列表与日志，并失效旧回调。GitHub 公开版本从源文件允许列表生成，不包含本机工作历史、内部验证日志或私人配置。

## 使用

1. 按原来的 TrollStore 安装方式更新 IPA。保留旧 IPA，先采用原位更新，勿先卸载原 App。
2. 打开新版。旧 `frpcConfigTOML` 配置会迁移至本机钥匙串；仅在写入并读回一致后删除旧存储。迁移失败会提示并保留旧值。
3. 基础表单填服务器地址、服务器端口、认证 Token、访问密钥。目标代理默认 `ollama`、本机端口默认 `11434`，可在高级连接选项修改。也可切换高级 TOML 粘贴原配置。
4. 点“保存并连接”。模型接口测试紧邻按钮显示；成功会列出模型名称。“模型接口可用”只表示 `/api/tags` 响应有效，实际生成需在聊天客户端中测试。
5. 将“聊天客户端服务器地址”复制到 Enchanted 等 Ollama 客户端。电脑上的 Ollama、发布端 frpc、中继 frps 需同时工作。
6. 不用时点“停止连接”。停止等待在后台执行，不阻塞界面；停止完成前不能启动新隧道。

基础表单与高级 TOML 的生效来源明确分开。切换到高级模式时，可保存当前表单或使用已有 TOML；粘贴/修改 TOML 后，再以基础表单重建会要求确认。未被表单表示的设置、非默认回环绑定地址等被标为自定义，避免静默丢弃。

目前只支持一个启用的 STCP visitor，且监听地址必须是回环地址。禁止外部 includes、模板加载和 `loginFailExit=false`：配置为内存中的字面 TOML，首次失败的有界重试由 App 管理。高级不支持的配置会明确拒绝，不回退到其他配置。

## 连接、测试与后台

- “正在连接”表示客户端任务启动中，不能当作已登录或模型已通。API 验证成功才显示“模型接口可用”。
- 测试使用当前运行配置的实际本机地址和端口，校验 HTTP 200 和 `models` JSON；空数组显示 0 个模型，HTML/无效 JSON 不算成功。测试不跟随 HTTP 重定向，不使用持久 Cookie/缓存。
- 测试任务可取消，并同时校验连接代次和请求代次。停止/重启后旧结果不能改变新状态。
- 初次 DNS、超时、拒绝连接等瞬时错误最多重试 5 次，间隔 1、2、4、8、16 秒。认证、证书和配置错误停止重试。用户停止后取消所有待执行重试。已建立连接的恢复由 frp 自身处理；一次模型 API 失败不会重启整个隧道。
- 可选“后台连接辅助”使用粗略定位；位置不保存、不上传。权限只通过用户点击请求，前台使用无需定位。权限状态和实际定位活动分开显示，任何隧道终态都停止定位。
- iOS 调度、静止、低电量、锁屏和进程回收仍可能中断后台运行。从多任务划掉 App 会结束隧道；不保证永久在线。

## 存储与 TLS

整份 TOML（含高级配置中的密钥）保存在 `AfterFirstUnlockThisDeviceOnly` 钥匙串项，不进行 iCloud 同步，也不随设备迁移。重启后需先解锁一次。读取失败时禁止以空白配置覆盖原值；保存失败不会删除旧存储。升级/签名方式可能影响钥匙串访问，真机需确认；请保留可恢复的配置来源，勿分享带密钥的截图。

Go 直接从内存解析配置，不再生成明文临时 TOML。首次启动清理仅限 App 自己临时目录中旧版命名的残留文件；日志在输出至界面和 stdout 前对已知密钥脱敏，解析错误不回显原配置。

frp v0.72.0 默认启用 TLS，默认不校验 frps 证书。基础表单可选择系统 CA 或导入 PEM 公共 CA 证书；导入会校验证书编码并拒绝私钥。实际证书有效期、信任链和域名在 TLS 握手时校验。开启前中继必须配置匹配证书，现有自签服务器可能被拒绝。本轮不修改服务器。TLS 传输加密不等同端到端加密；中继仍处于信任边界内。

官方依据：[frp TLS](https://gofrp.org/en/docs/features/common/network/network-tls/)、[Apple Keychain 访问组](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)、[Apple 后台定位授权](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services)。

## 构建

依赖：macOS、Xcode、Go >= 1.26。frp 固定 `v0.72.0`，gomobile/gobind 固定 `v0.0.0-20261011034528-197770444867`。不要使用未固定的 latest 来生成交付产物。

```sh
./build.sh --unsigned
```

输出为 `build/FrpClient-unsigned.ipa`，使用既有 TrollStore 流程安装。Go 静态链接进主可执行文件，不嵌入无用的空 framework。无须把 IPA 安装到 Mac 或修改 VPS。

已有开发者签名配置时可运行 `./build.sh TEAMID` 生成开发版签名产物；本次交付使用未签名构建，未配置开发者账户。

## 本地验证

```sh
(cd go && GOPROXY=off GOTOOLCHAIN=local go test -race ./frpclib -count=1 -v)
./tests/run-controller-tests.sh
```

Go 测试含并发启动唯一性、停止超时保留所有权、构建/停止交错、异步退出、配置验证/往返、回环端口与日志脱敏。控制器测试注入可控运行时、假配置存储和 URLProtocol，验证停止与重试冲突、旧回调隔离、模型响应解析、配置迁移失败/读回不一致等，不接触用户钥匙串或真实服务器。

`go/e2e` 是仅使用本机回环地址的 STCP 集成验证；可运行 `./tests/run-e2e.sh`。本次检查结果见 `docs/RELEASE-1.2.1.md`。它不证明真机锁屏、耗电、Wi-Fi/蜂窝切换或实际远端模型推理成功。最终构建摘要与文件哈希见交付的验证记录。

第三方模块许可证与通知见 [THIRD-PARTY-NOTICES](docs/THIRD-PARTY-NOTICES.md) 和 `third-party/licenses/`。
