#!/usr/bin/env bash
# Boots a built image once with QEMU/KVM and an OpenStack config drive, and
# checks it through the QEMU guest agent:
#   1. the guest agent answers (VirtIO serial driver and QEMU-GA service);
#   2. Cloudbase-Init used the metadata server, not the config drive (each
#      gives another hostname);
#   3. the random Administrator password reached the metadata server,
#      encrypted with the instance key (nova get-password), and opens a
#      session in the guest;
#   4. C: was extended to the larger disk (ExtendVolumesPlugin).
# The image itself is never modified: the VM runs on a temporary overlay.
#
# The metadata server (scripts/metadata-server.py) listens on the host; an
# iptables rule, limited to the user of this script, redirects the
# connections of QEMU (user networking) to 169.254.169.254:80 to it. sudo
# is needed for that rule.
#
# Usage: scripts/smoke.sh IMAGE.qcow2 [timeout-minutes]   (BIOS only)
set -euo pipefail

image="${1:?usage: scripts/smoke.sh IMAGE.qcow2 [timeout-minutes]}"
timeout_min="${2:-40}"
hostname_expected="oic-smoke"
hostname_config_drive="oic-config-drive"
metadata_port=8775

qemu_binary="$(command -v qemu-system-x86_64 || true)"
if [ -z "$qemu_binary" ] && [ -x /usr/libexec/qemu-kvm ]; then
  qemu_binary=/usr/libexec/qemu-kvm
fi
[ -n "$qemu_binary" ] || { echo "qemu-system-x86_64 not found" >&2; exit 1; }
[ -w /dev/kvm ] || { echo "/dev/kvm is not writable" >&2; exit 1; }
sudo -n iptables -t nat -S OUTPUT >/dev/null ||
  { echo "sudo iptables is needed for the metadata server" >&2; exit 1; }

work="$(mktemp -d)"
qemu_pid=""
metadata_pid=""
redirect=(-p tcp -d 169.254.169.254 --dport 80 -m owner --uid-owner "$(id -u)"
  -j REDIRECT --to-ports "$metadata_port")
