#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="$repo_root/scripts/verify-rmx1901-abi-cohort.py"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rmx1901-abi-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT
mkdir -p "$tmp_root/fixture/lib64" "$tmp_root/fixture/bin" "$tmp_root/fixture/etc" "$tmp_root/manifests"

cat >"$tmp_root/provider.c" <<'EOF'
int needed_symbol(void) { return 42; }
EOF
cat >"$tmp_root/consumer.c" <<'EOF'
extern int needed_symbol(void);
int main(void) { return needed_symbol() == 42 ? 0 : 1; }
EOF
aarch64-linux-gnu-gcc -shared -fPIC "$tmp_root/provider.c" -Wl,-soname,libprovider.so \
    -o "$tmp_root/fixture/lib64/libprovider.so"
aarch64-linux-gnu-gcc "$tmp_root/consumer.c" -L"$tmp_root/fixture/lib64" -lprovider \
    -Wl,-rpath,/userdata/rmx1901-hw/wifi/lib64 -o "$tmp_root/fixture/bin/consumer"
printf '<cohort fixture="true"/>\n' >"$tmp_root/fixture/etc/config.xml"

python3 - "$verifier" "$tmp_root" <<'PY'
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

verifier_path = Path(sys.argv[1])
root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("abi_verifier", verifier_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)

def entry(source, destination, consumer, feature="wifi", required_symbols=None):
    path = root / "fixture" / source.lstrip("/")
    metadata = module.elf_metadata("readelf", path)
    return {
        "feature": feature,
        "source_release": "fixture-api30",
        "source_path": source,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "elf_class": metadata["elf_class"],
        "machine": metadata["machine"],
        "soname": metadata["soname"],
        "needed": metadata["needed"],
        "runtime_destination": destination,
        "consumer": consumer,
        **({"required_symbols": required_symbols} if required_symbols else {}),
    }

provider = entry("/lib64/libprovider.so", "/userdata/rmx1901-hw/wifi/lib64/libprovider.so", "consumer")
consumer = entry("/bin/consumer", "/userdata/rmx1901-hw/wifi/bin/consumer", "fixture.service", required_symbols=["needed_symbol"])
config = entry("/etc/config.xml", "/userdata/rmx1901-hw/wifi/etc/config.xml", "fixture.service")
provided = {"libprovider.so"}
allowed = sorted({name for item in (provider, consumer) for name in item["needed"] if name not in provided})
manifest = {
    "schema": "rmx1901-hardware-cohorts-v1",
    "complete": True,
    "source_roots": {"fixture-api30": "fixture"},
    "allowed_system_libraries": allowed,
    "entries": [consumer, config, provider],
}
base = root / "manifests" / "base.json"
base.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

variants = {}
value = copy.deepcopy(manifest); value["complete"] = False; variants["incomplete"] = value
value = copy.deepcopy(manifest); value["entries"][0]["sha256"] = "0" * 64; variants["hash"] = value
value = copy.deepcopy(manifest); value["entries"][0]["needed"] = []; variants["needed"] = value
value = copy.deepcopy(manifest); value["entries"] = [value["entries"][0], value["entries"][1]]; variants["unresolved"] = value
value = copy.deepcopy(manifest); value["entries"][2]["feature"] = "bluetooth"; value["entries"][2]["runtime_destination"] = "/userdata/rmx1901-hw/bluetooth/lib64/libprovider.so"; variants["cross"] = value
value = copy.deepcopy(manifest); value["entries"][0]["runtime_destination"] = "/android/vendor/bin/consumer"; variants["global"] = value
value = copy.deepcopy(manifest); value["entries"][0]["required_symbols"] = ["not_provided"]; variants["symbol"] = value
value = copy.deepcopy(manifest); value["entries"][0]["source_path"] = "/../bin/consumer"; variants["unsafe"] = value
value = copy.deepcopy(manifest); value["entries"].append(copy.deepcopy(value["entries"][0])); variants["duplicate"] = value
for name, data in variants.items():
    (root / "manifests" / f"{name}.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY

chmod +x "$verifier"
"$verifier" "$tmp_root/manifests/base.json" --json-output "$tmp_root/report.json" >"$tmp_root/stdout.json"
grep -Fq '"status": "pass"' "$tmp_root/report.json"
grep -Fq '"entries": 3' "$tmp_root/report.json"

for name in incomplete hash needed unresolved cross global symbol unsafe duplicate; do
    set +e
    "$verifier" "$tmp_root/manifests/$name.json" >"$tmp_root/$name.out" 2>"$tmp_root/$name.err"
    status=$?
    set -e
    test "$status" -eq 1
    grep -Fq 'error:' "$tmp_root/$name.err"
done
"$verifier" "$tmp_root/manifests/incomplete.json" --allow-incomplete >/dev/null

ln -s "$tmp_root/fixture/bin/consumer" "$tmp_root/fixture/bin/symlink-consumer"
python3 - "$tmp_root/manifests/base.json" "$tmp_root/manifests/symlink.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
value["entries"][0]["source_path"] = "/bin/symlink-consumer"
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"), sort_keys=True)
PY
set +e
"$verifier" "$tmp_root/manifests/symlink.json" >/dev/null 2>"$tmp_root/symlink.err"
status=$?
set -e
test "$status" -eq 1
grep -Fq 'non-symlink' "$tmp_root/symlink.err"

echo 'RMX1901 ABI cohort verifier tests passed'
