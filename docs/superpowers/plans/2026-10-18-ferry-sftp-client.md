# Ferry SFTP 客户端 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做一个原生 macOS SFTP 小客户端：存好的连接点一下即连，单栏浏览远程目录，双击远程文件像 Finder 一样用默认程序打开（查看为主）。

**Architecture:** Swift Package，分 `FerryKit`（纯逻辑库，无 UI）与 `FerryApp`（SwiftUI app）两个 target。SSH/SFTP 用纯 Swift 的 Citadel。纯逻辑（favorites、known_hosts/TOFU、Keychain、缓存路径）用 XCTest 单元测试；SFTP 会话与 host key 校验用一个 loopback 的 Citadel SSH/SFTP 服务器夹具做集成测试，不依赖外部网络。

**Tech Stack:** Swift 5.9+ / SwiftUI、Citadel（SPM）、Security.framework（Keychain）、AppKit `NSWorkspace`、XCTest。

**Spec:** `docs/superpowers/specs/2026-10-18-ferry-sftp-client-design.md`

## Global Constraints

- 平台 macOS 14（Sonoma）及以上；语言 Swift + SwiftUI。
- SSH/SFTP 库用 Citadel（纯 Swift，SPM），不引入 libssh2 或任何 C 依赖。
- 认证仅两种：密码、未加密 ED25519 私钥。RSA、带 passphrase 的加密私钥不做。
- 同一时间只保持一个活动 SFTP 连接；切换 favorite 即断开前一个。
- Host key 采用应用私有 known_hosts（OpenSSH 兼容格式），不读写 `~/.ssh/known_hosts`。
- 密码、私钥相关敏感项只进 Keychain；favorites 的 JSON 里不得出现任何密码。
- 打开文件走「下载到缓存 + `NSWorkspace` 打开」，不使用 FileProvider。
- 本期为只读查看，缓存文件改动不回传；但打开流程集中在 `FileOpenCoordinator` 一处，便于日后加回传。

## Review Focus

- Host key 变更（疑似中间人）：已记录过的主机再次连接时 key 变了，连接必须被拒绝并告警，不得静默接受。→ 测试落在 Task 4（KnownHostsStore）与 Task 7（SFTPSession 连接拒绝）。
- 非标准端口的 known_hosts 条目：22 以外端口按 OpenSSH 的 `[host]:port` 记法存取，解析/写入都要对。→ 测试落在 Task 4。
- 远程同路径但内容变了（mtime/size 变化）：缓存不能把旧文件当新文件返回。→ 测试落在 Task 5（CachePaths）。
- 含空格/非 ASCII 的文件名与远程路径拼接：列目录与下载的路径处理不能错位。→ 测试落在 Task 3（路径拼接）与 Task 7（list/download）。
- 连接/认证/超时失败：以明确的错误类型上抛，UI 能提示，不崩溃。→ 测试落在 Task 7（SFTPSession 错误映射）。

---

## Task 1: 工程骨架 + Citadel 风险 spike（host key 暴露 + loopback 服务器夹具）

本任务先立起 Swift Package 并验掉两个决定后续设计的 Citadel 未知项：自定义 host key 校验能否拿到服务器原始公钥；能否在进程内起一个 SSH/SFTP 服务器供集成测试连。产出一个能在 loopback 上连通、并把服务器 host key 指纹交到应用手里的测试。

**Files:**
- Create: `Package.swift`
- Create: `Sources/FerryKit/Ferry.swift`（占位，确保库 target 可编译）
- Create: `Tests/FerryKitTests/CitadelSpikeTests.swift`
- Create: `Tests/FerryKitTests/Support/LoopbackSSHServer.swift`
- Create: `docs/superpowers/notes/citadel-spike-findings.md`

