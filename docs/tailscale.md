# Reach the machine from anywhere

The machine can join your private Tailscale network, and does not unless you ask.

Tailscale is inside the image already — it comes from uCore, so nothing here downloads it and
nothing pins a version of its own. What this repository adds is the configuration: one field in
your configuration file and the machine joins your tailnet on first boot, with nobody watching
(SPEC.md §spec:tailscale).

Without it, Portainer is reachable from your own network and nowhere else. That is the whole
of the problem this solves. The alternatives — forwarding a port on your router, or putting
Portainer's administration interface on the internet — are worse than the problem.

## What joining does

The machine appears in your tailnet under a name you choose, with its own address. From any
device on that tailnet you can then:

- open Portainer at `https://<tailnet address>:9443`
- SSH to the machine with the same key you already named in your configuration file

Nothing else changes. The machine keeps its address on your own network, and Portainer keeps
answering there too — unless you ask for the opposite, which is the last section on this page.

**Tailscale SSH is deliberately off.** You reach the machine through its own SSH server, with
your key. Tailscale's SSH server would authenticate against your tailnet's access rules
instead, which is a second front door with a different lock on it, and SPEC.md
§spec:remote-access is written to avoid exactly that.

## Switching it on when you flash

Generate a key in the Tailscale admin console: **Settings > Keys > Generate auth key**. It
begins `tskey-auth-`. Then:

```
KANTAINER_TAILSCALE_AUTHKEY=tskey-auth-...
KANTAINER_TAILSCALE_HOSTNAME=garage-box
```

`just config-check` reads it back to you — without the key itself — so you can see which
machine you are about to build.

Two things about the key surprise people, so the check says them too:

- **It expires**, by default in 90 days, and the expiry is on the key rather than on the
  machine. A stick you flashed today still installs a machine next year; the key inside it will
  not join anything. Generate a fresh key when you reflash.
- **It is single-use** unless you tick *Reusable* when you generate it. Single-use is the
  better choice: it is spent the moment this machine joins.

The name matters more than it looks. Nothing in this repository sets the machine's system
hostname, so without `KANTAINER_TAILSCALE_HOSTNAME` every kantainer machine arrives in your
tailnet as `kantainer` and Tailscale tells them apart with a numeric suffix.

An API access token (`tskey-api-`) is a different thing and cannot join a machine to a tailnet.
The configuration check refuses one by name, because at first boot it fails with `invalid key`,
which reads like a typo.

## Switching it on later

Over SSH, on a machine flashed without a key:

```bash
sudo tailscale up
```

It prints a URL; open it and approve the machine. That is all — `tailscale up` starts
`tailscaled` itself, and the machine stays on the tailnet across reboots.

The login-screen address block and the gated units are driven by a file, so if you want the
machine to behave exactly like one flashed with a key:

```bash
sudo touch /etc/kantainer/tailscale-enabled
sudo systemctl start kantainer-tailscale
```

## After it has joined

The machine's tailnet address is on its **login screen**, below its ordinary address. You do
not need to log in to read it, and you do not need the admin console to find it.

The key is not needed again. The machine's own credentials live in `/var/lib/tailscale`, which
survives reboots and operating system updates. Deleting the spent key is good hygiene and
safe:

```bash
sudo rm /etc/kantainer/tailscale-authkey
```

It does not take the machine off the tailnet — the gate is the separate
`/etc/kantainer/tailscale-enabled` file precisely so that this tidy-up cannot.

### Changing settings afterwards

`/etc/kantainer/tailscale.env` is read when the machine **joins**, not on every boot. Once a
machine has joined, change settings with Tailscale's own command:

```bash
sudo tailscale set --advertise-exit-node
```

The join unit deliberately leaves a machine that is already logged in alone, including its
settings, so a change you make this way is not undone by the next reboot.

To leave the tailnet entirely:

```bash
sudo tailscale logout
sudo rm /etc/kantainer/tailscale-enabled
sudo systemctl stop kantainer-tailscale tailscaled
```

