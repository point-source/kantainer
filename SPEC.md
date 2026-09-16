# kantainer — Specification

## Base image and composition §spec:base-image

*Status: complete* — all four additions are in the built image: the Docker engine
(§spec:container-engine), Portainer (§spec:portainer-service), wireless support, and
boot-health checking (§spec:boot-health-and-rollback). Not yet confirmed on real hardware:
the restored wireless packages are verified as installed, not as associating with a
network, which needs a machine with an adapter. The base is
`ghcr.io/ublue-os/ucore-minimal:stable-20260904`, pinned by digest in `Containerfile`
and recorded in `versions.env`.

The system is a single bootable container image derived from uCore's minimal variant,
published to a container registry by the repository's own automation. It adds to that
base exactly four things: the Docker engine turned on, Portainer, wireless support, and
boot-health checking. It adds no desktop, no file-sharing services, and no application
catalogue.

**Decision and constraint.** uCore publishes three variants. The minimal one is chosen
because the larger ones add Samba, NFS, snapraid and mergerfs — network storage features
that §req:constraints places out of scope and that §req:quality-attributes forbids under
minimality. The image is derived rather than assembled from scratch because §req:constraints
requires a uCore base, and because uCore already carries the Docker engine, the bootc
update machinery, and a signing policy that would otherwise have to be reproduced.

The minimal variant omits wireless firmware and wireless network support, which the larger
variant carries. The system restores those specifically, rather than moving to the larger
variant, because wireless is required by §req:quality-attributes while network storage is
excluded by it. Taking the larger variant to obtain wireless would import the excluded
features as a side effect.

**Alternatives rejected.** A plain Fedora bootc base was considered and rejected: it would
have made the installer story easier (see §spec:installer-media) but §req:constraints names
uCore, and abandoning it would mean reproducing uCore's server-oriented curation by hand.
uCore's full and hyperconverged variants were rejected as carrying excluded functionality.

**Tradeoffs.** Deriving from uCore inherits its release cadence and its defects; a bad uCore
publish becomes a bad kantainer publish. Restoring wireless support by hand means tracking
package changes the larger variant would have tracked for us.

Cites §req:constraints, §req:quality-attributes.

## Installer media §spec:installer-media

*Status: complete* — not yet confirmed on real hardware: the build environment has no USB
device to write and no machine to boot, so the write itself, both reboots and the signature
refusal remain unobserved. Everything up to the write is covered by `just ci`.

One thing to capture on the first hardware run, because no test on either side can reach it:
after the machine attaches itself, `bootc status` must report its signature mode as
`containerPolicy`. §spec:os-updates refuses to update a machine that reports anything else,
and the two halves meet only on a booted machine. The attachment's `ostree-image-signed:`
prefix is defined to produce exactly that mode, so this is a confirmation rather than an open
question — but a machine that got it wrong would install, serve, and then quietly never
update again.

The operator produces a bootable USB stick with one command, from two inputs: the Fedora
CoreOS installer image and their filled-in configuration file. Booting a target machine
from that stick installs the operating system to disk and reboots, with no keyboard input,
in the single-disk case. The machine then attaches itself to the published kantainer image
and reboots once more. From the operator's side this is one action: flash, boot, walk away.

Portainer answers on the network after the second reboot. Between flashing and that point
the machine downloads the kantainer image over its wired connection; a machine with no
working wired network at install time completes the first stage and then stops, rather than
reaching a serving state.

The installer verifies the signature of the kantainer image before adopting it, using
signing material placed on the machine during installation. An image that does not carry a
valid signature from the repository's key is refused. The attachment uses the command uCore
documents for this transition rather than one of ours; uCore's own example reaches the
signed image through an unsigned rebase first, because its policy exists only inside its
image, and placing the policy during installation is what removes that unverified step.

That placement has one permanent consequence, recorded here because it is invisible from
outside. ostree carries `/etc` forward as local modification, so after the rebase the
machine's signing policy is the copy the installer wrote, shadowing the image's own for the
life of the machine. Two effects, both accepted: the image's `ghcr.io/ublue-os` scope is
absent on an installed machine, which costs nothing because such a machine only ever pulls
its own image; and a later change to the image's policy reaches an installed machine by
reflashing rather than by updating. A rotated signing key therefore stops that machine
updating rather than being accepted silently — it fails closed.

**Decision and constraint.** uCore ships no installer of its own and cannot be installed
directly from an installer image — it is a Fedora CoreOS derivative, and the only supported
way to reach it is to install Fedora CoreOS and then attach the derived image. This is not
a limitation of this project; it is how every uCore machine in existence is installed. The
system therefore uses the Fedora CoreOS installer, personalised at flash time, rather than
building an installer of its own.

The personalisation happens on the operator's machine rather than in the repository's
automation because §req:quality-attributes forbids operator-specific material from entering
the public repository, and an installer that carries an SSH key and a password cannot be
published. The repository contributes the generic half of the configuration; the operator's
configuration file contributes the machine-specific half; the single flash command combines
them.

**Alternatives rejected.** Building an installer with the Universal Blue template's own
disk-image tooling was rejected on evidence: that tooling assembles an installer environment
from distribution packages and expects a partition layout Fedora CoreOS does not use, the
one recorded attempt against uCore failed, Universal Blue's own answer to this problem was
to create a second server image on a different base — which they then shut down, directing
users back to uCore — and the installer type in question has since been deprecated upstream
with removal announced. Building a bespoke installer image from the kantainer image itself
was considered and rejected as unproven: the tool that would do it is small and lightly
maintained, and no published example of the combination exists. That approach would remove
the extra reboot and the install-time download, and it can replace the installer source
later without changing the operator's flash command, but it is not what this system does.

**Tradeoffs.** The install takes longer than it would if the image were carried on the
stick, and it depends on the wired network and on the registry being reachable. The failure
mode is a machine that installed the operating system but never became a container host —
visible only by going to look at it. In exchange, every part of the path is one that uCore's
maintainers use and test.

Because the installer environment is stock Fedora CoreOS, which carries no wireless support,
the installation itself requires a wired connection even on machines that will later run on
wireless. See §spec:network-attachment.

Cites §req:sc:one-flash-command, §req:sc:unattended-install, §req:sc:push-publishes,
§req:constraints, §req:quality-attributes, §req:priorities.

## Operator-host support §spec:operator-host-support

*Status: complete* — pull requests keep the full Linux gate and add a focused Apple-silicon
macOS 26 job through the operating system's `/bin/bash`. Deterministic Linux and macOS
artifacts prove byte-identical configuration rendering; small real-command fixtures cover stock
checksum tools, runtime selection and retry, device policy, mutation ordering, complete writes
and sync.

The operator runs `just config-check`, `just render`, and `just flash` on the existing Linux
environment or an Apple-silicon Mac running macOS 26 or newer. Every path behind those commands
works with the Bash 3.2 and checksum utility supplied by macOS; unsupported systems are refused
before the target changes.

The two hosts accept the same configuration and render byte-identical machine specifications.
Operator values remain literal, including shell syntax and placeholder-shaped text, and
duplicate fields remain invalid even when the first value is empty. Both hosts verify the
installer against the repository's checksum and preserve the same valid-cache, corrupt-cache,
and download outcomes.

On macOS, local installer personalisation works with Docker Desktop or Podman. Docker is chosen
when both are usable. If Docker fails and Podman is available, the operator chooses whether to
retry; declining or a failed retry leaves the target untouched. Linux retains Podman.

