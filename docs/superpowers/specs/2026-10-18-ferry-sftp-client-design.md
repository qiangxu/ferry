# Ferry — 一个可改造的 macOS SFTP 小客户端 · 设计文档

日期 2026-10-18 · 状态 待批准

## 背景与意图

作者（qiangxu）长期用 ForkLift 的 SFTP 客户端功能，最常做的事是：连到几台固定服务器，浏览远程目录，把日志、中间结果文件拉出来看，偶尔传一个部署包上去。他喜欢 ForkLift 里「远程文件像本地文件一样，点一下就在 Finder/默认程序里打开」的体验。

做这个项目不是因为 ForkLift 哪里不够用，而是想拥有一份自己能随时改的原生 Swift 代码。所以本项目的首要价值不是功能对标，而是代码小、好读、好改。任何在「更多功能」和「更简单的代码」之间的取舍，一律偏向后者。

本设计中标注为「观察自 ForkLift」的是对 ForkLift 4.7.6 做静态逆向（Ghidra 伪代码 + 符号/字符串）得到的行为事实；其余是本项目的设计选择，不代表 ForkLift 的实现方式。

## 目标（Goals）

- Favorites：保存好的连接，点一下即连，针对作者那几台固定服务器（如内网的 dolphin/180 等）。
- 单栏远程目录浏览器，像 Finder 一样导航（进目录、返回、面包屑路径）。
- Finder 式「点开即看」：双击远程文件 → 自动抓到本地缓存 → 用系统默认程序打开（.html 进浏览器、.log 进文本编辑器等）。当前阶段只做查看。
- SFTP 认证支持两种：密码、SSH 私钥（v1 限未加密的 ED25519 私钥，正好覆盖作者当前的 `~/.ssh/id_ed25519`）。RSA 私钥、带 passphrase 的加密私钥不在 v1，理由见「技术选型」与「评审确认」。
- Host key 校验采用 OpenSSH 式 TOFU：未知主机弹窗展示 SHA256 指纹让用户确认；已知主机 key 变更则拒绝连接并告警；known_hosts 记录存本地。
- 凭证（密码、私钥 passphrase）存入 macOS Keychain；favorites 的非敏感元数据存 Application Support 下的 JSON。
- 偶尔的上传（部署包）作为次要功能：从本地拖入或按钮选择后上传到当前远程目录。

## 非目标（Non-goals）

- 不做「编辑后自动传回服务器」。架构上要给它留位置（见下文 FileOpenCoordinator），但本期不实现。
- 不做左右双栏、不做本地↔远程对拖的对称文件管理器。
- 不做 SFTP 以外的任何协议（FTP、S3、WebDAV、云盘等一概不碰）。
- 不追求在功能数量上接近 ForkLift。

## 反目标（Anti-goals，即便技术上能跑也算失败）

- 代码复杂到作者不愿意动手改。宁可功能少，不要架构绕。
- 引入重量级或难读的依赖（例如为了「全功能」去包 libssh2 C 库）。
- 安全上偷工：静默接受未知/变更的 host key、把密码明文落盘，都算失败。

## 约束（Constraints）

- 平台：原生 macOS，Swift + SwiftUI。目标系统版本 macOS 14（Sonoma）及以上（本项目作者设备为 macOS 15 / Darwin 24）。
- 分发：本地开发自用，开发者签名即可，不走 App Store、不做公证流程（builder 可后补）。
- 单用户、本机运行，无后端服务。
- 同一时间只保持一个活动 SFTP 连接；切换到另一个 favorite 即断开前一个。会话层据此按单会话设计（见「评审确认」）。
- 网络环境：作者常开 Clash VPN（TUN 透明代理）；SFTP 连接走普通 TCP，无需特殊处理，但连接超时/中断的错误提示要清楚。

## 已定的「怎么做」（设计选择）

### 技术选型

- 语言/界面：Swift + SwiftUI，单窗口 macOS app。
- SSH/SFTP 库：Citadel（基于 SwiftNIO SSH 的纯 Swift 库，含 SFTP 客户端），通过 SPM 引入。
  - 选它的唯一理由就是「可改」：纯 Swift、无 C 互操作，读改都顺。
  - 已知代价：ssh-agent、keyboard-interactive、部分冷门 KEX/算法的支持不如 libssh2 全。对本项目的密码/私钥场景够用。若日后需要，换 libssh2 是一次独立改造，不在本期。
  - 密钥能力边界（评审时对照 Citadel 文档核实）：主线 Citadel 支持 Curve25519/ed25519 私钥（作者当前的 key 即此类，且未加密）；RSA 私钥认证只存在于 NIOSSH 的一个 fork，不在 v1；磁盘上带 passphrase 的加密私钥，Citadel 无现成解密支持，也不在 v1。v1 只认未加密 ed25519 + 密码。
  - 观察自 ForkLift：ForkLift 用的是静态链接的 libssh2（新版，已含 Terrapin/CVE-2023-48795 的 strict-KEX 缓解），支持 password/publickey/keyboard-interactive/agent 四种认证。本项目只取 password + publickey 两种，是刻意缩小。

### 打开远程文件的流程

- 双击文件 → 经一个 `FileOpenCoordinator` 组件：
  1. 把远程文件下载到本机缓存目录（`~/Library/Caches/<bundleid>/` 下，按 host+远程路径组织，带远程 mtime/size 以便判断是否复用缓存）。
  2. 用 `NSWorkspace.shared.open(_:)` 交给系统默认程序打开。
