# SPDX-License-Identifier: MIT
import fcntl
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
from state import part, register
implementation = Path('/bedrock/strata') / part(os.getxattr('/', 'user.bedrock.stratum').decode()) / 'usr/share/brl-impurifier'
config, state = register(implementation)
program = config['installable'] + '/bin/' + config['program']
environment = os.environ.copy()
os.environ['PATH'] = config['nixBin'] + ':' + os.environ.get('PATH', '')
if config.get('hardware'):
    spec = importlib.util.spec_from_file_location('engine', implementation / 'engine.py')
    engine = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(engine)
    manifest = engine.validate({'name': 'brl-hardware', 'version': '1', 'priority': 5,
        'installable': config['installable'], 'hardware': config['hardware']}, 'brl-impurifier')
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        snapshot = engine.hardware_snapshots([manifest], state)['brl-hardware']
        subprocess.run([config['nixBin'] + '/nix-store', '--realise', snapshot, '--add-root', str(state / ('library-' + hashlib.sha256(snapshot.encode()).hexdigest())), '--indirect'], check=True, stdout=subprocess.DEVNULL)
    environment['LD_LIBRARY_PATH'] = snapshot + (':' + environment['LD_LIBRARY_PATH'] if environment.get('LD_LIBRARY_PATH') else '')
    if config['hardware'].get('preload'):
        environment['LD_PRELOAD'] = ' '.join(snapshot + '/' + name for name in config['hardware']['preload'])
os.execve(program, [program, *sys.argv[1:]], environment)