A pull request passes a deterministic Linux render to a focused macOS job, which compares its
bytes and exercises the real operator commands with controlled fixtures. The broader Linux gate
continues to cover image and installed-machine behavior; Bash 3.2 applies to operator-facing
paths and everything they invoke.

**Decision and constraint.** Configuration, rendering, installer fetch, and flash remain one
contract across hosts; only operating-system capabilities differ. The compatibility gate
invokes the complete operator paths because testing their top-level scripts alone would miss
newer shell features or Linux-only utilities reached underneath them.

**Alternatives rejected.** Requiring a newer Bash on macOS was rejected because it adds a
replacement shell before the workflow begins. Executing configuration as shell input or using
shell replacement syntax was rejected because operator values contain syntax that must stay
literal. Requiring one macOS container runtime was rejected because either supported runtime
can perform the work. Porting the installed-machine suite to Bash 3.2 was rejected because it
lies outside the operator-host boundary.

**Tradeoffs.** Supporting the operating system's built-in tools leaves a small amount of
host-specific behavior to maintain and makes two CI environments part of the release gate.
The focused macOS check does not prove a multi-gigabyte download, a physical write, or a
boot. The Docker-to-Podman retry needs operator input, but it keeps one runtime's failure
from silently changing the tool that handles the operator's personalised installer.

Cites §req:sc:macos-host-commands, §req:sc:byte-identical-render, §req:sc:macos-runtime-choice,
§req:sc:macos-support-check, §req:user-stories, §req:quality-attributes (Operator-host
portability, Compatibility checks), §req:constraints.

## Flash target safety and write integrity §spec:flash-target-safety

*Status: complete* — controlled fixtures exercise the Linux and macOS paths through the real
`just flash` command, including complete aligned and unaligned writes and failure ordering. The
pull-request macOS job also runs the disposable RAM-disk check with native device tools; a
physical USB write remains outside the release gate.

Linux keeps its established whole-disk rule, including internal disks. The ordinary macOS
path accepts only an external whole physical disk and refuses partitions, internal or virtual
disks, non-device paths, incomplete facts, and unsupported hosts before unmounting or writing.
An explicit advanced choice admits any existing block or character device node with a
stronger risk message; it does not weaken reclassification, confirmation, or write integrity.

The command classifies the target before installer preparation and again immediately before
showing its current identity and risk. A changed or missing target, a refusal, any answer
other than the exact supplied path, or end of input leaves the target untouched. Once
confirmed, macOS unmounts the whole disk, uses the faster raw device only for images aligned
to 4 KiB, writes every byte, and makes the result durable. Any unmount, write, or durability
failure exits without success; a started write is reported as potentially incomplete. After
success the operator is told to eject the disk manually, and the command never ejects it.

**Decision and constraint.** Erasing the wrong disk is the workflow's only unrecoverable
failure, so ordinary macOS flashing requires positive device classification. The advanced
path remains available because §req:sc:macos-advanced-target requires intentional access to
other real device nodes. Exact-path confirmation is still necessary because device metadata cannot
distinguish an installer stick from an external backup. Buffered writes remain necessary for
unaligned images; aligned images can safely use the faster raw interface.

**Alternatives rejected.** Linux's broad whole-disk rule was rejected for ordinary macOS
flashing because macOS can identify known high-risk categories. Removing the advanced path
would prevent intentional writes outside the common case. Always using the raw interface can
lose a final partial sector; always using the buffered interface slows aligned images without
improving integrity. Automatic eject was rejected in favor of a clear durable-write result
followed by an explicit operator action.

**Tradeoffs.** Positive classification cannot distinguish one external physical disk from
another, and advanced mode deliberately permits dangerous targets. Reclassification narrows
device-name reuse but cannot prevent a physical swap after confirmation. Unaligned images use
the slower interface, and manual eject adds one step after success.

**User-level verification.** The real entry-point fixtures cover ordinary and advanced
selection, all pre-mutation refusals, exact confirmation, unmount ordering, aligned and
unaligned writes, complete bytes, durability failures, Linux compatibility, and the final
manual-eject instruction. Native macOS verification adds the disposable RAM-disk branch.

Cites §req:sc:one-flash-command, §req:sc:macos-ordinary-target-rules,
§req:sc:macos-advanced-target, §req:sc:macos-unmount-and-write, §req:sc:macos-support-check,
§req:user-stories, §req:quality-attributes (Flash safety, Write integrity, Compatibility
checks), §req:constraints, §req:priorities.

## Machine configuration §spec:machine-configuration

*Status: complete* — `kantainer.conf.example` carries the template and `just config-check`
applies the rules below. `just flash` (see §spec:installer-media) wraps the same check. The
console password named below is specified in §spec:console-password.

The repository carries a configuration template. The operator copies it, fills it in, and
keeps their copy out of version control. It is the only place machine-specific values
exist. `kantainer.conf.example` is the authoritative list of what it carries: a login
account, an SSH public key and the Portainer administrator password are required; a target
drive, a wireless network name and passphrase, a console password and whether the machine
runs Watchtower (§spec:container-updates) are optional.

The file is parsed rather than executed, and each value is taken literally to the end of its
line. The operator is not asked to learn shell quoting for a password.

Validation refuses when a required value is missing, when the SSH public key is not one, or
when either password is shorter than the twelve characters Portainer itself will accept
without demanding an immediate change. The refusal names the offending field and exits
non-zero. Nothing is written — not a USB stick, not a rendered configuration, not a temporary
file left behind. The console password is the one field whose absence is reported rather than
refused: a machine without one is a supported choice, and the check says what that choice
costs (§spec:console-password). The Watchtower switch is refused unless it is exactly `true`
or `false`: `yes`, `1` and `on` all read as agreement to a person and none of them is what
the installer tests for, so accepting them quietly would produce a machine that does not
update its containers and an operator certain that it does.

**Decision and constraint.** The Portainer password is required rather than optional, which
departs from §req:sc:portainer-login-without-watching and §req:priorities, where it ranks sixth
as convenience with a fallback. The fallback no longer exists: current Portainer refuses to
create its first administrator account without a token that it prints only to its own log, so
an operator who skips the password cannot claim the account from a browser at all and must
connect over SSH to read the token. Requiring the password removes both that step and the
window during which an unclaimed administration page is exposed. The operator was presented
with the alternatives and chose this.

Values live in a file on the operator's machine rather than being fetched from a server at
boot because §req:constraints excludes a configuration server, and rather than being baked
into the published image because §req:quality-attributes forbids operator-specific material
in a public repository.

**Alternatives rejected.** Making the password optional and preserving Portainer's token
gate was rejected as trading a mandatory field for a mandatory SSH session. Making it
optional and disabling the token gate was rejected as deliberately switching off a
protection added upstream this year, in a service that holds root-equivalent access to the
machine.

**Tradeoffs.** A password now sits in a plain file on the operator's machine and on the USB
stick. The stick is a physical object the operator controls, and the alternative — a machine
reachable on the network with an unclaimed administrative interface — is worse. The
configuration file becomes a thing the operator must not lose, since regenerating a stick
requires it.

Cites §req:sc:one-flash-command, §req:sc:portainer-login-without-watching,
§req:sc:ssh-by-key-only, §req:constraints, §req:quality-attributes.

## Drive selection §spec:drive-selection

*Status: complete* — not yet confirmed on real hardware: every branch of the rule is driven
by tests against fixtures, but no two-disk machine has been booted to watch it stop.

