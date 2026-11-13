"""Synthetic native-runtime check, executed only by the hosted MSI harness."""
from __future__ import annotations

import ctypes
from ctypes import wintypes
import importlib.util
import json
from pathlib import Path
import re
import struct
import sys

VC_NAME = re.compile(r'^(?:msvcp140.*|vcruntime140.*|concrt140|vcomp140|vcamp140|vccorlib140)\.dll$', re.I)


def pe_imports(path):
    """Read normal/delay PE imports without loading the file."""
    with path.open('rb') as source:
        dos = source.read(64)
        if len(dos) < 64 or dos[:2] != b'MZ':
            raise ValueError('Invalid PE header')
        source.seek(struct.unpack_from('<I', dos, 60)[0])
        header = source.read(24)
        if header[:4] != b'PE\0\0':
            raise ValueError('Invalid PE signature')
        count = struct.unpack_from('<H', header, 6)[0]
        optional = source.read(struct.unpack_from('<H', header, 20)[0])
        magic = struct.unpack_from('<H', optional)[0]
        if magic not in (0x20b, 0x10b):
            raise ValueError('Unsupported PE optional header')
        directory_offset = 112 if magic == 0x20b else 96
        image_base = struct.unpack_from('<Q' if magic == 0x20b else '<I', optional, 24 if magic == 0x20b else 28)[0]
        sections = []
        for _ in range(count):
            section = source.read(40)
            size, address, raw_size, raw_address = struct.unpack_from('<IIII', section, 8)
            sections.append((address, max(size, raw_size), raw_address))

        def offset(rva):
            for address, size, raw in sections:
                if address <= rva < address + size:
                    return raw + rva - address
            if 0 <= rva < 4096:
                return rva
            raise ValueError('Invalid PE RVA')

        def name(rva):
            source.seek(offset(rva))
            return source.read(512).split(b'\0', 1)[0].decode('ascii').lower()

        imports = []
        for index, record_size in ((1, 20), (13, 32)):
            if len(optional) < directory_offset + index * 8 + 8:
                continue
            rva, size = struct.unpack_from('<II', optional, directory_offset + index * 8)
            if not rva:
                continue
            base = offset(rva)
            for position in range(min(4096, max(1, size // record_size + 1))):
                source.seek(base + position * record_size)
                descriptor = source.read(record_size)
                if not descriptor or not any(descriptor):
                    break
                if index == 1:
                    name_rva = struct.unpack_from('<I', descriptor, 12)[0]
                else:
                    attrs, name_rva = struct.unpack_from('<II', descriptor)
                    if not attrs & 1:
                        name_rva -= image_base
                imports.append(name(name_rva))
        return set(imports)


def loaded_modules():
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.K32EnumProcessModules.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.HMODULE), wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    kernel.K32EnumProcessModules.restype = wintypes.BOOL
    kernel.K32GetModuleFileNameExW.argtypes = [wintypes.HANDLE, wintypes.HMODULE, wintypes.LPWSTR, wintypes.DWORD]
    kernel.K32GetModuleFileNameExW.restype = wintypes.DWORD
    process = kernel.GetCurrentProcess()
    modules = (wintypes.HMODULE * 4096)()
    needed = wintypes.DWORD()
    if not kernel.K32EnumProcessModules(process, modules, ctypes.sizeof(modules), ctypes.byref(needed)):
        raise ctypes.WinError(ctypes.get_last_error())
    if needed.value > ctypes.sizeof(modules):
        raise ValueError('Module enumeration overflow')
    paths = []
    for handle in modules[:needed.value // ctypes.sizeof(wintypes.HMODULE)]:
        buffer = ctypes.create_unicode_buffer(32768)
        if not kernel.K32GetModuleFileNameExW(process, handle, buffer, len(buffer)):
            raise ctypes.WinError(ctypes.get_last_error())
        paths.append(Path(buffer.value).resolve())
    return paths


def main():
    root = Path(sys.argv[1]).resolve(strict=True)
    if not Path(sys.executable).resolve().is_relative_to(root):
        raise SystemExit('Probe must use the installed bundled interpreter.')
    binaries = [p for p in root.rglob('*') if p.suffix.lower() in ('.dll', '.pyd', '.exe')]
    packaged = {p.name.lower() for p in binaries}
    vc_imports = set()
    for path in binaries:
        vc_imports.update(name for name in pe_imports(path) if VC_NAME.fullmatch(name))
    missing = sorted(vc_imports - packaged)
    if missing:
        raise SystemExit('Unbundled VC imports: ' + ', '.join(missing))
    # Import exactly the installed engine's dependencies. No model/network fetch.
    spec = importlib.util.spec_from_file_location('qa_installed_engine', root / 'app/offline_ai/engine.py')
    engine = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(engine)
    engine.disable_network()
    engine._load_dependencies()
    loaded = [p for p in loaded_modules() if VC_NAME.fullmatch(p.name)]
    if not loaded or any(not p.is_relative_to(root) for p in loaded):
        raise SystemExit('VC DLL loaded from outside the installed package.')
    print(json.dumps({'vc_import_closure': True, 'binaries_examined': len(binaries),
                      'vc_import_names': sorted(vc_imports), 'loaded_vc_app_local': True,
                      'loaded_vc_paths': [p.relative_to(root).as_posix() for p in loaded]}, indent=2))


if __name__ == '__main__':
    main()
