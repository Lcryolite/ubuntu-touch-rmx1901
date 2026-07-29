#!/usr/bin/env python3
import hashlib, json, os, shutil, subprocess, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "scripts/stage-m1-predecessor.py"
TMP = Path(tempfile.mkdtemp(prefix="stage-m1-predecessor.", dir=os.environ.get("TMPDIR", "/tmp")))
try:
    root = TMP / "root"; root.mkdir(mode=0o700)
    image = TMP / "predecessor.img"; image.write_bytes(b"p" * 4096)
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    lock = {"schema":"rmx1901-m1-deployment-v1","device":"RMX1901","serial":"7b0c1c49","product":"fox_RMX1901","model":"RMX1901","target":"/dev/block/sde10","target_size":4096,"target_major_minor":"8:4a","predecessor_sha256":digest,"candidate_sha256":"8"*64,"candidate_size":4096}
    raw = SOURCE.read_text().replace('ROOT = Path("/var/lib/rmx1901-m1-control")', f'ROOT = Path("{root}")').replace('67108864,"8:4a",67108864', '4096,"8:4a",4096').replace('os.geteuid() != 0', 'False')
    tool = TMP / "stage.py"; tool.write_text(raw); tool.chmod(0o500)
    (root / "m1-deployment-v1.json").write_text(json.dumps(lock)); (root / "m1-deployment-v1.json").chmod(0o400)
    subprocess.run([str(tool), str(image)], check=True)
    assert (root / "m1-predecessor.img").read_bytes() == image.read_bytes()
    assert subprocess.run([str(tool), str(image)], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 20
    print("ok - locked M1 predecessor stages once for verified recovery")
finally:
    shutil.rmtree(TMP, ignore_errors=True)
