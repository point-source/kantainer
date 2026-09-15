# Flash the installer to a USB stick

Two inputs — your filled-in configuration file and a USB stick — and one command. Out of it comes
a stick that installs a machine which serves Portainer without anyone touching it.

**The installer is built here and never published.** It carries your account, your SSH key and
your Portainer password, and this repository is public. The repository publishes the *image*,
which is what machines consume; the stick is personalised on your own machine, at flash time,
from the Fedora CoreOS release pinned in `versions.env`.

## What you need

- A supported operator host: the existing Linux environment, or an Apple-silicon Mac running
  macOS 26 or newer. On a Mac, the commands use the operating system's `/bin/bash`, `shasum`,
  `diskutil` and `plutil`; do not install a replacement Bash or checksum utility.
- `mise`, `git`, `jq`, `curl` and `ssh-keygen` available.
- On Linux, run `mise install`. Install Podman and make sure `sudo`, `lsblk` and `sha256sum` are
  available.
- On macOS, run `mise install just aqua:coreos/butane`. Install Docker Desktop or Podman and make
  sure it is running. Docker Desktop has priority when both work. The system supplies `sudo` and
  the disk tools used for the write.
- A wired network on the machine you are about to install. This is required **even if that
  machine will run on wireless afterwards** — see [below](#the-install-is-always-wired).
- Around 1.3 GB of disk for the Fedora CoreOS ISO, cached in `output/installer/`.

## 1. Copy the template and fill it in

```bash
cp kantainer.conf.example kantainer.conf
$EDITOR kantainer.conf
```

`kantainer.conf` is the only place machine-specific values live. Everything else belongs in the
image.

**Keep your copy.** Regenerating a stick needs it, and nothing else in the repository holds these
values.

**Keep it out of git.** `.gitignore` already covers `kantainer.conf`, `kantainer*.conf` and
`*.ign`, because the file holds your Portainer password in plain text and this repository is
public. If you keep it inside the repository under some other name, the tools refuse to run until
git ignores it. Keeping it outside the repository entirely also works — name it when you run the
commands.

### The format

One `KEY=value` per line. The value is **everything after the first `=`, taken literally to the
end of the line**: no quotes, no escapes, no shell expansion. A password containing `$`, backtick,
quotes, backslash or spaces is written exactly as it reads. Trailing spaces become part of the
value, so do not add any. Blank lines and lines starting with `#` are ignored.

A misspelt field name is refused rather than ignored, and so is setting the same field twice — an
ignored line would mean the value you meant to set never arrives, and nothing would say so.

### The fields

**Required:**

- `KANTAINER_USERNAME` — the login account created on the machine. A Linux user name: lower-case
  letters, digits, underscore and dash, starting with a letter or underscore, at most 32
  characters.

- `KANTAINER_SSH_PUBLIC_KEY` — the whole one-line contents of your `.pub` file, e.g.
  `cat ~/.ssh/id_ed25519.pub`. **This is the only way in:** the machine refuses password logins
  for every account. Never put the private key here. The check runs `ssh-keygen` over what you
  wrote, which catches the two classic mistakes — pasting the path to the key instead of the key,
  and pasting the private one.

- `KANTAINER_PORTAINER_PASSWORD` — the Portainer administrator password, **at least 12
  characters**.

  Twelve is Portainer's own minimum, not ours. Below it, Portainer makes you change the password
  at first login — which is a trip to the machine this password exists to avoid.

  It is **required, not optional**, which is worth explaining because it reads like a
  convenience. Current Portainer will not create its first administrator without a token it
  prints only to its own log. So an operator who leaves this blank cannot claim the account from
  a browser at all — they would have to SSH in and read the log. Setting it here creates the
  administrator before the web interface accepts its first connection, which also closes the
  window where an unclaimed administration page sits on the network.

**Optional:**

- `KANTAINER_CONSOLE_PASSWORD` — the password for logging in at the machine's **own keyboard**,
  at least 12 characters. Leave it blank and no account has a password at all.

  **Leaving it blank is a supported choice.** It costs you one thing: if the machine's network
  ever fails, you cannot reach it at all, and reflashing is the only way back in. `just
  config-check` says so every time, so you decline it knowingly rather than discovering it with a
  keyboard in your hand.

  It never reaches the network. SSH refuses password logins for every account whether or not you
  set this, so it widens physical access and nothing else.

  Twelve characters is a floor because **the login prompt is the whole of the gate** — once past
  it, privileged commands on the machine do not ask again.

  You write it in readable form, like the Portainer password. The machine turns it into its
  stored form during installation, and after that it exists there only in the machine's own
  account database. Changing it later means rendering and flashing again, like every other value
  in this file.

- `KANTAINER_TARGET_DRIVE` — the drive to install to, e.g. `/dev/sda` or `/dev/nvme0n1`. Name it
  as the machine will see it. Leave blank on a single-drive machine.

  On a machine with more than one drive, leaving this blank means the installer writes nothing:
  it lists the drives it found and stops at a prompt. That is the correct behaviour, but on a
  headless machine it looks exactly like a crash. **Naming the drive avoids that situation
  entirely.**

- `KANTAINER_WIFI_SSID` and `KANTAINER_WIFI_PASSPHRASE` — the wireless network the installed
  machine joins when no wired connection is available. **Set both or neither**; half a
  configuration renders a profile that cannot associate. The passphrase is 8–63 characters, which
  is WPA-PSK's range rather than ours — the machine's supplicant refuses anything outside it.

  Leave both blank for a wired machine. A wired machine carries no wireless configuration at all.

## 2. Check it

```bash
just config-check
```

Writes nothing anywhere. It refuses anything the machine cannot be built from and names the field
to go and fix, then says what machine your file describes:

```
kantainer.conf is complete.
  login account: <name>, by SSH key only
  network:       wired
  drive:         installs to the machine's only drive, or stops and asks if there is more than one
  Portainer administrator password is set.
  Console password is not set.
  If this machine's network fails, you cannot reach it at all. Reflashing is the only way back.
```

The passwords and the wireless passphrase are deliberately not echoed.

Add a path if your configuration lives outside the repository: `just config-check /path/to/my.conf`.

`just render` prints the machine specification built from the same file, if you want to see it.

## 3. Flash

### Linux

List whole drives and identify the stick:

```bash
lsblk --nodeps --output NAME,MODEL,SIZE
```

Then pass its full device path:

```bash
just flash /dev/sdX
```

Linux requires a block device that is a whole drive. It refuses a partition and points to its
containing drive. Linux retains its existing policy of allowing either an internal or external
whole drive, so read the model and size at confirmation carefully.

### macOS: ordinary external-disk path

List external physical disks:

```bash
diskutil list external physical
```

Use the original, full whole-disk path from that list. It has the form `/dev/diskN`:

```bash
just flash /dev/diskN
```

Do not supply a partition such as `/dev/disk7s1`, a bare name such as `disk7`, or the raw
`/dev/rdiskN` spelling. The ordinary path accepts only a disk macOS currently identifies as an
external whole physical disk. It refuses an internal disk, partition, virtual disk, regular file,
mount point, missing path, noncanonical path, or disk whose facts are incomplete. Every refusal
happens before the target is unmounted or written.

That classification cannot tell a spare installer stick from an external backup drive. Read the
model and size at confirmation and decide whether the eligible disk is the one you mean to erase.

### macOS: advanced device override

The advanced path deliberately bypasses ordinary macOS classification:

```bash
just flash --advanced-device=/dev/diskN
```

Use it only when you intend to write an existing block or character device that the ordinary path
refuses, such as an internal disk, partition or virtual device. It displays `ADVANCED OVERRIDE` in
the final risk line. It still rejects regular files, mount points, bare names and nonexistent
paths, rechecks the device before writing, and requires you to type the exact full path back.

For either host, a second argument names a configuration kept elsewhere:
`just flash /dev/sdX /path/to/my.conf` on Linux, or
`just flash /dev/diskN /path/to/my.conf` on macOS. With the advanced form, put the configuration
path after the `--advanced-device=...` argument.

### What happens before anything is erased

Everything that can refuse does so **before the device is touched**, in this order:

1. Your configuration is read and validated. A bad field stops the command here.
2. The device is classified for the host and selected mode. This runs before the download, so a
   typo'd or ineligible path costs you nothing.
3. The runtime is checked. Linux requires Podman. macOS uses Docker Desktop when it is usable,
   otherwise Podman.
4. The pinned Fedora CoreOS ISO is downloaded to `output/installer/` and verified against the
   checksum committed in `versions.env`. A cached copy is re-verified on every run, not just when
   it was written, and a cached file that disagrees with the pin is a refusal rather than a silent
   re-download.
5. The installer configuration is rendered into a private staging directory.
6. The pinned `coreos-installer` container writes your account, key and password into a copy of
   the ISO.

If Docker Desktop fails while building that copy and Podman is usable, the command names the
Docker failure and asks:

```
Type podman to retry with Podman, or anything else to stop.
```

Only the exact answer `podman` starts the retry. Any other answer, end of input, an unavailable
Podman, or a failed Podman retry stops without touching the target. Linux never offers this retry.

**Then, and only then, the command classifies the device again and asks for confirmation:**

```
ABOUT TO ERASE /dev/diskN
    model: <what is actually plugged in>
    size:  <how big it is>
    risk:  external whole physical disk

Everything on that device will be gone, and this cannot be undone.
Type /dev/diskN to go ahead, or anything else to stop.
```

Linux shows `whole disk selected by the operator` in the risk line. Advanced macOS mode shows
`ADVANCED OVERRIDE — macOS safety classification bypassed`.

You have to type the exact path you originally supplied. "y" does not work, and neither does a
different spelling of the same disk. Any other answer or end of input stops with nothing written.

The device is read *again* at this point rather than described from the check in step 2. Minutes
pass in between, and a stick pulled out in that window frees its name for whatever is plugged in
next. What you read here is what is about to be erased.

If the device disappeared, changed identity, or no longer passes the selected policy, the command
stops before unmounting or writing it.

### What happens after confirmation

On macOS, the command first unmounts the containing whole disk with `diskutil unmountDisk`. If
unmounting fails, no bytes are written. Keep supplying and confirming the original `/dev/diskN`
path: the command chooses the faster `/dev/rdiskN` write interface internally only when the
personalised image length is aligned to 4 KiB. It uses buffered `/dev/diskN` for every unaligned
image so the final partial block is preserved.

Linux writes the confirmed whole drive with its existing Podman/Linux path. On both hosts, the
command writes the complete personalised ISO and runs `sync` before reporting success.

A failure before `dd` starts leaves the target's contents unchanged. A `dd` failure means the write
began and the target may be incomplete. A `sync` failure means all bytes were handed to the device
but their durability is unknown. In either of the latter cases, do not boot from the target; run
the command again from the beginning.

After successful write and sync, Linux says the stick is ready. macOS also tells you to eject the
original `/dev/diskN` manually before removing it. The command never ejects the disk for you.

## The install is always wired

The installer environment is stock Fedora CoreOS, which ships neither wireless firmware nor
wireless network management. Wireless support lives in the kantainer image, and the image is not
on the machine until the installation has finished downloading it.

So: **install on ethernet, then move the machine.** A machine that will live somewhere without a
network cable still has to be installed somewhere with one. It is a one-time inconvenience, not
an ongoing constraint — `KANTAINER_WIFI_SSID` takes over once the machine is running its own
image.

## Next

[Confirm Portainer is up after first boot](verify.md).
