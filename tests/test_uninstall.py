from pathlib import Path
import json,os,re,shutil,stat,subprocess,sys,tempfile,tarfile
if sys.platform != 'linux' or os.geteuid() != 0:
 raise SystemExit('此测试需要 Linux 和 root；所有移除操作只在临时 chroot 中执行')
os.environ['LC_ALL']='C'
SCRIPT=Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]/'install-xray.sh'
def run(args,**kw):return subprocess.run(args,text=True,capture_output=True,**kw)
with tempfile.TemporaryDirectory(prefix='xray-chroot-tests-') as scratch:
 scratch=Path(scratch); runtime=scratch/'runtime'; runtime.mkdir()
 def copy_runtime(path):
  path=Path(path); target=runtime/str(path).lstrip('/')
  if target.exists():return
  target.parent.mkdir(parents=True,exist_ok=True)
  shutil.copy2(path.resolve(),target)
  out=run(['ldd',str(path.resolve())]).stdout
  for lib in re.findall(r'(/[^\s()]+)',out):
   if Path(lib).is_file():
    dest=runtime/lib.lstrip('/');dest.parent.mkdir(parents=True,exist_ok=True)
    if not dest.exists():shutil.copy2(Path(lib).resolve(),dest)
 for name in ['/bin/bash','/bin/sh','/usr/bin/python3','/usr/bin/uname','/usr/bin/flock','/usr/bin/mktemp','/usr/bin/tar','/usr/bin/gzip','/usr/bin/install','/usr/bin/mkdir','/usr/bin/cp','/usr/bin/rm']:
  copy_runtime(name)
 stdlib=Path('/usr/lib')/f'python{sys.version_info.major}.{sys.version_info.minor}'
 shutil.copytree(stdlib,runtime/str(stdlib).lstrip('/'),dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','site-packages','dist-packages'))
 for so in stdlib.rglob('*.so'):copy_runtime(so)
 def write(root,name,text,mode=0o644):
  p=root/name.lstrip('/');p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text);p.chmod(mode);return p
 def mock(name,body):write(runtime,'/usr/bin/'+name,'#!/bin/bash\nset -eu\n'+body,0o755)
 mock('dpkg','printf "amd64\\n"\n')
 mock('dpkg-query','printf "installed"\n')
 mock('systemctl','''printf 'systemctl %s\\n' "$*" >> /test-events
case "$1" in
 list-units) if [[ -e /other-instance ]]; then printf 'xray@other.service loaded active running\\n'; fi;;
 cat) [[ -e /etc/systemd/system/$2 ]];;
esac
''')
 mock('apt-get','''printf 'apt %s\\n' "$*" >> /test-events
if [[ $1 == -s ]]; then
 printf 'Purg nginx [1.0]\\n'
 if [[ -e /apt-other ]]; then printf 'Remv unrelated-app [1.0]\\n'; fi
elif [[ -e /apt-fail ]]; then exit 56
fi
''')
 mock('curl','''printf 'download\\n' >> /test-events
[[ ! -e /download-fail ]] || exit 22
while (($#)); do
 if [[ $1 == --output ]]; then cp /official-fixture.sh "$2"; exit; fi
 shift
done
exit 99
''')
 official='''#!/bin/bash
set -eu
printf 'official %s\\n' "$*" >> /test-events
if [[ $1 == install ]]; then exit 77; fi
[[ $1 == remove && $2 == --purge ]]
rm -rf /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray /var/log/xray /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /etc/systemd/system/xray.service.d
'''
 def fixture(root):
  shutil.copy2(SCRIPT,root/'install-xray.sh')
  write(root,'/etc/os-release','ID=ubuntu\nVERSION_CODENAME=noble\n')
  (root/'run/systemd/system').mkdir(parents=True);(root/'run/lock').mkdir()
  (root/'tmp').mkdir(mode=0o1777)
  write(root,'/dev/null','')
  for name in ['/etc/nginx/nginx.conf','/opt/xray-nginx/backup/nginx/nginx.conf']:write(root,name,'events {}\nhttp {}\n')
  for name in ['/etc/nginx/conf.d','/opt/xray-nginx/backup/nginx/conf.d']: (root/name.lstrip('/')).mkdir(parents=True)
  write(root,'/opt/xray-nginx/backup/nginx/conf.d/default.conf','default\n')
  write(root,'/etc/nginx/conf.d/xray-nginx.conf','# 由 install-xray.sh 管理\nserver {}\n')
  write(root,'/var/www/xray-nginx/index.html','site')
  write(root,'/usr/local/ssl/xray-nginx/key.pem','private-certificate-fixture',0o600)
  write(root,'/opt/xray-nginx/client.txt','private-client-fixture',0o600)
  write(root,'/usr/local/etc/xray/config.json',json.dumps({'inbounds':[{'listen':'127.0.0.1','port':8443,'protocol':'vless','streamSettings':{'network':'xhttp'}}]}),0o640)
  write(root,'/usr/local/bin/xray','fixture')
  write(root,'/usr/local/share/xray/geoip.dat','geodata')
  for unit in ['xray.service','xray@.service','nginx.service','xray-acme-renew.service','xray-acme-renew.timer']:write(root,'/etc/systemd/system/'+unit,'fixture')
  write(root,'/etc/apt/sources.list.d/xray-nginx.list','nginx repo')
  write(root,'/etc/apt/preferences.d/xray-nginx','pin')
  write(root,'/usr/share/keyrings/xray-nginx.gpg','key')
  write(root,'/opt/xray-nginx/xray-install-release.sh',official,0o600)
  write(root,'/official-fixture.sh',official,0o600)
  write(root,'/etc/ssh/sshd_config','preserve-ssh')
  write(root,'/shared-dependency','preserve-dependency')
 def events(root):return (root/'test-events').read_text() if (root/'test-events').exists() else ''
 def execute(root,*args):return run(['chroot',str(root),'/bin/bash','/install-xray.sh',*args])
 def setup(name):
  root=scratch/name;shutil.copytree(runtime,root,copy_function=os.link);fixture(root);return root
 root=setup('success')
 result=execute(root,'--uninstall');assert result.returncode==0,result.stdout+result.stderr
 backups=list((root/'var/backups/xray-nginx').glob('*.tar.gz'));assert len(backups)==1
 assert stat.S_IMODE(backups[0].stat().st_mode)==0o600
 with tarfile.open(backups[0]) as archive:
  assert archive.extractfile('opt/xray-nginx/client.txt').read()==b'private-client-fixture'
  assert archive.extractfile('usr/local/ssl/xray-nginx/key.pem').read()==b'private-certificate-fixture'
 assert not (root/'opt/xray-nginx').exists() and not (root/'etc/nginx').exists() and not (root/'usr/local/bin/xray').exists()
 assert (root/'etc/ssh/sshd_config').read_text()=='preserve-ssh' and (root/'shared-dependency').is_file()
 assert 'official remove --purge' in events(root) and 'download' not in events(root)
 result=execute(root,'--uninstall');assert result.returncode==0 and len(list((root/'var/backups/xray-nginx').glob('*.tar.gz')))==1
 print('PASS: 隔离 Linux 中完整移除、敏感备份可读取且权限600、保留SSH/依赖、重复移除安全',flush=True)
 for name,change in [
  ('other-nginx',lambda r:write(r,'/etc/nginx/conf.d/other.conf','other site')),
  ('changed-nginx',lambda r:write(r,'/etc/nginx/nginx.conf','changed')),
  ('other-xray',lambda r:write(r,'/usr/local/etc/xray/other.json','{}')),
  ('other-instance',lambda r:write(r,'/other-instance','')),
  ('apt-other',lambda r:write(r,'/apt-other','')),
  ('shared-logrotate',lambda r:write(r,'/etc/systemd/system/logrotate@.timer','shared')),
 ]:
  root=setup(name);change(root);result=execute(root,'--uninstall');assert result.returncode!=0,(name,result.stdout,result.stderr)
  assert (root/'opt/xray-nginx/client.txt').exists() and 'systemctl stop' not in events(root)
 print('PASS: 拒绝其他Nginx站点/配置改动、其他Xray配置/实例、连带移除包、共享logrotate',flush=True)
 root=setup('preview');result=execute(root,'--uninstall','--dry-run');assert result.returncode==0,result.stderr
 assert not (root/'var/backups/xray-nginx').exists() and not (root/'run/lock/xray-nginx-install.lock').exists() and 'systemctl stop' not in events(root)
 root=setup('network-failure');(root/'opt/xray-nginx/xray-install-release.sh').unlink();write(root,'/download-fail','');result=execute(root,'--uninstall');assert result.returncode==22,result.stderr
 assert (root/'opt/xray-nginx/client.txt').exists() and 'systemctl stop' not in events(root)
 root=setup('legacy');(root/'opt/xray-nginx/xray-install-release.sh').unlink();result=execute(root,'--uninstall');assert result.returncode==0,result.stderr
 assert 'download' in events(root) and 'official remove --purge' in events(root)
 root=setup('apt-failure');write(root,'/apt-fail','');result=execute(root,'--uninstall');assert result.returncode==56,result.stderr
 assert (root/'opt/xray-nginx/client.txt').exists() and list((root/'var/backups/xray-nginx').glob('*.tar.gz'))
 print('PASS: 无写入预览、旧版兼容、网络失败不停止服务、移除失败保留完整备份和退出码',flush=True)
 root=setup('symlink')
 shutil.rmtree(root/'var/www/xray-nginx');(root/'var/www/xray-nginx').symlink_to('/unrelated-site')
 result=execute(root,'--uninstall');assert result.returncode!=0 and 'systemctl stop' not in events(root)
 root=setup('backup-failure');(root/'usr/bin/tar').unlink();write(root,'/usr/bin/tar','#!/bin/bash\nexit 55\n',0o755)
 result=execute(root,'--uninstall');assert result.returncode==55 and 'systemctl stop' not in events(root)
 assert (root/'opt/xray-nginx/client.txt').exists()
 result=execute(root,'--uninstall','--domain','example.com');assert result.returncode!=0
 print('PASS: 拒绝链接目录和冲突参数；备份失败时不停止服务或删除文件',flush=True)
 root=setup('official-install')
 script='source /install-xray.sh; TEMP_DIR=/tmp; mkdir -p /tmp; BASE=/opt/xray-nginx; install_xray'
 result=run(['chroot',str(root),'/bin/bash','-c',script]);assert result.returncode==77,result.stdout+result.stderr
 assert 'official install --manually-restart-later' in events(root) and '--local' not in events(root)
 print('PASS: Xray安装委托官方在线install，未使用API选包或--local，保留官方错误码',flush=True)
print('ALL ISOLATED CHECKS PASSED',flush=True)
