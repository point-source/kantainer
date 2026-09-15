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

**If you have a monitor attached, the login screen already tells you.** Below the Fedora CoreOS
lines and the SSH host key fingerprints, the machine prints what to type into a browser — one
line per network it is on:

```
Portainer at https://192.168.1.50:9443 (wired)
Portainer at https://192.168.1.51:9443 (wireless: Kitchen)
```

You do not need to log in to read it, and you do not need to have been watching. It keeps up with
the machine on its own: plug in a cable, move it to another network, or let the router hand out a
new address, and the screen changes without a reboot.

When the machine has no address at all it says so:

```
Portainer: no network address yet - nothing to type into a browser.
```

That is a machine that is up and has nowhere to be reached yet — usually a cable that is out, or
a first boot before the router has answered. Docker's own networks never appear here; they are
addresses the machine talks to itself on, not ones you can reach it at.

**Below the address lines, the screen says what it knows about Portainer.** Two lines:

```
Portainer service: active
Portainer port 9443: answering (checked 2026-09-15 14:03:11+01:00)
```

**Those are two separate statements, on purpose, and they can disagree.** The first is what the
machine's own service manager says. The second is the result of actually opening an HTTPS
connection to port 9443 and seeing whether anything answered.

On a working machine they agree and you can stop reading. When they disagree, **the disagreement
is the information** — the screen shows you both rather than picking one:

```
Portainer service: active
Portainer port 9443: no answer (checked 2026-09-15 14:03:11+01:00)
```

