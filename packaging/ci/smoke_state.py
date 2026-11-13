"""Synthetic customer-state fixture used only by the isolated installer smoke."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import sqlite3


def hash_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(directory):
    files = {path.relative_to(directory).as_posix(): hash_file(path)
             for path in sorted(directory.rglob('*')) if path.is_file()}
    with sqlite3.connect(directory / 'qcontract.sqlite3') as db:
        counts = {table: db.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0]
                  for table in ('companies', 'employees', 'contracts', 'images')}
        docx = db.execute('SELECT docx FROM contracts').fetchone()[0]
        photo = db.execute('SELECT content FROM images').fetchone()[0]
    return {'files': files, 'counts': counts, 'contract_sha256': hashlib.sha256(docx).hexdigest(),
            'photo_sha256': hashlib.sha256(photo).hexdigest()}


def create(directory):
    from domain import Store
    from signatures import windows_protect
    store = Store(directory)
    company = store.save_company({'name_ar': 'شركة اختبار وهمية', 'name_en': 'Synthetic MSI Test Company'})['id']
    png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jp1sAAAAASUVORK5CYII=')
    employee = store.save_employee({'company_id': company, 'name_ar': 'موظف الاختبار',
        'name_en': 'SYNTHETIC TEST PERSON', 'civil_id': '291010112345', 'passport': 'TEST12345',
        'salary': '250.000', 'job_ar': 'موظف اختبار',
        'images': {'front': 'data:image/png;base64,' + base64.b64encode(png).decode()}})['id']
    store.create_contract({'employee_id': employee, 'start_date': '2026-01-01', 'end_date': '2027-01-01',
                           'salary': '250.000', 'contract_type': 'محدد المدة', 'language': 'عربي'})
    # Test bytes only: no real activation code, license, or signing key is used.
    (directory / 'activation.dpapi').write_bytes(windows_protect(b'{"fixture":"installer-preservation-only"}'))
    # server --diagnose opens this log even without any diagnostic error.
    # Include its empty baseline now so a healthy diagnosis adds no new file.
    (directory / 'qcontract.log').write_bytes(b'')
    backup = directory / 'Backups'
    backup.mkdir(exist_ok=True)
    (backup / 'synthetic-msi-fixture.zip').write_bytes(store.backup())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=('create', 'verify'))
    parser.add_argument('data_directory', type=Path)
    parser.add_argument('baseline', type=Path)
    args = parser.parse_args()
    if args.operation == 'create':
        create(args.data_directory)
        value = snapshot(args.data_directory)
        args.baseline.write_text(json.dumps(value, indent=2), encoding='utf-8')
    else:
        value = snapshot(args.data_directory)
        expected = json.loads(args.baseline.read_text(encoding='utf-8'))
        if value != expected:
            raise SystemExit('Reinstall/uninstall changed the synthetic customer state.')
    print(json.dumps({'data_preserved': True, 'counts': value['counts'],
                      'files_checked': len(value['files'])}, indent=2))


if __name__ == '__main__':
    main()
