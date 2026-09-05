# Confirm Portainer is up after first boot

What to expect after you boot the machine from the stick, and how to tell it worked.

The one thing to know before you start: **the machine reboots twice before it serves.** Between
those two reboots it downloads its own operating system image over the wired connection, and
during that download it looks like nothing is happening. That window is normal. It is also the
window in which a genuine failure looks exactly the same from outside, which is why the second
half of this page exists.

## What happens, in order

**1. You boot the machine from the stick, on a wired network.**

The installer picks a drive — the one you named in `KANTAINER_TARGET_DRIVE`, or the machine's only
drive if you named none — and installs Fedora CoreOS to it. The USB stick itself is never a
candidate, so a single-drive machine really does have exactly one.

When it finishes it says so and reboots:

```
kantainer-install: installed to /dev/sda. Rebooting.
REMOVE THE USB STICK NOW, so this machine boots from /dev/sda and not
from the installer again.
```

**That is the first reboot.** Take the stick out.

**2. The machine downloads its own image.**

What is now on the disk is stock Fedora CoreOS, not kantainer. On this boot the machine attaches
itself to the published image — it pulls `ghcr.io/point-source/kantainer:latest` over the wired
connection and verifies the signature against the key the installer placed on it. An image that
is not validly signed by this repository's key is refused, and the machine stays where it is.

**This is the long part, and its length is your internet connection rather than the machine.**
There is no progress bar to watch unless you have a display attached. Nothing is wrong.

When the pull finishes the machine reboots again. **That is the second reboot.**

**3. The machine serves.**

On this boot it is running the kantainer image. Docker starts, Portainer's image is loaded from
the copy carried inside the operating system image — nothing is fetched from Docker Hub — and
Portainer starts.

## Find the machine

The machine takes whatever address your router hands out. It assumes no fixed address, and it is
not given one.

**Look at your router's device list or DHCP leases.** The new machine appears under the account
name from your configuration file.

## Open it

```
https://<the machine's address>:9443
```

HTTPS, and port 9443. There is nothing on port 80 or 443, and nothing on Portainer's usual
plain-HTTP port 9000 — that listener is switched off.

**Your browser will warn you about the certificate. That is expected.** Portainer generates a
certificate for itself the first time it runs and reuses it afterwards. Nobody has issued it, so
no browser trusts it. Click through the warning.

## The success signal is a login page

**You should see Portainer's login page — not a setup screen, and not a "create the first user"
prompt.**

This is the check that actually tells you the whole chain worked, so it is worth being precise
about. The administrator account is created from the password in your configuration file
*before* the web server accepts its first connection. So:

- **A login page** means the machine installed itself, attached to the right image, verified its
  signature, started Docker, loaded Portainer and passed it your password. Log in as `admin` with
  that password.
- **A setup or "create the first user" screen** would mean Portainer started without your
  password. Do not claim the account from that screen — read the next section instead.

After logging in you land on a working dashboard with the machine's own Docker engine already
connected. There is no environment to add.

## How long

The honest answer is that it depends on two things nobody can predict for you: how fast the
machine writes to its disk, and how fast it downloads its operating system image from a container
registry.

Rather than watching a clock, watch for the signals:

| Phase | Ends when |
| --- | --- |
| Installing to disk | The machine says `REMOVE THE USB STICK NOW` and reboots |
| Downloading the image | The machine reboots a second time, on its own |
| Starting up | The address answers on port 9443 |

The download is normally the longest of the three by a good margin. If you have gone away and
come back, the useful question is not "how long has it been" but "has it rebooted twice" — and
if you cannot tell, the next section is how to find out.
