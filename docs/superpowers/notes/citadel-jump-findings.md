# Citadel 0.12.1 ProxyJump 调研结论

结论：jump API 可用，两跳 loopback 夹具可行（需要自带转发 delegate，见下）。验证测试：`Tests/FerryKitTests/ProxyJumpSpikeTests.swift`。

## 1. 调用序列

```swift
let jumpClient = try await SSHClient.connect(to: SSHClientSettings)      // 跳板
let targetClient = try await jumpClient.jump(to: SSHClientSettings)      // 目标，走跳板上的 direct-tcpip 通道
let sftp = try await targetClient.openSFTP()                             // 在目标 client 上开 SFTP
```

- `SSHClientSettings(host:port:authenticationMethod:hostKeyValidator:)`，`authenticationMethod` 是 `@Sendable () -> SSHAuthenticationMethod` 闭包，`hostKeyValidator` 是 `SSHHostKeyValidator`。可再设 `connectTimeout`（默认 30s）、`algorithms`、`protocolOptions`、`group`。
- 注意：现有单跳用的是 `SSHClient.connect(host:port:authenticationMethod:hostKeyValidator:reconnect:)`，两跳要换成 `connect(to: settings)` 这个重载。
- `jump(to:)` 的 settings.host/port 是**从跳板视角**解析的目标地址（跳板去连它），不是客户端本机。
- 关闭：先 `sftp.close()`，再 `targetClient.close()`，最后 `jumpClient.close()`。jumpClient 必须在 target 使用期间保持存活，Task 5 的 SFTPSession 要同时持有两个 client。
- `jump` 内部 originatorAddress 写死 `fe80::1:22`，无影响。

## 2. 每跳各自的 hostKeyValidator

每个 `SSHClientSettings` 自带 `hostKeyValidator`，两跳互相独立。Ferry 的 `PolicyHostKeyDelegate` 接 `.custom(delegate)`，各自构造一个（host/port 分别是跳板和目标），TOFU 就能对两台分别记录。测试里两个 delegate 各自收到了对应服务器的 host key（`jump.hostKey`、`target.hostKey`）。目标的 host key 校验发生在经跳板转发的通道内，在 `jump(to:)` 期间执行。

## 3. 错误形态（实测）

| 场景 | 抛出位置 | 错误 |
| --- | --- | --- |
| 跳板 host key 被拒 | `SSHClient.connect(to:)` | validator 在 promise 里 fail 的原始错误（和单跳一致，用 errorBox 可捕获） |
| 跳板认证失败 | `SSHClient.connect(to:)` | `SSHClientError.allAuthenticationOptionsFailed`（按单跳现有映射） |
| 目标 host key 被拒 | `jump(to:)` | validator 的原始错误 |
| 目标认证失败 | `jump(to:)` | `SSHClientError.allAuthenticationOptionsFailed` |
| 跳板不允许转发 / 目标端口连不上 | `jump(to:)` | `NIOSSHError.channelSetupRejected` (Reason: 2，即 connect failed)，两种原因不可区分 |

区分跳板和目标失败靠调用位置，不靠错误类型：`connect(to:)` 抛的是跳板的问题，`jump(to:)` 抛的是目标（或转发）的问题。Task 5 需要在两个 `do/catch` 里分别包装，并给 `PolicyHostKeyDelegate` 各配一个 errorBox，错误里带上是哪一跳。认证失败的错误类型两跳相同，只能靠位置标注。

## 4. 两跳 loopback 夹具

可行，但 Citadel 自带的 `DirectTCPIPForwardingDelegate` 不能用：
- 它的 remote 侧 `ProxyChannelHandler` 只是 outbound handler，目标到客户端方向没有 inbound 中继；
- 它自己又加了一个 `DataToBufferCodec`，而 `SSHServer` 在调 delegate 前已经加过一个，双重 codec 导致 NIO 在 `NIOAny` 解包时 fatalError（"tried to decode as type SSHChannelData but found IOData"），整个测试进程崩溃，不是可捕获的错误。

做法：`LoopbackSSHServer` 新增 `allowDirectTCPIP: Bool = false` 参数，为 true 时 `enableDirectTCPIP(withDelegate: LoopbackForwardingDelegate())`。`LoopbackForwardingDelegate`（同文件）自己连目标，两端各挂一个 `Relay` inbound handler 做双向转发，不再加 codec。

Task 5 用法：起 jump（`allowDirectTCPIP: true`）和 target 两台 server，各用不同的 `TempDirSFTPDelegate` 根目录，客户端 `connect(to:)` jump 再 `jump(to:)` target，列目录断言得到的是 target 的内容。未开转发的 server 作跳板可用来测"转发被拒"（`channelSetupRejected`）。