**Interfaces:**
- Produces: `LoopbackSSHServer`，供后续集成测试复用。最小形态：
  - `LoopbackSSHServer(username: String, password: String, authorizedEd25519PublicKey: NIOSSHPublicKey?)`
  - `func start() async throws -> Int`（返回实际监听端口）
  - `func stop() async`
  - `var hostKey: NIOSSHPublicKey { get }`（服务器自身 host key，供断言指纹用）
- Produces: 结论文档说明「自定义 `hostKeyValidator` 是否暴露原始 `NIOSSHPublicKey`」。若暴露 → Task 4/7 的 validator 按该接口设计；若不暴露 → 在结论文档记录替代方案（下沉到 NIOSSH 层或改 host key 模块形态），并据此调整 Task 4/7。

- [ ] **Step 1: 写 `Package.swift`**，声明 macOS 14 平台、Citadel 依赖（锁一个具体版本）、`FerryKit` 库 target、`FerryKitTests` 测试 target。
- [ ] **Step 2: 写失败的 spike 测试 `test_customValidatorReceivesServerHostKey`**

```swift
// 起 loopback 服务器；用一个自定义 validator 连接；断言 validator 收到了服务器的原始 host key，
// 且其 SHA256 指纹与 server.hostKey 的指纹一致。
func test_customValidatorReceivesServerHostKey() async throws {
    let server = LoopbackSSHServer(username: "u", password: "p", authorizedEd25519PublicKey: nil)
    let port = try await server.start()
    defer { Task { await server.stop() } }
    var captured: NIOSSHPublicKey?
    _ = try? await connectCapturingHostKey(host: "127.0.0.1", port: port,
                                            username: "u", password: "p") { captured = $0 }
    XCTAssertEqual(sha256Fingerprint(captured), sha256Fingerprint(server.hostKey))
}
```

- [ ] **Step 3: 运行，确认失败**（Run: `swift test --filter CitadelSpikeTests`；Expected: 编译失败或断言失败）
- [ ] **Step 4: 实现 `LoopbackSSHServer` 与 `connectCapturingHostKey` 辅助**，用 Citadel 的服务器 API + 自定义 `hostKeyValidator` 连接；若 Citadel 服务器不支持 SFTP 子系统，本步只验证 SSH 层 host key 暴露即可，并在结论文档记录对集成测试的影响。
- [ ] **Step 5: 运行，确认通过**（Run: `swift test --filter CitadelSpikeTests`；Expected: PASS）
- [ ] **Step 6: 写结论文档** `citadel-spike-findings.md`：host key 是否暴露、其类型/取字节的方式、loopback 服务器能否承载 SFTP、对 Task 4/7 的影响。
- [ ] **Step 7: Commit**（`git add -A && git commit -m "chore: package skeleton + Citadel host-key spike"`）

---

## Task 2: Favorite 模型 + FavoritesStore（JSON 持久化）

**Files:**
- Create: `Sources/FerryKit/Models/Favorite.swift`
- Create: `Sources/FerryKit/Stores/FavoritesStore.swift`
- Create: `Tests/FerryKitTests/FavoritesStoreTests.swift`

**Interfaces:**
- Produces: `struct Favorite: Codable, Identifiable, Equatable` 字段 `id: UUID`、`name: String`、`host: String`、`port: Int`（默认 22）、`username: String`、`auth: AuthMethod`、`privateKeyPath: String?`、`initialPath: String`、`colorLabel: String?`、`note: String`。
- Produces: `enum AuthMethod: String, Codable { case password, privateKey }`。
- Produces: `struct FavoritesStore { init(fileURL: URL); func load() throws -> [Favorite]; func save(_ favorites: [Favorite]) throws }`，默认 `fileURL` = `Application Support/Ferry/favorites.json`（提供 `static func defaultFileURL() throws -> URL`）。JSON 中不含任何密码/passphrase。

- [ ] **Step 1: 写失败测试 `test_saveThenLoad_roundTrips` 与 `test_load_missingFile_returnsEmpty`**