## Routing for the rest of your tailnet

The machine can carry traffic for your other devices. Two separate things, and both are only
**offers** until you approve them in the Tailscale admin console:

```
KANTAINER_TAILSCALE_EXIT_NODE=true
KANTAINER_TAILSCALE_ROUTES=192.168.1.0/24
```

- **Exit node** — other devices can send their internet traffic through this machine, as
  though they were sitting on your home network.
- **Routes** — other devices can reach hardware on the networks you list, without that
  hardware running Tailscale. A NAS, a printer, your router's own admin page.

Each entry in `KANTAINER_TAILSCALE_ROUTES` is an address and a prefix length — `192.168.1.0/24`,
not `192.168.1.5`. Separate several with commas and no spaces. The configuration check refuses
anything else by name.

**Neither does anything until you approve it.** Open the machine's entry in the admin console
and enable the exit node, or tick each route. This is the commonest surprise: the field is set,
the machine says it is advertising, and nothing routes, because the other half of the switch
lives on Tailscale's side.

A machine flashed with either setting also gets the kernel side of it — IP forwarding — written
by the installer. If you add one of these settings **by hand** on a machine that was flashed
without it, the forwarding file is not there, and the machine will accept an approved route and
then drop every packet sent through it. `systemctl status kantainer-tailscale` warns about this
at boot. To fix it:

```bash
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' |
    sudo tee /etc/sysctl.d/99-kantainer-tailscale-forwarding.conf
sudo sysctl --system
```

**What a route means is not something this repository decides.** Advertising `192.168.1.0/24`
makes your whole home network reachable from your tailnet. Which devices may use it is decided
by your tailnet's access rules, in Tailscale's admin console.

## Portainer on the tailnet only

By default Portainer answers on every address the machine has — your own network and the
tailnet both. You can narrow that to the tailnet alone:

```
KANTAINER_PORTAINER_TAILNET_ONLY=true
```

Then nobody on your own network can reach Portainer, including you, standing next to the
machine, without Tailscale on the device you are holding.

**What it costs.** If Tailscale cannot come up, Portainer does not start — there is no address
left for it to serve on. It does *not* fall back to answering everywhere, because that would
answer a request for "tailnet only" by putting the administration interface on your whole
network at the exact moment you cannot see the machine to notice.

The containers you deployed keep running throughout. This is Portainer's own port and nothing
else. But managing them again means fixing Tailscale first, over SSH or at the machine's own
keyboard — so **set `KANTAINER_CONSOLE_PASSWORD` if you choose this**, or a machine whose
tailnet and network both fail is a machine you cannot get into at all.

The login screen tells you when this is what has happened: the address lines stop offering a
Portainer URL, and the Tailscale line says the machine is not connected.

To undo it on a running machine:

```bash
sudo rm /etc/kantainer/portainer-tailnet-only
sudo systemctl restart kantainer-portainer
```

This is a binding on Portainer's port, not a firewall rule, and it has to be. A published
container port is forwarded rather than delivered to the host's firewall, so no firewall zone
can narrow it — see the comment in
`system_files/usr/lib/firewalld/zones/kantainer.xml`.

## When something is wrong

```bash
systemctl status kantainer-tailscale    # the join: gated, and runs once
systemctl status tailscaled             # the daemon itself
tailscale status                        # what Tailscale thinks
tailscale ip -4                         # this machine's tailnet address
```

`kantainer-tailscale` reporting a skipped condition means the machine was flashed without a
key — that is the switch, not a fault.

A machine that joined once and will not join again usually has a spent or expired key. Generate
a fresh one and either write it to `/etc/kantainer/tailscale-authkey` and restart the unit, or
just run `sudo tailscale up` and follow the URL.

The firewall opens UDP 41641 on every machine, which is what lets Tailscale build a direct
connection rather than relaying everything through its servers. Nothing listens on it unless
Tailscale is running.
