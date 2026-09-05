# kantainer — Specification

## Base image and composition §spec:base-image

*Status: in progress* — the derivation and wireless restoration are built; the Docker
engine, Portainer and boot-health checking are added by later work. The base is
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

*Status: not started*

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
valid signature from the repository's key is refused.

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

Cites §req:success-criteria (1, 2, 11), §req:constraints, §req:quality-attributes,
§req:priorities.

## Machine configuration §spec:machine-configuration

*Status: complete* — `kantainer.conf.example` carries the template and `just config-check`
applies the rules below. `just flash` (see §spec:installer-media) wraps the same check.

The repository carries a configuration template. The operator copies it, fills it in, and
keeps their copy out of version control. It is the only place machine-specific values
exist. `kantainer.conf.example` is the authoritative list of what it carries: a login
account, an SSH public key and the Portainer administrator password are required; a target
drive and a wireless network name and passphrase are optional.

The file is parsed rather than executed, and each value is taken literally to the end of its
line. The operator is not asked to learn shell quoting for a password.

Validation refuses when a required value is missing, when the SSH public key is not one, or
when the Portainer password is shorter than the length Portainer itself will accept without
demanding an immediate change. The refusal names the offending field and exits non-zero.
Nothing is written — not a USB stick, not a rendered configuration, not a temporary file
left behind.

**Decision and constraint.** The Portainer password is required rather than optional, which
departs from §req:success-criteria item 4 and §req:priorities, where it ranks fifth as
convenience with a fallback. The fallback no longer exists: current Portainer refuses to
create its first administrator account without a token that it prints only to its own log,
so an operator who skips the password cannot claim the account from a browser at all and
must connect over SSH to read the token. Requiring the password removes both that step and
the window during which an unclaimed administration page is exposed. The operator was
presented with the alternatives and chose this.

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

Cites §req:success-criteria (1, 4, 10), §req:constraints, §req:quality-attributes.

## Drive selection §spec:drive-selection

*Status: not started*

When the configuration file names a target drive, the installer uses it. When it does not
and the machine has exactly one drive, the installer uses that drive. When it does not and
the machine has more than one, the installer writes nothing: it lists the drives it found,
with enough detail — model, size, and serial — to tell them apart, and stops at a prompt
where the operator can select one.

The medium the installer booted from is never a candidate.

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

Cites §req:success-criteria (9), §req:quality-attributes, §req:priorities,
§req:constraints.

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

Cites §req:quality-attributes, §req:constraints, §req:success-criteria (3).

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

Mandatory access control remains enforcing on the machine as a whole. The single exemption
is Portainer's own access to the Docker control socket; see §spec:portainer-service.

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

Cites §req:problem-statement, §req:success-criteria (5), §req:quality-attributes,
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

Cites §req:success-criteria (3, 4, 5, 7), §req:constraints, §req:quality-attributes.

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
§req:success-criteria item 10 requires password logins to be refused. Refusing passwords
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

Cites §req:success-criteria (10), §req:quality-attributes, §req:constraints.

## Operating system updates §spec:os-updates

*Status: complete* — not yet confirmed on real hardware: the build environment has no
virtualisation, so the overnight reboot, the signature refusal and the survival of
container data across an update remain unobserved. The base image's arrangement was read
directly rather than assumed: `rpm-ostreed-automatic.timer` ships enabled with
`AutomaticUpdatePolicy=stage`, and `bootc-fetch-apply-updates.timer` — whose service runs
`bootc upgrade --apply` — ships present but disabled. The image switches those round and
gives the applying timer an overnight schedule.

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

Signature verification is required because the machine updates itself unattended from a
network location; an update channel that accepts anything is a way to own every machine
that listens to it. The verification material is placed on the machine during installation,
so the very first update is verified like every other.

The baked policy turns out to be necessary and not sufficient, which cost this system a
component. `bootc` does not consult `/etc/containers/policy.json` unless the machine was
attached to the image with `--enforce-container-sigpolicy`: the mode is recorded in the
deployment origin at attach time, and `bootc upgrade` inherits it without revisiting it. A
machine attached without that flag pulls its nightly update with no signature check while
the policy sits there unread, and nothing on the machine fails or says so. The update
service therefore asks `bootc` which mode it is in and refuses to update unless the answer
is the container signing policy. Passing that flag when the machine is attached belongs to
§spec:installer-media; this refusal is what makes its absence loud instead of silent.

**Alternatives rejected.** Keeping the base platform's prepare-but-never-apply behaviour was
rejected as failing §req:success-criteria item 6 while appearing to satisfy it — the most
dangerous kind of failure, because the machine looks healthy while falling behind on fixes.
Notifying the operator was rejected by §req:quality-attributes, which states the operator
learns about problems by looking rather than by being paged.

**Tradeoffs.** Containers stop during the nightly reboot. For a machine whose workloads are
the operator's own, on a home network, this is the intended trade — §req:quality-attributes
accepts it explicitly. A reboot that lands badly is handled by
§spec:boot-health-and-rollback.

Cites §req:success-criteria (6, 7), §req:quality-attributes, §req:priorities.

## Boot health and rollback §spec:boot-health-and-rollback