When the configuration file names a target drive, the installer uses it. When it does not
and the machine has exactly one drive, the installer uses that drive. When it does not and
the machine has more than one, the installer writes nothing: it lists the drives it found,
with enough detail — model, size, and serial — to tell them apart, and stops at a prompt
where the operator can select one.

The medium the installer booted from is never a candidate. Excluding it is a matter of
correctness and not only of safety: a single-drive machine has the USB stick attached while
the rule runs, so counting it would present two drives and stop at a prompt, breaking the
unattended installation §req:sc:unattended-install asks for. The medium is identified from
the live ISO's own account of itself, on the kernel command line, and the installer refuses
outright rather than guessing if that cannot be resolved.

**Decision and constraint.** §req:priorities ranks not destroying data third, and notes it
is the only failure here that is not recoverable. The installer's own unattended mode
cannot be used: it clears every attached drive, not the first one, and it cannot be combined
with the custom instructions a named-drive rule requires. Drive selection is therefore
governed by the repository's own rule rather than the installer's default.

Stopping at a prompt rather than powering off was chosen by the operator. It means a
multi-drive machine with no drive named waits for a person, which is a narrow exception to
the unattended behaviour §req:quality-attributes requires — an exception that document
already anticipates and endorses for exactly this case.

**Alternatives rejected.** Printing the list and powering off was rejected as requiring a
re-flash to recover. Printing and halting without a prompt was rejected as leaving the
machine powered on with no way forward. Both avoid an interactive installer, which
§req:constraints lists as out of scope; the operator accepted the prompt as the better
tradeoff given it occurs only in the ambiguous case.

**Tradeoffs.** A headless machine stopped at this prompt is indistinguishable from a crashed
one until someone attaches a display. Naming the drive in the configuration file avoids the
situation entirely, and the documentation says so.

Cites §req:sc:multi-drive-halt, §req:quality-attributes, §req:priorities, §req:constraints.

## Network attachment §spec:network-attachment

*Status: complete* — wireless support is in the image (§spec:base-image) and the connection
profile is built from the operator's configuration. A wired machine gets no configuration
at all, which is the whole of the wired case.

The machine obtains its address automatically. With a wired connection present it uses it
and needs no configuration. When the configuration file names a wireless network and
passphrase, the installed machine joins that network and uses it when no wired connection
is available.

Installation itself requires a wired connection, regardless of whether the machine will
later run on wireless. A machine intended for wireless operation is installed on ethernet
once and then moved.

The wireless radio does not sleep. NetworkManager's default leaves power management to the
driver, which parks the card between beacons; a station that is asleep receives broadcast
frames only after a DTIM beacon, and the ARP request that begins every inbound connection is
broadcast. Such a machine answers nobody while still reaching its gateway and holding its
lease - unreachable, and healthy by every measure it can take of itself. The profile turns
power save off.

The operator finds the machine's address from their router. The machine assumes no fixed
address.

**Decision and constraint.** §req:quality-attributes places both wired and wireless machines
in scope. Wireless is optional in the configuration file at the operator's direction, so a
wired machine carries no wireless configuration at all.

The wired-only installation is forced, not chosen: the installer environment is stock Fedora
CoreOS, which ships neither wireless firmware nor wireless network management. Wireless
support exists in the kantainer image because it is added there deliberately, but the image
is not present until after the installation completes. Carrying wireless into the installer
would require building the installer from the kantainer image, which §spec:installer-media
rejects.

**Alternatives rejected.** A fixed address was rejected by §req:constraints. Making wireless
mandatory was rejected as forcing configuration on the wired case, which is the common one.

**Tradeoffs.** A machine that will live somewhere without ethernet must be installed
somewhere with it. This is a one-time inconvenience at install, not an ongoing constraint.
A wireless machine also draws slightly more power for a radio that never sleeps, which buys
the only path to a machine that has one.

Cites §req:quality-attributes, §req:constraints, §req:sc:portainer-in-a-browser.

## Container engine §spec:container-engine

*Status: complete* — not yet confirmed on real hardware: the build environment has no
virtualisation, so `systemctl is-active` and the firewall's runtime behaviour remain
unobserved.

Docker runs from first boot and restarts with the machine. It is the engine Portainer
manages and the engine the operator's containers run under. Containers set to restart
automatically come back after a reboot.

Podman is present, because the base image carries it, and is not used for workloads.

The machine's firewall accepts connections on the Portainer interface and on SSH, and
nothing else. Portainer's agent-tunnel and plain-HTTP interfaces are not exposed.

Mandatory access control remains enforcing on the machine as a whole, and no container
reaches the Docker control socket by default. Two named domains may, and a container enters
one only by asking for it: Portainer's own (§spec:portainer-service), and one shared by
Watchtower and anything else the operator decides may hold the socket
(§spec:container-updates).

**Decision and constraint.** §req:problem-statement makes running Docker containers the
machine's one job. The base image ships Docker but deliberately leaves it switched off,
preferring Podman and warning against running both engines at once. The system switches
Docker on and leaves Podman unused for workloads rather than running both, because that
warning comes from the base platform's own maintainers and running two engines against one
machine's resources invites conflicts nobody would enjoy diagnosing on a headless box.

The firewall is closed by default and opened to two ports because §req:constraints excludes
exposing Portainer to the internet and §req:quality-attributes calls for minimality; a
container host that answers on ports nothing uses is a larger target for no benefit.

Narrowing the base platform's default zone also drops DHCPv6 and Cockpit. Dropping DHCPv6
means a network that hands out IPv6 addresses that way will not address this machine; IPv4
DHCP and IPv6 SLAAC are unaffected, and §req:quality-attributes scopes the target to a home
network that assigns addresses automatically, which is IPv4 in practice.

The firewall also cannot promise as much as it appears to. A published container port is
translated and forwarded rather than delivered to the host, so it never meets these rules:
the firewall governs what the machine itself listens on, not what is published on the
operator's behalf. Portainer's agent-tunnel and plain-HTTP interfaces are closed by not
publishing them, not by the firewall.

**Alternatives rejected.** Running Portainer's workloads under Podman was rejected: the
operator asked for a Docker host, and Portainer's Docker support is its most exercised path.
Removing Podman from the image was rejected as fighting the base image for no gain — it is
inert when nothing invokes it.

**Tradeoffs.** Two container engines are installed and one is idle, costing disk. Enabling
Docker diverges from the base image's default, so a future base change could silently
reverse it; the boot health check in §spec:boot-health-and-rollback treats a machine without
a running Docker engine as a failed boot, which catches exactly that.

Cites §req:problem-statement, §req:sc:containers-survive-reboot, §req:quality-attributes,
§req:constraints.

## Portainer service §spec:portainer-service

*Status: complete* — not yet confirmed on real hardware: SELinux enforcement needs an
enforcing kernel, and systemd's unit ordering needs a boot, neither of which the build
environment has.

Portainer is part of the image. It is present on disk before the machine ever boots and is
never downloaded onto the machine. It starts automatically, after Docker is available, and
restarts if it stops or if the machine reboots.

It serves its web interface over HTTPS, with a certificate the machine generates for itself
on first run and reuses thereafter. Browsers warn about that certificate; the warning is
expected and the documentation says so.

The administrator account exists before the interface accepts its first connection, using
the password from the configuration file. There is no setup screen, no token to retrieve,
and no window during which an unclaimed account is exposed. The connection to the local
Docker engine is already configured when the operator first logs in.

Portainer's own settings, its certificate, and the definitions of anything the operator
deploys through it are stored on the machine's persistent storage and survive both reboots
and operating system updates.

