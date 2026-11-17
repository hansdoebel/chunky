from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest


class SyncGuardTests(unittest.TestCase):
    def test_preserves_local_vendor_files(self):
        for kind in ('modified', 'untracked', 'ignored'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                vendor = root / 'LocalPackages/qdrant-swift/Sources'
                vendor.mkdir(parents=True)
                script = root / 'tools/vendor/sync_qdrant.py'
                script.parent.mkdir(parents=True)
                shutil.copyfile(Path(__file__).with_name('sync_qdrant.py'), script)
                script.with_name('qdrant-swift.json').write_text(json.dumps({'paths': ['Sources'], 'patch': 'compat.patch', 'revision': 'HEAD'}))
                script.with_name('compat.patch').write_text('')
                tracked = vendor / 'tracked.swift'
                tracked.write_text('original')
                (root / '.gitignore').write_text('*.backup\n')
                subprocess.run(['git', 'init', '-q', str(root)], check=True)
                subprocess.run(['git', 'add', '.'], cwd=root, check=True)
                subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], cwd=root, check=True)
                local = tracked if kind == 'modified' else vendor / ('local.backup' if kind == 'ignored' else 'local.swift')
                local.write_text('preserve me')
                result = subprocess.run([sys.executable, str(script), str(root / 'missing-upstream'), '--update'], cwd=root, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Refusing to overwrite', result.stderr)
                self.assertEqual(local.read_text(), 'preserve me')
                self.assertTrue(tracked.exists())
