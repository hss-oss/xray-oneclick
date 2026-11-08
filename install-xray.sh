#!/usr/bin/env bash
# Debian/Ubuntu: Nginx + VLESS/XHTTP + TLS + acme.sh。
# 来源：用户提供的 Xray + Nginx 部署笔记。
set -Eeuo pipefail
umask 077

DOMAINS=()
EMAIL=''
CLIENT_UUID=''
XHTTP_PATH=''
DRY_RUN=0
RESUME_SITE_DOWNLOAD=0
UNINSTALL=0
UNINSTALL_NOTHING=0
REMOVE_NGINX_PACKAGE=0
SITE_URL=https://raw.githubusercontent.com/hss-oss/xray-oneclick/v1.0.0/assets/xray-site.tar.gz
SITE_FALLBACK_URL=https://github.com/hss-oss/xray-oneclick/releases/download/v1.0.0/xray-site.tar.gz
SITE_SHA256=bc152def1c5e4527809a27eb7fed7802cc4abf19bb99a07cfb15d595bc470202
BASE=/opt/xray-nginx
ACME_HOME=$BASE/acme
WEB_ROOT=/var/www/xray-nginx
CERT_DIR=/usr/local/ssl/xray-nginx
NGINX_CONF=/etc/nginx/conf.d/xray-nginx.conf
XRAY_CONF=/usr/local/etc/xray/config.json
TEMP_DIR=''
BACKUP=''
NGINX_CHANGED=0
XRAY_INSTALLED=0
RENEWAL_ENABLED=0
COMPLETED=0

info() { printf '\n[信息] %s\n' "$*"; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
用法：sudo bash install-xray.sh [选项]
  --domain example.com       域名；可重复指定多个域名
  --email you@example.com    ACME 注册邮箱
  --uuid UUID               客户端 UUID；默认随机生成
  --path /random-path       XHTTP 路径；默认独立随机生成
  --uninstall               备份后移除本脚本部署（可配合 --dry-run 预览）
  --resume-site-download    仅续装：上次在站点资源下载阶段失败
  --dry-run                 仅输出配置，不安装、不写文件（需要 python3）
  -h, --help                显示帮助

无参数运行时交互输入域名和邮箱。面向新服务器；不覆盖已有业务配置。
自动下载 Release 中的站点资源，无需另外上传或安装 RAR 解压工具。
需先将所有域名的 A/AAAA 记录指向服务器，并放通 TCP 80/443、UDP 443。
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --domain|--email|--uuid|--path)
        [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 缺少参数"
        case "$1" in
          --domain) DOMAINS+=("$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')");;
          --email) EMAIL=$2;;
          --uuid) CLIENT_UUID=$2;;
          --path) XHTTP_PATH=$2;;
        esac
        shift 2;;
      --uninstall) UNINSTALL=1; shift;;
      --resume-site-download) RESUME_SITE_DOWNLOAD=1; shift;;
      --dry-run) DRY_RUN=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "未知参数：$1（使用 --help 查看用法）";;
    esac
  done
}

