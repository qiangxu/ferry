# Ferry ProxyJump 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Ferry 像 `ssh -J` 那样经一台跳板机连到目标机并浏览目标机文件，两跳共用同一凭证、各自做 host key TOFU，并提供「忘掉/重新信任主机」逃生口。

**Architecture:** 在 v1 基础上增量：`SFTPSession.connect` 增加可选跳板参数，用 Citadel 的 `jump(to:)` 做两跳；host key 确认闭包改为携带 host:port 以区分两跳；`Favorite` 增加跳板地址字段；`KnownHostsStore` 增加删除能力。先用一个 spike 任务验 Citadel 0.12.1 的 jump API 与两跳 loopback 测试夹具。

**Tech Stack:** Swift 6.1.2 / SwiftUI、Citadel 0.12.1（`SSHClient.jump`）、Swift Testing、Security.framework。

**Spec:** `docs/superpowers/specs/2026-10-18-ferry-proxyjump-design.md`

## Global Constraints

- 延续 v1：Swift 6.1.2 原生 `swift test`（无 Xcode / `-Xswiftc` flag），测试用 Swift Testing（`@Test`/`#expect`），非 XCTest。
- 纯 Swift Citadel 0.12.1，不引 libssh2/C 依赖。
- 两跳共用同一 username + 同一 `AuthInput`（ed25519 未加密 或 密码）。跳板不单独配凭证。
- host key 策略不变：unknown→确认、changed→拒绝；跳板与目标各自校验，均经同一 `KnownHostsStore`，按 host:port 为键。
- 向后兼容：无跳板字段的旧 favorite = 直连；现有 50 个测试须保持绿。
- 提交 message 结尾附：`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。不得 `git add` `.superpowers/` 下任何文件。

## Review Focus

- 跳板机 host key 变更（对跳板的 MITM）：必须 `hostKeyChanged` 拒绝、不连。→ 测试落在 Task 5。
- 首次两跳：弹两次指纹确认且每次能看出是哪台主机（跳板 vs 目标）。→ 测试落在 Task 2（闭包带 host）+ Task 5（两跳各调一次）。
- 旧 favorite JSON 无跳板字段：解码为直连（jumpHost=nil, jumpPort=22），不崩。→ 测试落在 Task 3。
- 跳板连不上 vs 目标连不上：错误可区分，不混成一个。→ 测试落在 Task 5。
- 忘掉主机后重连：该 host:port 重新变 unknown、再次走 TOFU。→ 测试落在 Task 4。

---

## Task 1: Spike — Citadel jump API + 两跳 loopback 夹具

验两件事：Citadel 0.12.1 怎么做 ProxyJump（连跳板→`jump(to:)`→在目标 client 上 `openSFTP`；每跳 hostKeyValidator 如何分别传入；跳板失败 vs 目标失败如何区分），以及能否用两台 loopback server（跳板允许 direct-tcpip 转发到目标）搭两跳集成测试。

**Files:**
- Create: `Tests/FerryKitTests/ProxyJumpSpikeTests.swift`
- Modify: `Tests/FerryKitTests/Support/LoopbackSSHServer.swift`（若需支持转发/串联）
- Create: `docs/superpowers/notes/citadel-jump-findings.md`

**Interfaces:**
- Produces: 结论文档说明 ① `SSHClient` 连跳板后到目标的确切调用序列与类型；② 两跳各自 hostKeyValidator 的传法；③ 跳板失败与目标失败的错误形态；④ loopback 两跳夹具能否成立（Citadel server 是否支持 direct-tcpip 转发），若不成立给出 Task 5 可测子集。
- Produces: 若可行，一个可复用的「两跳 loopback」测试辅助（跳板 server 转发到目标 server），供 Task 5。

- [ ] **Step 1: 写失败的 spike 测试 `test_connectTargetThroughJump_overLoopback`**：起两台 `LoopbackSSHServer`（jump、target），客户端连 jump 后 `jump(to: target)`，在 target 上 `openSFTP` 并 `listDirectory("/")`，断言拿到 target 夹具（非 jump 夹具）的内容。
- [ ] **Step 2: 运行确认失败**（Run: `swift test --filter ProxyJumpSpikeTests > /tmp/j.out 2>&1; tail -8 /tmp/j.out`；Expected: 编译/断言失败）
- [ ] **Step 3: 实现夹具串联与客户端两跳**，按 Citadel 实际 API 接。如 Citadel server 不支持 direct-tcpip 转发：改为验证「连跳板 + 对跳板做 host key 校验」的子集，并在结论文档记录对 Task 5 的影响。
- [ ] **Step 4: 运行确认通过**（Expected: PASS，或记录受限结论）
- [ ] **Step 5: 写结论文档** `citadel-jump-findings.md`。
- [ ] **Step 6: Commit**（`chore: spike Citadel jump API + two-hop loopback`）

---

## Task 2: host key 确认闭包携带 host:port

现有 `confirmHostKey` 只带指纹；两跳会弹两个无法区分的框。改为带上主机身份。这是对既有代码的重构，须保持 50 个测试绿（同步改签名与接线）。

**Files:**
- Modify: `Sources/FerryKit/SFTP/HostKeyValidating.swift`（`TOFUHostKeyValidator` 的 confirm 类型）
- Modify: `Sources/FerryApp/SessionViewModel.swift`（`init` 的 `confirmHostKey` 参数类型）
- Modify: `Sources/FerryApp/*`（`HostKeyPrompter` / RootView 弹窗，显示主机）
- Modify: 相关测试中构造 validator / ViewModel 的调用

**Interfaces:**
- Produces: `TOFUHostKeyValidator(store:confirm:)` 的 `confirm` 改为 `@Sendable (_ host: String, _ port: Int, _ fingerprint: String) async -> Bool`；validator 在 `.unknown` 时把它已持有的 host/port 一并传入。
- Produces: `SessionViewModel.init(... confirmHostKey: @Sendable (String, Int, String) async -> Bool ...)`，向 UI 透传。
- Produces: `HostKeyPrompter` 在弹窗文案里展示 `host:port` 与指纹。

- [ ] **Step 1: 改失败测试**：把一个现有 host-key 确认测试的 confirm 闭包改成新签名，并新增断言 `test_unknownHost_confirmReceivesHostAndPort`（validator 调 confirm 时收到正确的 host 与 port）。
- [ ] **Step 2: 运行确认失败**（Run: `swift test --filter HostKey > /tmp/h.out 2>&1; tail -8 /tmp/h.out`）
- [ ] **Step 3: 改 `TOFUHostKeyValidator`、`SessionViewModel.init`、`HostKeyPrompter` 及所有调用点**到新签名。
- [ ] **Step 4: 运行全量确认通过**（`swift test`，50 测试 + 新增仍绿）
- [ ] **Step 5: Commit**（`refactor: host-key confirm closure carries host:port`）

---

## Task 3: Favorite 跳板字段 + 向后兼容

**Files:**
- Modify: `Sources/FerryKit/Models/Favorite.swift`
- Test: `Tests/FerryKitTests/FavoritesStoreTests.swift`

**Interfaces:**
- Produces: `Favorite` 增加 `jumpHost: String?`、`jumpPort: Int`（默认 22）。保持 `Codable, Identifiable, Equatable, Sendable`。解码旧 JSON（无这两键）时 `jumpHost=nil`、`jumpPort=22`。JSON 仍不含任何密码。

- [ ] **Step 1: 写失败测试**：`test_favoriteWithJumpHost_roundTrips`；`test_decodeLegacyJSON_withoutJumpFields_defaultsToDirect`（手写一段无 jump 键的 JSON，断言解码成功、jumpHost==nil、jumpPort==22）。
- [ ] **Step 2: 运行确认失败**（`swift test --filter FavoritesStore`）
- [ ] **Step 3: 加字段**，用默认值/自定义解码保证旧 JSON 兼容。
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: Commit**（`feat: favorite jump-host fields (backward compatible)`）

---

## Task 4: KnownHostsStore.remove（忘掉主机）

**Files:**
- Modify: `Sources/FerryKit/Security/KnownHostsStore.swift`
- Test: `Tests/FerryKitTests/KnownHostsStoreTests.swift`

**Interfaces:**
- Produces: `func remove(host: String, port: Int) throws`：重写 known_hosts 文件、删掉匹配该 host:port（含端口 22 的裸形与非 22 的 `[host]:port` 形）的行；保留其它行；文件不存在视为无操作。host 比较与 `decision`/`trust` 一致（小写化）。

- [ ] **Step 1: 写失败测试**：`test_removeThenDecision_returnsUnknown`（trust 后 remove，再 decision 为 `.unknown`）；`test_remove_keepsOtherHosts`（两台主机，remove 其一不动另一）；`test_remove_nonStandardPortBracketForm`。
- [ ] **Step 2: 运行确认失败**（`swift test --filter KnownHostsStore`）
- [ ] **Step 3: 实现 `remove`**。
- [ ] **Step 4: 运行确认通过**
- [ ] **Step 5: Commit**（`feat: known_hosts remove (forget host)`）

---

## Task 5: SFTPSession 两跳连接

依赖 Task 1 的结论/夹具、Task 2 的新 confirm 契约。

**Files:**
- Modify: `Sources/FerryKit/SFTP/SFTPSession.swift`
- Modify: `Sources/FerryKit/SFTP/SFTPError.swift`（若需区分跳板/目标失败）
- Test: `Tests/FerryKitTests/SFTPSessionTests.swift`

**Interfaces:**
- Consumes: Task 1 的 Citadel jump 调用序列与两跳 loopback 夹具；Task 2 的 `HostKeyValidating`/`TOFUHostKeyValidator`。
- Produces: `SFTPSession.connect` 增加参数 `jumpHost: String?`（默认 nil）、`jumpPort: Int`（默认 22）。`jumpHost` 为 nil/空 → 维持现有单跳，行为与签名其余部分不变。非空 → 用同一 `username`+`auth` 先连跳板（经 `validator` 校验跳板 host key），再 `jump(to:)` 目标（经 `validator` 校验目标 host key），`openSFTP` 在目标上。
- Produces: 错误区分——跳板阶段失败与目标阶段失败映射到不同 `SFTPError`（如复用 `.connectionFailed` 但带阶段信息，或新增 `.jumpConnectionFailed`；具体由 Task 1 结论定，在本任务 Interfaces 注明最终形态）。

- [ ] **Step 1: 写失败测试**（对两跳 loopback 夹具）：
  - `test_connectThroughJump_listsTargetDirectory`（列到的是目标夹具内容）
  - `test_jumpHostChangedKey_throws`（跳板 host key 变更 → 拒绝，不连）  // Review Focus
  - `test_firstTimeJump_promptsForJumpThenTarget`（confirm 被按「跳板、目标」顺序各调一次，host 参数正确）  // Review Focus
  - `test_jumpUnreachable_vs_targetUnreachable_distinctErrors`  // Review Focus
  - 若 Task 1 结论为夹具受限：按其可测子集实现等价断言，并在报告说明。
- [ ] **Step 2: 运行确认失败**（`swift test --filter SFTPSession > /tmp/s.out 2>&1; tail -10 /tmp/s.out`）
- [ ] **Step 3: 实现两跳 connect**，按 Task 1 的 API 结论接 Citadel `jump`。
- [ ] **Step 4: 运行全量确认通过**
- [ ] **Step 5: Commit**（`feat: SFTP connect through a jump host`）

---

## Task 6: UI 装配 — 跳板字段 + 接线 + 忘掉主机

依赖 Task 3（Favorite 字段）、Task 4（remove）、Task 5（两跳 connect）、Task 2（confirm 契约）。以装配为主，人工冒烟，不强求 UI 单测；`swift build` 须编译、`swift test` 须保持绿。

**Files:**
- Modify: `Sources/FerryApp/Views/ConnectView.swift`（跳板 host/port 字段）
- Modify: `Sources/FerryApp/SessionViewModel.swift`（透传 jump 字段；一个 `forgetHost(host:port:)` 入口调 `KnownHostsStore.remove`）
- Modify: `Sources/FerryApp/Views/*`（favorites 右键或连接失败弹窗里「忘掉这台主机」操作）
- Modify: `docs/superpowers/notes/smoke-checklist.md`

**Interfaces:**
- Consumes: `Favorite.jumpHost/jumpPort`、`SFTPSession.connect(... jumpHost:jumpPort:)`、`KnownHostsStore.remove`、Task 2 的 confirm 契约。

- [ ] **Step 1: 实现 ConnectView 跳板字段**：一个「经跳板机」开关/分区，展开后 Jump host、Jump port（默认 22，占位「blank = 直连」）；save 时写入 Favorite。留空=直连。
- [ ] **Step 2: 接线 SessionViewModel.connect**：把 `favorite.jumpHost/jumpPort` 透传给 `SFTPSession.connect`；加 `forgetHost(host:port:)` 调 `KnownHostsStore.remove`。
- [ ] **Step 3: 加「忘掉这台主机」UI 操作**（favorites 右键或连接失败提示里的按钮），调 `forgetHost`。
- [ ] **Step 4: `swift build` + `swift test`**（编译通过、既有测试全绿）。
- [ ] **Step 5: 更新冒烟清单**：经跳板连 180、首次两次指纹确认（各显主机）、列到 180 的目录、忘掉某主机后重连重新确认。
- [ ] **Step 6: Commit**（`feat: jump-host UI + forget-host action`）

---

## 备注
- 两跳同凭证是硬约束：`SFTPSession.connect` 不为跳板单设 username/auth 参数。
- 若 Task 1 判定 Citadel server 不支持 direct-tcpip 转发，Task 5 的两跳集成测试退化为「连跳板 + 两段 host key 校验 + 错误区分」的可测子集，功能代码仍按完整两跳实现；该取舍记入 `citadel-jump-findings.md` 与 Task 5 报告。
