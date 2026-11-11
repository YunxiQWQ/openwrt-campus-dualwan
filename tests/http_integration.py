#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real curl requests to a loopback-only fictional portal. No campus is contacted."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = 'TEST_ONLY_ACCOUNT+&中文'
PASSWORD = 'TEST_ONLY_PASSWORD%&='
QUERY = 'wlanuserip=127.0.0.2&session=TEST_ONLY%2Bspace'


class Handler(http.server.BaseHTTPRequestHandler):
    authenticated = False
    logins = 0
    foreign_redirect = False

    def log_message(self, *_args):
        pass

    def do_GET(self):
        if type(self).authenticated:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(302)
            origin = 'http://203.0.113.2' if type(self).foreign_redirect else self.server.origin
            self.send_header('Location', origin + '/eportal/index.jsp?' + QUERY)
            self.end_headers()

    def do_POST(self):
        fields = urllib.parse.parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
        if self.path.endswith('method=pageInfo'):
            assert fields['queryString'][0] == QUERY
            result = {'passwordEncrypt': False, 'validCodeUrl': ''}
        elif self.path.endswith('method=login'):
            assert urllib.parse.unquote_plus(fields['userId'][0]) == ACCOUNT
            assert urllib.parse.unquote_plus(fields['password'][0]) == PASSWORD
            assert urllib.parse.unquote_plus(fields['queryString'][0]) == QUERY
            type(self).authenticated = True
            type(self).logins += 1
            result = {'result': 'success'}
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps(result).encode())


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.origin = f'http://127.0.0.1:{server.server_port}'
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='campus-http-test-') as temp:
        directory = Path(temp)
        for name, value in [('username', ACCOUNT), ('password', PASSWORD)]:
            (directory / name).write_text(value)
            (directory / name).chmod(0o600)
        config = json.loads((ROOT / 'examples/auth.example.json').read_text())
        config.update(portal_origin=server.origin, campus_device='lo',
                      username_file=str(directory / 'username'), password_file=str(directory / 'password'),
                      connectivity_checks=[{'url': server.origin + '/check1', 'status': 200, 'body': 'OK'},
                                           {'url': server.origin + '/check2', 'status': 200, 'body': 'OK'}])
        (directory / 'config.json').write_text(json.dumps(config))
        driver = r'''
require ARGV.shift
class LoopbackTransport < CampusDualwan::CurlTransport
  def status(_interface); {device: 'lo', ip: '127.0.0.2'}; end
  def wait(_seconds); end
end
config = CampusDualwan.json(ARGV[0])
portal = CampusDualwan::Portal.new(config, transport: LoopbackTransport.new)
begin
  puts portal.authenticate(ARGV[1])
rescue CampusDualwan::Error => error
  warn error.message
  puts 'controlled_rejection'
end
'''
        command = ['ruby', '-e', driver, str(ROOT / 'lib/portal.rb'), str(directory / 'config.json'), temp]
        first = subprocess.run(command, capture_output=True, text=True, check=True, timeout=30)
        assert first.stdout.strip() == 'online', first.stdout + first.stderr
        assert Handler.logins == 1
        Handler.authenticated = False
        Handler.foreign_redirect = True
        second = subprocess.run(command, capture_output=True, text=True, check=True, timeout=30)
        assert second.stdout.strip() == 'controlled_rejection'
        assert Handler.logins == 1, 'credentials submitted after foreign redirect'
        assert ACCOUNT not in first.stdout + first.stderr + second.stdout + second.stderr
        assert PASSWORD not in first.stdout + first.stderr + second.stdout + second.stderr
        print('PASS: real curl, UTF-8/double encoding, post-login verification, foreign redirect rejection')
finally:
    server.shutdown()
    server.server_close()