- 本期为只读查看：缓存文件的本地改动不回传。
- 预留 write-back 的缝：`FileOpenCoordinator` 是未来挂「监视缓存文件改动 → 上传回远程」的唯一改动点，本期不实现但接口留好。
- 观察自 ForkLift：ForkLift 链接了 FileProvider 框架来做「远程即本地」的挂载式体验。本项目不用 FileProvider（那是一套更重的 File Provider extension 机制），改用「下载到缓存 + NSWorkspace 打开」的轻量做法，这是刻意简化，交互上对「点开就看」已经等价。

### Host key 校验

- 连接时用 SSH 层回调拿到服务器 host key，计算 SHA256 指纹。
- 维护一个**应用私有**的 known_hosts 文件（Application Support 下，OpenSSH 兼容格式）：
  - 未知主机：弹窗显示 `host:port` 与 SHA256 指纹，用户确认后写入。
  - 已知且匹配：直接放行。
  - 已知但 key 变了：拒绝连接，弹窗明确告警（可能的中间人），不提供「一键接受」。
- 设计决定（builder 之外、我的判断）：用应用私有 known_hosts，不直接读写用户的 `~/.ssh/known_hosts`，以免这个小工具污染作者真实的 SSH 配置。若日后想复用系统 known_hosts，作为一个 opt-in 开关另加。
- 待验证的技术风险（计划阶段先 spike，再定 host key 模块）：Citadel 的自定义 `hostKeyValidator` 是否把服务器的原始 host key（`NIOSSHPublicKey` 字节）交给应用。README 只演示了 `.acceptAnything()`。本设计的 TOFU + 指纹确认 + 变更拦截依赖拿到原始 key 来算 SHA256；若自定义 validator 只给「接受/拒绝预置 key」而不暴露原始 key，host key 模块要围绕它实际暴露的接口重新设计（必要时下沉到 NIOSSH 层）。计划阶段用一个最小 spike 先确认，再动手。
- 观察自 ForkLift：ForkLift 实现了完整的 OpenSSH `ssh_config` 语义（strictHostKeyChecking 含 accept-new、userKnownHostsFile/globalKnownHostsFile、verifyHostKeyDNS、revokedHostKeys、fingerprintHash、hashKnownHosts 等），并在未知主机时弹窗确认指纹。本项目只取「TOFU + 变更拦截」这一最小安全闭环，其余 OpenSSH 选项不做。

### 凭证与 favorites 存储

- Keychain：密码、私钥 passphrase。以 service = bundle id、account = favorite id 的形式存取。
- Favorites 元数据：Application Support 下一个 JSON，字段至少包含
  - id、显示名、host、port（默认 22）、username
  - 认证方式（password | privateKey）、私钥文件路径（privateKey 时）
  - 初始远程路径、颜色标签、备注
  - 不在 JSON 里存任何密码/passphrase（那些在 Keychain）。
- 观察自 ForkLift：ForkLift 的 favorite 字段（Server/Port/Username/Password/Path/Local Path/Base URL/Text Encoding/Note/Color Label 等）与此对应；本项目去掉 Base URL、Text Encoding 等当前场景用不到的项。

### 界面结构

- 单窗口，左侧 favorites 边栏 + 右侧主区。
- Connect 对话框（参照 ForkLift 的 Connect 面板，但只留 SFTP 需要的字段）：
  - Protocol 固定 SFTP、Server、Port（默认 22）、Username、Password/私钥切换、初始 Path、Note、Color、以及 "Add to Favorites" 与 "Connect"。
- 主区：单栏远程文件列表（列：名称、大小、修改时间、类型），顶部面包屑路径，双击目录进入、双击文件按上文流程打开，返回/上级操作。
- 上传（次要）：主区支持从 Finder 拖入文件上传到当前目录，或一个上传按钮。

## 留给 builder 的部分

- SwiftUI 的具体视图拆分、状态管理（建议 async/await + 一个连接会话的 actor/ObservableObject）。
- 并发与取消：远程列目录、下载、上传的异步结构与进度/取消 UI。
- 缓存目录的组织细节与清理策略（何时失效、是否手动清缓存）。
- 错误处理与提示文案的具体设计（连接失败、认证失败、host key 变更、网络中断）。
- 大文件下载的进度展示与中断续传是否需要（本期可先不做续传）。
- 打包、开发者签名与本地运行的工程配置。
- 首个里程碑建议：先打通「Connect 对话框 → 连上 → 单栏列目录 → 双击 .html/.log 用默认程序打开」这条主链路，favorites、上传、颜色标签等随后迭代。

## 评审确认（2026-10-18）

一个工程师 reviewer 读过本文档，提了三个会影响计划的点，处理如下：

作者拍板的：
- 认证范围：v1 只支持未加密 ED25519 私钥 + 密码。依据是作者 `~/.ssh` 下只有一把未加密的 ed25519 key，且 Citadel 主线正好支持此类。RSA、带 passphrase 的加密私钥明确推迟。
- 连接数：同一时间只保持一个活动连接，会话层按单会话设计。

作者机器上核实的事实（非假设）：
- 作者唯一的 SSH 私钥是 `~/.ssh/id_ed25519`（ED25519，256 位，未加密）。
- Citadel 主线支持 ed25519/Curve25519 私钥；RSA 仅在 NIOSSH 的 fork；加密私钥无现成解密支持。据此划定了上面的认证范围。

留作计划阶段处理（builder/我，非作者）：
- host key 风险：Citadel 自定义 `hostKeyValidator` 是否暴露原始 host key 待一个最小 spike 确认，再定 host key 模块（见「Host key 校验」）。
