# 安装、配置与回退

这些步骤用于已有双上联的路由器。先通过有线 LAN 保留管理通道，并备份当前网络、代理配置；本仓库不会改无线连接、校园网接入方式、默认校园出口或门户认证参数。

## 1. 检查目标环境

```sh
command -v ruby
ruby -rjson -ryaml -ripaddr -ropen3 -rtmpdir -e 'puts "Ruby libraries ready"'
command -v curl
command -v ubus
command -v ifup
```

OpenWrt 的包管理器和包名因固件而异；按固件来源安装 Ruby、JSON/YAML 库与 curl。小闪存设备先核实余量，不要混装其他发行版的软件源。本仓库不提供替换系统库或压缩核心的安装器。

从自己的工作机把 `bin/` 与 `lib/` 复制到路由器的 `/usr/libexec/campus-dualwan/`，目录由 root 维护。示例文件只用于参考；不要连同工作机的 `private/`、`.git/` 或生成目录批量上传。

## 2. 配置路由与代理候选

根据 `ubus call network.interface.<逻辑接口> status` 核对 `l3_device`、地址和网关。逻辑接口名（例如 `mobile`）与实际设备名（例如 `wlan0`）用途不同，需要分别填写。

在工作机编辑自己的 `render.json`、`network.json`，生成 README 中的两个候选文件。`node_ipv4` 是实际节点入口，而非要访问的网站；节点解析变化后需要更新。服务器别名在生成时展开，明确的 `sni` 保留；有别名的 TLS 节点缺少 SNI 时会停止，交由使用者确认。

生成器只对静态 `proxies` 应用移动接口和标记。它去掉全局移动接口/标记，避免把 `DIRECT` 也一起指定到移动网；不改变节点的证书验证选项。请自行审查输入中的 TLS 设置。

合并网络片段前：

- 检查 `cdw_` 段名、表号与规则优先级未占用，不重复追加同一批段。
- 确认移动网关属于所填移动子网，LAN 回程包含实际管理子网。
- `cdw_guard` 必须属于 `loopback`，其 `unreachable` 默认应在移动下线后保留。
- 核对既有防火墙、透明代理及流量分载的影响；必要时补充校园出口上的节点拒绝规则。

保存网络配置后，通过固件提供的应用方式加载，现场检查 `ip -4 rule show` 与 `ip -4 route show table <表号>`。没有经过真实下线/恢复验收，不把候选片段视作已完成部署。

Mihomo 候选先用已安装核心的 `-t` 检查。OpenClash 可能要求自己的 `SAFE_PATHS` 等环境；使用该版本的校验入口。候选有效后，再通过该版本支持的方式加载。`openwrt/openclash-overwrite.example.sh` 仅生成候选，不自动替换文件，便于先审查完整差异。

## 3. 配置校园认证

路由器上新建仅 root 可访问的目录：

```sh
umask 077
mkdir -p /etc/campus-dualwan/private
chmod 700 /etc/campus-dualwan/private
```

用编辑器新建 `auth.json`（按 `examples/auth.example.json` 填写），以及 `username`、`password` 两个凭据文件；每个凭据单独一行。不要把真实值放在命令参数、Git 文件或问题反馈截图中。

```sh
chmod 600 /etc/campus-dualwan/private/auth.json
chmod 600 /etc/campus-dualwan/private/username /etc/campus-dualwan/private/password
```

主要配置项：

| 字段 | 说明 |
|---|---|
| `configured` | 全部配置完成后手工改为 `true` |
| `portal_origin` | 自己确认的门户源，仅协议、主机和可选端口；不含路径/查询/账号 |
| `campus_interface` / `campus_device` | 校园逻辑接口和实际设备，状态不一致时拒绝登录 |
| `username_file` / `password_file` | root 所有、0600 的普通文件，拒绝符号链接 |
| `service` | 门户要求的服务选项；不需要则留空 |
| `renew_before_cidrs` | 只有认证前地址属于这些网段时才在接受登录后运行 `ifup`；不清楚时留空 |
| `direct_gid` | 可选的直连组编号，必须核实透明代理有对应绕过规则后再填写 |
| `transparent_proxy_bypass_verified` | 验证绕过后设 `true`；启用 OpenClash 时，本项与 `direct_gid` 缺一即停止 |
| `connectivity_checks` | 至少两项状态/内容检查，选择你所在网络可用且不被门户放行的目标 |

历史部署使用过 GID 65534 绕过当时 OpenClash 的自身流量拦截，但不能假定每个版本都相同。本仓库不会自动创建该绕过规则。先核实出站 owner/GID 规则并抓包确认，不能只看到 curl 指定了网口就勾选“已验证”。若不是 OpenClash，需另外审查你所用透明代理的截获规则。

仅做本地配置与权限检查（不发请求）：

```sh
ruby /usr/libexec/campus-dualwan/bin/campus-auth.rb /etc/campus-dualwan/private/auth.json --check
```

确认设备、门户、检查目标与代理绕过正确后，再手动运行：

```sh
ruby /usr/libexec/campus-dualwan/bin/campus-auth.rb /etc/campus-dualwan/private/auth.json --run
```

程序只从预设门户源提取 `/eportal/index.jsp` 查询，不跟随 HTTP 重定向提交凭据。只接受无验证码、`passwordEncrypt=false` 的流程；若门户本身使用 HTTP，这个遗留协议仍以 HTTP 提交表单，仓库不能把它变成加密协议。

返回 `online` 才表示本轮联网检查成功；`accepted_but_unverified` 保留为未验证。明确拒绝登录后退避 15 分钟，凭据和门户响应不写日志。定时运行时相同任务通过文件锁避免并发。

## 4. 手动验收后，再装事件与定时任务

如果要使用 hotplug，将 `openwrt/95-campus-auth` 复制到 `/etc/hotplug.d/iface/95-campus-auth` 并设 0755。它读取私有配置的校园接口名，只响应对应接口事件。

可在 root crontab 中手工加入一条，避免重复：

```cron
* * * * * ruby /usr/libexec/campus-dualwan/bin/campus-auth.rb /etc/campus-dualwan/private/auth.json --run 2>&1 | logger -t campus-auth
```

按固件方式重载 cron。学校真正强制下线、VLAN 切换和断电重启后的恢复，必须各自验收；本仓库的模拟测试不代替这些场景。

可选移动恢复：编辑并保护 `recovery.json` 和 `proxy-health.curl`，手动设 `configured=true`，再安装 `openwrt/97-mobile-recovery`。它只处理配置接口的 `ifup`，且只重启已启用、正在运行的 OpenClash。私有 curl 文件中仅填写需要的本地代理认证，0600；无需认证则创建空文件。该钩子会重启服务，可能中断现有连接，按需启用。

## 5. 回退

先取消新增 cron 与两个 hotplug 钩子，再恢复自己保存的代理和网络配置，按原固件方式加载。不要在远程唯一通道上先删除保护规则再等待后续操作。

恢复原配置后复查原默认出口、两台设备管理页及网站访问。确认不再使用时，再手动移除本项目程序和私有目录；不要在反馈中上传备份或认证响应。
