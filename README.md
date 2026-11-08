# Xray 一键安装

项目地址：[hss-oss/xray-oneclick](https://github.com/hss-oss/xray-oneclick)。在 Debian/Ubuntu 新服务器执行：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/hss-oss/xray-oneclick/main/install-xray.sh -o install-xray.sh && sudo bash install-xray.sh
```

也可以将 `install-xray.sh` 上传至服务器，运行：

```bash
sudo bash install-xray.sh
```

按提示填写域名和邮箱即可。也可以一次传入参数，将示例替换为实际值：

```bash
sudo bash install-xray.sh --domain proxy.example.com --email admin@example.com
```

多个域名可重复指定 `--domain`；第一个域名用于证书安装和客户端连接信息：

```bash
sudo bash install-xray.sh \
  --domain proxy.example.com \
  --domain www.example.com \
  --email admin@example.com
```

## 安装条件

- **目标为尚未安装 Nginx/Xray 的新服务器**，系统为官方 Nginx mainline 仓库仍支持的 Debian/Ubuntu，架构为 amd64 或 arm64，需要 systemd 和 root 权限。
- 所有域名的 A/AAAA 记录均应正确指向服务器。没有可用 IPv6 时不要配置 AAAA；首次部署建议使用直接指向服务器的 DNS 记录。
- 在云安全组及服务器防火墙放通 TCP 80、TCP 443；使用 HTTP/3 时还需 UDP 443。脚本不修改防火墙规则。
- 服务器能访问系统软件源、nginx.org、GitHub 和 Let's Encrypt。TCP 80 必须能从公网访问，供签发和续期验证使用。
- **脚本会安装系统软件包、添加 Nginx 官方软件源，并启用服务及证书续期 timer。** 检测到已有 Nginx、Xray、相关安装文件或端口占用时会停止，避免覆盖现有业务。

## 部署内容

```text
客户端 → TLS/HTTP2（TCP 443）→ Nginx → XHTTP/VLESS → Xray（127.0.0.1:8443）
浏览器 → HTTP/HTTPS/HTTP3 → html.rar 中的 Photosec 摄影网站
ACME → HTTP（TCP 80）→ /.well-known/acme-challenge/
```

- Nginx 从官方 mainline 仓库安装，并核对官方签名密钥指纹。根据编译模块和系统 IPv6 状态生成配置。
- Xray 使用 XTLS 官方安装脚本，安装稳定版本及 geodata；acme.sh 使用官方源码，申请 Let's Encrypt ECC 证书。
- UUID 与 XHTTP 路径分别随机生成，不复用原文中的示例凭据。可用 `--uuid`、`--path` 指定自己的值。
- Xray 仅监听回环地址，通过非 root 服务用户运行；私钥与连接信息仅 root 可读，错误日志进入 journald，不开启 Xray 访问日志。
- 保留原文的私网、`geoip:cn` 和广告域名阻断规则。因此通过该节点访问中国大陆 IP 可能被阻断；如需调整，编辑 Xray 配置后先校验再重启。
- 安装每天检查证书续期的 systemd timer；证书更新后先执行 `nginx -t`，通过后 reload。
- 原始 `html.rar` 保存在 [v1.0.0 Release](https://github.com/hss-oss/xray-oneclick/releases/tag/v1.0.0) 的附件中。脚本优先从 GitHub Raw 下载固定 `v1.0.0` 资源，失败时切换至该 Release 的 `xray-site.tar.gz`，校验固定的 SHA-256 后，将 `html/` 内的页面、CSS、JS、字体和图片部署到 `/var/www/xray-nginx/`。不需要手动下载附件或安装 RAR 解压软件。
- 若脚本同目录已有 `xray-site.tar.gz`，优先使用该文件并执行相同的校验；可用来离线部署站点资源。其他系统组件安装仍需网络。
- HTTP 和 HTTPS 均使用该站点目录，`index.html` 直接位于目录根部；保留 `.well-known/acme-challenge/`，不影响证书签发及续期。
- 分发前移除了原模板的 Google Maps API key 及对应加载脚本，保留模板署名和其余页面。原有字体及 OwlCarousel CDN 引用仍按模板保留，网站文件的原编码与换行保持不变。

## 旧版安装补装页面

如果之前已使用默认 Welcome 首页的旧版脚本安装，先下载新版 `install-xray.sh`，在文件所在目录执行以下命令。此步骤只备份并更新静态网站，不重新安装 Nginx/Xray，也不改变 UUID、路径或证书。

```bash
# 先备份现有站点；确认上述路径来自本安装脚本
sudo cp -a /var/www/xray-nginx "/opt/xray-nginx/backup/site-before-update-$(date +%Y%m%d-%H%M%S)"

# 仅调用新版脚本的站点部署函数，保留 ACME 验证目录
sudo bash -c 'source ./install-xray.sh; install_site'
```

完成后访问自己的 HTTPS 域名，应显示 Photosec 摄影网站。静态文件更新无需 reload Nginx；浏览器若仍显示旧首页，请刷新缓存。

## 查看连接与管理服务

```bash
# 内含 UUID 和 VLESS 链接，请妥善保存
sudo cat /opt/xray-nginx/client.txt

# 服务与错误日志
sudo systemctl status nginx xray --no-pager
sudo journalctl -u xray -u nginx -n 100 --no-pager

# 证书续期计划及运行日志
sudo systemctl list-timers xray-acme-renew.timer --all
sudo journalctl -u xray-acme-renew.service -n 50 --no-pager
```

客户端需要支持 XHTTP，使用导出的 VLESS 链接；若客户端不支持链接中的 XHTTP 字段，可按 `client.txt` 手动填写。传输使用 XHTTP，TLS 开启，ALPN 为 `h2`，Mode 为 `auto`，Flow 留空。Nginx 同时启用 HTTP/3 不代表客户端必须使用 HTTP/3。

主要路径：

| 内容 | 服务器路径 |
| --- | --- |
| Nginx 站点配置 | `/etc/nginx/conf.d/xray-nginx.conf` |
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| TLS 证书和私钥 | `/usr/local/ssl/xray-nginx/` |
| 静态站点及 ACME webroot | `/var/www/xray-nginx/` |
| acme.sh 及账户数据 | `/opt/xray-nginx/acme/` |
| 客户端参数及 VLESS 链接 | `/opt/xray-nginx/client.txt` |
| 安装时 Nginx 配置备份 | `/opt/xray-nginx/backup/nginx/` |

修改配置后的检查与生效命令：

```bash
sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
sudo nginx -t
# 仅在上述检查通过后执行
sudo systemctl restart xray
sudo systemctl reload nginx
```

## 预览与失败处理

Mac 或 Linux 上可以只生成配置预览，不安装软件、不写部署文件，需要 `python3`：

```bash
bash install-xray.sh --dry-run --domain proxy.example.com --email admin@example.com
```

预览会展示同时启用 IPv6 和 HTTP/3 的配置；实际安装时自动检测支持情况。

如果签发失败，优先核对报错中的域名、DNS、AAAA、CAA、TCP 80 及 ACME 限额。不要短时间重复尝试生产证书签发。

发生错误时，脚本会保留原始失败退出码，清理自身临时目录，停止本次安装的 Xray 和已经启用的续期 timer，并尝试恢复 Nginx 默认站点。**这不等于完整卸载：已安装软件包、软件源、证书账户和排查文件会保留。** Nginx 的备份是安装官方包后、替换站点前的配置。

默认重跑会拒绝覆盖已有文件。若旧版在“部署 html.rar 站点资源”时因 HTTP 504 等下载错误退出，可使用 v1.0.1 的专用续装入口（替换域名和邮箱）：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/hss-oss/xray-oneclick/v1.0.1/install-xray.sh -o install-xray.sh
sudo bash install-xray.sh --resume-site-download \
  --domain proxy.example.com --email admin@example.com
```

该入口只接受站点下载失败阶段：Nginx 配置必须与原备份完全一致，站点与证书目录为空，尚无 ACME、Xray 或续期配置。检查通过后跳过 apt 和 Nginx 重装，从站点部署继续，保留原备份。存在业务文件或配置改动时会拒绝执行；其他阶段的错误需要单独排查，不要直接删除配置和证书目录。

资源优先走 GitHub Raw，Release 作为备用，两者均校验同一固定 SHA-256。也可把可信的 `xray-site.tar.gz` 放在脚本同目录。下载和校验完成后才替换默认 Nginx 配置；失败清理仅对正在运行的 Nginx reload，避免产生额外的“服务未启动”报错。安装过程不更改 SSH、防火墙或系统目录的整体权限。

## 验证范围

已完成 Bash 语法检查、ShellCheck、参数校验、失败退出清理测试；生成的配置通过官方 Xray Core `26.10.31` 校验，并通过 Nginx `1.27.5` 的 HTTP/3 与 IPv6 四种配置组合校验。

使用临时端口和测试证书，实际验证了 HTTPS 证书校验、ACME webroot、客户端经 TLS/HTTP2 → Nginx → XHTTP/VLESS 访问公网网页，以及私网阻断规则。新增测试覆盖站点资源逐文件完整性、目录层级、权限、ACME 文件保留、损坏资源拒绝写入，以及 Nginx 实际返回 Photosec 首页、CSS、JS、图片、字体和子页面。测试结束后已停止临时进程。未在真实 Debian/Ubuntu 服务器上执行完整 apt 安装、生产证书签发或定时续期；实际安装会下载届时的官方版本。

新增故障测试覆盖主链路失败自动切换、双链路失败保留退出码及拒绝写入、续装阶段顺序，以及拒绝已有证书、ACME、网站内容、链接或配置改动。已在用户 Ubuntu 24.04 服务器上复现 Release HTTP 504，确认 Raw HTTP 200、资源校验通过，且专用续装前置检查通过。

相关官方项目：[Nginx 软件源](https://nginx.org/en/linux_packages.html)、[Xray-install](https://github.com/XTLS/Xray-install)、[acme.sh](https://github.com/acmesh-official/acme.sh)。