**Decision and constraint.** §req:constraints requires Portainer to ship inside the image
rather than be installed after first boot. Docker offers no way to share a read-only image
store, so Portainer's container image is carried inside the operating system image as an
archive and loaded into Docker the first time the machine boots. This is what makes the
machine's first boot independent of the registry: a Docker Hub outage, or its rate limits,
cannot prevent a freshly installed machine from serving.

Portainer holds the Docker control socket, which is root-equivalent access to the machine.
Reaching that socket from inside a container requires an exemption from the machine's
mandatory access control. The exemption is scoped to the Portainer container alone and the
rest of the machine stays enforcing. This grants Portainer nothing it did not already have
by holding the socket.

**Alternatives rejected.** Pulling Portainer on first boot was rejected by §req:constraints
and because it makes the machine's first useful moment depend on a third party's uptime.
Running Portainer under Podman was rejected: it would allow the image to be carried by the
platform's own mechanism rather than an archive, but it means running both engines against
one machine — see §spec:container-engine — and no published example of that arrangement
exists. Granting the exemption machine-wide, or running Portainer with full privileges as
Portainer's own documentation suggests, were both rejected as broader than necessary.

**Tradeoffs.** Portainer's image occupies space twice: once in the operating system image
and once in Docker's store after loading. Updating Portainer requires rebuilding and
republishing the operating system image rather than pulling a new container, which is slower
but means the version in use is the version the repository recorded. Anyone who reaches
Portainer's interface and knows the password owns the machine; the password's strength is
the whole of the defence, which is why §spec:machine-configuration enforces a minimum
length.

The administrator password is delivered readable and stays readable on the machine, unlike the
console password, which is converted before the installer media is written
(§spec:console-password). Portainer is handed the password itself rather than a stored form of
it, and neither the container the flash command runs nor the machine's own image can produce the
form Portainer would accept instead. The operator chose to accept that rather than hold the
feature, and the mitigation is documentation: §spec:operator-documentation tells the operator to
change the password in Portainer once they are logged in, which is also the moment they are first
looking at it. Portainer ignores the delivered password once an administrator exists - verified
against the pinned image, which logs that it is skipping the password flags - so the change
survives restarts and operating system updates, and the delivered copy stops being a way in
rather than being deleted. The stick is a secret-bearing object either way, which
§spec:installer-media already says.

Cites §req:sc:portainer-in-a-browser, §req:sc:portainer-login-without-watching,
§req:sc:containers-survive-reboot, §req:sc:data-survives-updates, §req:constraints,
§req:quality-attributes.

## Container updates §spec:container-updates

*Status: complete* — not yet confirmed on real hardware: the gate, the SELinux domain and
the nightly schedule all need an enforcing kernel and a boot, which the build environment
has neither of.

The machine can update the containers the operator deploys, and does not unless they ask.

Watchtower is part of the image on the same terms as Portainer: present on disk before the
machine ever boots, pinned by tag and digest in the repository, never downloaded onto the
machine. It is loaded into Docker on every boot whether or not it is switched on.

Two things switch it on, and they are alternatives rather than a pair. The configuration
file carries an optional field, and a machine flashed with it set starts Watchtower from
first boot. An operator who did not set it can deploy Watchtower themselves from Portainer,
from the image already in the store, or create the gate file and start the unit over SSH.
Starting a second one when the first is already running is refused, with a message naming
the one already there.

Once running, it updates only the containers the operator has labelled for it. Each night it
checks those, replaces any whose image has a newer version, and deletes the image it
replaced. Switching Watchtower on and labelling nothing changes nothing. The check is at
05:00, clear of the operating system's own update window and the reboot that ends it
(§spec:os-updates).

These defaults live in a file the image owns, and the operator can override any of them in a
file of their own on the machine — the schedule, notifications, a monitor-only mode, or the
scope itself. An override the operator writes takes effect; none is accepted and then
ignored.

Portainer and Watchtower itself carry an exclusion label. Under the default scope it is
redundant, since neither is labelled in. It stays because the operator can widen the scope
to every container, and from that moment the label is the only thing keeping Watchtower off
two containers that are pinned in this repository and move only when the image moves.

Watchtower reaches the Docker control socket, which is root-equivalent access to the
machine, and so needs the same exemption from mandatory access control that Portainer needs.
The exemption is a second domain, which nothing runs in unless something names it. The rest
of the machine stays enforcing, and `container_t` — every container the operator deploys —
still has no route to the socket.

**Decision and constraint.** §req:quality-attributes asks for a machine that keeps itself
alive without attention, and §spec:os-updates already delivers that for the operating
system. The containers on top of it were the half with no answer: an operator who deployed
something through Portainer had no way to get its fixes short of redeploying it by hand.

It is off by default because it is not the same kind of update as the operating system's.
That one is a signed image this repository built, with a health check and an automatic
rollback behind it (§spec:boot-health-and-rollback). This one is whatever a third party
pushed to a tag, applied unattended, with nothing to roll back to — Docker keeps no previous
deployment. An operator who wants that should say so; an operator who does not should not
discover it from a container that stopped working overnight.

The scope is opt-in by label because the two ways of getting it wrong are not the same size.
An operator who forgets to label a container in leaves it un-updated, which is where it
already was. An operator who forgets to label one out — under a watch-everything scope —
finds it stopped, replaced and restarted overnight with nobody watching and nothing to roll
back to. A switch that asks for a label per container looks less switched on than it is, and
`just config-check` names the label for exactly that reason: the likelier surprise is
Watchtower running and updating nothing.

The defaults are environment variables in an image-owned file, passed ahead of the
operator's own, rather than flags on Watchtower's command line. Both obvious alternatives
break the override silently, and both were verified against the pinned image rather than
assumed: Watchtower lets a flag win over its own environment variable, and Docker lets
`--env` win over every `--env-file` regardless of order. Either way the operator's setting
would be accepted and ignored with nothing reporting it. Docker does let a later env file
override an earlier one, which is the whole mechanism, and `scripts/test-watchtower.sh`
fails if a default reappears on the command line or the two files swap order.

A second SELinux domain rather than reusing Portainer's: Portainer's domain also owns
Portainer's database, administrator hash and TLS key, and Watchtower has no business with
any of them. The new domain owns no file type at all. It is also reusable, which is what
makes "deploy it yourself from Portainer" a supported path rather than a trick — anything
else the operator runs that needs the socket names the same domain.

That separation is worth exactly what it is worth and no more. A container holding the
Docker socket is root-equivalent and can start another container with any label it likes.
The domain is not a wall around a socket holder; it is the difference between one named
opt-in and every container on the machine, which is the argument §spec:portainer-service
already made.

**Alternatives rejected.** Granting the socket to `container_t` was rejected for the reason
§spec:portainer-service rejected it: it hands root-equivalent access to anything the
operator ever deploys. `--security-opt label=disable`, which is the usual advice for this
denial, was rejected as the same trade made less visibly — it runs the container unconfined
rather than in a domain anyone can read.

Shipping Watchtower enabled was rejected as changing what an existing machine does on the
strength of an image update.

Watching every container and excluding by label was rejected as the larger of the two
mistakes (above). It remains one line away for an operator who wants it.

A systemd drop-in as the way to change Watchtower's options was rejected: overriding
`ExecStart` forks the whole command line — the SELinux opt-in, `--pull=never`, the socket
mount — into `/etc`, where a later change to the image's copy never reaches it. Not shipping it at all and documenting the label-and-domain
recipe was rejected as leaving the operator to assemble from documentation the one
arrangement this repository is in a position to get right.