validate_inputs() {
  local domain label previous=' ' labels=()
  ((${#DOMAINS[@]})) || die '请至少指定一个 --domain'
  for domain in "${DOMAINS[@]}"; do
    [[ ${#domain} -le 253 && $domain == *.* && $domain != *..* && $domain != *. ]] || die "域名格式错误：$domain"
    [[ $domain =~ ^[a-z0-9.-]+$ && ! $domain =~ ^[0-9.]+$ ]] || die "请填写域名而非 IP、URL 或通配符：$domain"
    IFS=. read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
      [[ ${#label} -ge 1 && ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "域名标签不合法：$domain"
    done
    [[ $previous != *" $domain "* ]] || die "域名重复：$domain"
    previous+="$domain "
  done
  [[ $EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die '请填写有效的 --email'
  [[ $CLIENT_UUID =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die 'UUID 格式错误'
  [[ $XHTTP_PATH =~ ^/[A-Za-z0-9_-]{1,100}$ ]] || die '路径必须为 / 开头的单段字母、数字、下划线或短横线'
}

new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

collect_inputs() {
  if ((${#DOMAINS[@]} == 0)) && [[ -t 0 ]]; then
    local input
    read -r -p '域名（多个域名用空格分隔）：' input
    input=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
    read -r -a DOMAINS <<< "$input"
  fi
  if [[ -z $EMAIL && -t 0 ]]; then
    read -r -p '证书通知邮箱：' EMAIL
  fi
  [[ -n $CLIENT_UUID ]] || CLIENT_UUID=$(new_uuid)
  [[ -n $XHTTP_PATH ]] || XHTTP_PATH=/$(new_uuid)
  validate_inputs
}

render_nginx() {
  local tls=${1:-0} http3=${2:-0} ipv6=${3:-0}
  cat <<EOF
# 由 install-xray.sh 管理；HTTP 保持在前，用于 ACME webroot 验证。
server {
    listen 80;
$(if [[ $ipv6 == 1 ]]; then printf '    listen [::]:80;'; fi)
    server_name ${DOMAINS[*]};
    root $WEB_ROOT;
    index index.html;
    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  [[ $tls == 1 ]] || return 0
  cat <<EOF

server {
    listen 443 ssl;
$(if [[ $ipv6 == 1 ]]; then printf '    listen [::]:443 ssl;'; fi)
$(if [[ $http3 == 1 ]]; then
    printf '    listen 443 quic reuseport;\n'
    [[ $ipv6 != 1 ]] || printf '    listen [::]:443 quic reuseport;\n'
    printf '    add_header Alt-Svc '\''h3=":443"; ma=86400'\'' always;'
  fi)
    http2 on;
    server_name ${DOMAINS[*]};
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root $WEB_ROOT;
    index index.html;

    # XHTTP 转发到回环地址上的明文 HTTP/2；TLS 由 Nginx 终止。
    location ^~ $XHTTP_PATH {
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_pass grpc://127.0.0.1:8443;
        grpc_set_header Host \$host;
        grpc_set_header X-Forwarded-For \$remote_addr;
    }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
}

render_xray() {
  python3 - "$CLIENT_UUID" "$XHTTP_PATH" <<'PY'
import json, sys
config = {
    "log": {"loglevel": "warning"},
    "dns": {"servers": ["https+local://1.1.1.1/dns-query", "localhost"]},
    "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
        {"type": "field", "ip": ["geoip:private", "geoip:cn"], "outboundTag": "block"},
        {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"}
    ]},
    "inbounds": [{"listen": "127.0.0.1", "port": 8443, "protocol": "vless",
        "settings": {"clients": [{"id": sys.argv[1], "level": 0}], "decryption": "none"},
        "streamSettings": {"network": "xhttp", "security": "none",
                           "xhttpSettings": {"path": sys.argv[2], "mode": "auto"}}}],
    "outbounds": [{"tag": "direct", "protocol": "freedom"},
                  {"tag": "block", "protocol": "blackhole"}]
}
print(json.dumps(config, indent=2))
PY
}

install_site() (
  info '部署 html.rar 站点资源'
  local site_temp archive_path
  site_temp=$(mktemp -d "${TMPDIR:-/tmp}/xray-site.XXXXXXXX")
  trap 'rm -rf -- "$site_temp"' EXIT
  archive_path=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/xray-site.tar.gz
  if [[ ! -f $archive_path ]]; then
    archive_path=$site_temp/xray-site.tar.gz
    if ! download "$SITE_URL" "$archive_path"; then
      info 'GitHub Raw 下载失败，改用 Release 中的同版本资源'
      download "$SITE_FALLBACK_URL" "$archive_path" || return "$?"
    fi
  fi
  python3 - "$archive_path" "$WEB_ROOT" "$SITE_SHA256" <<'PY'
import hashlib, io, shutil, sys, tarfile
from pathlib import Path, PurePosixPath

payload = Path(sys.argv[1]).read_bytes()
if hashlib.sha256(payload).hexdigest() != sys.argv[3]:
    raise SystemExit('站点资源校验失败，请重新下载资源包')
root = Path(sys.argv[2])
with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
    members = archive.getmembers()
    # 只部署 html/ 内的普通文件与目录，禁止路径越界和链接。
    for member in members:
        path = PurePosixPath(member.name)
        if (path.is_absolute() or '..' in path.parts or path.parts[:1] != ('html',)
                or '.well-known' in path.parts or not (member.isfile() or member.isdir())):
            raise SystemExit(f'站点资源路径不合法：{member.name}')
    if not any(m.name == 'html/index.html' and m.isfile() for m in members):
        raise SystemExit('站点缺少 index.html')
    root.mkdir(parents=True, exist_ok=True)
    for member in members:
        target = root.joinpath(*PurePosixPath(member.name).parts[1:])
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, target.open('wb') as destination:
                shutil.copyfileobj(source, destination)
            target.chmod(0o644)
    # umask 077 会限制新目录权限，显式开放 Nginx 所需的目录遍历权限。
    for directory in [root, *(p for p in root.rglob('*') if p.is_dir())]:
        directory.chmod(0o755)
print(f'站点已部署：{root}/index.html；ACME 验证目录保留')
PY
)

download() {
  curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 --output "$2" "$1"
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ $status != 0 && $COMPLETED == 0 ]]; then
    if [[ $RENEWAL_ENABLED == 1 ]]; then
      systemctl disable --now xray-acme-renew.timer >/dev/null 2>&1 || true
    fi
    if [[ $XRAY_INSTALLED == 1 ]]; then systemctl stop xray >/dev/null 2>&1 || true; fi
    if [[ $NGINX_CHANGED == 1 ]]; then
      rm -f -- "$NGINX_CONF"
      [[ ! -e $BACKUP/default.conf ]] || cp -a "$BACKUP/default.conf" /etc/nginx/conf.d/default.conf
      if [[ -e $BACKUP/default || -L $BACKUP/default ]]; then
        cp -a "$BACKUP/default" /etc/nginx/sites-enabled/default
      fi
      if nginx -t && systemctl is-active --quiet nginx; then
        systemctl reload nginx || true
      fi
    fi
    printf '\n安装未完成。依赖包、Xray 和 ACME 文件保留以供排查。\n' >&2
    [[ $NGINX_CHANGED == 0 ]] || printf '已尝试恢复 Nginx 默认站点，请检查 nginx -t 和服务状态。\n' >&2
    [[ -z $BACKUP ]] || printf '备份目录：%s\n' "$BACKUP" >&2
  fi
  [[ -z $TEMP_DIR ]] || rm -rf -- "$TEMP_DIR"
  exit "$status"
}

# 只接受 v1.0.0 在站点下载失败后留下的状态；拒绝已有证书、Xray 或配置改动。
check_site_download_resume() {
  command -v nginx >/dev/null || die '续装需要上次已安装的 Nginx'
  local dependency
  for dependency in python3 curl openssl gpg unzip ss; do
    command -v "$dependency" >/dev/null || die "续装缺少依赖：$dependency"
  done
  [[ ! -e $XRAY_CONF && ! -e /usr/local/bin/xray && ! -L $XRAY_CONF ]] || die '已存在 Xray，不能使用站点下载续装模式'
  [[ ! -e /etc/systemd/system/xray-acme-renew.service && ! -L /etc/systemd/system/xray-acme-renew.service && ! -e /etc/systemd/system/xray-acme-renew.timer && ! -L /etc/systemd/system/xray-acme-renew.timer ]] || die '已存在续期配置，不能使用站点下载续装模式'
  [[ ! -e $ACME_HOME && ! -L $ACME_HOME ]] || die '已进入证书步骤，不能使用站点下载续装模式'
  python3 - "$BASE" "$CERT_DIR" "$WEB_ROOT" "${NGINX_CONF%/conf.d/*}" <<'PYRESUME'
import os, sys
from pathlib import Path
base, certs, web, nginx = map(Path, sys.argv[1:])
def reject(message):
    raise SystemExit('不能安全续装：' + message)
for path in (base, certs, web, base / 'backup', base / 'backup/nginx', nginx):
    if path.is_symlink() or not path.is_dir():
        reject(f'目录缺失或是链接：{path}')
if {p.name for p in base.iterdir()} != {'backup'}:
    reject('安装目录中存在其他步骤的文件')
if any(certs.iterdir()):
    reject('证书目录非空')
for path in web.rglob('*'):
    if path.is_symlink() or not path.is_dir() or path.relative_to(web).as_posix() not in ('.well-known', '.well-known/acme-challenge'):
        reject('站点目录已有文件或非预期目录')
def inventory(root):
    result = {}
    for path in root.rglob('*'):
        key = path.relative_to(root).as_posix()
        if path.is_symlink(): result[key] = ('link', os.readlink(path))
        elif path.is_file(): result[key] = ('file', path.read_bytes())
        elif path.is_dir(): result[key] = ('dir',)
        else: reject(f'不支持的文件类型：{path}')
    return result
backup = base / 'backup/nginx'
if not (backup / 'nginx.conf').is_file() or inventory(backup) != inventory(nginx):
    reject('当前 Nginx 配置与安装前备份不一致，请先人工检查')
print('续装检查通过：配置与备份一致，尚未部署站点、证书或 Xray')
PYRESUME
  nginx -t
  local port
  for port in 443 8443; do
    [[ -z $(ss -H -ltn "sport = :$port") ]] || die "TCP $port 已被占用"
  done
  [[ -z $(ss -H -lun 'sport = :443') ]] || die 'UDP 443 已被占用'
}

preflight() {
  [[ $(uname -s) == Linux && -r /etc/os-release ]] || die '安装仅支持 Debian/Ubuntu Linux；macOS 可使用 --dry-run 预览'
  [[ $EUID == 0 ]] || die '请使用 sudo bash 或 root 运行'
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ $ID == debian || $ID == ubuntu ]] || die "不支持的发行版：$ID"
  [[ ${VERSION_CODENAME:-} =~ ^[a-z]+$ ]] || die '无法确定系统发行代号'
  [[ $(dpkg --print-architecture) =~ ^(amd64|arm64)$ ]] || die '仅支持 amd64/arm64'
  [[ -d /run/systemd/system ]] || die '需要正在运行的 systemd（不支持普通 Docker 容器）'
  command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux'
  if [[ $DRY_RUN == 0 ]]; then
    exec 9>/run/lock/xray-nginx-install.lock
    flock -n 9 || die '已有安装或移除进程正在运行'
  fi
  if [[ $UNINSTALL == 1 ]]; then
    check_uninstall
    return
  fi
  if [[ $RESUME_SITE_DOWNLOAD == 1 ]]; then
    check_site_download_resume
    return
  fi
  [[ ! -e $BASE && ! -e $CERT_DIR && ! -e $WEB_ROOT ]] || die "发现已有安装或残留文件，请先检查 $BASE；本脚本不覆盖现有部署"
  [[ ! -e $XRAY_CONF && ! -e /usr/local/bin/xray ]] || die '已安装 Xray；请先备份并人工确认，脚本不覆盖'
  for file in /etc/apt/sources.list.d/xray-nginx.list /etc/apt/preferences.d/xray-nginx \
    /usr/share/keyrings/xray-nginx.gpg /etc/systemd/system/xray-acme-renew.service \
    /etc/systemd/system/xray-acme-renew.timer; do
    [[ ! -e $file && ! -L $file ]] || die "发现已有安装文件：$file；请先人工检查"
  done
  local file
  shopt -s nullglob
  for file in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
    case "$file" in
      /etc/nginx/conf.d/default.conf|/etc/nginx/sites-enabled/default) ;;
      *) die "发现现有 Nginx 站点：$file；请使用新服务器或人工合并配置";;
    esac
  done
  shopt -u nullglob
  if command -v nginx >/dev/null 2>&1 || [[ -e /etc/nginx/nginx.conf ]]; then
    die '检测到已安装的 Nginx。为避免升级影响现有服务，本脚本仅支持未安装 Nginx 的新服务器'
  fi
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update
  apt-get -o Acquire::Retries=3 install -y curl ca-certificates gnupg openssl unzip python3 iproute2
  local port
  for port in 80 443 8443; do
    [[ -z $(ss -H -ltn "sport = :$port") ]] || die "TCP $port 已被占用"
  done
  [[ -z $(ss -H -lun 'sport = :443') ]] || die 'UDP 443 已被占用'
  python3 - "${DOMAINS[@]}" <<'PY'
import socket, sys
for domain in sys.argv[1:]:
    try:
        addresses = sorted({item[4][0] for item in socket.getaddrinfo(domain, 80)})
    except socket.gaierror as exc:
        raise SystemExit(f"域名无法解析：{domain}: {exc}")
    print(f"DNS {domain}: {', '.join(addresses)}")
PY
  info '确认以上 DNS 指向本机；ACME 将从公网验证 TCP 80。'
}

install_nginx() {
  info '安装 Nginx 官方 mainline 包'
  download https://nginx.org/keys/nginx_signing.key "$TEMP_DIR/nginx.key"
  local fingerprints
  fingerprints=$(gpg --batch --with-colons --show-keys "$TEMP_DIR/nginx.key")
  [[ $fingerprints == *573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62* ]] || die 'Nginx 签名密钥指纹变化，请按官方文档核实'
  gpg --batch --yes --dearmor --output "$TEMP_DIR/nginx.gpg" "$TEMP_DIR/nginx.key"
  install -m 644 "$TEMP_DIR/nginx.gpg" /usr/share/keyrings/xray-nginx.gpg
  printf 'deb [signed-by=/usr/share/keyrings/xray-nginx.gpg] https://nginx.org/packages/mainline/%s/ %s nginx\n' \
    "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/xray-nginx.list
  chmod 644 /etc/apt/sources.list.d/xray-nginx.list
  cat > /etc/apt/preferences.d/xray-nginx <<'EOF'
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
EOF
  chmod 644 /etc/apt/preferences.d/xray-nginx
  apt-get -o Acquire::Retries=3 update
  apt-get -o Acquire::Retries=3 install -y nginx
  install -d -m 700 "$BASE" "$CERT_DIR" "$BASE/backup"
  BACKUP=$BASE/backup
  cp -a /etc/nginx "$BACKUP/nginx"
  [[ ! -e /etc/nginx/conf.d/default.conf ]] || cp -a /etc/nginx/conf.d/default.conf "$BACKUP/default.conf"
  if [[ -e /etc/nginx/sites-enabled/default || -L /etc/nginx/sites-enabled/default ]]; then
    cp -a /etc/nginx/sites-enabled/default "$BACKUP/default"
  fi
  configure_nginx_site
}

configure_nginx_site() {
  local build
  build=$(nginx -V 2>&1)
  [[ $build == *--with-http_v2_module* ]] || die 'Nginx 未编译 HTTP/2 支持'
  HTTP3=0
  [[ $build != *--with-http_v3_module* ]] || HTTP3=1
  IPV6=0
  if [[ -r /proc/net/if_inet6 ]] && grep -q . /proc/net/if_inet6; then IPV6=1; fi
  # 下载和校验完成后才替换默认配置，网络失败时保留当前配置。
  install -d -m 755 "$WEB_ROOT" "$WEB_ROOT/.well-known" "$WEB_ROOT/.well-known/acme-challenge"
  install_site
  NGINX_CHANGED=1
  rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default
  render_nginx 0 > "$NGINX_CONF"
  chmod 644 "$NGINX_CONF"
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

install_certificate() {
  info "安装 acme.sh，并使用 Let's Encrypt webroot 申请 ECC 证书"
  download https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh "$TEMP_DIR/acme.sh"
  sh -n "$TEMP_DIR/acme.sh"
  (cd "$TEMP_DIR" && sh ./acme.sh --install --home "$ACME_HOME" --accountemail "$EMAIL" --nocron --noprofile)
  "$ACME_HOME/acme.sh" --register-account --home "$ACME_HOME" --server letsencrypt -m "$EMAIL"
  local args=() domain
  for domain in "${DOMAINS[@]}"; do args+=(-d "$domain"); done
  "$ACME_HOME/acme.sh" --issue --home "$ACME_HOME" --server letsencrypt \
    --webroot "$WEB_ROOT" --keylength ec-256 "${args[@]}"
  touch "$CERT_DIR/key.pem" "$CERT_DIR/fullchain.pem"
  chmod 600 "$CERT_DIR/key.pem"
  chmod 644 "$CERT_DIR/fullchain.pem"
  "$ACME_HOME/acme.sh" --install-cert --home "$ACME_HOME" -d "${DOMAINS[0]}" --ecc \
    --key-file "$CERT_DIR/key.pem" --fullchain-file "$CERT_DIR/fullchain.pem" \
    --reloadcmd 'nginx -t && systemctl reload nginx'
}

install_xray() {
  info '调用 XTLS 官方安装脚本安装 Xray 和 geodata'
  download https://github.com/XTLS/Xray-install/raw/main/install-release.sh "$TEMP_DIR/xray-install.sh"
  bash -n "$TEMP_DIR/xray-install.sh"
  install -m 600 "$TEMP_DIR/xray-install.sh" "$BASE/xray-install-release.sh"
  XRAY_INSTALLED=1
  bash "$TEMP_DIR/xray-install.sh" install --manually-restart-later
  [[ -x /usr/local/bin/xray ]] || die 'Xray 安装未生成可执行文件'
  local service_user service_group
  service_user=$(systemctl show xray -p User --value)
  [[ -n $service_user && $service_user != root ]] || die 'Xray 服务必须使用非 root 用户'
  service_group=$(id -gn "$service_user")
  render_xray > "$TEMP_DIR/xray.json"
  /usr/local/bin/xray run -test -config "$TEMP_DIR/xray.json"
  install -m 640 -o root -g "$service_group" "$TEMP_DIR/xray.json" "$XRAY_CONF"
  # 不记录访问日志，错误交给 journald；服务用户无需读取 TLS 私钥。
  systemctl enable xray
  systemctl restart xray
  systemctl is-active --quiet xray
}

enable_renewal() {
  cat > /etc/systemd/system/xray-acme-renew.service <<EOF
[Unit]
Description=Renew Xray Nginx TLS certificates
Wants=network-online.target
After=network-online.target nginx.service

[Service]
Type=oneshot
UMask=0077
ExecStart=$ACME_HOME/acme.sh --cron --home $ACME_HOME
EOF
  cat > /etc/systemd/system/xray-acme-renew.timer <<'EOF'
[Unit]
Description=Daily ACME renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 /etc/systemd/system/xray-acme-renew.{service,timer}
  systemctl daemon-reload
  RENEWAL_ENABLED=1
  systemctl enable --now xray-acme-renew.timer
  systemctl is-active --quiet xray-acme-renew.timer
}

write_client_info() {
  python3 - "${DOMAINS[0]}" "$CLIENT_UUID" "$XHTTP_PATH" > "$BASE/client.txt" <<'PY'
import sys, urllib.parse
host, uid, path = sys.argv[1:]
query = urllib.parse.urlencode({"encryption": "none", "security": "tls", "sni": host,
    "alpn": "h2", "fp": "chrome", "type": "xhttp", "host": host, "path": path, "mode": "auto"})
print(f"地址: {host}\n端口: 443\nUUID: {uid}\n协议: VLESS\n传输: XHTTP\n路径: {path}\nTLS: 开启\nSNI/Host: {host}\nALPN: h2\nFlow: 留空\nMode: auto\n")
print(f"vless://{uid}@{host}:443?{query}#" + urllib.parse.quote(f"{host}-XHTTP"))
PY
  chmod 600 "$BASE/client.txt"
}

# 识别本脚本的新部署或旧版备份；共享实例/配置须人工处理。
check_uninstall() {
  if [[ ! -e $BASE && ! -L $BASE && ! -e $WEB_ROOT && ! -L $WEB_ROOT && ! -e $CERT_DIR && ! -L $CERT_DIR && ! -e $NGINX_CONF && ! -L $NGINX_CONF && ! -e /etc/apt/sources.list.d/xray-nginx.list ]]; then
    UNINSTALL_NOTHING=1
    return
  fi
  command -v python3 >/dev/null || die '移除检查需要 python3'
  python3 - "$BASE" "$WEB_ROOT" "$CERT_DIR" <<'PYUNINSTALL'
import json, os, sys
from pathlib import Path
base, web, cert = map(Path, sys.argv[1:])
def reject(reason):
    raise SystemExit('拒绝移除：' + reason)
# 拒绝受管目录及其父目录被重定向；归档和删除均只处理预期路径。
for path in (base, web, cert, Path('/etc/nginx'), Path('/usr/local/etc/xray'),
             Path('/usr/local/share/xray'), Path('/var/log/xray'), Path('/var/log/nginx'),
             Path('/var/cache/nginx'), Path('/var/backups/xray-nginx')):
    if path.resolve() != path:
        reject(f'目录或父目录包含链接：{path}')
backup = base / 'backup/nginx'
if not (backup / 'nginx.conf').is_file() or backup.resolve() != backup:
    reject('找不到本脚本安装前的 Nginx 备份')
def inventory(root):
    result = {}
    for path in root.rglob('*'):
        key = path.relative_to(root).as_posix()
        if path.is_symlink(): result[key] = ('link', os.readlink(path))
        elif path.is_dir(): result[key] = ('dir',)
        elif path.is_file(): result[key] = ('file', path.read_bytes())
        else: reject(f'不支持的文件类型：{path}')
    return result
current, original = inventory(Path('/etc/nginx')), inventory(backup)
managed = current.pop('conf.d/xray-nginx.conf', None)
if managed and (managed[0] != 'file' or not managed[1].startswith('# 由 install-xray.sh 管理'.encode())):
    reject('Nginx 站点不是本脚本生成的配置')
for name, value in current.items():
    if original.get(name) != value:
        reject(f'Nginx 存在新增或修改的配置：{name}')
if set(original) - set(current) - {'conf.d/default.conf', 'sites-enabled/default'}:
    reject('Nginx 配置结构与原始备份不符')
xray_dir = Path('/usr/local/etc/xray')
if xray_dir.exists():
    if any(p.name != 'config.json' or not p.is_file() or p.is_symlink() for p in xray_dir.iterdir()):
        reject('发现其他 Xray 配置文件或链接')
    config = xray_dir / 'config.json'
    if config.exists():
        data = json.loads(config.read_text())
        inbounds = data.get('inbounds', [])
        if (len(inbounds) != 1 or inbounds[0].get('listen') != '127.0.0.1'
                or inbounds[0].get('port') != 8443 or inbounds[0].get('protocol') != 'vless'
                or inbounds[0].get('streamSettings', {}).get('network') != 'xhttp'):
            reject('Xray 不是本脚本的单实例 XHTTP 配置')
for path in Path('/etc/systemd/system/xray.service.d').glob('*'):
    if path.name != '10-donot_touch_single_conf.conf':
        reject('发现自定义 Xray systemd 配置')
for name in ('logrotate@.service', 'logrotate@.timer'):
    path = Path('/etc/systemd/system') / name
    if path.exists() or path.is_symlink():
        reject('发现可能共享的 logrotate 模板，请先人工处理')
print('移除归属检查通过')
PYUNINSTALL
  [[ -z $(systemctl list-units --all --plain --no-legend 'xray@*.service') ]] || die '发现其他 Xray 实例，拒绝移除'
  local package_state
  package_state=$(dpkg-query -W -f='${db:Status-Status}' nginx 2>/dev/null || true)
  if [[ $package_state == installed || $package_state == config-files ]]; then
    REMOVE_NGINX_PACKAGE=1
    # 仅允许移除 nginx 本身；若 apt 计划连带移除别的软件则停止。
    apt-get -s purge nginx | python3 -c 'import sys
for line in sys.stdin:
    parts = line.split()
    if parts and parts[0] in ("Remv", "Purg") and parts[1].split(":")[0] != "nginx":
        raise SystemExit("拒绝移除：apt 计划连带删除 " + parts[1])'
  fi
}

uninstall_cleanup() {
  local status=$?
  trap - EXIT
  [[ -z $TEMP_DIR ]] || rm -rf -- "$TEMP_DIR"
  if [[ $status != 0 ]]; then
    printf '\n移除未完成，请根据错误继续排查。完整备份：%s\n' "${BACKUP:-尚未创建；未执行移除}" >&2
  fi
  exit "$status"
}

uninstall_deployment() {
  if [[ $UNINSTALL_NOTHING == 1 ]]; then
    info '未发现本脚本的部署，无需移除'
    return
  fi
  if [[ $DRY_RUN == 1 ]]; then
    info '仅预览：归档配置/证书/站点/程序；停止服务和续期任务；官方 remove --purge 移除 Xray；移除 Nginx 包和本部署文件。'
    info '备份保存在 /var/backups/xray-nginx/；公共依赖包和系统账户保留。'
    return
  fi
  TEMP_DIR=$(mktemp -d /tmp/xray-nginx-remove.XXXXXXXX)
  trap uninstall_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local remove_xray=0 path unit paths=()
  if [[ -e /usr/local/bin/xray || -e /etc/systemd/system/xray.service ]]; then
    remove_xray=1
    # 新安装缓存官方安装器，移除时无需网络；兼容未缓存安装器的旧版。
    if [[ -f $BASE/xray-install-release.sh && ! -L $BASE/xray-install-release.sh ]]; then
      cp "$BASE/xray-install-release.sh" "$TEMP_DIR/xray-install.sh"
    else
      download https://github.com/XTLS/Xray-install/raw/main/install-release.sh "$TEMP_DIR/xray-install.sh"
    fi
    bash -n "$TEMP_DIR/xray-install.sh"
  fi
  install -d -m 700 /var/backups/xray-nginx
  BACKUP=$(mktemp /var/backups/xray-nginx/uninstall-XXXXXXXX.tar.gz)
  for path in "$BASE" "$WEB_ROOT" "$CERT_DIR" /etc/nginx /var/log/nginx /var/cache/nginx \
    /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray /var/log/xray \
    /etc/systemd/system/xray.service /etc/systemd/system/xray@.service \
    /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d \
    /etc/systemd/system/xray-acme-renew.service /etc/systemd/system/xray-acme-renew.timer \
    /etc/apt/sources.list.d/xray-nginx.list /etc/apt/preferences.d/xray-nginx /usr/share/keyrings/xray-nginx.gpg; do
    [[ ! -e $path && ! -L $path ]] || paths+=("${path#/}")
  done
  tar -czf "$BACKUP" -C / -- "${paths[@]}"
  tar -tzf "$BACKUP" >/dev/null
  info "移除前的完整备份：$BACKUP（仅 root 可读，含证书和连接凭据）"
  for unit in xray-acme-renew.timer xray-acme-renew.service nginx.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      systemctl stop "$unit"
      [[ $unit == xray-acme-renew.service ]] || systemctl disable "$unit"
    fi
  done
  if [[ $remove_xray == 1 ]]; then
    DAT_PATH=/usr/local/share/xray JSON_PATH=/usr/local/etc/xray JSONS_PATH='' \
      bash "$TEMP_DIR/xray-install.sh" remove --purge
  fi
  if [[ $REMOVE_NGINX_PACKAGE == 1 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=3 purge -y nginx
  fi
  rm -f -- /etc/systemd/system/xray-acme-renew.{service,timer} \
    /etc/apt/sources.list.d/xray-nginx.list /etc/apt/preferences.d/xray-nginx /usr/share/keyrings/xray-nginx.gpg
  rm -rf -- "$BASE" "$WEB_ROOT" "$CERT_DIR" /etc/nginx /var/log/nginx /var/cache/nginx
  systemctl daemon-reload
  info "移除完成。完整备份保存在 $BACKUP；公共依赖包、系统账户和云防火墙规则保留。"
}

main() {
  parse_args "$@"
  if [[ $UNINSTALL == 1 ]]; then
    [[ $RESUME_SITE_DOWNLOAD == 0 && ${#DOMAINS[@]} == 0 && -z $EMAIL && -z $CLIENT_UUID && -z $XHTTP_PATH ]] || die '--uninstall 仅可与 --dry-run 配合使用'
    preflight
    uninstall_deployment
    return
  fi
  if [[ $DRY_RUN == 1 ]]; then
    command -v python3 >/dev/null || die '--dry-run 需要 python3'
    collect_inputs
    printf '\n--- Nginx（HTTP/3、IPv6 均启用的预览）---\n'
    render_nginx 1 1 1
    printf '\n--- Xray ---\n'
    render_xray
    return
  fi
  preflight
  collect_inputs
  TEMP_DIR=$(mktemp -d /tmp/xray-nginx.XXXXXXXX)
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ $RESUME_SITE_DOWNLOAD == 1 ]]; then
    BACKUP=$BASE/backup
    configure_nginx_site
  else
    install_dependencies
    install_nginx
  fi
  install_certificate
  install_xray
  render_nginx 1 "$HTTP3" "$IPV6" > "$NGINX_CONF"
  nginx -t
  systemctl reload nginx
  # 校验证书及本机 HTTPS 页面；保留完整证书验证，不使用 -k。
  curl --fail --silent --show-error --noproxy '*' --connect-timeout 10 --max-time 20 \
    --resolve "${DOMAINS[0]}:443:127.0.0.1" "https://${DOMAINS[0]}/" >/dev/null
  systemctl is-active --quiet nginx xray
  enable_renewal
  write_client_info
  COMPLETED=1
  info "安装完成。HTTP/3=$HTTP3（1 表示启用）；连接信息保存在 $BASE/client.txt（仅 root 可读）"
  printf '查看连接：sudo cat %s/client.txt\n查看日志：sudo journalctl -u xray -u nginx -n 100 --no-pager\n' "$BASE"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
