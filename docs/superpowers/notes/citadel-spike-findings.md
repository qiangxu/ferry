# Citadel spike 结论

日期：2026-10-18。版本：Citadel 0.12.1（Package.swift 中 exact 锁定），其依赖 swift-nio-ssh 为 Wellz26 的 fork，解析到 0.3.7，swift-nio 2.104.0。

## 1. 自定义 hostKeyValidator 是否暴露原始 host key

暴露。`SSHHostKeyValidator.custom(_:)` 接收任意 `NIOSSHClientServerAuthenticationDelegate`，其 `validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise:)` 拿到的就是服务器握手时出示的 `NIOSSHPublicKey`，与服务器 `NIOSSHPrivateKey.publicKey` 相等。

取字节的方式：`NIOSSHPublicKey.write(to: inout ByteBuffer)` 是 public，写出的是 SSH wire 格式 blob（含 `ssh-ed25519` 类型串头），与 `~/.ssh/known_hosts` 里 base64 解码后的内容一致。对这段 blob 做 SHA256 再 base64（去掉 `=` 填充），加 `SHA256:` 前缀，就是 OpenSSH 风格指纹。测试里的 `sha256Fingerprint` 即这样实现，且 client 侧与 server 侧指纹一致（`customValidatorReceivesServerHostKey` 通过）。

另外：`NIOSSHPublicKey` 是 Hashable，可直接放 Set 比较；`init(openSSHPublicKey:)` 可从 known_hosts 里的 `type base64` 文本还原，因此 Task 4 的 KnownHostsStore 可以直接存 blob 或 OpenSSH 文本，比对时用 `==` 或比对 blob 均可。validator 的 promise 可以异步完成，所以 TOFU 弹窗（等用户点确认再 succeed/fail）可以直接挂在 `validationCompletePromise` 上，不需要下沉到 NIOSSH 层。

对 Task 4/7 的影响：按这个接口设计即可，host key 模块不需要换形态。

## 2. loopback 服务器

可以。Citadel 自带 `SSHServer.host(host:port:hostKeys:authenticationDelegate:group:)`，传 `port: 0` 让系统分配端口，用 `server.channel.localAddress?.port` 读回（`channel` 是 internal，所以夹具文件 `@testable import Citadel`，测试在 debug 下构建，没问题）。夹具 `LoopbackSSHServer` 每个实例生成新的 Ed25519 host key，支持密码认证，传入 `authorizedEd25519PublicKey` 时额外支持公钥认证（`publicKeyAuthAgainstLoopbackServer` 通过）。

SFTP 子系统也能承载：`server.enableSFTP(withDelegate:)` 接一个 `SFTPDelegate`，客户端 `openSFTP()` + `listDirectory` 走通（`loopbackServerServesSFTPSubsystem` 通过，用的是只读的 `StubSFTPDelegate`，只返回固定的 `hello.txt`）。所以 Task 7/8 的集成测试不需要容器 sshd，也不需要外部网络。Task 7 要做的是写一个基于临时目录的真实 `SFTPDelegate`（目前只有协议和 stub，没有现成的文件系统实现），夹具已留了 `sftpDelegate:` 参数。

注意点：SFTPDelegate 协议有 11 个方法，openFile 返回的 `SFTPFileHandle` 需要自己实现读写，Task 7 的工作量主要在这里。

## 3. 本机环境问题（影响后续所有任务的测试写法）

本机只装了 Command Line Tools（Swift 6.2.3），没有 Xcode，且 CLT 安装是半更新状态，三个问题：

1. `swift package`/`swift build` 在任何 Package.swift 上都链接失败。原因是 `ManifestAPI/PackageDescription.swiftmodule` 里残留了 2024 年的 `*.private.swiftinterface`（Swift 5.10），与新的 `libPackageDescription.dylib` 不匹配。
2. 没有 XCTest。`import XCTest` 报 no such module，所以 spike 测试改用 Swift Testing（`import Testing`，`@Test`、`#expect`），不是计划里写的 XCTest 语法。后续任务计划中的 XCTest 示例需要同样转换（或者装上 Xcode 后恢复 XCTest）。
3. `Testing.framework` 可用，但 `_Testing_Foundation.framework` 缺 Modules。同一个文件里同时 `import Foundation` 和 `import Testing` 会报 no such module '_Testing_Foundation'。绕法：测试文件不 import Foundation，需要 Foundation 的辅助代码放进 `Support/` 里的单独文件。

本次的临时绕法（不入库）：把 `/Library/Developer/CommandLineTools` 的 usr 和 Library 复制到临时目录，删掉 stale 的 `*.private.swiftinterface`，把该目录的 `usr/bin` 放到 PATH 最前，再跑：

```
swift test -Xswiftc -F -Xswiftc <copy>/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker <copy>/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker <copy>/Library/Developer/Frameworks
```

根治办法是装完整 Xcode（或重装 CLT），之后这些绕法都不需要，XCTest 也恢复可用。
