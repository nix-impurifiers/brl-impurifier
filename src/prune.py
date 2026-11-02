# SPDX-License-Identifier: MIT
import json
import shutil
from pathlib import Path
from state import PREFIX, load, state_root
root = state_root()
if root.is_dir():
    for state in root.iterdir():
        descriptor = state / 'source.json'
        if not descriptor.is_file():
            continue
        source = json.loads(descriptor.read_text())
        try:
            _, digest = load(Path(source['implementation']))
        except FileNotFoundError:
            digest = None
        if digest == source['digest']:
            continue
        # Native rename/copy can retain the same payload under another stratum.
        replacement = None
        for candidate in PREFIX.glob('*/usr/share/brl-impurifier/application.json'):
            try:
                _, digest = load(candidate.parent)
            except FileNotFoundError:
                continue
            if digest == source['digest']:
                replacement = candidate.parent
                break
        if replacement is None:
            shutil.rmtree(state)
        else:
            source['implementation'] = str(replacement)
            descriptor.write_text(json.dumps(source))
