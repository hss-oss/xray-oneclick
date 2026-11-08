# Xray XHTTP 一键安装

本版本新增 `--uninstall` 一键移除，并将 Xray 安装恢复为 XTLS 官方 `install-release.sh` 的默认在线流程：由官方脚本自动识别架构、选择稳定版、下载安装包并执行校验。

```bash
curl -fL --retry 3 https://github.com/hss-oss/xray-oneclick/releases/download/v1.1.0/install-xray.sh -o install-xray.sh && sudo bash install-xray.sh
```

- 移除封装层的 Xray API 选包、附件下载、摘要校验和 `--local` 安装逻辑。
- 官方安装脚本通过官方 README 中的 GitHub 地址下载，先检查 HTTP 状态和 Bash 语法，再执行 `install --manually-restart-later`。
- 保留配置生成与校验，配置通过后再启动 Xray。
- 保留 Nginx、证书签发与续期、站点资源下载、UUID/路径生成、客户端链接和站点下载失败的专用续装入口。

## 一键移除

**会停止服务并移除本套 Nginx/Xray 部署。** 请先下载本版本脚本，再执行：

```bash
sudo bash install-xray.sh --uninstall --dry-run  # 先预览
sudo bash install-xray.sh --uninstall            # 执行移除
```

移除前保存完整备份至 `/var/backups/xray-nginx/`，归档权限 `0600`，包含证书和连接凭据。Xray 调用官方 `remove --purge`，Nginx 使用 apt purge；保留公共依赖、系统账户和云防火墙规则。检测到共享站点、其他实例或配置改动时停止，避免误删。

面向尚未安装 Nginx/Xray 的 Debian/Ubuntu 服务器，支持 amd64/arm64 和 systemd。已有部署无需重新安装。安装成功后的 VLESS/XHTTP 链接保存在 `/opt/xray-nginx/client.txt`。

附件包含 `install-xray.sh`、原始 `html.rar`、脚本使用的 `xray-site.tar.gz` 及 `SHA256SUMS`。请先设置域名解析并放通 TCP 80/443；HTTP/3 另需 UDP 443。详情见 README。
