# OpenWrt 校园网认证与双上联分流

从一台 TR3000 + R106 的实际配置整理而来：校园网上联负责直连，移动上联承接代理节点连接；移动上联断开时，节点连接应停止，不回退到校园网。

提供可配置的源码、候选配置生成器、认证脚本和验证步骤。**没有携带学校地址、校园账号、订阅、真实节点、控制器密钥或原始运行日志。** 示例节点不可使用，示例门户位于文档保留地址段，认证默认禁用。

```text
电脑 / LAN ── TR3000
                ├── 校园网上联：国内直连、下载、校园认证
                └── 移动上联：代理节点连接
                       断开后：阻断节点连接，保留校园直连
```

## 包含什么

| 文件 | 用途 |
|---|---|
| `bin/render-mihomo.rb` | 给本地完整 Mihomo 配置添加节点接口、标记、IPv4 与直连规则，展开服务器别名并保留 SNI |
| `bin/render-network.rb` | 生成 OpenWrt UCI 候选片段：移动专用表、LAN 回程、标记/出口/节点目的规则、loopback 不可达后备 |
| `bin/campus-auth.rb` | 锐捷 ePortal 明文表单流程；绑定校园接口、校验门户来源、登录后验证联网、拒绝后退避 |
| `bin/recover-mobile.rb` | 可选的移动接口恢复处理：重启已启用的 OpenClash，使用私有 curl 配置检查本地 SOCKS |
| `openwrt/` | 可选 hotplug 和 OpenClash 候选生成钩子，均需手工安装 |
| `tests/` | 离线测试、本机 HTTP 假门户、隔离 Linux 网络命名空间验证 |

这次通用化版本保留了原部署思路，重写了硬编码参数和敏感数据处理。**尚未把通用化版本重新部署到真实校园网验收**；原部署经历与当前代码测试的范围见 [验证说明](docs/VERIFICATION.md)。

## 使用前确认

- 目标：运行 OpenWrt 的路由器，已有校园与移动两个上联；两条上联和 LAN 子网不能冲突。
- 运行依赖：Ruby 3.0+、JSON/YAML 标准库、curl、ubus、ifup；恢复钩子另用 uci、pidof、timeout、logger。
- 代理部分适配 OpenClash + Mihomo 的本地完整配置。暂不处理动态 `proxy-providers`，也不安装代理核心、规则库或订阅。
- 本仓库只实现 IPv4 策略。启用 IPv6 时必须另行实现并验证对应出口保护，不能仅依赖配置中的 `ipv6: false`。
- 认证仅支持 `passwordEncrypt=false`、无验证码的 ePortal 页面。遇到加密密码、验证码、SSO 或不同协议时直接停止，不修改门户的安全设置。

## 先生成候选文件

在本机克隆仓库后，把私有输入放在忽略目录，权限设为仅当前用户可读：

```sh
umask 077
mkdir -p private generated
# 用编辑器创建 private/provider.yaml，放入你自己的完整配置。
cp examples/render.example.json private/render.json
cp examples/network.example.json private/network.json
chmod 600 private/provider.yaml private/render.json private/network.json
```

先修改示例地址、逻辑接口、实际设备名、网关、LAN 子网、节点地址与 DNS 设置。两个 JSON 中的 `routing_mark` 必须一致；路由表与规则优先级应避开设备已有配置。

```sh
ruby bin/render-mihomo.rb private/provider.yaml private/render.json generated/config.yaml
ruby bin/render-network.rb private/network.json > generated/network.fragment
```

`generated/config.yaml` 含你自己的节点凭据。输出文件为 0600，候选目录也应保持私有。不要上传生成结果。生成器不会写 `/etc/config/network`，不会加载配置或重启服务。

网络片段需要审阅后合并；**不能用它覆盖整份 `/etc/config/network`**。安装认证、配置 OpenClash、定时运行与恢复原状见 [安装和回退](docs/INSTALL.md)。

## 这几件事需要分别验证

1. 网站命中代理规则之后，节点的实际连接是否从移动接口发出。
2. 移动默认路由消失后，专用表中的不可达后备是否仍在；它关联 `loopback`，不能随移动接口一起删除。
3. 节点域名的真实入口是否与抓包、目的路由和防火墙保护名单一致。
4. 校园认证是否真正绕过透明代理；单独指定 curl 的接口不能代替这项检查。
5. 页面返回登录成功之后，实际联网、DHCP 地址变化和管理页面是否正常。

本仓库不自动安装学校专用的出口防火墙规则；应结合固件的 fw3/fw4 编写并验证。已有防火墙、路由表或 OpenClash 标记可能改变结果，必须完成 [验收清单](docs/VERIFICATION.md) 后再启用定时任务。

## 开发与测试

测试只使用虚构账号、示例域名和保留地址，不连接真实校园网：

```sh
ruby tests/run.rb
shellcheck -s sh tests/netns.sh tests/http-netns.sh openwrt/95-campus-auth openwrt/97-mobile-recovery openwrt/openclash-overwrite.example.sh
# Linux 上有 root / 网络命名空间权限时；所有网络修改均在新命名空间里。
sudo sh tests/netns.sh
sudo sh tests/http-netns.sh
python3 scripts/check_public.py
```

HTTP 测试只在新网络命名空间的 loopback 监听；它验证真实 curl 请求与表单编码，不验证 TLS 服务或学校强制下线场景。镜像网络模式的 WSL 对绑定原始 lo 的请求可能有额外限制，因此使用同一隔离入口。CI 会运行相同检查。

## 许可证与来源

项目采用 **GPL-3.0-only**，完整文本见 [LICENSE](LICENSE)。校园认证的 ePortal 表单处理源自 [nekomiya-hinata/RuijiePortalLoginScript](https://github.com/nekomiya-hinata/RuijiePortalLoginScript)，来源与修改记录见 [THIRD_PARTY.md](THIRD_PARTY.md)。不附带 Mihomo、OpenClash、规则集或第三方固件二进制。

参考：[OpenWrt 策略路由](https://openwrt.org/docs/guide-user/network/routing/pbr_netifd)、[Mihomo 代理字段](https://wiki.metacubex.one/config/proxies/)、[Mihomo DNS](https://wiki.metacubex.one/config/dns/)。