```swift
func test_saveThenLoad_roundTrips() throws {
    let url = tmpURL()
    let store = FavoritesStore(fileURL: url)
    let fav = Favorite(id: UUID(), name: "dolphin", host: "10.0.0.180", port: 22,
                       username: "qiangxu", auth: .privateKey, privateKeyPath: "~/.ssh/id_ed25519",
                       initialPath: "/home/qiangxu", colorLabel: nil, note: "")
    try store.save([fav])
    XCTAssertEqual(try store.load(), [fav])
}
func test_load_missingFile_returnsEmpty() throws {
    XCTAssertEqual(try FavoritesStore(fileURL: tmpURL()).load(), [])
}
func test_savedJSON_containsNoPasswordField() throws { /* 读回原始 JSON 文本，断言不含 "password" 键 */ }
```

- [ ] **Step 2: 运行确认失败**（Run: `swift test --filter FavoritesStoreTests`；Expected: FAIL）
- [ ] **Step 3: 实现 `Favorite`、`AuthMethod`、`FavoritesStore`**，`load` 对缺失文件返回 `[]`，`save` 前确保父目录存在。
- [ ] **Step 4: 运行确认通过**（Expected: PASS）
- [ ] **Step 5: Commit**（`feat: favorites model + JSON store`）

---

## Task 3: 远程路径工具 RemotePath

集中处理 POSIX 远程路径的拼接/归一（含空格与非 ASCII），避免各处手写出错。

**Files:**
- Create: `Sources/FerryKit/Support/RemotePath.swift`
- Create: `Tests/FerryKitTests/RemotePathTests.swift`

**Interfaces:**
- Produces: `enum RemotePath { static func join(_ base: String, _ name: String) -> String; static func parent(_ path: String) -> String; static func name(of path: String) -> String }`。规则：始终 `/` 分隔；`join` 处理 base 结尾斜杠；`parent("/")` 仍为 `/`；不做百分号编码（SFTP 走原始字节字符串）。

- [ ] **Step 1: 写失败测试**：`join("/a","b")=="/a/b"`、`join("/a/","b")=="/a/b"`、`join("/a","my file")=="/a/my file"`、`join("/","日志")=="/日志"`、`parent("/a/b")=="/a"`、`parent("/")=="/"`、`name(of:"/a/b.log")=="b.log"`。
- [ ] **Step 2: 运行确认失败**（Run: `swift test --filter RemotePathTests`）
- [ ] **Step 3: 实现 `RemotePath`**。
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: Commit**（`feat: remote path helpers`）

---

## Task 4: KnownHostsStore（OpenSSH 兼容 + TOFU 决策）

**Files:**
- Create: `Sources/FerryKit/Security/HostKeyFingerprint.swift`
- Create: `Sources/FerryKit/Security/KnownHostsStore.swift`
- Create: `Tests/FerryKitTests/KnownHostsStoreTests.swift`

**Interfaces:**
- Produces: `enum HostKeyDecision: Equatable { case unknown(fingerprint: String); case match; case changed(fingerprint: String) }`。
- Produces: `func sha256Fingerprint(keyType: String, blob: Data) -> String`，输出 OpenSSH 风格 `SHA256:<base64-no-padding>`。
- Produces: `struct KnownHostsStore { init(fileURL: URL); func decision(host: String, port: Int, keyType: String, blob: Data) throws -> HostKeyDecision; func trust(host: String, port: Int, keyType: String, blob: Data) throws }`。记录行格式：端口 22 用 `host keytype base64blob`，非 22 用 `[host]:port keytype base64blob`。`trust` 追加写入；缺文件视为空。

- [ ] **Step 1: 写失败测试**