That is a Portainer that started and then stopped serving. The machine thinks it is running,
because the container is still there; your browser disagrees, because nothing answers. It is the
reason you walked over to the machine, and it is the one case a single "Portainer: running" line
would have got wrong. Go to [When Portainer does not
answer](#when-portainer-does-not-answer).

The reverse disagreement — `failed` with a port that answers — means the unit gave up while
something is still listening. Same page.

**The time in brackets is when the port was last asked, and the machine asks once a minute.** So
that line can be up to a minute behind reality; the timestamp is there so you can tell how far.
The service line is not on a timer — it changes the moment Portainer starts, stops or fails. Right
after you restart Portainer, the two lines disagreeing for a few seconds is the port line catching
up, not a fault.

Until the first check lands, a few seconds into the boot, the line reads `not checked yet`. That
is not a failure — it means nobody has asked yet.

**The port is checked from the machine itself.** So `answering` means Portainer is serving; it
does not promise that your network path to it is open. If the screen says `answering` and your
browser still cannot reach it, the problem is between you and the machine, not on it.

**This display only exists once the machine is running its own image.** During the installation
and during the window in which it downloads that image, the screen is whatever stock Fedora
CoreOS shows. If you are watching an early boot and see no kantainer line, read [When Portainer
does not answer](#when-portainer-does-not-answer) below rather than assuming something broke.

Without a monitor, find the address the other way.

**Look at your router's device list or DHCP leases.** Nothing here sets the machine's hostname,
so do not go looking for one called `kantainer` — it will appear under whatever Fedora CoreOS
reports by default. Two reliable ways to pick it out:

- It is the entry that was not there before you started.
- If you have several new entries, match the MAC address of the machine's ethernet port.

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
  signature, started Docker, loaded Portainer and passed it your password. Log in with the
  password from your configuration file, as the administrator account Portainer creates from it
  (`admin`).
- **A setup or "create the first user" screen** would mean Portainer started without your
  password. Do not claim the account from that screen — read the next section instead.

After logging in you land on a working dashboard with the machine's own Docker engine already
connected. There is no environment to add.

## Optional: confirm the machine will keep itself updated

**Skip this if you like — nothing here needs it, and the machine works either way.** It is worth
ten seconds because of *what it checks*, not how likely it is to fail.

The machine installs its own updates overnight, and it only does that if it can verify that an
update is signed by this repository's key. Whether it can was decided once, during installation,
and is never revisited. If that came out wrong, everything you have just seen still looks
perfect — it installed, it serves, you logged in — and the machine then refuses every update for
the rest of its life. Nothing on the dashboard would ever tell you. This is the one moment you
have a reason to look.

```bash
ssh <your login account>@<the machine's address> \
  "bootc status --json | jq -r '.status.booted.image.image.signature'"
```

**You want it to print `containerPolicy`.** Anything else — `null`, `none`, or an error — means
the machine will not install updates, and reflashing is the fix rather than anything you can
change on the machine. That is the same field, read the same way, that the machine itself checks
before every update; there is no second opinion to get.

That refusal is deliberate. The alternative was a machine that updates itself from the internet
without checking who signed the update.

## Optional: confirm you can log in at the machine itself

**Only if you set `KANTAINER_CONSOLE_PASSWORD`.** Skip this if you left it blank.

Attach a monitor and keyboard and log in at the machine's own prompt, with the account name from
your configuration file and that password. It is worth doing once, now, while the machine is
still on your desk — the whole reason it exists is the day the network is gone and this is the
only way in.

You get an administrative session: privileged commands there do not ask for the password again.
That is why the check refuses one shorter than 12 characters.

If you left it blank there is nothing to test. No account has a password, the prompt cannot be
satisfied by anyone, and your SSH key is the only way in.

Either way, SSH still refuses password logins. A console password does not change that.

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

---

# When Portainer does not answer

This system has a legitimate multi-minute window in which **correct behaviour and failure look
identical from outside**: no answer on 9443, nothing on the network, no output anywhere you can
see. A procedure that only described success would leave you guessing during exactly the interval
where guessing is likely.

So here is how to tell the cases apart. Work down the list — it is ordered by how early in the
install each one happens.

## Was there a working wired network at install time?

Check this first, because it is the most common cause and the easiest to miss.

The installer environment is stock Fedora CoreOS and has no wireless support at all. A machine
with no working wired connection completes the first stage — it installs to disk and reboots
quite normally — and then simply stops, because it cannot download its own image. From outside it
looks like a machine that installed and died.

**How to tell:** the machine reached the first reboot but never the second one, and it does not
answer on 9443. If it is on the network at all, it is reachable over SSH (see
[below](#is-the-download-still-running)) and `rpm-ostree status` shows it still running Fedora
CoreOS.

**The fix is just to plug it in and reboot.** Nothing needs resetting. The unit that attaches the
machine to its image runs on every boot until the machine actually *is* that image — its condition
is a fact about the running system, not a flag anything left behind — so it retries by itself.

## Is it sitting at the drive prompt?

If the machine has more than one drive and your configuration did not name one, the installer
**writes nothing** and stops to ask which drive to use. That is deliberate: erasing the wrong
drive is the one failure in this system that cannot be undone.

The catch is that this prompt only exists on a screen. It goes to the machine's console, and the
installer environment has **no SSH access whatsoever** — the live system creates no account and
carries no key. So a headless machine at this prompt is invisible on the network and
**indistinguishable from a crashed one until you attach a display**.

**How to tell:** attach a monitor. You will see the drives it found, with model, size and serial
for each, and:

```
kantainer: this machine has more than one drive and the configuration does
not name one. NOTHING HAS BEEN WRITTEN.
```

followed by `Select the drive to install to [1-N], then press Enter:`. Answer it and the install
carries on.

**Naming the drive in `KANTAINER_TARGET_DRIVE` avoids this entirely** — that is the whole reason
that field exists. If you are installing a headless machine, fill it in.

While you have a display attached: an install that *failed* looks different. The installer drops
the machine into emergency mode rather than carrying on to a login prompt, precisely so that a
failed install cannot be mistaken for a finished one.

## Is the download still running?

This is the case that looks most like failure and is not.

**The useful thing to know: after the first reboot the machine is already reachable over SSH.**
The installer wrote your account and your public key into the installed system, so you can log in
before the kantainer image has even arrived:

```bash
ssh <your-username>@<the machine's address>
```

Then ask what the attach step is doing:

```bash
systemctl status kantainer-attach.service
journalctl -u kantainer-attach.service -b
rpm-ostree status
```

- **Still running** — the unit is `activating`, and the journal shows the pull in progress. Leave
  it alone. This is the normal case and it is the reason this page exists.
- **Failed** — the unit is `failed` and the journal says why. A signature that did not verify and
  a registry it could not reach look different there.
- **Nothing to see, and `rpm-ostree status` already shows the kantainer image** — the attach is
  done. The machine is past this stage; carry on to the next section.

**A monitor shows no kantainer line during this window, and that is correct.** The address lines
come from the kantainer image, and the machine is still downloading it — the screen is stock
Fedora CoreOS until the attach finishes and it reboots. An absent line here says nothing about
whether the download is going well; the `systemctl status` above is what answers that.

## What to look at once the machine is running its own image

SSH in and work upward, stopping at the first thing that is not running:

```bash
bootc status                                        # which image, and is it verifying signatures
systemctl status docker.service                     # the engine everything else needs
systemctl status kantainer-portainer-load.service   # Portainer's image, loaded from the OS image
systemctl status kantainer-portainer.service        # Portainer itself
journalctl -u kantainer-portainer.service -b
docker ps
```

**If the login screen showed the two Portainer lines disagreeing, start with `docker ps`.** A
service the machine calls `active` whose port does not answer is a container that is still there
and no longer serving — the journal for `kantainer-portainer.service` usually says what it hit.
Restarting it is the first thing to try:

```bash
systemctl restart kantainer-portainer.service
```

Watch the login screen afterwards if you have a monitor on it: the service line moves
immediately, and the port line follows within a minute.

Two of these are built to explain themselves rather than fail quietly:

- **Portainer refuses to start without the administrator password.** If the password file is
  missing or empty, `systemctl status kantainer-portainer.service` carries a message saying so and
  what to do about it. It refuses on purpose: starting anyway would publish an administration page
  on your network that anyone reaching it could claim, which is worse than not serving. This is
  also why a "create the first user" screen should never appear — if you somehow see one, the
  units above are where the answer is.
- **It stops retrying after three attempts in a minute** and lands in `failed`. Without that limit
  it would restart forever and bury the one journal line that explains why.

If `bootc status` reports its signature mode as anything other than `containerPolicy`, the machine
will refuse to install updates and say so in
`systemctl status bootc-fetch-apply-updates.service`. That refusal is deliberate — a machine that
stops updating tells you; a machine that updates without checking signatures never would.

## A known gap: a bad update can leave Portainer broken

Worth knowing before it happens, because the machine will not fix this one for you.

The machine checks its own health after an update. That check tests two things: that the machine
reached a running state, and that the Docker engine is active. If a boot fails those checks
repeatedly, the machine returns to the version it was running before the update, on its own.

**The check does not test Portainer.** So an update that leaves the machine booting and Docker
running, but Portainer broken, **is not caught and does not roll back.**

That narrowness is deliberate rather than an oversight. A health check that is wrong in the strict
direction is worse than none: it rolls back working updates indefinitely, and the machine quietly
stops receiving fixes while appearing to run perfectly normally — the one failure nobody would
ever notice. A slow Portainer start or a Portainer-side fault would do exactly that if it were
part of the verdict.

The trade is that this particular failure is left to you. It is a good trade, because unlike the
failure it avoids, this one is **visible** — your browser stops reaching Portainer — and
**recoverable over SSH**, which is what remote access exists for:

```bash
systemctl status kantainer-portainer.service
journalctl -u kantainer-portainer.service -b
bootc status                # what this machine is running
bootc rollback              # return to the version before the update, then reboot
```

`bootc rollback` is the same command the machine's own health checking uses when it rolls back by
itself, so this is the automatic recovery run by hand rather than a different mechanism.