Updating Portainer with Watchtower was rejected outright. Portainer is digest-pinned inside
the OS image and started by systemd with `--pull=never`; a Watchtower recreating it would
pull an unsigned image from Docker Hub by tag, past that pin, and then trade the container
name back and forth with systemd until the service gave up. The exclusion label prevents it
under any scope the operator can choose, and is not optional.

**Tradeoffs.** The image carries a second container archive it may never run, costing space
in the image and in Docker's store, and about a second of boot time loading it. Switching
Watchtower on by editing a file on the machine rather than through Portainer means an
operator who only ever uses the web interface has to either use the configuration file at
flash time or deploy their own copy — the gate is a file because at Ignition time the unit
does not exist yet to be enabled.

Unattended container updates can break a service overnight with nobody watching, and nothing
here rolls that back. That is the cost of the feature rather than a defect in it, which is
why it is off unless asked for, opt-in per container once it is on, and why both the
configuration template and `just config-check` say so in those words.

Opt-in has a quiet failure of its own: a container deployed later and never labelled is never
updated, and nothing reports it. That was judged the right way round to be quiet.

The operator's override file is a second place Watchtower's behaviour is decided, and
`docker inspect` shows both the default and the override as separate entries even though
only the later one takes effect. The documentation says so, because it is the first thing
someone debugging an override will look at.

Cites §req:problem-statement, §req:quality-attributes, §req:constraints,
§req:sc:containers-survive-reboot, §req:sc:data-survives-updates.

## Remote access §spec:remote-access

*Status: complete*

The machine accepts SSH connections to the account named in the configuration file, using
the public key that file carries. That account can become root: remote access exists to
look at a machine, and an account that cannot administer it cannot do that. Password
authentication is refused, for every account.

Remote access exists for the rare occasion something needs looking at. Nothing in normal
operation — installing, reaching Portainer, deploying containers, updating, recovering from
a bad update — requires it.

**Decision and constraint.** §req:quality-attributes requires key-only access and
§req:sc:ssh-by-key-only requires password logins to be refused. Refusing passwords
outright, rather than merely not setting one, means a later change that sets a password
somewhere cannot quietly open a door.

Fedora CoreOS already disables password authentication. This repository restates it anyway,
in a drop-in numbered *below* the platform's own, because sshd takes the first value it
reads for a keyword: the lowest-numbered file is the authoritative one, and a higher number
would leave ours the file being overridden rather than the one doing the overriding. Both
`PasswordAuthentication` and `KbdInteractiveAuthentication` are refused, because they are
two separate doors to a password prompt and closing one leaves the other open.

**Alternatives rejected.** Leaving password authentication available for console recovery
was rejected: §req:constraints puts one operator and one machine in scope, and a machine
whose only network-reachable authentication is a key is materially harder to attack than one
where a password would be accepted if guessed.

**Tradeoffs.** Losing the private key means losing remote access to the machine, with
physical access and a reinstall as the only recovery. For a machine whose entire
configuration lives in a file the operator already keeps, reinstalling is cheap.

Cites §req:sc:ssh-by-key-only, §req:quality-attributes, §req:constraints.

## Console display §spec:console-display

*Status: complete* — not confirmed on real hardware: the build environment has no console and
no network interface, so the screen itself is only ever rendered against fixtures. Five things
for the first hardware run, because nothing in this repository can reach them. `agetty
--show-issue` renders the whole screen without a reboot and answers the first three.

First, the kantainer block appears *below* the platform's lines, with the Portainer lines below
the address lines — the prefixes sort that way, but the screen is agetty's, and the tradeoff
below already accepts that a change in the platform's snippets moves ours. Second, the block
names the machine's real interface and omits `docker0` and the bridges Portainer creates — a
filter wrong in the loose direction advertises an address that reaches Portainer from nowhere,
and one wrong in the strict direction leaves the block empty. Third, plugging a cable changes
the screen with nobody logged in, and so does the port probe's own timer. Fourth, the same
`agetty --reload` redraws the platform's own per-interface line; that it does follows from that
line being an agetty escape, but only a real console shows it happening. Fifth, the probe
reaches Portainer's published port with SELinux enforcing.

A wedge itself is not quite on that list. A listener that accepts a connection and then never
completes the handshake is reproducible off the machine, and the probe was run against one by
hand while this was built: it reported the port unanswered, bounded by its own timeout, where a
bare TCP connect to the same listener reported it as serving. That was a one-off check and
nothing in CI repeats it — what the tests hold is the choice it justified, that the probe makes
a completed HTTPS request with a deadline rather than a connect. The first hardware run adds
only that a wedged
*Portainer container* presents to the probe the same way a wedged socket does.

With a monitor attached, the machine's login screen answers the two questions an operator
standing at it has: what to type into a browser, and whether Portainer is there. It answers
them before anyone logs in, and it does not require a keyboard to have been used.

Below what the platform already prints, the screen carries a kantainer block. For each network
the machine is actually on, the block gives the machine's address written the way it is typed
into a browser to reach Portainer, and the name of that network — the wireless network the
machine joined, or that the connection is wired. When the machine has no address at all, the
block says exactly that in words, rather than leaving a space where an address would be.

Portainer is reported as two separate statements: what the machine's service manager says about
it, and whether an HTTPS connection to its port was actually answered, together with when that
was last checked. On a healthy machine the two agree. When they disagree, the screen shows the
disagreement rather than choosing one. Until the port has been checked at all, the second
statement says so rather than reporting a refusal.

The block is current rather than a snapshot of boot. Attaching a cable, joining a network, a
new address arriving from the router, and Portainer starting, stopping or failing are all
reflected on the screen without a reboot and without anyone logging in. The platform's own
per-interface line is refreshed from the same events, so it cannot sit stale next to a correct
kantainer line. The answered-on-its-port statement refreshes on its own schedule and says when
it last looked.

This display exists only on a machine that is running its own image. During installation and
during the window in which the machine downloads that image, the screen is whatever stock
Fedora CoreOS shows.

**Decision and constraint.** §req:sc:screen-shows-address, §req:sc:screen-says-no-address and
§req:sc:screen-keeps-up and §req:quality-attributes' console visibility require this, and
§req:priorities ranks it fourth because it takes the router out of the first-boot path — which
matters most on exactly the networks the operator does not administer. It is read-only and
cannot lock anyone out, which is why it ranks above the console password.

The display extends the platform's existing console message machinery rather than replacing it.
That machinery is already in the base image, already enumerates network interfaces, already
redraws the login prompt the instant a cable goes up or down, and already survives updates as
part of the platform. Writing a display of our own would reproduce all of it in order to add a
handful of lines.

The operator chose to keep the platform's own per-interface line and add the kantainer block
beneath it, so that the platform's part keeps working if ours breaks. For the cheapest safety
in the project, degrading is the right failure mode: a screen that shows an address in the
platform's shape is worth more than a blank one.

Portainer is reported twice, at the operator's direction, because an operator is at the
keyboard precisely when the web page did not load — the one case where a container that started
and then wedged reads as running. A screen that agreed with the machine rather than with the
operator would be wrong exactly when it is being read. The two statements are also kept
independent of each other: a Portainer event never invalidates the recorded port answer,
because discarding one statement on the other's evidence is choosing between them by another
route.

The service manager's verdict is reprinted in systemd's own words rather than translated. A
mapping into friendlier terms is this repository's copy of systemd's judgement, and it is the
copy that goes stale when a state is added; it would also disagree in wording with the
`systemctl status` the operator runs next.

