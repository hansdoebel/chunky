import os
from pathlib import Path
import shutil
import subprocess
import sys


WORKER = Path(__file__).resolve().parents[1]
SCRIPTS = WORKER.parent / "Chunky" / "Resources" / "Scripts"


def run_fresh_filter(package_path, expected_scripts, cwd, configured_scripts=None):
    env = {**os.environ, "PYTHONPATH": str(package_path), "EXPECTED_SCRIPTS": str(expected_scripts)}
    env.pop("CHUNKY_SCRIPTS_DIR", None)
    if configured_scripts is not None:
        env["CHUNKY_SCRIPTS_DIR"] = str(configured_scripts)
    result = subprocess.run(
        [sys.executable, "-c", """
import os
from pathlib import Path
import sys
from chunky_worker.search import PayloadFilter, build_query_filter
assert 'element_types' not in sys.modules
assert 'docling_convert' not in sys.modules
query = build_query_filter([PayloadFilter(key='content_type', match='figure')])
import element_types
assert Path(element_types.__file__).parent == Path(os.environ['EXPECTED_SCRIPTS'])
clauses = query.must[0].should
assert clauses[0].key == 'content_type'
assert {'figure', 'picture', 'image', 'chart'} <= set(clauses[0].match.any)
assert clauses[1].key == 'content_types'
assert clauses[1].match.any == ['figure']
assert 'docling_convert' not in sys.modules
print('Fresh element filter loaded the expected helper and preserved aliases')
"""],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_installed_worker_uses_configured_scripts_before_any_conversion(tmp_path):
    installed = tmp_path / "site-packages"
    shutil.copytree(WORKER / "chunky_worker", installed / "chunky_worker", ignore=shutil.ignore_patterns("__pycache__", "web_dist"))
    helpers = tmp_path / "configured-helpers"
    helpers.mkdir()
    shutil.copyfile(SCRIPTS / "element_types.py", helpers / "element_types.py")
    run_fresh_filter(installed, helpers, tmp_path, configured_scripts=helpers)


def test_repository_worker_keeps_default_scripts_without_configuration(tmp_path):
    run_fresh_filter(WORKER, SCRIPTS, tmp_path)
