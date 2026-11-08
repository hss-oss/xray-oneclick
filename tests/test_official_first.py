from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
SCRIPT=ROOT/'install-xray.sh'
with tempfile.TemporaryDirectory() as td:
 td=Path(td)
 stub='''#!/usr/bin/env bash
printf 'official %s\\n' "$*" >> "$TEST_LOG"
if [[ $2 == --local ]]; then exit 0; fi
case "$MODE" in
 success) exit 0;;
 network) printf 'curl: (22) The requested URL returned error: 504\\nerror: Download failed! Please check your network or try again.\\n'; exit 77;;
 checksum) printf 'error: SHA256 check failed!\\n'; exit 78;;
 permission) printf 'error: Permission denied\\n'; exit 79;;
esac
'''
 (td/'xray-install.sh').write_text(stub)
 for mode,expected,count in [('success',0,0),('network',0,1),('checksum',78,0),('permission',79,0)]:
  log=td/f'{mode}.log'
  code='source "$1"; TEMP_DIR=$2; export TEST_LOG=$3 MODE=$4; prepare_xray_archive() { printf "api-fallback\\n" >> "$TEST_LOG"; }; run_xray_installer'
  p=subprocess.run(['bash','-c',code,'_',str(SCRIPT),str(td),str(log),mode],text=True,capture_output=True)
  assert p.returncode==expected,(mode,p.returncode,p.stdout,p.stderr)
  events=log.read_text()
  assert events.count('api-fallback')==count,(mode,events)
  assert events.startswith('official install --manually-restart-later\n')
  if count: assert 'official install --local' in events
 print('PASS: 官方在线成功不走备用；网络失败触发API；校验/权限错误保留退出码')
 # 验证续装主流程沿用证书，不能再次触发证书申请或 apt 安装。
 code='''source "$1"
TEMP_ROOT=$2
preflight() { :; }
collect_inputs() { :; }
configure_nginx_site() { :; }
install_certificate() { return 91; }
install_dependencies() { return 92; }
install_nginx() { return 93; }
install_xray() { :; }
render_nginx() { printf test; }
openssl() { :; }
nginx() { :; }
systemctl() { :; }
curl() { :; }
enable_renewal() { :; }
write_client_info() { :; }
BASE=$TEMP_ROOT
NGINX_CONF=$TEMP_ROOT/nginx.conf
DOMAINS=(example.com)
HTTP3=1
IPV6=1
main --resume-xray
'''
 p=subprocess.run(['bash','-c',code,'_',str(SCRIPT),str(td)],text=True,errors='backslashreplace',capture_output=True)
 assert p.returncode==0,p.stdout+p.stderr
 print('PASS: --resume-xray 跳过 apt/Nginx重装和证书签发')
