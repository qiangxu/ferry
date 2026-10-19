# Ferry — ProxyJump（经跳板机连接）· 设计文档

日期 2026-10-18 · 状态 待批准 · 增量于 v1（2026-10-18-ferry-sftp-client-design.md）

## 背景与意图

作者常用 `ssh -J qiangxu@ngrokd.xyz10.com:48425 qiangxu@192.168.3.180` 这样经一台跳板机连到内网目标机（180）。Ferry v1 只做单跳直连，连上跳板机后看到的是跳板机自己的目录，到不了 180。本增量给 Ferry 加 ProxyJump：像 `ssh -J` 那样，经一台跳板机连到目标机，浏览目标机的文件系统。

## 目标（Goals）

- Favorite 可选配置一台跳板机（host + port）；主 Server/Port/Username 仍指目标机。
- 连接时若配了跳板：先连跳板机，再从跳板机 `jump` 到目标机，SFTP 跑在目标机上（对应 `ssh -J`）。
- 两跳共用同一套凭证：同一 username + 同一 ed25519 私钥（或密码）。跳板机不单独配用户名/钥匙。
- 跳板机与目标机**各自做 host key TOFU 校验**：第一次连弹两次指纹确认（跳板一次、目标一次），都存进应用私有 known_hosts。
- Connect 对话框加一块跳板机填写（host + port）；留空即现在的单跳直连，行为不变。
- 向后兼容：已存的 favorite 没有跳板字段 = 直连。
- 「忘掉/重新信任主机」逃生口：`KnownHostsStore` 增加删除某条 host:port 记录的能力，界面上提供一个操作（按钮或右键）。用途：当某台主机（尤其跳板这类隧道端点）的 host key 合法轮换、被 changed→拒绝策略永久挡住时，用户不必手动编辑 known_hosts 文件就能忘掉旧记录、下次连接重新走 TOFU 确认。

## 非目标（Non-goals）

- 不做多级跳板链（只支持一台跳板，一次 jump）。`ssh -J a,b,c` 这种级联不做。
- 不做跳板机与目标机用不同凭证（不同用户名/不同钥匙/一边密码一边钥匙）——作者确认不会遇到。
- 不做 ssh-agent（延续 v1）。
- 不做跳板机上的端口转发暴露给用户配置（转发目标就是主 Server/Port，不额外开口子）。

## 反目标（Anti-goals）

- 跳过跳板机的 host key 校验（只校验目标、放过跳板）——算失败，跳板同样是 MITM 面。
- 把跳板凭证单独存一份、与目标凭证不一致——与「两跳同凭证」的事实背离，徒增复杂。

## 约束（Constraints）

- Citadel 0.12.1 的 jump API（`SSHClient` 连跳板后 `jump(to:)` 到目标）。确切签名、以及「每跳如何传 hostKeyValidator」「SFTP 如何在 jump 后的 client 上打开」需在计划首个任务里 spike 确认。
- 延续 v1：Swift 6.1.2 原生构建、Swift Testing（非 XCTest）、macOS 14+、纯 Swift Citadel（不引 C 依赖）、凭证进 Keychain、host key 走应用私有 known_hosts。

## 已定的「怎么做」（设计选择）

### 数据模型
- `Favorite` 增加两个可选字段：`jumpHost: String?`、`jumpPort: Int`（默认 22，`jumpHost` 为空/ nil 时忽略）。用户名与认证沿用现有字段（`username` / `auth` / `privateKeyPath`），两跳共用。
- JSON 向后兼容：旧 favorite 无这两个字段即直连；新字段可选。

### 连接层
- `SFTPSession.connect` 增加可选跳板参数（`jumpHost: String?`, `jumpPort: Int`）。
  - 无跳板：维持现有单跳路径，不变。
  - 有跳板：用同一 username + `AuthInput` 先连跳板机（经 `TOFUHostKeyValidator` 校验跳板 host key），再 `jump(to:)` 目标机（经 `TOFUHostKeyValidator` 校验目标 host key），SFTP 在目标机上打开。