cleanup() {
  status=$?
  if [ -n "$qemu_pid" ]; then kill "$qemu_pid" 2>/dev/null || true; fi
  if [ -n "$metadata_pid" ]; then
    kill "$metadata_pid" 2>/dev/null || true
    sudo -n iptables -t nat -D OUTPUT "${redirect[@]}" 2>/dev/null || true
    if [ "$status" -ne 0 ] && [ -s "$work/metadata.log" ]; then
      echo "--- metadata server requests ---"
      tail -n 30 "$work/metadata.log"
    fi
  fi
  # On failure, the end of the serial console (Cloudbase-Init logs there).
  if [ "$status" -ne 0 ] && [ -s "$work/serial.log" ]; then
    echo "--- last lines of the serial console ---"
    tail -n 40 "$work/serial.log" | tr -d '\r'
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# Overlay on the image, with a disk larger than the image so that the
# volume extension can be checked.
qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$image")" "$work/disk.qcow2" 60G

# Instance key pair (RSA, the type Cloudbase-Init encrypts with) and the
# metadata server.
ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -C oic-smoke -f "$work/key"
python3 "$(dirname "$0")/metadata-server.py" "$metadata_port" "$hostname_expected" \
  "$work/key.pub" "$work/password.b64" 2>"$work/metadata.log" &
metadata_pid=$!
sudo -n iptables -t nat -A OUTPUT "${redirect[@]}"

# OpenStack config drive (label config-2), with another hostname: the
# metadata server must win, since only it can receive the password.
mkdir -p "$work/cd/openstack/latest"
cat > "$work/cd/openstack/latest/meta_data.json" <<EOF
{"uuid": "$(cat /proc/sys/kernel/random/uuid)", "hostname": "$hostname_config_drive", "name": "$hostname_config_drive"}
EOF
xorriso -as mkisofs -quiet -V config-2 -J -r -o "$work/config-2.iso" "$work/cd"

machine=(-machine pc)

"$qemu_binary" "${machine[@]}" -accel kvm -cpu host -smp 2 -m 4096 \
  -drive "file=$work/disk.qcow2,if=virtio,discard=unmap" \
  -drive "file=$work/config-2.iso,media=cdrom,readonly=on" \
  -nic user,model=virtio-net-pci \
  -device virtio-serial-pci \
  -chardev "socket,path=$work/qga.sock,server=on,wait=off,id=qga0" \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -display none -serial "file:$work/serial.log" &
qemu_pid=$!

# The guest agent is driven from Python (standard library only).
python3 - "$work/qga.sock" "$hostname_expected" "$timeout_min" "$work" <<'PY'
import base64, json, os, socket, subprocess, sys, time

sock_path, expected, timeout_min = sys.argv[1], sys.argv[2], int(sys.argv[3])
work = sys.argv[-1]
deadline = time.time() + timeout_min * 60


def call(cmd, args=None, wait=10):
    """One guest agent command on a fresh connection; None if no answer."""
    s = None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(wait)
        s.connect(sock_path)
        # guest-sync flushes any stale answer left on the channel.
        token = int(time.time()) % 100000
        s.sendall(json.dumps({"execute": "guest-sync", "arguments": {"id": token}}).encode())
        buf = b""
        while True:
            buf += s.recv(65536)
            if f'"return": {token}'.encode() in buf or f'"return":{token}'.encode() in buf:
                break
        req = {"execute": cmd}
        if args:
            req["arguments"] = args
        s.sendall(json.dumps(req).encode())
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                return None
            buf += chunk
            try:
                return json.loads(buf.decode()).get("return")
            except json.JSONDecodeError:
                continue
    except OSError:
        return None
    finally:
        if s:
            s.close()


last = {}


def decode(field):
    raw = base64.b64decode(field or "")
    # wmic writes UTF-16 when its output is not a console.
    enc = "utf-16" if b"\x00" in raw else "utf-8"
    return raw.decode(enc, errors="replace").replace("\ufeff", "").strip()


def run(path, *args):
    """Runs a program in the guest, returns its stdout or None (exit code and
    stderr in last). Arguments go one by one: the guest agent quotes them, so
    a command line passed through cmd.exe /c would reach PowerShell as a
    quoted string, not as code."""
    last.clear()
    r = call("guest-exec", {"path": path, "arg": list(args), "capture-output": True})
    if not r:
        return None
    for _ in range(60):
        st = call("guest-exec-status", {"pid": r["pid"]})
        if st and st.get("exited"):
            last.update(exitcode=st.get("exitcode"), err=decode(st.get("err-data"))[-600:])
            return decode(st.get("out-data"))
        time.sleep(2)
    return None


start = time.time()
name = out = None
step = "guest agent"
while time.time() < deadline:
    if call("guest-ping", wait=5) is not None:
        break
    time.sleep(10)
else:
    sys.exit(f"FAIL: {step} did not answer within {timeout_min} min")
print(f"ok: guest agent answers after {int(time.time() - start)} s")

info = call("guest-get-osinfo") or {}
print(f"ok: {info.get('pretty-name', '?')} ({info.get('kernel-version', '?')})")

# Cloudbase-Init sets the hostname, then reboots the instance: wait for it.
step = "hostname from the metadata server"
while time.time() < deadline:
    name = run("hostname.exe")
    if name and name.lower() == expected:
        break
    time.sleep(15)
else:
    sys.exit(f"FAIL: {step} (last seen: {name!r})")
print(f"ok: hostname {name} from the metadata server after {int(time.time() - start)} s")

# The password posted by SetUserPasswordPlugin, decrypted with the private
# key as nova get-password does, must open an Administrator session.
step = "password posted to the metadata server"
password_file = os.path.join(work, "password.b64")
while time.time() < deadline and not os.path.exists(password_file):
    time.sleep(10)
if not os.path.exists(password_file):
    sys.exit(f"FAIL: {step}")
with open(password_file, "rb") as f:
    encrypted = base64.b64decode(f.read())
password = subprocess.run(
    ["openssl", "pkeyutl", "-decrypt", "-inkey", os.path.join(work, "key"),
     "-pkeyopt", "rsa_padding_mode:pkcs1"],
    input=encrypted, capture_output=True, check=True).stdout.decode()
print(f"ok: password of {len(password)} characters posted and decrypted")


def logon(candidate):
    """Network logon of Administrator in the guest (net use on IPC$ of the
    guest itself); True if accepted. PowerShell 2.0 cannot do it here: run
    by the agent, without a console, it stops with a FailFast (0x80131623).
    The password is alphanumeric (Cloudbase-Init), no quoting issue."""
    run("net.exe", "use", r"\\127.0.0.1\IPC$", candidate, "/user:Administrator")
    accepted = last.get("exitcode") == 0
    if accepted:
        run("net.exe", "use", r"\\127.0.0.1\IPC$", "/delete", "/y")
    return accepted


# The wrong password first: an open connection would make the second net use
# fail with another error (1219).
if logon(password + "x"):
    sys.exit("FAIL: a wrong password was accepted")
if not logon(password):
    sys.exit(f"FAIL: the posted password does not open a session ({last})")
print("ok: the posted password opens an Administrator session, a wrong one is refused")

step = "C: extended to the disk"
while time.time() < deadline:
    # Windows Server 2008: no Get-Partition, ask WMI for the size of C:.
    raw = run("wmic.exe", "logicaldisk", "where", "DeviceID='C:'", "get", "Size", "/value")
    digits = "".join(ch for ch in (raw or "") if ch.isdigit())
    out = str(round(int(digits) / 2**30)) if digits else raw
    if digits and int(digits) / 2**30 >= 55:
        break
    time.sleep(15)
else:
    sys.exit(f"FAIL: {step} (C: is {out!r} GB on a 60 GB disk)")
print(f"ok: C: is {out} GB on a 60 GB disk")
PY
echo "smoke test passed"