The port statement is a completed HTTPS request, not a TCP connect, and it is made from the
machine itself. A connect would report a wedged TLS listener as serving, which is the exact
fault the statement exists to catch. Asking over the loopback keeps the statement honest on a
machine with no address at all; the cost is that it reports that Portainer is serving, not that
any particular network path to it is open.

Nothing here may be on the zero-touch path. §req:constraints says the machine has a screen and
a keyboard only when the operator attaches them, so the block is produced whether or not
anything is displaying it, and nothing waits for a display, a login, or a person.

**Alternatives rejected.** Replacing the platform's per-interface line with a single
kantainer-authored block was offered and rejected by the operator: it reads better, but it
makes the whole screen ours to break, and a fault in it leaves nothing where the platform would
still have shown an address. Removing the SSH host key fingerprints the platform prints was
rejected with it — they are the only way to verify this host on a first SSH connection.
Reporting Portainer from the service manager alone was rejected as agreeing with the machine in
the one case that brings an operator to the keyboard; probing the port alone was rejected as
unable to tell a stopped Portainer from a wedged one. Reporting a not-yet-checked port as
unanswered was rejected as putting a disagreement on the screen that nothing had established,
during the early boot when someone is most likely to be reading it. Carrying the display
through the install and download window was rejected as scope beyond the requirement;
docs/verify.md already explains that window in prose (§spec:operator-documentation). A status
dashboard or a custom program on the console was rejected outright: §req:quality-attributes
promises the console is ordinary, with no menu and no recovery tool.

**Tradeoffs.** The address appears twice on the screen in two different shapes, and on a
machine whose interface came up without an address the platform's line may sit above the
kantainer block with nothing after it. Both are the accepted cost of not owning the platform's
part. Something knocks on Portainer's port on a schedule for the life of the machine, so that
statement lags reality by up to that interval — which is why it says when it last looked, and
why a screen read seconds after a restart can show the two statements disagreeing while the
port statement catches up. The service statement has a smaller version of the same lag: it is
re-read from a hook that fires while the unit is still stopping, so a deliberate stop can leave
the word `deactivating` on the screen until the probe's next run replaces it with `inactive`.
Ordering the renderer behind Portainer's own unit would close that window and was rejected for
the reason above — the renderer's whole job is to report on a Portainer that may be stopped,
failed or looping, and it must not be scheduled behind it. The word is what the service manager
said at the moment it was asked, the port statement is already saying the port does not answer,
and the next run corrects it. The block's position on the screen depends on the platform's own
snippets, so a change there moves ours. Anyone standing at the machine learns its address and
whether Portainer is serving; that requires physical presence, the address is not a secret to
anyone already on that network, and the Portainer password remains the whole of the defence
(§spec:portainer-service).

Cites §req:sc:screen-shows-address, §req:sc:screen-says-no-address, §req:sc:screen-keeps-up,
§req:quality-attributes, §req:priorities, §req:constraints.

## Console password §spec:console-password

*Status: complete* — not confirmed on real hardware: nothing in this repository can boot a
machine, so the login itself and the boot-partition question below are both for the first
hardware run. The conversion itself is settled rather than waiting: the coreos-installer
container pinned in `versions.env` ships shadow-utils, and the hash it produces was checked
against that digest — it round-trips byte-for-byte against `openssl passwd -6` with the same
salt.

The configuration file carries an optional console password for the machine's login account.

Left blank, the machine is exactly what it is today: no account has a password, the login
prompt cannot be satisfied by anyone, and the SSH key is the only way in. Set, the operator
logs in at the machine's own keyboard and administers it from that session.

The password never reaches the network. SSH refuses password authentication for every account
whether or not one is set (§spec:remote-access), so setting one widens physical access and
nothing else.

The check refuses one shorter than twelve characters, names the field, and writes nothing — the
same floor as the Portainer password (§spec:machine-configuration), for a different reason. A
blank one is accepted rather than refused, and the check says plainly that a machine without
one cannot be reached at all once its network fails, so the operator declines the insurance
knowingly rather than discovering it later with a keyboard in their hand.

**Decision and constraint.** §req:sc:console-login, §req:sc:console-password-never-remote,
§req:sc:blank-console-password-accepted and §req:sc:console-password-floor require this, and
§req:priorities ranks it fifth: insurance rather than daily use, off unless the operator asks
for it, and it must leave the default posture exactly as locked down as it is today. That last
clause is why the field is optional and why nothing about a machine with a blank one changes.

The operator writes it readable in their configuration file, the same way they write the
Portainer password: that file's whole design is one literal value per line with no syntax to
learn. The readable form goes no further than that file.

`just flash` converts it on the operator's own host, inside the coreos-installer container that
command already runs, and the stick carries only the result. The supported hosts do not agree
on a tool that can do this — the Bash and the OpenSSL macOS 26 ships cannot produce the modern
form, and §req:constraints forbids requiring a Mac operator to install anything extra — but the
container is no new dependency: it is the same pinned image that personalises the installer
media. The password reaches it on standard input, never in an argument, which anyone on the
host could read.

`just render` converts nothing and carries `passwordHash: "*"`, crypt's own "no password will
ever match this account". A `$6$` hash has a random salt, and §spec:operator-host-support
depends on `just render` staying containerless, deterministic and byte-identical between Linux
and macOS. The placeholder fails closed: a machine that somehow receives an unsubstituted
document has a locked account, not an unknown credential. After installation the password
exists on the machine only in its account database.

A conversion that cannot happen stops on the operator's own host, before the installer is
downloaded and before any stick is written, naming the runtime that failed — rather than
aborting the machine's own install into emergency mode after they have carried a stick to it.

Privileged commands do not ask for the password again. The base platform already grants this
account administrative rights without a prompt, which is how key-based administration over SSH
works today; requiring a password would leave a machine with no console password unable to
administer itself at all, contradicting §spec:remote-access. The login prompt is therefore the
whole of the gate, which is what makes the twelve-character floor load-bearing rather than
ceremonial.

**Alternatives rejected.** Having the operator supply a pre-scrambled password was offered and
rejected: it keeps the readable form off the stick, but macOS ships no tool that produces the
strong form, so it would either push Mac operators onto a weak one or break the macOS support
§spec:operator-host-support exists to provide. The container does for them what their own host
cannot, without asking them to. Accepting either form was rejected as two paths to get wrong in
a file whose value is the absence of syntax. Hashing on the host outside a container was
rejected for the same macOS reason. Converting during installation, so that the readable value
travelled on the installer media, was how this worked first and was rejected once the container
turned out to be able to do it: it put a readable secret on a physical object that leaves the
operator's desk, purely so the machine could scramble it later. Making `just render` emit the
hash was rejected because a random salt breaks the byte comparison §spec:operator-host-support
rests on. Making the console password required was rejected by §req:constraints, which makes
blank a supported choice. Requiring the password for privileged commands was rejected because
it breaks administration on every machine that does not set one. Logging the console in
automatically, with no password, was rejected as strictly worse than today: it hands the
machine to whoever walks up to it. A separate recovery account was rejected as a second
identity to reason about and lock down, for no capability the operator's own account lacks.

