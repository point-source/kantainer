# Keep your containers updated

The machine can update the containers you deploy, and does not unless you ask.

Watchtower is inside the image already. Nothing downloads it, and nothing runs it until you
switch it on. Once it is on, it still updates nothing until you label a container for it.
This page is what to know before you do either (SPEC.md §spec:container-updates).

## What it does when it is on

Once a night at 05:00 UTC it looks at the containers **you have labelled** for it. Any whose
image has a newer version is stopped, pulled, and recreated from the new one, and the image
it replaced is deleted.

Everything else is left alone. A container is opted in by one label, in the stack that
defines it:

```yaml
services:
  jellyfin:
    image: jellyfin/jellyfin:10.10
    labels:
      com.centurylinklabs.watchtower.enable: "true"
```

Nobody is watching when an update happens. If a container breaks on its new version, it
stays broken until you look. Nothing rolls it back — Docker keeps no previous deployment the
way the operating system does. That is why the label is per container: label the things you
would otherwise update by hand, and leave off the one you care about deeply.

The flip side is quiet too. A container you deploy later and forget to label is never
updated, and nothing tells you. Opt-in was chosen because that mistake leaves a container
where it already was, and the other one does not.

**It holds the Docker socket, which is root on this machine.** Anything that can drive the
Docker engine can start a container that mounts your disk. Switching Watchtower on is the
same decision as giving it root, and the machine's SELinux policy does not change that — all
it does is keep the socket away from every *other* container you deploy.

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

## Changing how it behaves

The machine's defaults are in `/usr/lib/kantainer/watchtower-defaults.env`, which belongs to
the image — do not edit it, an update replaces it. Put your changes in
`/etc/kantainer/watchtower.env` instead. It does not exist until you create it, and anything
you set there overrides the default of the same name:

```bash
sudo tee /etc/kantainer/watchtower.env <<'EOF'
WATCHTOWER_NOTIFICATION_URL=ntfy://ntfy.sh/your-topic
EOF
sudo systemctl restart kantainer-watchtower
```

Every Watchtower option has a variable of this form; the
[Watchtower documentation](https://github.com/nicholas-fedor/watchtower) lists them. A few
worth knowing:

| Variable | What it does |
| --- | --- |
| `WATCHTOWER_NOTIFICATION_URL` | Tell you what it updated. Without it, the journal is the only record. |
| `WATCHTOWER_MONITOR_ONLY=true` | Check and report, change nothing. A safe first week. |
| `WATCHTOWER_LABEL_ENABLE=false` | Update **every** container instead. Read the warning below first. |
| `WATCHTOWER_SCHEDULE=0 0 6 * * *` | Move the nightly run. Seconds come first. |
| `WATCHTOWER_RUN_ONCE=true` | One pass, then stop. The unit goes `inactive (dead)`, not failed. |

The format is stricter than it looks. `KEY=value`, with the value taken literally to the end
of the line: **no quotes**, which become part of the value, and comments only on lines of
their own.

`docker inspect kantainer-watchtower` shows both the default and your override as separate
lines. That is expected — the later one is what Watchtower uses.

### Updating every container instead

`WATCHTOWER_LABEL_ENABLE=false` turns opt-in off, and every container on the machine is then
updated unattended unless it carries the label set to `"false"`. Portainer and Watchtower
itself carry that label already, so they stay out of it either way.

Everything you deploy after that is in scope the moment it exists. That is the mistake
opt-in exists to prevent, so switch it off knowing that.

### Moving the schedule

The operating system updates itself between 03:00 and 04:00 UTC and reboots when it does. A
reboot that lands between Watchtower stopping a container and recreating it leaves that
container **gone**, not stopped — no restart policy brings back a container that no longer
exists. Keep the schedule outside that hour.

## Running it from Portainer instead

If you would rather own it yourself, the image is already in Docker's store — you do not
need to reach a registry. Deploy it as a stack:

```yaml
services:
  watchtower:
    image: ghcr.io/nicholas-fedor/watchtower:1.11.8
    environment:
      WATCHTOWER_LABEL_ENABLE: "true"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_SCHEDULE: "0 0 5 * * *"
    volumes:
      - /run/docker.sock:/var/run/docker.sock
    security_opt:
      - label=type:kantainer_socket_client_t
    labels:
      com.centurylinklabs.watchtower.enable: "false"
    restart: unless-stopped
```

That is the same configuration the machine's own unit runs. Compose quotes are fine here —
it is only the env file that takes values literally.

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

Watchtower running and updating nothing is usually a machine where no container carries
`com.centurylinklabs.watchtower.enable: "true"`. That is the default working as intended.