```swift
func test_unknownHost_returnsUnknownWithFingerprint() throws { /* 空库 → .unknown(非空指纹) */ }
func test_trustThenDecision_returnsMatch() throws { /* trust 后同 key → .match */ }
func test_sameHost_differentKey_returnsChanged() throws { /* trust 后换 blob → .changed */ }
func test_nonStandardPort_roundTripsWithBracketNotation() throws {
    // port=2222 trust 后，known_hosts 文本含 "[host]:2222"，且再次 decision 为 .match
}
func test_fingerprint_matchesKnownVector() throws { /* 固定 blob → 固定 SHA256:... 串 */ }
```

- [ ] **Step 2: 运行确认失败**（Run: `swift test --filter KnownHostsStoreTests`）
- [ ] **Step 3: 实现 `HostKeyFingerprint` 与 `KnownHostsStore`**，用 CryptoKit `SHA256`，base64 去尾部 `=`。
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: Commit**（`feat: known_hosts store with TOFU decision`）

---

## Task 5: CachePaths（内容变更即换文件）

**Files:**
- Create: `Sources/FerryKit/Open/CachePaths.swift`
- Create: `Tests/FerryKitTests/CachePathsTests.swift`

**Interfaces:**
- Produces: `struct CachePaths { init(root: URL); func cacheURL(host: String, remotePath: String, mtime: Date, size: Int64) -> URL }`，默认 `root` = `Caches/Ferry/`。同 `(host, remotePath)` 但 `mtime` 或 `size` 不同 → 必须是不同的 URL；文件名保留原始扩展名（让 `NSWorkspace` 能按类型打开）。

- [ ] **Step 1: 写失败测试**：同参→同 URL；改 mtime→不同 URL；改 size→不同 URL；`cacheURL(...,"/a/b.html",...)` 结果后缀为 `.html`。
- [ ] **Step 2: 运行确认失败**（Run: `swift test --filter CachePathsTests`）
- [ ] **Step 3: 实现 `CachePaths`**，用 `(host+remotePath+mtime+size)` 的哈希做目录名、原始文件名做末段。
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: Commit**（`feat: content-addressed cache paths`）

---

## Task 6: CredentialStore（Keychain）

**Files:**
- Create: `Sources/FerryKit/Security/CredentialStore.swift`
- Create: `Tests/FerryKitTests/CredentialStoreTests.swift`

**Interfaces:**
- Produces: `struct CredentialStore { init(service: String); func setPassword(_ p: String, for id: UUID) throws; func password(for id: UUID) throws -> String?; func removePassword(for id: UUID) throws }`。用 `kSecClassGenericPassword`，`service` 固定、`account` = favorite id 字符串。缺失返回 `nil`；`set` 覆盖已存在项。

- [ ] **Step 1: 写失败测试**（用唯一临时 service 名避免污染）：set→get 往返；覆盖后 get 为新值；remove 后 get 为 nil；未存过 get 为 nil。
- [ ] **Step 2: 运行确认失败**（Run: `swift test --filter CredentialStoreTests`。注：需本机 Keychain 可用；CI 无 Keychain 时标记跳过。）
- [ ] **Step 3: 实现 `CredentialStore`**（SecItemAdd/Copy/Update/Delete）。
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: Commit**（`feat: keychain credential store`）

---

## Task 7: SFTPSession（连接 + host key 校验 + 列目录/下载/上传）

依赖 Task 1 的 `LoopbackSSHServer` 与结论、Task 4 的 `KnownHostsStore`、Task 3 的 `RemotePath`。

**Files:**
- Create: `Sources/FerryKit/SFTP/RemoteEntry.swift`
- Create: `Sources/FerryKit/SFTP/HostKeyValidating.swift`
- Create: `Sources/FerryKit/SFTP/SFTPSession.swift`
- Create: `Sources/FerryKit/SFTP/SFTPError.swift`
- Create: `Tests/FerryKitTests/SFTPSessionTests.swift`

