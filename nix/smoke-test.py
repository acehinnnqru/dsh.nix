"""Run without credentials against an installed dsh output (outside build sandbox)."""
import argparse
import http.cookiejar
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('package', type=Path)
parser.add_argument('--node', required=True)
args = parser.parse_args()
package = args.package.resolve()
with tempfile.TemporaryDirectory(prefix='dsh-smoke-') as temporary:
    env = {'HOME': temporary, 'DSH_HOME': temporary + '/home',
           'TMPDIR': temporary, 'PATH': os.environ.get('PATH', ''),
           'DSH_TELEMETRY_DISABLED': '1', 'NO_COLOR': '1'}
    cli = str(package / 'bin/dsh')
    version = subprocess.check_output([cli, '--version'], env=env, text=True).strip()
    subprocess.run([cli, '--help'], env=env, stdout=subprocess.DEVNULL, check=True)
    # `dsh plugin` forwards to pnpm, and the package is supposed to keep the
    # pinned one on the runtime PATH by default, so plugin management must work
    # with nothing else installed. Gate on an explicit opt-in: a build with
    # `pluginPnpm = false` is a supported configuration, not a failure.
    if os.environ.get('DSH_SMOKE_EXPECT_PNPM') == '1':
        plugin = subprocess.run([cli, 'plugin', '--profile', 'smoke-probe', 'list'],
                                env=env, text=True, capture_output=True)
        if 'pnpm not found on PATH' in plugin.stdout + plugin.stderr:
            sys.exit('pnpm is not on the runtime PATH even though pluginPnpm is '
                     'meant to be on (build with pluginPnpm = false and unset '
                     'DSH_SMOKE_EXPECT_PNPM, or restore the bundled pnpm)')
        print('pnpm: passed')
    # Verify the installed native binary, not a development node_modules tree.
    pty_test = r'''
const {createRequire} = require('node:module');
const requireRuntime = createRequire(process.argv[1] + '/package.json');
const pty = requireRuntime('node-pty');
const terminal = pty.spawn('/bin/sh', ['-c', 'printf DSH_PTY_OK'], {env: process.env});
let output = '';
const timeout = setTimeout(() => { terminal.kill(); process.exit(1); }, 10000);
terminal.onData(text => output += text);
terminal.onExit(({exitCode}) => {
  clearTimeout(timeout);
  if (exitCode !== 0 || !output.includes('DSH_PTY_OK')) process.exit(1);
  console.log('PTY: passed');
});
'''
    subprocess.run([args.node, '-e', pty_test, str(package / 'lib/dsh')], env=env, check=True)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    log = Path(temporary) / 'web.log'
    with log.open('w') as output:
        process = subprocess.Popen([cli, 'web', '--host', '127.0.0.1', '--port', str(port), '--no-open'],
                                   cwd=temporary, env=env, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    origin = f'http://127.0.0.1:{port}'
    # The server refuses unauthenticated requests: it prints one URL carrying
    # the access token, which trades that token for a session cookie and
    # redirects to `/`. Follow that with a cookie jar, then check the assets the
    # served HTML actually references.
    served_origin = origin + '/'
    cookie_jar = http.cookiejar.CookieJar()
    # Do not let ambient proxy settings redirect localhost checks.
    http = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(cookie_jar),
    )
    try:
        for _ in range(120):
            if process.poll() is not None:
                raise RuntimeError('Web exited early:\n' + log.read_text())
            served = re.search(r'http://127\.0\.0\.1:\d+/[^\s]*', log.read_text())
            if served:
                served_origin = served.group(0)
            try:
                with http.open(served_origin, timeout=1) as response:
                    html = response.read().decode()
                break
            except (OSError, TimeoutError):
                time.sleep(0.5)
        else:
            raise RuntimeError('Web startup timed out:\n' + log.read_text())
        if not served_origin.startswith(origin):
            raise RuntimeError(f'Web advertised an unexpected origin: {served_origin}')
        token = urllib.parse.parse_qs(urllib.parse.urlsplit(served_origin).query).get('token', [''])[0]
        # The SPA is built with relative asset URLs ("./assets/..."), so resolve
        # whatever the HTML references against the URL that served it.
        referenced = re.findall(r'''(?:src|href)=["']([^"'#]+)["']''', html)
        assets = sorted({path for path in referenced if '/assets/' in path})
        if not any('.js' in asset for asset in assets):
            raise RuntimeError('No built JavaScript asset referenced by served HTML')
        for asset in ['/manifest.webmanifest', *assets]:
            url = urllib.parse.urljoin(served_origin, asset)
            # Static assets are served without the token; retry with it so a
            # stricter server still passes this check rather than failing it.
            for candidate in (url, f'{url}?token={token}'):
                try:
                    with http.open(candidate, timeout=10) as response:
                        if response.status != 200 or not response.read():
                            raise RuntimeError(f'{asset} returned {response.status}')
                    break
                except (OSError, TimeoutError) as error:
                    last = error
            else:
                raise RuntimeError(f'{asset} could not be fetched: {last}')
        print(json.dumps({'version': version, 'cli': 'passed', 'web': 'passed', 'assets': len(assets)}))
    except Exception:
        print(log.read_text())
        raise
    finally:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