**Tradeoffs.** The stick carries the console password as a `$6$` hash rather than in readable
form. That is much better and it is not safe: whoever picks the stick up can attack that hash
offline, at their own pace, and the twelve-character floor is the whole of what stands behind
it. The asymmetry with the Portainer password is deliberate and settled: that one stays
readable on the stick and on the machine, because Portainer is handed the password itself and
nothing available here can produce the form it would take instead. The operator accepted it and
the answer is documentation rather than code — see §spec:portainer-service. Setting a console
password means the machine can be taken over by someone with physical access and that password;
leaving it blank means a machine whose network has failed can only be reflashed. The check
states that choice at the moment it is made. Changing the password later means rendering and
reflashing, like every other value in the file. One thing to confirm on the first hardware run,
because nothing in this repository can answer it: whether the installer leaves the delivered
machine configuration readable in the installed machine's boot partition. It already carries
the Portainer password, so the answer does not change this design, but it is the kind of fact
this repository records rather than assumes.

Cites §req:sc:console-login, §req:sc:console-password-never-remote,
§req:sc:blank-console-password-accepted, §req:sc:console-password-floor, §req:constraints,
§req:quality-attributes, §req:priorities.

## Operating system updates §spec:os-updates

*Status: complete* — not yet confirmed on real hardware: the build environment has no
virtualisation, so the overnight reboot, the signature refusal, and the survival of
container data across an update remain unobserved.

The machine checks for a new published kantainer image once a day, in an overnight window,
and installs it without being asked. Applying an update requires a reboot, which the machine
performs itself. The operator initiates nothing and is not notified.

Only images carrying a valid signature from the repository's key are installed. An
unsigned or wrongly signed image is refused and the machine stays on the version it has.

Containers, the data they store, and Portainer's settings are unchanged by an update.

**Decision and constraint.** §req:quality-attributes states that if the base platform
already schedules updates its schedule stands, and otherwise updates apply overnight
accepting a short reboot. The base platform does not qualify: it disables the automatic
update service it inherits and configures the remaining one to prepare updates without ever
applying them, so an untouched machine would accumulate downloaded updates it never runs.
The system therefore replaces that arrangement with one that applies and reboots, on the
overnight schedule §req:quality-attributes specifies.

The applying half is not written here. The base platform already carries a timer that
fetches the new image and reboots into it, switched off; the system turns that on, gives it
the overnight schedule, and switches the staging one off — disabled *and* masked, because
disabling alone leaves a unit anything could switch back on and masking alone leaves the
machine still reporting a staging timer among its enabled units. The update agent the base
platform inherits from Fedora CoreOS is masked for the same reason: it is already off, but
it is enabled in a preset, so anything that ever applied presets would restore a second
update agent pointing at a different source entirely.

Signature verification is required because the machine updates itself unattended from a
network location; an update channel that accepts anything is a way to own every machine
that listens to it. The verification material is placed on the machine during installation,
so the very first update is verified like every other.

The signing policy §spec:image-publication bakes into the image turns out to be necessary
and not sufficient, which cost this system a component. The update tool does not consult
that policy unless the machine was told to enforce it when it was attached to the image,
and that choice is recorded once, at attach time, rather than reconsidered on each update.
A machine attached without it pulls its nightly update with no signature check at all while
the policy sits there unread, and nothing on the machine fails or says so. Before updating,
the machine therefore asks the update tool which mode it is in and refuses to update unless
the answer is the signing policy — it reads that tool's own answer rather than re-reading
the policy file, because a second opinion about someone else's judgement is the one that
goes stale. Choosing enforcement at attach time belongs to §spec:installer-media; this
refusal is what makes its absence loud instead of silent, and it fails closed on an answer
it does not recognise for the same reason.

**Alternatives rejected.** Keeping the base platform's prepare-but-never-apply behaviour was
rejected as failing §req:sc:automatic-updates while appearing to satisfy it — the most
dangerous kind of failure, because the machine looks healthy while falling behind on fixes.
Notifying the operator was rejected by §req:quality-attributes, which states the operator
learns about problems by looking rather than by being paged.

**Tradeoffs.** Containers stop during the nightly reboot. For a machine whose workloads are
the operator's own, on a home network, this is the intended trade — §req:quality-attributes
accepts it explicitly. A reboot that lands badly is handled by
§spec:boot-health-and-rollback.

Cites §req:sc:automatic-updates, §req:sc:data-survives-updates, §req:quality-attributes,
§req:priorities.

## Boot health and rollback §spec:boot-health-and-rollback

*Status: complete* — not yet confirmed on real hardware: a rollback needs failed boots, and
the build environment has no virtualisation. One part is unconfirmed rather than merely
unobserved, and is called out under **Tradeoffs** below.

After an update, the machine checks that it reached a running state and that the Docker
engine is active. A boot that fails those checks repeatedly returns the machine to the
version it was running before the update, automatically, with no operator action. The
machine ends up serving again on the previous version.

The check deliberately does not test Portainer, or anything Portainer depends on beyond
Docker itself.

**Decision and constraint.** §req:sc:automatic-rollback requires automatic recovery from a
bad update. Neither uCore nor Fedora CoreOS beneath it carries any health-check machinery;
they keep the previous version on disk and expect a person to invoke the rollback. The
system adds the missing piece.

That piece is greenboot, a Fedora package rather than something written here. It counts
boots, reboots the machine while the count is armed and the checks fail, and invokes the
rollback when the count runs out. It arrives with no other packages, so minimality survives
it. What this system supplies is the one required check — the Docker engine is active — and
one piece of wiring greenboot cannot supply for itself.

That wiring is greenboot's own boot counter. The countdown runs in the bootloader, from a
snippet the bootloader tooling installs only when it *installs* a bootloader, never when it
updates one. A machine built as a virtual disk from this image gets it, because the
bootloader is installed from this image. A machine installed the way §spec:installer-media
describes does not: it installs Fedora CoreOS, whose bootloader was written before this
image existed, and then attaches this image without ever rewriting it. There, greenboot
would arm a counter nothing decrements and select a fallback nothing honours — no rollback
at all, on every machine an operator actually owns, while the health check runs and reports
success. The image therefore installs greenboot's own snippet through the bootloader's
documented extension point on every boot, and fails loudly on a machine that offers no such
extension point rather than reporting a rollback it does not have. It installs greenboot's
file rather than a reimplementation of it, so the countdown stays greenboot's to maintain.

The machine reaching a running state needs no check of its own. greenboot's health check
runs as part of reaching a running state, so a machine that never gets there never runs it,
never records a successful boot, and rolls back on the count alone.

The check is narrow at the operator's direction. A health check that is wrong in the strict
direction is worse than none: it rolls back working updates indefinitely, and the machine
quietly stops receiving fixes while appearing to run normally — the one failure mode nobody
would notice. Restricting the check to the system running and Docker being active catches
the failures that actually strand a headless machine, and is nearly impossible to trip by
accident.

**Alternatives rejected.** Including Portainer's responsiveness in the check was rejected on
the reasoning above: a slow start or a Portainer-side fault would be misread as a bad
operating system update. Relying on manual rollback over SSH was rejected as failing
§req:sc:automatic-rollback, and because an update that breaks networking takes SSH with
it. greenboot's own optional default health checks were rejected for the same
strict-direction reason as Portainer: they make a DNS check against a package repository a
*required* one, so a home network with flaky DNS would fail the boot and roll back a
working update — the failure this section exists to avoid, arriving through the package
meant to help. Writing the boot counter from the installer instead of the image was
rejected because it would reach only machines installed that way and would not repair
itself if the bootloader were ever rewritten.

