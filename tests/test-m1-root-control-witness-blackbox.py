#!/usr/bin/env python3
"""Black-box tests for the production witness protocol.

The only fakes are a copied fixed-trust command and fixed runtime adapter inside
this disposable harness.  The production source has no test switch, env knob,
or caller-selected selector.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "scripts/m1-root-control-witness.py"
TMP = Path(tempfile.mkdtemp(prefix="m1-witness-blackbox.", dir=os.environ.get("TMPDIR", "/tmp")))


def run(args, *, ok=True):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if ok and result.returncode:
        raise AssertionError(f"failed {args}: {result.returncode}: {result.stderr}")
    return result


def put(path, data, mode=0o400):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data, encoding="ascii")
    path.chmod(mode)


def metadata(path, attempt):
    put(path, "\n".join((
        "SPEC_VERSION=RMX1901-M1-EVIDENCE-V1", f"ATTEMPT_ID={attempt}", "UNIQUE_VARIABLE=cmdline-observation",
        "SOURCE_COMMIT=" + "1" * 40, "INITRD_SHA256=" + "2" * 64, "BOOT_SHA256=" + "3" * 64,
        "TOOLCHAIN_SHA256=" + "4" * 64, "SOURCE_TREE_SHA256=" + "5" * 64, "SOURCE_DIRTY=NO",
        "INPUT_SHA256=" + "8" * 64, "OUTPUT_SHA256=" + "3" * 64, "PREDECESSOR_SHA256=" + "8" * 64,
        "",
    )))


def make_harness(name, deterministic=False):
    base = TMP / name; root = base / "root"; lib = base / "lib"; profile = root / "preboot-profile"
    root.mkdir(parents=True, mode=0o700); (root / "state").mkdir(mode=0o700); (root / "registry/receipts").mkdir(parents=True, mode=0o700)
    profile.mkdir(mode=0o700)
    put(profile / "profile.env", "PROFILE_SCHEMA=RMX1901-M1-PREBOOT-V1\nINPUT_SHA256=" + "8" * 64 + "\nPREDECESSOR_SHA256=" + "8" * 64 + "\nBOOT_SHA256=" + "3" * 64 + "\nOUTPUT_SHA256=" + "3" * 64 + "\n")
    put(profile / "preflight.env", "ADB_STATE=recovery\nADB_SERIAL=7b0c1c49\nADB_PRODUCT=fox_RMX1901\nADB_MODEL=RMX1901\nADB_DEVICE=RMX1901\nUNLOCKED=YES\nBOOT_PATH=/dev/block/sde10\nBOOT_SIZE=67108864\nBOOT_MAJOR_MINOR=8:4a\nBATTERY_PERCENT=80\nSAFETY_GATE=PASS\n")
    put(profile / "boot-unpack.txt", "boot image header version: 1\nadditional command line args: \ncommand line args: console=tty0 systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0 rmx1901.debug_rndis=1\nkernel size: 8388608\nramdisk size: 3949319\n")
    put(profile / "write-readback.env", "PREDECESSOR_SHA256=" + "8" * 64 + "\nDEVICE_READBACK_SHA256=" + "3" * 64 + "\nHOST_READBACK_SHA256=" + "3" * 64 + "\n")
    put(profile / "profile-SHA256SUMS", "".join(f"{hashlib.sha256((profile / x).read_bytes()).hexdigest()}  {x}\n" for x in sorted(("profile.env", "preflight.env", "boot-unpack.txt", "write-readback.env"))))
    private = root / "witness-ed25519.pem"; public = root / "witness-ed25519.pub"
    run(["/usr/bin/openssl", "genpkey", "-algorithm", "ED25519", "-out", str(private)])
    run(["/usr/bin/openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)])
    private.chmod(0o400); public.chmod(0o400)
    put(root / "witness-ed25519.sha256", hashlib.sha256(public.read_bytes()).hexdigest() + "\n")
    trust = lib / "fixed-trust"; put(trust, "#!/bin/sh\ntest \"$1\" = check\n", 0o500)
    adapter = lib / "runtime-adapter"; mode = base / "mode"
    adapter_text = '''#!/usr/bin/python3
import pathlib, sys
mode = pathlib.Path(__file__).parent.parent.joinpath("mode").read_text().strip()
out = pathlib.Path(sys.argv[2]); (out / "runtime").mkdir()
if mode == "missing": sys.exit(20)
if mode == "panic":
 t="TRANSPORT=panic\\nPRODUCT=Failed to boot\\nTCP22=CLOSED\\nTCP23=OPEN\\nBANNER=NONE\\nHOSTKEY=NONE\\nAUTH=NONE\\nPID1_COMM=init\\nPID1_EXE=/bin/sh\\nPID1_CMDLINE=/bin/sh /init\\n"; u="CLASSIFICATION=panic\\nVIDPID=18d1:d001\\nPRODUCT=Failed to boot\\nNETDEV=rndis.usb0\\nIP=192.168.2.15\\nTCP22=CLOSED\\nTCP23=OPEN\\n"; comm,exe,cmd="init","/bin/sh","/bin/sh /init"
else:
 t="TRANSPORT=systemd-ssh\\nPRODUCT=RMX1901 diagnostic bridge\\nTCP22=OPEN\\nTCP23=CLOSED\\nBANNER=SSH-2.0-OpenSSH_9.6\\nHOSTKEY=SHA256:YWJjZA==\\nAUTH=PUBLICKEY_OK\\nPID1_COMM=systemd\\nPID1_EXE=/usr/lib/systemd/systemd\\nPID1_CMDLINE=/usr/lib/systemd/systemd\\n"; u="CLASSIFICATION=systemd-ssh\\nVIDPID=18d1:d001\\nPRODUCT=RMX1901 diagnostic bridge\\nNETDEV=rndis.usb0\\nIP=192.168.2.15\\nTCP22=OPEN\\nTCP23=CLOSED\\n"; comm,exe,cmd="systemd","/usr/lib/systemd/systemd","/usr/lib/systemd/systemd"
files={"proc-cmdline.txt":"console=tty0 systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0 rmx1901.debug_rndis=1\\n","handoff-events.log":"RMX1901_HANDOFF sequence=1 stage=CMDLINE_PARSED systempart=valid cgroup=valid console=valid diagnostic_rndis=valid\\n","handoff-kmsg.log":"<6>initrd: RMX1901_HANDOFF sequence=1 stage=CMDLINE_PARSED systempart=valid cgroup=valid console=valid diagnostic_rndis=valid\\n","transport.env":t,"usb-state.env":u,"runtime/pid1-comm.txt":comm+"\\n","runtime/pid1-exe.txt":exe+"\\n","runtime/pid1-cmdline.txt":cmd+"\\n","runtime/boot-id.txt":("12345678-1234-4123-8123-123456789abc" if mode == "panic" else "87654321-1234-4123-8123-123456789abc")+"\\n","runtime/mounts.txt":"rootfs / rootfs ro 0 0\\n","runtime/journal.txt":"journal\\n","runtime/failed-units.txt":"none\\n","runtime/configfs.txt":"none\\n","runtime/netdev.txt":"rndis.usb0\\n","runtime/systemd-confirmed.env":("SYSTEMD_CONFIRMED=NO\\n" if mode == "panic" else "SYSTEMD_CONFIRMED=YES\\n")}
for n,v in files.items(): (out/n).write_text(v)
'''
    put(adapter, adapter_text, 0o500); put(mode, "panic\n", 0o600)
    witness = base / "capture-witness"
    text = SOURCE.read_text().replace('TRUST = "/usr/local/libexec/rmx1901-m1-control/fixed-trust"', f'TRUST = "{trust}"').replace('ADAPTER = "/usr/local/libexec/rmx1901-m1-control/runtime-adapter"', f'ADAPTER = "{adapter}"').replace('ROOT = Path("/var/lib/rmx1901-m1-control")', f'ROOT = Path("{root}")')
    if deterministic: text = text.replace("secrets.token_hex(16)", '"a" * 32')
    put(witness, text, 0o500)
    validator_root = base / "validator-repo"; shutil.copytree(REPO / "scripts", validator_root / "scripts")
    validator = validator_root / "scripts/validate-m1-attempt.sh"
    v = validator.read_text().replace('/usr/local/libexec/rmx1901-m1-control/fixed-trust', str(trust)).replace('/var/lib/rmx1901-m1-control', str(root))
    validator.write_text(v); validator.chmod(0o500)
    return base, root, witness, mode, validator


def capture_and_validate(harness, attempt_id, state):
    base, root, witness, mode, validator = harness; mode.write_text(state + "\n")
    meta = base / f"{attempt_id}.env"; metadata(meta, attempt_id)
    suffix = str(sum(map(ord, attempt_id)) % 10)
    dirname = f"20260728T01010{suffix}Z-{attempt_id}"; bundle = base / f"bundle-{attempt_id}"; bundle.mkdir()
    run([str(witness), str(meta), dirname, str(bundle)])
    assert sorted(item.name for item in bundle.iterdir()) == ["attempt", "receipt.env", "receipt.sig"]
    attempt = base / dirname; (bundle / "attempt").rename(attempt)
    expected = base / "expected"; expected.write_text("console=tty0\nsystempart=/dev/disk/by-partlabel/system\nsystemd.unified_cgroup_hierarchy=0\nrmx1901.debug_rndis=1\n")
    run([str(validator), str(attempt), str(expected)])
    return bundle, attempt


try:
    panic = make_harness("panic"); capture_and_validate(panic, "panic", "panic")
    ssh = make_harness("ssh"); capture_and_validate(ssh, "ssh", "ssh")
    missing = make_harness("missing"); base, root, witness, mode, _ = missing; mode.write_text("missing\n"); meta = base / "m.env"; metadata(meta, "missing"); out = base / "out"; out.mkdir()
    result = run([str(witness), str(meta), "20260728T010109Z-missing", str(out)], ok=False)
    assert result.returncode == 20 and not any(out.iterdir()) and not (root / "state/sequence").exists() and not any((root / "registry/receipts").iterdir())
    collision = make_harness("collision", deterministic=True); capture_and_validate(collision, "one", "panic")
    base, root, witness, mode, _ = collision; mode.write_text("ssh\n"); meta = base / "two.env"; metadata(meta, "two"); out = base / "out-two"; out.mkdir(); before = sorted((root / "registry/receipts").iterdir())
    result = run([str(witness), str(meta), "20260728T010108Z-two", str(out)], ok=False)
    assert result.returncode == 20 and not any(out.iterdir()) and sorted((root / "registry/receipts").iterdir()) == before and (root / "state/sequence").read_text() == "1\n", (result.stderr, list(out.iterdir()), list((root / "registry/receipts").iterdir()), (root / "state/sequence").read_text())
    # A power loss after the receipt pair is durable but before state is
    # advanced must be recovered on the next capture.  The repeated boot ID
    # deliberately makes that next capture fail after recovery; this proves
    # recovery itself did not sign a second receipt.
    journal = make_harness("journal", deterministic=True)
    capture_and_validate(journal, "journal", "panic")
    base, root, witness, mode, _ = journal
    receipt = next((root / "registry/receipts").glob("*.receipt"))
    session = receipt.name.removesuffix(".receipt")
    receipt_sha = hashlib.sha256(receipt.read_bytes()).hexdigest()
    boot_id = "12345678-1234-4123-8123-123456789abc"
    for name in ("sequence", "head", "boot-ids"):
        (root / "state" / name).unlink()
    empty_sha = hashlib.sha256(b"").hexdigest()
    put(root / "state/receipt-transaction.env", "".join((
        "TRANSACTION_SCHEMA=RMX1901-M1-RECEIPT-TRANSACTION-V1\n",
        f"SESSION={session}\n", f"RECEIPT_SHA256={receipt_sha}\n", f"BOOT_ID={boot_id}\n",
        "OLD_SEQUENCE=0\nOLD_HEAD=GENESIS\n", f"OLD_SEEN_SHA256={empty_sha}\n",
        f"NEW_SEQUENCE=1\nNEW_HEAD={receipt_sha}\n", f"NEW_SEEN_SHA256={hashlib.sha256((boot_id + chr(10)).encode()).hexdigest()}\nPHASE=PUBLISHED\n",
    )))
    meta = base / "journal-restart.env"; metadata(meta, "journal-restart")
    out = base / "journal-restart"; out.mkdir()
    result = run([str(witness), str(meta), "20260728T010107Z-journal-restart", str(out)], ok=False)
    assert result.returncode == 20 and not (root / "state/receipt-transaction.env").exists()
    assert (root / "state/sequence").read_text() == "1\n" and boot_id in (root / "state/boot-ids").read_text()
    print("ok - panic and authenticated SSH runtime bundles validate against the real validator")
    print("ok - absent runtime source emits no bundle, receipt, or state")
    print("ok - receipt collision cannot overwrite a receipt or advance state")
    print("ok - published receipt journal recovers state after an interrupted commit")
finally:
    if os.environ.get("M1_KEEP_BLACKBOX"):
        print(TMP, file=sys.stderr)
    else:
        shutil.rmtree(TMP, ignore_errors=True)
