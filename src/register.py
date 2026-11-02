# SPDX-License-Identifier: MIT
import sys
from pathlib import Path
sys.dont_write_bytecode = True
from state import register
register(Path(sys.argv[1]), nix_store=sys.argv[2])
