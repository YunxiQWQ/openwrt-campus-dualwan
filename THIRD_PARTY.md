# 来源、许可证与修改

## RuijiePortalLoginScript

- 作者/项目：nekomiya-hinata / RuijiePortalLoginScript。
- 来源：https://github.com/nekomiya-hinata/RuijiePortalLoginScript
- 参考文件：`Openwrt & LEDE/ruijie_general.sh`。
- 核对版本：`e20fe3d97fe6156332c13fa8f187b4a17b5a0d28`。
- 上游许可证：GNU GPL version 3；本仓库保留完整文本于 `LICENSE`，衍生实现按 GPL-3.0-only 发布。

认证表单、ePortal pageInfo/login 与查询参数编码流程参考该项目。2026-11-12 本仓库将先前本地适配重构为 `lib/portal.rb` 与 `bin/campus-auth.rb`：移除学校专用常量，分离账户文件，加入严格门户来源、接口匹配、私有状态、拒绝退避、登录后联网检查与测试。并非上游原样副本，问题请先在本仓库说明。

## OpenClash / Mihomo / OpenWrt

本仓库生成这些软件可用的配置并调用使用者已安装的程序。不包含其核心、安装包、规则数据库、固件、认证资料或原始日志。它们的版本、许可和配置语义应以各自上游为准。
