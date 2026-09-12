# Flash the installer to a USB stick

Two inputs — your filled-in configuration file and a USB stick — and one command. Out of it comes
a stick that installs a machine which serves Portainer without anyone touching it.

**The installer is built here and never published.** It carries your account, your SSH key and
your Portainer password, and this repository is public. The repository publishes the *image*,
which is what machines consume; the stick is personalised on your own machine, at flash time,
from the Fedora CoreOS release pinned in `versions.env`.

## What you need

- `mise install` done (this brings in `butane`, which renders the configuration).
- `podman`. coreos-installer publishes no portable binary, so the installer is personalised in
  the container pinned in `versions.env`.
- `sudo`, for the write itself.
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
```

The password and the wireless passphrase are deliberately not echoed.

Add a path if your configuration lives outside the repository: `just config-check /path/to/my.conf`.

`just render` prints the machine specification built from the same file, if you want to see it.

## 3. Flash

Find the stick first:

```bash
lsblk --nodeps --output NAME,MODEL,SIZE
```

Then:

```bash
just flash /dev/sdX
```

A second argument names a configuration kept elsewhere: `just flash /dev/sdX /path/to/my.conf`.

### What happens before anything is erased

Everything that can refuse does so **before the device is touched**, in this order:

1. Your configuration is read and validated. A bad field stops the command here.
2. The device is checked — it must be a block device, and a whole drive rather than a partition.
   This runs before the download, so a typo'd path costs you nothing.
3. `podman` must be on `PATH`.
4. The pinned Fedora CoreOS ISO is downloaded to `output/installer/` and verified against the
   checksum committed in `versions.env`. A cached copy is re-verified on every run, not just when
   it was written, and a cached file that disagrees with the pin is a refusal rather than a silent
   re-download.
5. The installer configuration is rendered into a private staging directory.
6. The pinned `coreos-installer` container writes your account, key and password into a copy of
   the ISO.

**Then, and only then, the confirmation:**

```
ABOUT TO ERASE /dev/sdX
    model: <what is actually plugged in>
    size:  <how big it is>

Everything on that device will be gone, and this cannot be undone.
Type /dev/sdX to go ahead, or anything else to stop.
```

You have to type the device path back. "y" does not work, and neither does anything else —
anything but the path stops the command with nothing written.

The device is read *again* at this point rather than described from the check in step 2. Minutes
pass in between, and a stick pulled out in that window frees its name for whatever is plugged in
next. What you read here is what is about to be erased.

The command does not try to work out whether a device is safe to erase. It cannot: your spare
stick and your only backup drive look identical to `lsblk`. Naming what is about to be erased and
asking is the whole of the defence, and the judgement is yours.

After that it writes the ISO with `dd` and syncs, then tells you the stick is ready.

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
