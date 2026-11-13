"""Exercise bundled inference after a real install, with a synthetic blank PNG."""
from __future__ import annotations

import base64
import json
from pathlib import Path
import struct
import subprocess
import sys
import zlib


def blank_png(width=320, height=220):
    def chunk(kind, body):
        return struct.pack('!I', len(body)) + kind + body + struct.pack('!I', zlib.crc32(kind + body) & 0xffffffff)
    pixels = (b'\x00' + b'\xff\xff\xff' * width) * height
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


def main():
    installed = Path(sys.argv[1]).resolve()
    request = {'images': ['data:image/png;base64,' + base64.b64encode(blank_png()).decode('ascii')], 'languages': ['ar', 'en']}
    result = subprocess.run([str(installed / 'runtime/python.exe'), '-B', '-X', 'utf8', str(installed / 'app/offline_ai/engine.py')],
                            input=json.dumps(request).encode(), capture_output=True, timeout=75)
    if result.returncode:
        raise SystemExit('Installed offline inference failed; exit=' + str(result.returncode))
    output = json.loads(result.stdout)
    if output.get('network_disabled') is not True or len(output.get('images', [])) != 1:
        raise SystemExit('Installed inference returned an invalid result.')
    print(json.dumps({'offline_inference_ok': True, 'network_disabled': True,
                      'elapsed_seconds': output.get('elapsed_seconds')}, indent=2))


if __name__ == '__main__':
    main()
