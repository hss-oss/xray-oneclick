from pathlib import Path
import json,subprocess,tempfile
SCRIPT=Path(__file__).resolve().parent.parent/'install-xray.sh'
UUID='12345678-1234-4123-8123-123456789abc'
with tempfile.TemporaryDirectory() as td:
 td=Path(td);base=td/'managed';log=td/'steps'
 def shell(code,*args):
  return subprocess.run(['bash','-c','source "$1"; shift; '+code,'_',str(SCRIPT),*map(str,args)],text=True,errors='backslashreplace',capture_output=True)
 p=shell('BASE=$1; DOMAINS=(example.com); EMAIL=admin@example.com; CLIENT_UUID=$2; XHTTP_PATH=/test-path; save_install_state certificate',base,UUID)
 assert p.returncode==0,p.stderr
 assert (base/'install-state.json').stat().st_mode & 0o777==0o600
 state=json.loads((base/'install-state.json').read_text());assert state['stage']=='certificate'
 code='''BASE=$1; LOG=$2; MODE=$3
preflight() { :; }
resume_nginx() { printf 'nginx\\n' >> "$LOG"; }
certificate_ready() { return 0; }
install_certificate() { printf 'unexpected-certificate\\n' >> "$LOG"; return 99; }
install_dependencies() { printf 'unexpected-dependencies\\n' >> "$LOG"; return 98; }
install_xray() { printf 'xray\\n' >> "$LOG"; if [[ $MODE == fail ]]; then return 77; fi; }
render_nginx() { printf 'mock nginx'; }
nginx() { :; }
systemctl() { :; }
curl() { :; }
gpg() { :; }
ss() { :; }
enable_renewal() { printf 'renewal\\n' >> "$LOG"; }
write_client_info() { printf 'client\\n' >> "$LOG"; }
NGINX_CONF=$BASE/test-nginx.conf
HTTP3=0
IPV6=0
main --resume
'''
 p=shell(code,base,log,'fail');assert p.returncode==77,p.stdout+p.stderr
 failed=json.loads((base/'install-state.json').read_text());assert failed['stage']=='certificate' and failed['uuid']==UUID
 p=shell(code,base,log,'success');assert p.returncode==0,p.stdout+p.stderr
 finished=json.loads((base/'install-state.json').read_text());assert finished['stage']=='complete' and finished['uuid']==UUID and finished['path']=='/test-path'
 assert log.read_text().splitlines()==['nginx','xray','nginx','xray','renewal','client']
 print('PASS: Xray阶段失败保留证书进度；下次恢复跳过依赖/签发并完成后续，UUID/路径保持一致')
 before=(base/'install-state.json').read_bytes()
 p=shell('BASE=$1; DOMAINS=(other.example.com); load_install_state',base)
 assert p.returncode and (base/'install-state.json').read_bytes()==before
 p=shell('BASE=$1; CLIENT_UUID=87654321-1234-4123-8123-123456789abc; load_install_state',base)
 assert p.returncode
 print('PASS: 进度文件权限600；拒绝续装中意外更换域名或UUID')
