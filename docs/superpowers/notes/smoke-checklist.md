# Ferry 冒烟清单

准备：一台可 SFTP 登录的服务器，目录里放一个 `.html` 和一个 `.log` 文件。运行：`swift run Ferry`。

- [ ] 点边栏的 + 新建连接：Server、Port（默认 22）、Username、密码，Path 填一个有文件的目录，点 Add to Favorites，边栏出现该条目
- [ ] 检查 `~/Library/Application Support/Ferry/favorites.json` 里没有密码；钥匙串里有 service 为 `com.ferry.sftp` 的条目
- [ ] 点边栏条目（或 Connect）连上，右侧列出目录，列为名称、大小、修改时间、类型，目录排在前面
- [ ] 面包屑点任一级、向上按钮、双击目录，都能切换目录
- [ ] 双击 `.html`，用默认浏览器打开
- [ ] 双击 `.log`，用默认文本编辑器打开
- [ ] 首次连接未知主机，弹出带 SHA256 指纹的确认框；选 Cancel 连接失败，选 Trust and Connect 继续，再次连接不再弹窗
- [ ] 把 Ferry 的 known_hosts 文件里该主机的密钥改坏后重连，应提示 host key changed 并拒绝
- [ ] 从 Finder 拖一个文件到列表，上传成功，列表自动刷新并出现该文件
- [ ] 私钥登录：选 Private key，选 ed25519 私钥，能连上
- [ ] 密码错误时显示 Authentication failed
- [ ] 经跳板机连接：新建连接，Server 填 192.168.3.180、Port 22，打开 Via jump host，Jump host 填 ngrokd.xyz10.com、Jump port 48425（用户名和密码与目标共用）；连接时依次弹出两次指纹确认，第一次写明跳板机 ngrokd.xyz10.com:48425，第二次写明目标 192.168.3.180:22；连上后列出的是 180 的目录，不是跳板机的
- [ ] 编辑该条目，关掉 Via jump host 或清空 Jump host 保存，favorites.json 里 jumpHost 为空，连接走直连
- [ ] 右键该条目选 Forget this host，再次连接，两个主机的指纹确认框重新弹出