**Tradeoffs.** An update that leaves the machine booting and Docker running, but Portainer
broken, is not caught and does not roll back. That failure is visible — the operator's
browser does not reach Portainer — and recoverable over SSH, which is what
§spec:remote-access exists for. The health-check mechanism is an addition to the base
platform rather than something it maintains, so the boot counter is a component this
project owns.

The bootloader reads that extension point later in its configuration than the position
greenboot installs its own snippet at. The countdown is expected to work from either, since
the bootloader chooses its entry after reading the whole configuration — but this is the one
behaviour in the arrangement that has not been observed on a machine, and if it is wrong
the symptom is silent: a machine that never rolls back. It is the first thing to confirm
when hardware is available.

Cites §req:sc:automatic-rollback, §req:quality-attributes, §req:priorities.

## Image publication §spec:image-publication

*Status: complete* — never yet exercised: nothing has been pushed and no image has been
published, so the build, push, sign and verify sequence is confirmed by reading the workflow
rather than by watching it run. It also cannot run until `SIGNING_SECRET` holds the private
half of the committed `cosign.pub` (see the README's Signing section); until then the signing
step fails by design.

Pushing to the default branch produces a newly built, signed, published kantainer image at
`ghcr.io/point-source/kantainer` with no manual build step. That published image is what
installed machines update themselves from, so a push is how a change reaches the machine.
A pull request builds the image but publishes nothing, so a change that breaks the build is
caught before it can reach a machine, and a fork cannot publish under this project's name.

The build runs in the repository's automation rather than on the operator's computer, so
building twice from the same repository state produces an image that behaves the same way.
The base image and the Fedora CoreOS release are pinned by digest and by version, so a
rebuild is a rebuild rather than a fresh roll of the dice. The repository's own gate refuses
a base image that is not pinned, and refuses a pin that disagrees with the recorded one —
the two are written in different files for different consumers, and drift between them would
otherwise be silent.

Signing uses a keypair whose public half is committed and whose private half lives only in a
repository secret. The signature covers the digest rather than a tag, because a tag resolves
to different content over time while the machine verifies the digest it actually pulled.
After signing, the automation verifies the new signature against the committed public key: a
key mismatch and a signature written in a format the machine cannot read are both silent at
signing time and would otherwise strand every installed machine at once.

The installer image is not published. It is produced by the operator's flash command from
the pinned Fedora CoreOS release and their configuration file.

Every pinned version has something that moves it, and the repository refuses to let a new pin
be added without one — an unwatched pin does not fail, it simply stops being current until the
day somebody needs it to be, which for the installer half means a stick built from a release
old enough not to recognise the hardware in front of it. The container pins are raised
automatically. The Fedora CoreOS release is raised automatically too, but its checksum cannot
be: no bot can hash a 1.3 GB image, so a raise lands with the previous release's checksum
beside the new version, and every offline check in the repository passes on it. A separate
check compares the pin against Fedora's own published metadata and fails the pull request until
the checksum is corrected. It is kept out of the repository's main gate deliberately — that
gate is offline so it runs anywhere, and a check needing a Fedora server would make it fail on
a train.

The installer pins are raised weekly rather than as often as the bot would offer. Neither is a
security-response path — the Fedora CoreOS release is replaced by the kantainer image minutes
after it installs, and the personalisation tool only ever runs on the operator's own machine —
so what they guard against is drift measured in months. Portainer is deliberately not slowed
down: it serves the administrative interface, and its fixes should arrive as fast as they are
offered.

**Decision and constraint.** §req:sc:push-publishes asks that a push produce both a
new published image and a new installer image with no manual step. The first half is met.
The second is not met as written, and cannot be: an installer image is only useful once it
carries the operator's account, key and password, and §req:quality-attributes forbids that
material from the public repository where the automation runs. The system therefore
publishes the image — which is what machines actually consume, and what a push is really
changing — and produces the installer locally at flash time. The operator's experience is
unchanged: one command, two inputs, per §req:constraints.

Signing is not optional. §spec:os-updates refuses unsigned images, so an unsigned build is
an image no machine will install.

**Alternatives rejected.** Publishing a partially personalised installer for the operator to
finish was rejected: the installer's customisation is written once and replaced wholesale on
a second pass, so a two-stage arrangement would discard the first stage. Publishing an
unmodified copy of the upstream installer under this project's name was rejected as
pretending to add value; pinning the upstream release and verifying it at flash time
achieves the same reproducibility honestly.

**Tradeoffs.** The published image is a large artifact rebuilt on every push, which costs
build minutes and time. Deferring installer production to flash time means the operator's
machine needs the tooling to do it, which the documentation covers.

Cites §req:sc:push-publishes, §req:quality-attributes, §req:constraints.

## Operator documentation §spec:operator-documentation

*Status: complete* — the README indexes the rebuild, flash, and verification procedures, and the
container-update guide beside them. The single flash guide covers the supported Linux and macOS
host branches, every target-safety and write-integrity outcome, and the final manual eject;
repository-owned references are checked by `just ci`.

The three procedures cover rebuilding, flashing, and confirming Portainer after first boot. The
verification guide also distinguishes a machine that stopped during installation from one still
working.

A fourth guide covers unattended container updates (§spec:container-updates). It states what
Watchtower does once a night, that it touches only containers labelled in and nothing rolls back
one it breaks, how to change its defaults and what widening the scope or moving the schedule
costs, both ways to switch it on, and the SELinux line an operator running it from Portainer
themselves will otherwise spend a day on. It says in the operator's own terms that the agent
holds root-equivalent access to the machine.

The flash procedure states the supported operator hosts and their prerequisites. For macOS it
shows how to list external physical disks, requires the full `/dev/diskN` path, explains the
ordinary refusal categories and the advanced opt-in, and presents confirmation, unmount, write,
durability, and manual eject in the order the operator experiences them. It explains Docker's
priority, the prompted Podman retry, and the difference between a failure before the write and a
failure that may have left a partial target. The Linux procedure retains its existing whole-disk
selection and Podman behavior.

`just ci` rejects documentation that names a missing repository-owned recipe, path, unit,
configuration field, or relative link. It checks references rather than prose semantics; ports,
first-boot behavior, and procedure order still require review.

**Decision and constraint.** §req:sc:three-documents requires the first three documents, and
§req:sc:watchtower-documented the fourth. The Watchtower guide is separate rather than folded
into one of the others because none of them is about a capability the operator chooses: it is
the only page that exists to be read BEFORE a decision rather than during a procedure.
The verification procedure covers failure because installation has a period in which correct
progress and a stopped machine look alike from outside. The macOS branch shares the flash guide
because both hosts expose the same commands and safety contract; separate guides would duplicate
destructive instructions and let them drift. Unmeasured durations are omitted in favor of signals
that identify each completed phase.

**Alternatives rejected.** A success-only procedure would leave installation failures ambiguous.
A separate macOS guide would duplicate one safety contract, while omitting advanced mode would
hide an intentionally available destructive path. Automated prose, port, or upstream-unit checks
were rejected because the repository cannot decide their meaning reliably.

**Tradeoffs.** Documentation written last is documentation that can be cut under pressure.
§req:priorities accepts that ranking while stating the repository is worth little without it.
Host-specific branches make the flash procedure longer, but keep the shared configuration and
first-boot sequence in one place.

Cites §req:sc:three-documents, §req:sc:watchtower-documented, §req:sc:macos-host-commands,
§req:sc:macos-ordinary-target-rules, §req:sc:macos-advanced-target,
§req:sc:macos-unmount-and-write, §req:sc:macos-runtime-choice, §req:user-stories,
§req:quality-attributes, §req:constraints, §req:priorities.