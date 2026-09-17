"""Run without credentials against an installed dsh output (outside build sandbox)."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time
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
    # Do not let ambient proxy settings redirect localhost checks.
    http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        for _ in range(120):
            if process.poll() is not None:
                raise RuntimeError('Web exited early:\n' + log.read_text())
            try:
                with http.open(origin + '/', timeout=1) as response:
                    html = response.read().decode()
                break
            except (OSError, TimeoutError):
                time.sleep(0.5)
        else:
            raise RuntimeError('Web startup timed out:\n' + log.read_text())
        assets = sorted(set(re.findall(r'''(?:src|href)=["'](/assets/[^"']+)["']''', html)))
        if not any('.js' in asset for asset in assets):
            raise RuntimeError('No built JavaScript asset referenced by served HTML')
        for asset in ['/manifest.webmanifest', *assets]:
            with http.open(origin + asset, timeout=10) as response:
                assert response.status == 200, asset
                assert response.read(), asset
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
