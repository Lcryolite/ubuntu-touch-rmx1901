#!/usr/bin/env python3
import hashlib, json, os, shutil, subprocess, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "scripts/m1-boot-controller.py"
TMP = Path(tempfile.mkdtemp(prefix="m1-boot-controller.", dir=os.environ.get("TMPDIR", "/tmp")))
try:
    root = TMP / "root"; root.mkdir(mode=0o700)
    candidate = bytearray(b"\0" * 4096)
    candidate[:8] = b"ANDROID!"
    candidate[8:12] = (1).to_bytes(4, "little")
    candidate[16:20] = (1).to_bytes(4, "little")
    candidate[40:44] = (1).to_bytes(4, "little")
    candidate[64:64+len("console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xA90000 androidboot.hardware=qcom androidboot.console=ttyMSM0 msm_rtb.filter=0x237 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 service_locator.enable=1 androidboot.configfs=true androidboot.usbcontroller=a600000.dwc3 swiotlb=1 loop.max_part=7 kpti=off printk.devkmsg=on androidboot.init_fatal_reboot_target=recovery systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0 console=tty0 rmx1901.debug_rndis=1")] = b"console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xA90000 androidboot.hardware=qcom androidboot.console=ttyMSM0 msm_rtb.filter=0x237 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 service_locator.enable=1 androidboot.configfs=true androidboot.usbcontroller=a600000.dwc3 swiotlb=1 loop.max_part=7 kpti=off printk.devkmsg=on androidboot.init_fatal_reboot_target=recovery systempart=/dev/disk/by-partlabel/system systemd.unified_cgroup_hierarchy=0 console=tty0 rmx1901.debug_rndis=1"
    candidate = bytes(candidate)
    predecessor = hashlib.sha256(b"p" * 4096).hexdigest()
    digest = hashlib.sha256(candidate).hexdigest()
    (root / "m1-candidate.img").write_bytes(candidate); (root / "m1-candidate.img").chmod(0o400)
    lock = {"schema":"rmx1901-m1-deployment-v1","device":"RMX1901","serial":"7b0c1c49","product":"fox_RMX1901","model":"RMX1901","target":"/dev/block/sde10","target_size":4096,"target_major_minor":"8:4a","predecessor_sha256":predecessor,"candidate_sha256":digest,"candidate_size":4096}
    (root / "m1-deployment-v1.json").write_text(json.dumps(lock)); (root / "m1-deployment-v1.json").chmod(0o400)
    (root / "m1-predecessor.img").write_bytes(b"p" * 4096); (root / "m1-predecessor.img").chmod(0o400)
    device = TMP / "device.img"; device.write_bytes(b"p" * 4096)
    fake = TMP / "adb"
    fake.write_text(f'''#!/usr/bin/python3
import hashlib, sys
from pathlib import Path
p=Path({str(device)!r}); a=sys.argv[1:]
if a[:2] != ['-s','7b0c1c49']: raise SystemExit(9)
a=a[2:]
if a == ['devices']: print('List of devices attached\\n7b0c1c49\\trecovery')
elif a == ['get-serialno']: print('7b0c1c49')
elif a[:3] == ['shell','getprop','ro.product.name']: print('fox_RMX1901')
elif a[:3] == ['shell','getprop','ro.product.device']: print('RMX1901')
elif a[:3] == ['shell','getprop','ro.product.model']: print('RMX1901')
elif a[:3] == ['shell','getprop','ro.bootmode']: print('recovery')
elif a[:3] == ['shell','getprop','ro.boot.vbmeta.device_state']: print('unlocked')
elif a == ['shell','readlink','-f','/dev/block/by-name/boot']: print('/dev/block/sde10')
elif a == ['shell','stat','-Lc','%t:%T','/dev/block/sde10']: print('8:4a')
elif a == ['shell','blockdev','--getsize64','/dev/block/sde10']: print('4096')
elif a == ['shell','cat','/sys/class/power_supply/battery/capacity']: print('80')
elif a == ['shell','sha256sum','/dev/block/sde10']: print(hashlib.sha256(p.read_bytes()).hexdigest()+'  /dev/block/sde10')
elif a == ['shell','tee','/dev/block/sde10 >/dev/null | wc -c']:
 d=sys.stdin.buffer.read(); p.write_bytes(d); print(len(d))
elif a == ['exec-out','cat','/dev/block/sde10']: sys.stdout.buffer.write(p.read_bytes())
else: raise SystemExit(8)
'''); fake.chmod(0o755)
    sealer = TMP / "sealer"
    sealer.write_text(f'''#!/usr/bin/python3
from pathlib import Path
r=Path({str(root)!r})/'preboot-inbox'
assert set(x.name for x in r.iterdir()) == {{'profile.env','preflight.env','boot-unpack.txt','write-readback.env'}}
assert 'BOOT_SHA256={digest}' in (r/'profile.env').read_text()
(Path({str(root)!r})/'preboot-profile').mkdir()
'''); sealer.chmod(0o755)
    raw = SOURCE.read_text()
    raw = raw.replace('ROOT = Path("/var/lib/rmx1901-m1-control")', f'ROOT = Path({str(root)!r})')
    raw = raw.replace('SEALER = "/usr/local/libexec/rmx1901-m1-control/seal-preboot-profile"', f'SEALER = {str(sealer)!r}')
    raw = raw.replace('ADB = "/usr/bin/adb"', f'ADB = {str(fake)!r}')
    raw = raw.replace('67108864', '4096')
    raw = raw.replace('c4d2b165855f6ec65fb1f606a349192fe254f9e98ad7d4c34d370bcbef08672f', predecessor)
    raw = raw.replace('58abf0069b3c37f01779543932a2eee3bc894282778566d1a4f2b77c5e667aec', digest)
    raw = raw.replace('current.st_uid != 0', 'False').replace('os.geteuid() != 0', 'False')
    controller = TMP / 'controller.py'; controller.write_text(raw); controller.chmod(0o755)
    result = subprocess.run([str(controller)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode == 0, result.stderr
    assert 'preboot_profile=sealed' in result.stdout and device.read_bytes() == candidate
    print('ok - M1 writes only after exact Recovery proof and seals readback evidence')
    device.write_bytes(b'x' * 4096)
    result = subprocess.run([str(controller)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode == 20 and device.read_bytes() == b'x' * 4096
    print('ok - predecessor mismatch fails before another write')
    device.write_bytes(b"p" * 4096)
    recovery = TMP / "recovery.py"
    recovery.write_text(raw.replace('if device_hash() != lock["candidate_sha256"]:', 'if True:'))
    recovery.chmod(0o755)
    result = subprocess.run([str(recovery)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode == 20 and device.read_bytes() == b"p" * 4096
    assert 'predecessor restored' in result.stderr
    print('ok - a post-write readback failure restores and verifies the predecessor')
    device.write_bytes(candidate)
    for entry in (root / "preboot-inbox", root / "preboot-profile"):
        if entry.exists(): shutil.rmtree(entry)
    result = subprocess.run([str(controller), "--seal-existing-complete-write"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode == 0 and 'write_state=resumed-after-dual-readback' in result.stdout
    print('ok - verified existing candidate can only resume evidence sealing without writing')
    actual = (Path("/home/lknife/android/rmx1901-halium11-artifacts/m2-91cad41-candidate/boot-m2-91cad41.img"))
    if actual.exists():
        mod = {}
        exec(SOURCE.read_text().rsplit('if __name__ == "__main__": main()', 1)[0], mod)
        report = mod["boot_report"](actual.read_bytes())
        assert "kernel size: 16714165\nramdisk size: 3949738\n" in report
        print('ok - real locked candidate header reports its true ramdisk size')
finally:
    shutil.rmtree(TMP, ignore_errors=True)
