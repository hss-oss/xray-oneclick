from pathlib import Path
import subprocess,tempfile,json,hashlib
ROOT=Path(__file__).resolve().parent.parent
SCRIPT=ROOT/'install-xray.sh'
payload=b'official archive test payload'
digest=hashlib.sha256(payload).hexdigest()
with tempfile.TemporaryDirectory() as td:
 td=Path(td)
 fixture=td/'metadata.json'; archive=td/'payload'; archive.write_bytes(payload)
 def metadata(arch='amd64',**changes):
  name='Xray-linux-64.zip' if arch=='amd64' else 'Xray-linux-arm64-v8a.zip'
  asset={'name':name,'digest':'sha256:'+digest,'url':'https://api.github.com/repos/XTLS/Xray-core/releases/assets/123','browser_download_url':'https://github.com/XTLS/Xray-core/releases/download/v26.10.31/'+name}
  asset.update(changes)
  fixture.write_text(json.dumps({'tag_name':'v26.10.31','draft':False,'prerelease':False,'assets':[asset]}))
 def run(arch='amd64',api_fail=False):
  scratch=td/'scratch'; scratch.mkdir(exist_ok=True)
  code='''source "$1"
TEMP_DIR=$2
FIXTURE=$3
ARCHIVE=$4
TEST_ARCH=$5
API_FAIL=$6
dpkg() { printf '%s\\n' "$TEST_ARCH"; }
download() {
 if [[ $1 == */releases/latest ]]; then cp "$FIXTURE" "$2"
 elif [[ $1 == */releases/assets/* && $API_FAIL == yes ]]; then return 22
 else cp "$ARCHIVE" "$2"; fi
}
prepare_xray_archive
'''
  return subprocess.run(['bash','-c',code,'_',str(SCRIPT),str(scratch),str(fixture),str(archive),arch,'yes' if api_fail else 'no'],text=True,capture_output=True)
 for arch in ['amd64','arm64']:
  metadata(arch)
  assert run(arch).returncode==0
  assert run(arch,True).returncode==0
 metadata(digest='sha256:'+'0'*64)
 assert run().returncode!=0
 metadata(digest=None)
 assert run().returncode!=0
 metadata(url='https://evil.invalid/payload')
 assert run().returncode!=0
 print('PASS: 官方元数据按 amd64/arm64 选包、API 失败回退、拒绝哈希不符/缺失/非官方地址')