- 两跳复用同一个 `KnownHostsStore`（按 host:port 分别记录跳板和目标的 key）。host key 策略不变：unknown→确认、changed→拒绝。
- known_hosts 仍只按 host:port 为键（跳板、目标各一条），与 `ssh -J` 一致，不做 jump 限定键。已知限制：两台不同物理机都用同一私有地址（如 192.168.3.180）会撞同一条、触发误报式「key 变更」拒绝——作者只有少数几台固定机，接受此限制。（评审确认，我的判断）

### 界面
- `ConnectView` 加一块跳板机填写：一个「经跳板机 / Via」开关或分区，展开后是 Jump host、Jump port 两个字段（port 默认 22）。留空=直连。
- `SessionViewModel.connect` 把 favorite 的跳板字段透传给 `SFTPSession.connect`。host key 确认弹窗两跳各弹一次。
- 确认闭包契约变更（评审确认，我的判断）：现有 `confirmHostKey: @Sendable (String) async -> Bool` 只带指纹，两跳弹两个一模一样的框、用户分不清在信任跳板还是目标。改为把主机身份一并传入，如 `(_ host: String, _ port: Int, _ fingerprint: String) async -> Bool`，弹窗明确写明是哪台主机的 key。此改动会波及 `SessionViewModel.init`、`TOFUHostKeyValidator`、FerryApp 的 `HostKeyPrompter` 接线及相关测试——属已知的小范围连锁改动，计划里单列。

### 观察自 ForkLift
ForkLift 的「Show Advanced」里有完整的 OpenSSH ProxyJump/ssh_config 选项。本增量只取「单台跳板 + 两跳同凭证 + 两段各校验 host key」这一最小闭环，其余 ssh_config 选项不做。

## 留给 builder 的部分
- Citadel 0.12.1 jump API 的确切用法（spike 确认：连跳板→`jump(to:)`→在目标 client 上 `openSFTP`；每跳 hostKeyValidator 如何分别传入；错误如何区分「跳板连不上」vs「目标连不上」映射到 `SFTPError`）。这是计划第一个任务，像 v1 的 Task 1 一样先验。
- 两跳集成测试的夹具：需要一个「跳板 SSH server 转发到目标 SSH server」的 loopback 结构（两台 loopback server，第一台允许 direct-tcpip 转发到第二台）。Citadel server 是否支持 direct-tcpip 转发以支撑该测试，需 spike 确认；若不支持，退而用「连通性 + host key 两段校验」的可测子集，并在结论文档说明。
- ConnectView 里跳板区块的具体摆放（Show Advanced 之下还是独立一行）、`jumpPort` 的校验与占位符。
- 错误提示文案：跳板连接失败 vs 目标连接失败要能区分。
- 「忘掉主机」的 UI 落点（favorites 右键？连接失败弹窗里的按钮？known_hosts 管理面板？）由 builder 选最简路径；`KnownHostsStore.remove(host:port:)` 的实现（重写文件去掉匹配行）由 builder 定。

## 评审确认（2026-10-18）

一个工程师 reviewer 读过本文档，提了三点：

作者拍板的：
- 加「忘掉/重新信任主机」逃生口（见 Goals）。理由：跳板是 ngrok 隧道端点，host key 真轮换时严格策略会永久挡住；端口变只是重新弹框不锁死，但 key 轮换需要这个出口。

我替作者定的（my call）：
- host key 确认闭包改为携带 host:port（见「界面」），让两跳的指纹确认框能分清在信任哪台主机——安全 UX，不改变功能本身。波及 SessionViewModel/HostKeyPrompter/测试，计划单列小改。
- known_hosts 仍按 host:port 为键（见「连接层」），与 ssh -J 一致；接受「不同机器复用同一私有地址会撞」的已知限制。

留给计划 spike（builder，非作者）：Citadel 0.12.1 jump API 的确切用法、两跳 loopback 测试夹具可行性——计划首个任务先验。
