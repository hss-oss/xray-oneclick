# Xray XHTTP 一键安装

面向尚未安装 Nginx/Xray 的 Debian/Ubuntu 服务器，支持 amd64/arm64 和 systemd。

```bash
curl -fL --retry 3 https://github.com/hss-oss/xray-oneclick/releases/download/v1.0.0/install-xray.sh -o install-xray.sh && sudo bash install-xray.sh
```

- 安装 Nginx mainline、Xray VLESS/XHTTP 和 acme.sh。
- 自动生成独立 UUID/路径、申请 Let's Encrypt ECC 证书并配置续期。
- 自动下载站点资源，校验 SHA-256 后部署 Photosec 页面，保留 ACME 验证目录。
- 安装成功后将 VLESS/XHTTP 链接保存到 `/opt/xray-nginx/client.txt`。

附件：

| 文件 | 用途 |
| --- | --- |
| `install-xray.sh` | 一键安装脚本，与此版本仓库代码一致 |
| `html.rar` | Notion 原始附件，原样留存 |
| `xray-site.tar.gz` | 脚本实际使用的 Linux 站点资源包，移除了原模板的 Google Maps API key 及加载代码 |
| `SHA256SUMS` | 三个文件的 SHA-256 校验值 |

请先设置正确的域名解析，放通 TCP 80/443；HTTP/3 另需 UDP 443。已有部署会被拒绝覆盖，具体用法和验证范围见 README。
