# Xray XHTTP 一键安装 v1.2.0

新增统一 `--resume`，从安装中断处检查并继续：复用依赖、Nginx、有效证书和已安装的 Xray，补齐 HTTPS、续期任务与连接信息。进度和参数写入权限为 `0600` 的 JSON，续装保持 UUID 与 XHTTP 路径。

新服务器安装：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/hss-oss/xray-oneclick/v1.2.0/install-xray.sh -o install-xray.sh && sudo bash install-xray.sh
```

中断后续装：

```bash
sudo bash install-xray.sh --resume
```

- 优先使用官方在线安装；官方脚本入口下载失败则通过 Raw 获取同一脚本；在线下载安装包失败才使用官方 API 备用，核对官方 SHA-256 后交给官方 `--local` 安装。
- 校验、权限等非下载错误保留退出码并停止。
- 已签发且有效的证书复用，避免重复申请；已安装的程序和原始 Nginx 备份复用。
- 检查实际文件、证书、配置和服务状态后继续，不只依据阶段标记。
- 保留 `--uninstall`（先备份）与 `--uninstall --dry-run`，及旧版两个专用续装入口。

旧版没有状态文件时，续装需显式传入 `--domain` 和 `--email`，并保有本脚本的原始 Nginx 备份。已有完整部署无需重新安装。

附件包含安装脚本、原始 `html.rar`、整理后的站点包及 `SHA256SUMS`。详见 README 中的适用范围、共享资源保护及回归测试说明。
