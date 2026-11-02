# SPDX-License-Identifier: MIT
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

PREFIX = Path('/bedrock/strata')
def part(value):
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.+-]*', value):
        raise ValueError('invalid native stratum name')
    return value

def location(stratum):
    return PREFIX / part(stratum) / 'usr/share/brl-impurifier'

def load(implementation):
    data = (implementation / 'application.json').read_bytes()
    config = json.loads(data)
    for field in ['installable', 'sdk']:
        target = config[field]
        if not re.fullmatch(r'/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+', target) or target.endswith('.drv'):
            raise ValueError('expected a Nix output store path')
    return config, hashlib.sha256(data).hexdigest()

def state_root():
    return Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'brl-impurifier'

def initialize(implementation):
    config, digest = load(implementation)
    key = digest
    state = state_root() / key
    state.mkdir(parents=True, exist_ok=True)
    (state / 'source.json').write_text(json.dumps({'implementation': str(implementation), 'digest': digest}))
    return config, state

def register(implementation, nix_store=None):
    config, state = initialize(implementation)
    for field, root in [('sdk', 'sdk-root'), ('installable', 'nix-root')]:
        subprocess.run([nix_store or (config['nixBin'] + '/nix-store'), '--realise', config[field], '--add-root', str(state / root), '--indirect'], check=True, stdout=subprocess.DEVNULL)
    return config, state
