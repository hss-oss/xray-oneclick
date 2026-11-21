"""验证生成配置；有 Nginx 时用临时端口实际验证代理与静态站点。"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time

SCRIPT = Path(__file__).resolve().parent.parent / 'install-xray.sh'
UUID = '12345678-1234-4123-8123-123456789abc'


def render(tls, http3, ipv6, web='/var/www/xray-nginx', cert='/tmp/test-cert'):
    code = '''source "$1"
DOMAINS=(example.test alt.example.test)
XHTTP_PATH=/test-xhttp
WEB_ROOT=$2
CERT_DIR=$3
render_nginx "$4" "$5" "$6"
'''
    return subprocess.check_output(
        ['bash', '-c', code, '_', str(SCRIPT), str(web), str(cert),
         str(tls), str(http3), str(ipv6)], text=True)


for http3 in (0, 1):
    for ipv6 in (0, 1):
        config = render(1, http3, ipv6)
        assert config.count('map $http_upgrade') == 1
        assert config.count('location = / {') == 1
        assert 'https://$host/view/' in config, '兜底跳转必须保留当前域名'
        assert 'server_name example.test alt.example.test;' in config
assert 'proxy_pass' not in render(0, 0, 0), '证书申请前的 HTTP 站点应保持静态服务'
invalid = subprocess.run(
    ['bash', str(SCRIPT), '--dry-run', '--domain', 'example.test',
     '--email', 'admin@example.test', '--uuid', UUID, '--path', '/view'],
    capture_output=True, text=True)
assert invalid.returncode != 0 and '/view 已保留' in invalid.stderr
print('PASS: 渲染组合、多域名、HTTP 初始阶段、保留路径校验')

nginx = shutil.which('nginx')
if not nginx:
    print('SKIP: 本机没有 Nginx；实际 HTTP/TLS 验证需在装有 Nginx 的 Linux 上执行')
    raise SystemExit(0)


def free_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


class Backend(BaseHTTPRequestHandler):
    mode = 200

    def do_GET(self):
        code = 503 if self.path == '/api/failure' else self.mode
        data = json.dumps({
            'path': self.path,
            'session_id': self.headers.get('session_id'),
            'upgrade': self.headers.get('Upgrade'),
            'connection': self.headers.get('Connection'),
        }).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix='xray-nginx-test-') as folder:
    root = Path(folder)
    # Nginx worker 需要穿过临时目录读取测试静态文件。
    root.chmod(0o755)
    web, cert = root / 'web', root / 'cert'
    web.mkdir(mode=0o755)
    cert.mkdir(mode=0o755)
    fixtures = {
        'index.html': '<html>static-view<link href="css/style.css"></html>',
        'about.html': 'static-about',
        'css/style.css': 'body { color: black; }',
        'js/app.js': 'console.log("static");',
        'images/test.svg': '<svg xmlns="http://www.w3.org/2000/svg"/>',
        'fonts/test.woff': 'font-fixture',
        '.well-known/acme-challenge/test': 'acme-token',
    }
    for name, content in fixtures.items():
        target = web / name
        target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        target.write_text(content)
        target.chmod(0o644)
    subprocess.run([
        'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', str(cert / 'key.pem'), '-out', str(cert / 'fullchain.pem'),
        '-days', '1', '-subj', '/CN=example.test',
        '-addext', 'subjectAltName=IP:127.0.0.1,DNS:example.test',
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    context = ssl.create_default_context(cafile=str(cert / 'fullchain.pem'))
    backend = ThreadingHTTPServer(('127.0.0.1', 0), Backend)
    thread = threading.Thread(target=backend.serve_forever, daemon=True)
    thread.start()
    http_port, tls_port = free_port(), free_port()
    config_path = root / 'nginx.conf'

    def write_config(http3=0, ipv6=0):
        config = render(1, http3, ipv6, web, cert)
        config = config.replace('listen 80;', f'listen 127.0.0.1:{http_port};')
        config = config.replace('listen [::]:80;', f'listen [::1]:{http_port};')
        config = config.replace('listen 443 ', f'listen 127.0.0.1:{tls_port} ')
        config = config.replace('listen [::]:443 ', f'listen [::1]:{tls_port} ')
        config = config.replace('127.0.0.1:3500', f'127.0.0.1:{backend.server_port}')
        config_path.write_text(
            f'worker_processes 1;\npid {root}/nginx.pid;\n'
            f'error_log {root}/error.log;\nevents {{ worker_connections 64; }}\n'
            f'http {{ access_log off; {config}\n}}\n')

    build = subprocess.run([nginx, '-V'], capture_output=True, text=True, check=True)
    http3_options = (0, 1) if '--with-http_v3_module' in build.stderr else (0,)
    for http3 in http3_options:
        for ipv6 in ((0, 1) if socket.has_ipv6 else (0,)):
            write_config(http3, ipv6)
            subprocess.run([nginx, '-t', '-c', str(config_path)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    write_config()

    def request(path, headers=None, secure=True):
        connection = (http.client.HTTPSConnection('127.0.0.1', tls_port, context=context, timeout=5)
                      if secure else http.client.HTTPConnection('127.0.0.1', http_port, timeout=5))
        try:
            connection.request('GET', path, headers={'Host': 'example.test', **(headers or {})})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    process = subprocess.Popen([nginx, '-c', str(config_path), '-g', 'daemon off;'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    backend_stopped = False
    try:
        for attempt in range(50):
            try:
                status, _, body = request('/')
                break
            except (OSError, http.client.HTTPException):
                if process.poll() is not None:
                    raise RuntimeError(process.stderr.read().decode())
                time.sleep(0.1)
        else:
            raise AssertionError('临时 Nginx 未就绪')
        assert status == 200 and json.loads(body)['path'] == '/'
        status, _, body = request('/echo', {'session_id': 'sticky-test'})
        assert status == 200
        assert json.loads(body)['session_id'] == 'sticky-test'
        assert json.loads(body)['connection'] == 'close'
        status, _, body = request('/echo', {'Upgrade': 'websocket', 'Connection': 'upgrade'})
        assert status == 200
        assert json.loads(body)['upgrade'] == 'websocket'
        assert json.loads(body)['connection'] == 'upgrade'
        assert request('/api/failure')[0] == 503, 'API 错误不能变成静态页面跳转'
        for error in (502, 503, 504):
            Backend.mode = error
            status, headers, _ = request('/')
            assert status == 302 and headers['Location'] == 'https://example.test/view/'
        assert request('/', secure=False)[2].decode() == fixtures['index.html']
        assert request('/.well-known/acme-challenge/test', secure=False)[2] == b'acme-token'
        backend.shutdown()
        backend.server_close()
        backend_stopped = True
        assert request('/')[0] == 302, '尚未启动后端时首页必须跳转'
        assert request('/api/failure')[0] == 502, '后端离线时 API 应返回网关错误'
        for name, content in fixtures.items():
            if not name.startswith('.well-known/'):
                status, _, body = request('/view/' + ('' if name == 'index.html' else name))
                assert status == 200 and body.decode() == content, name
        print('PASS: Nginx 配置校验、正常代理、下划线头、升级头、502/503/504 跳转、离线静态资源、API 错误和 ACME')
    finally:
        process.terminate()
        process.wait(timeout=10)
        if not backend_stopped:
            backend.shutdown()
            backend.server_close()
        thread.join(timeout=5)
