# Keep your containers updated

The machine can update the containers you deploy, and does not unless you ask.

Watchtower is inside the image already. Nothing downloads it, and nothing runs it until you
switch it on. This page is what to know before you do (SPEC.md §spec:container-updates).

## What it does when it is on

Once a night at 05:00 UTC it looks at every container on the machine. Any whose image has a
newer version is stopped, pulled, and recreated from the new one, and the image it replaced
is deleted.

Nobody is watching when that happens. If a container breaks on its new version, it stays
broken until you look. Nothing rolls it back — Docker keeps no previous deployment the way
the operating system does.

That is the whole of the deal. It is worth taking for a machine full of things you would
otherwise update by hand, and it is not worth taking for one container you care about
deeply.

**It holds the Docker socket, which is root on this machine.** Anything that can drive the
Docker engine can start a container that mounts your disk. Switching Watchtower on is the
same decision as giving it root, and the machine's SELinux policy does not change that — all
it does is keep the socket away from every *other* container you deploy.

## Two things are never touched

Portainer and Watchtower itself. Both are pinned in this repository and carried inside the
operating system image, so both move when the image moves — a Watchtower that updated them
would be pulling unsigned images past that pin and fighting systemd for the container name.

They are excluded by a label, and that is how you exclude anything else:

```yaml
services:
  the-one-you-care-about:
    image: example/app:2
    labels:
      com.centurylinklabs.watchtower.enable: "false"
```

Add it before you switch Watchtower on, not after.

## Switching it on when you flash

Set the field in your configuration file and flash as usual:

```
KANTAINER_WATCHTOWER_ENABLED=true
```

`just config-check` reads it back to you, so you can see which machine you are about to
build. Anything other than `true` or `false` is refused rather than assumed — `yes` and `on`
look like agreement and would have quietly given you a machine that never updates anything.

## Switching it on later

Over SSH:

```bash
sudo touch /etc/kantainer/watchtower-enabled
sudo systemctl start kantainer-watchtower
```

and to switch it off again:

```bash
sudo rm /etc/kantainer/watchtower-enabled
sudo systemctl stop kantainer-watchtower
```

The file is the switch. `/etc` is persistent, so either choice survives reboots and
operating system updates. The unit refuses to start without the file and says so:

```bash
systemctl status kantainer-watchtower
```

## Running it from Portainer instead

If you would rather own it yourself, the image is already in Docker's store — you do not
need to reach a registry. Deploy it as a stack:

```yaml
services:
  watchtower:
    image: ghcr.io/nicholas-fedor/watchtower:1.11.8
    command: --cleanup --schedule "0 0 5 * * *"
    volumes:
      - /run/docker.sock:/var/run/docker.sock
    security_opt:
      - label=type:kantainer_socket_client_t
    labels:
      com.centurylinklabs.watchtower.enable: "false"
    restart: unless-stopped
```

**`security_opt` is the line that matters.** Without it the container runs as `container_t`,
which is every container on this machine and deliberately has no route to the Docker socket.
You get `permission denied` on the socket and nothing in the logs explaining why. The
denial is visible with:

```bash
sudo ausearch -m AVC -ts recent
```

That same line is how you run anything else that needs the socket — a reverse proxy watching
container labels, a log viewer. The domain is named for what it is: a container the operator
has decided may hold the socket.

Keep the image tag in step with `WATCHTOWER_IMAGE` in `versions.env`, or the stack pulls a
different Watchtower from the internet instead of using the one already on the machine.

## Do not run two

Pick one: the unit, or your own stack. Two Watchtowers over one Docker engine both decide
the same container is out of date and both stop and recreate it, and the loser acts on a
container that no longer exists.

The unit checks for this and refuses to start if it finds another Watchtower already
running, naming it. It matches on the image, so a stack using a different tag or a digest
slips past — which is another reason to keep the tag in step.

## When something looks wrong

```bash
systemctl status kantainer-watchtower     # is it meant to be running, and is it
journalctl -u kantainer-watchtower        # what it did, and to what
docker ps --filter name=kantainer-watchtower
```

A unit reporting a skipped condition is a machine where Watchtower was never switched on —
that is the gate, not a fault.