**Interfaces:**
- Consumes: `KnownHostsStore`、`RemotePath`、`LoopbackSSHServer`。
- Produces: `struct RemoteEntry: Equatable { let name: String; let path: String; let isDirectory: Bool; let size: Int64; let modified: Date }`。
- Produces: `protocol HostKeyValidating { func decide(host: String, port: Int, keyType: String, blob: Data) -> HostKeyDecision }` 及一个由 `KnownHostsStore` 支撑、未知时回调 UI 确认的实现接口 `TOFUHostKeyValidator`（UI 确认回调类型 `(_ fingerprint: String) async -> Bool`）。
- Produces: `enum SFTPError: Error { case connectionFailed, authenticationFailed, hostKeyChanged(fingerprint: String), hostKeyRejected, timeout, io(String) }`。
- Produces: `actor SFTPSession` with `static func connect(host: String, port: Int, username: String, auth: AuthInput, validator: HostKeyValidating) async throws -> SFTPSession`、`func list(_ path: String) async throws -> [RemoteEntry]`、`func download(_ remotePath: String, to localURL: URL) async throws`、`func upload(_ localURL: URL, to remotePath: String) async throws`、`func disconnect() async`。`AuthInput` = `.password(String)` 或 `.ed25519(privateKeyPEMPath: String)`。

- [ ] **Step 1: 写失败测试**（均对 loopback 服务器）

```swift
func test_connect_unknownHost_whenValidatorAccepts_succeeds() async throws
func test_connect_changedHostKey_throwsHostKeyChanged() async throws   // Review Focus
func test_connect_wrongPassword_throwsAuthenticationFailed() async throws
func test_list_returnsEntries_withUnicodeAndSpaceNames() async throws   // Review Focus: "a b.txt","日志.log"
func test_download_writesByteIdenticalFile() async throws
func test_upload_thenList_showsUploadedFile() async throws
```

- [ ] **Step 2: 运行确认失败**（Run: `swift test --filter SFTPSessionTests`）
- [ ] **Step 3: 实现 `RemoteEntry`/`HostKeyValidating`/`SFTPError`/`SFTPSession`**，按 Task 1 结论接入 Citadel 的 host key 回调；在回调里调 `validator.decide`，`.changed` → 抛 `hostKeyChanged` 并拒连，`.unknown` → 经 UI 确认回调决定是否 `trust` 后放行，`.match` → 放行。list 结果用 `RemotePath.join` 填 `path`。
  - 若 Task 1 结论为「loopback 服务器不支持 SFTP 子系统」：改用容器化 sshd 夹具或 `swift-nio-ssh` 的 SFTP server 实现承载本任务测试；该选择记在 `citadel-spike-findings.md`，不改变上述对外接口。
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: Commit**（`feat: SFTP session with host-key validation`）

---

## Task 8: FileOpenCoordinator（下载到缓存 + 默认程序打开）

**Files:**
- Create: `Sources/FerryKit/Open/FileOpenCoordinator.swift`
- Create: `Tests/FerryKitTests/FileOpenCoordinatorTests.swift`

**Interfaces:**
- Consumes: `SFTPSession`、`CachePaths`。
- Produces: `protocol FileOpening { func open(url: URL) }`（默认实现包 `NSWorkspace.shared.open`，便于测试注入 spy）。
- Produces: `struct FileOpenCoordinator { init(session: SFTPSession, cache: CachePaths, opener: FileOpening); func open(_ entry: RemoteEntry) async throws }`。逻辑：算缓存 URL；存在且匹配则复用（不重复下载），否则下载再打开；最后调 `opener.open(url:)`。

- [ ] **Step 1: 写失败测试**（session 用 loopback，opener 用 spy）：首次 open→下载发生且 opener 收到正确 URL；同 entry 再 open→不重复下载、opener 再次被调；mtime 变化的同路径 entry→重新下载到新 URL。
- [ ] **Step 2: 运行确认失败**（Run: `swift test --filter FileOpenCoordinatorTests`）
- [ ] **Step 3: 实现 `FileOpenCoordinator` 与默认 `FileOpening`**。
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: Commit**（`feat: open remote file via cache + NSWorkspace`）

