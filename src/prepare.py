# SPDX-License-Identifier: MIT
import argparse
import os
import pwd
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
sys.dont_write_bytecode = True
from state import location, load
parser = argparse.ArgumentParser()
parser.add_argument('--owner')
parser.add_argument('stratum')
args = parser.parse_args()
implementation = location(args.stratum)
config, _ = load(implementation)
if args.owner:
    if os.geteuid() != 0:
        parser.error('--owner requires root')
    owner = pwd.getpwnam(args.owner)
    def drop():
        os.initgroups(owner.pw_name, owner.pw_gid)
        os.setgid(owner.pw_gid)
        os.setuid(owner.pw_uid)
    environment = dict(os.environ, HOME=owner.pw_dir, USER=owner.pw_name, LOGNAME=owner.pw_name)
    environment.pop('XDG_STATE_HOME', None)
    environment.pop('XDG_CACHE_HOME', None)
else:
    drop = None
    environment = os.environ.copy()
with tempfile.TemporaryDirectory(prefix='brl-impurifier-') as staging:
    for index, (field, cache_name) in enumerate([('sdk', 'sdk-cache'), ('installable', 'cache')]):
        command = [shutil.which('nix-store'), '--realise', config[field], '--add-root', f'{staging}/{index}', '--indirect']
        cache = implementation / cache_name
        if cache.is_dir():
            command += ['--option', 'substituters', cache.as_uri()]
            if os.geteuid() == 0:
                command += ['--option', 'require-sigs', 'false']
        subprocess.run(command, check=True)
    subprocess.run([sys.executable, str(Path(__file__).with_name('register.py')), str(implementation), shutil.which('nix-store')], check=True, preexec_fn=drop, env=environment)