*Status: complete* — not yet confirmed on real hardware: a rollback needs failed boots, and
the build environment has no virtualisation. One part in particular is unconfirmed and is
called out under **Tradeoffs** below: on machines installed the way §spec:installer-media
describes, the boot counter reaches GRUB through `custom.cfg`, which is sourced later in
the bootloader's configuration than the snippet greenboot installs itself.

After an update, the machine checks that it reached a running state and that the Docker
engine is active. A boot that fails those checks repeatedly returns the machine to the
version it was running before the update, automatically, with no operator action. The
machine ends up serving again on the previous version.

The check deliberately does not test Portainer, or anything Portainer depends on beyond
Docker itself.

**Decision and constraint.** §req:success-criteria item 8 requires automatic recovery from a
bad update. Neither uCore nor Fedora CoreOS beneath it carries any health-check machinery;
they keep the previous version on disk and expect a person to invoke the rollback. The
system adds the missing piece.

That piece is greenboot, which is a Fedora package rather than something written here. It
counts boots, reboots the machine while the count is armed and the checks fail, and calls
`bootc rollback` when the count runs out. It arrives with no other packages. What this
system supplies is the one required check — the Docker engine is active — and one piece of
wiring greenboot cannot supply for itself, described below.

The machine reaching a running state needs no check of its own. greenboot's health check is
wanted by `multi-user.target`, so a machine that never gets there never runs it, never
records a successful boot, and rolls back on the count alone.

greenboot's optional default health checks are deliberately not installed. They make a
check of DNS against a package repository a *required* one, so a home network with flaky
DNS would fail the boot and roll back a working update — the strict-direction failure this
section rejects, arriving through the package that was supposed to help.

The check is narrow at the operator's direction. A health check that is wrong in the strict
direction is worse than none: it rolls back working updates indefinitely, and the machine
quietly stops receiving fixes while appearing to run normally — the one failure mode nobody
would notice. Restricting the check to the system running and Docker being active catches
the failures that actually strand a headless machine, and is nearly impossible to trip by
accident.

**Alternatives rejected.** Including Portainer's responsiveness in the check was rejected on
the reasoning above: a slow start or a Portainer-side fault would be misread as a bad
operating system update. Relying on manual rollback over SSH was rejected as failing
§req:success-criteria item 8, and because an update that breaks networking takes SSH with
it.

**Tradeoffs.** An update that leaves the machine booting and Docker running, but Portainer
broken, is not caught and does not roll back. That failure is visible — the operator's
browser does not reach Portainer — and recoverable over SSH, which is what
§spec:remote-access exists for. The health-check mechanism is an addition to the base
platform rather than something it maintains, so it is a component this project owns.

The wiring greenboot cannot supply for itself is its own boot counter. The countdown runs
in the bootloader, from a snippet the bootloader tooling installs only when it *installs* a
bootloader — never when it updates one. A machine built as a virtual disk from this image
gets that snippet, because the bootloader is installed from this image. A machine installed
the way §spec:installer-media describes does not: it installs Fedora CoreOS, whose
bootloader was written before this image existed, and then attaches this image without ever
rewriting it. On such a machine greenboot would arm a counter nothing decrements and select
a fallback nothing honours — no rollback at all, on every machine an operator actually owns,
while the health check runs and reports success. The image therefore installs greenboot's
own snippet through the bootloader's documented extension point at every boot, and fails
the unit when a machine offers no such extension point rather than reporting a rollback it
does not have.

That extension point is read later in the bootloader's configuration than the position
greenboot installs its snippet at. The countdown is expected to work from either position,
because the bootloader chooses its entry after reading the whole configuration — but this is
the one behaviour in the arrangement that has not been observed on a machine, and if it is
wrong the symptom is silent: a machine that never rolls back.

Cites §req:success-criteria (8), §req:quality-attributes, §req:priorities.

## Image publication §spec:image-publication

*Status: complete*

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

**Decision and constraint.** §req:success-criteria item 11 asks that a push produce both a
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

Cites §req:success-criteria (11), §req:quality-attributes, §req:constraints.

## Operator documentation §spec:operator-documentation

*Status: not started*

The repository documents three things, each as a procedure the operator can follow without
reconstructing anything from memory: how to rebuild after changing something, how to write
the installer to a USB stick, and how to confirm Portainer is up after first boot.

The verification procedure states what the operator should expect to see and roughly when —
including that the machine reboots twice before it serves, that browsers warn about the
certificate, and how to find the machine's address. It also states what to check when
Portainer does not answer, so that a machine that stopped part-way through installation is
distinguishable from one that is merely still working.

**Decision and constraint.** §req:success-criteria item 12 requires exactly these three
documents. The verification procedure is expanded to cover the not-yet-working case because
this system's install has a legitimate multi-minute window during which the correct
behaviour and a failure look identical from outside — see §spec:installer-media. A
verification procedure that only describes success would leave the operator guessing during
precisely the interval where guessing is likely.

The documentation is written after the system is built, per §req:priorities, so that it
describes what exists.

**Alternatives rejected.** Documenting only the success path was rejected for the reason
above. Deferring documentation entirely was rejected by §req:success-criteria item 12.

**Tradeoffs.** Documentation written last is documentation that can be cut under pressure.
§req:priorities accepts that ranking while stating the repository is worth little without
it.

Cites §req:success-criteria (12), §req:priorities.