---

## Task 9: SessionViewModel（UI 状态，单会话）

**Files:**
- Create: `Sources/FerryApp/SessionViewModel.swift`
- Create: `Tests/FerryAppTests/SessionViewModelTests.swift`
- Modify: `Package.swift`（加 `FerryApp` target 与其测试 target）

**Interfaces:**
- Consumes: `FerryKit` 全部。
- Produces: `@MainActor final class SessionViewModel: ObservableObject`，发布 `currentPath: String`、`entries: [RemoteEntry]`、`state: SessionState`（`.disconnected/.connecting/.connected/.failed(String)`）；方法 `connect(_ favorite: Favorite) async`、`navigate(to path: String) async`、`goUp() async`、`open(_ entry: RemoteEntry) async`。单会话：`connect` 前先断开已有会话。host key 未知/变更经注入的确认回调驱动。

- [ ] **Step 1: 写失败测试**（注入假的 session 工厂与 loopback）：`connect` 成功后 `state==.connected` 且 `entries` 非空；`navigate` 改 `currentPath` 并刷新 `entries`；`goUp` 在根目录为幂等；`connect` 第二个 favorite 前旧会话被断开（断言旧 session.disconnect 被调）。
- [ ] **Step 2: 运行确认失败**（Run: `swift test --filter SessionViewModelTests`）
- [ ] **Step 3: 实现 `SessionViewModel`**。
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: Commit**（`feat: single-session view model`）

---

## Task 10: SwiftUI 界面装配（Connect 对话框 + favorites 边栏 + 单栏浏览器）

界面以装配为主，逻辑已在 Task 9 测过；本任务做人工冒烟验收，不强求 UI 单测。

**Files:**
- Create: `Sources/FerryApp/FerryApp.swift`（`@main`）
- Create: `Sources/FerryApp/Views/ConnectView.swift`
- Create: `Sources/FerryApp/Views/FavoritesSidebar.swift`
- Create: `Sources/FerryApp/Views/RemoteBrowserView.swift`
- Create: `docs/superpowers/notes/smoke-checklist.md`

**Interfaces:**
- Consumes: `SessionViewModel`、`FavoritesStore`、`CredentialStore`、`Favorite`。
- `ConnectView` 字段：Protocol（固定 SFTP）、Server、Port（默认 22）、Username、密码/私钥切换、初始 Path、Note、Color、`Add to Favorites`、`Connect`；保存时密码进 Keychain、元数据进 FavoritesStore。
- `RemoteBrowserView`：顶部面包屑；列表列 名称/大小/修改时间/类型；双击目录→`navigate`，双击文件→`open`；支持从 Finder 拖入上传到当前目录。

- [ ] **Step 1: 实现四个视图与 `@main` app**，用 `@StateObject` 持 `SessionViewModel`，边栏绑 `FavoritesStore.load()`。
- [ ] **Step 2: 写冒烟清单** `smoke-checklist.md`：新建 favorite→连上→列目录→双击 `.html` 进浏览器、双击 `.log` 进编辑器→未知主机弹指纹确认→拖入一个文件上传成功。
- [ ] **Step 3: 构建并运行，按清单逐条人工验收**（Run: `swift build` 后运行 app；逐条勾选）。
- [ ] **Step 4: Commit**（`feat: SwiftUI connect dialog + single-pane remote browser`）

---

## 备注

- host key「未知时弹窗确认」的 UI 确认回调在 Task 7 以闭包形式留出，Task 9/10 注入真实弹窗；因此安全闭环（变更拦截）在 Task 7 已可测，UI 只是接线。
- 上传为次要功能，仅在 Task 7（能力）与 Task 10（入口）覆盖，不单独成任务。
- 「编辑后回传」不在本计划；其唯一改动点是 `FileOpenCoordinator`（Task 8），日后在此加「监视缓存文件改动→upload」。
