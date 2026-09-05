#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for f in addon/*.sh install-online.sh; do sh -n "$f"; done
for f in build.sh build-ipk.sh server/*.sh; do bash -n "$f"; done
python3 -m unittest discover -s tests -p 'test_*.py'
