# Xray XHTTP 一键安装

面向尚未安装 Nginx/Xray 的 Debian/Ubuntu 服务器，支持 amd64/arm64 和 systemd。

```bash
curl -fL --retry 3 https://github.com/hss-oss/xray-oneclick/releases/download/v1.0.2/install-xray.sh -o install-xray.sh && sudo bash install-xray.sh
```

- 安装 Nginx mainline、Xray VLESS/XHTTP 和 acme.sh。
- 自动生成独立 UUID/路径、申请 Let's Encrypt ECC 证书并配置续期。
- 自动下载站点资源，校验 SHA-256 后部署 Photosec 页面，保留 ACME 验证目录。
- 安装成功后将 VLESS/XHTTP 链接保存到 `/opt/xray-nginx/client.txt`。

本次修复：

- Xray 安装包优先通过 GitHub 官方 API 下载并核对官方 SHA-256，再交给官方安装器 `--local` 安装，避免官方安装器的 Release 网页下载同样遭遇 504。
- 已在真实 Ubuntu 24.04 服务器续装，完成生产证书签发和服务启动。

- 针对 GitHub Release HTTP 504，优先使用固定版本的 GitHub Raw 资源，并保留 Release 备用链路和固定 SHA-256 校验。
- 新增 `--resume-site-download`，可从旧版站点下载失败后的状态续装；严格检查备份一致且未进入证书/Xray 步骤，不覆盖已有业务。
- 资源校验后才替换默认 Nginx 配置，失败清理仅 reload 运行中的服务。

旧版下载失败的服务器可执行：

```bash
sudo bash install-xray.sh --resume-site-download --domain proxy.example.com --email admin@example.com
```

附件：

| 文件 | 用途 |
| --- | --- |
| `install-xray.sh` | 一键安装脚本，与此版本仓库代码一致 |
| `html.rar` | Notion 原始附件，原样留存 |
| `xray-site.tar.gz` | 脚本实际使用的 Linux 站点资源包，移除了原模板的 Google Maps API key 及加载代码 |
| `SHA256SUMS` | 三个文件的 SHA-256 校验值 |

请先设置正确的域名解析，放通 TCP 80/443；HTTP/3 另需 UDP 443。已有部署会被拒绝覆盖，具体用法和验证范围见 README。
