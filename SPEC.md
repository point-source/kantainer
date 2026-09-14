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

Cites §req:success-criteria (1, 2, 11), §req:constraints, §req:quality-attributes,
§req:priorities.

## Operator-host support §spec:operator-host-support

*Status: not started*

The operator can run `just config-check`, `just render`, and `just flash` on the existing
Linux environment and on an Apple-silicon Mac running macOS 26 or newer. The complete path
behind those commands works with the Bash 3.2 supplied by macOS; the operator does not
install another shell. An unsupported operating system is refused with a message that names
the unsupported platform before a target device is changed.

Given the same repository state and configuration, Linux and macOS accept and refuse the
same configuration values and render byte-identical machine specifications. Quotes,
ampersands, backslashes, tabs, spaces, dollar signs, backticks, and text that resembles a
template placeholder remain literal. Replacement text is never interpreted as syntax,
matched again recursively, or changed by a later placeholder replacement. Configuration
checking continues to reject duplicate fields exactly, including when the first occurrence
has an empty value.

The Fedora CoreOS installer is verified against the repository's pinned checksum on both
hosts. A supported Mac uses checksum facilities supplied with the operating system, while
preserving the existing behavior for valid downloads, corrupt downloads, and corrupt cached
copies; macOS support requires no separate checksum package.

On macOS, local installer personalisation works with Docker Desktop or Podman. Docker is
chosen when both are usable, and Podman is chosen when Docker is absent. If Docker is
present but its personalisation attempt fails while Podman is available, the failure is
named and the operator chooses whether to retry with Podman. Declining, reaching end of
input, or a failed Podman attempt ends the command without touching the target. Linux keeps
its established Podman behavior.

A pull request runs a focused macOS compatibility check through the real operator commands
and the operating system's built-in Bash. It covers configuration, byte-identical rendering,
checksum verification, runtime choice, and the flash flow with small controlled inputs. The
broader Linux test suite may retain newer Bash features because it validates the image and
installed-machine behavior as well as operator commands; the Bash 3.2 floor applies to the
operator-facing paths and everything they invoke.

**Decision and constraint.** The existing shared configuration, rendering, installer-fetch,
and flash behavior remains one contract across hosts, with host differences confined to the
capabilities the operating system supplies. This extends the current architecture because
§req:success-criteria requires the same documented workflow on a stock supported Mac, and
§req:quality-attributes requires the two hosts to produce the same installer from the same
inputs. A compatibility claim that covered only the top-level scripts would still fail as
soon as a command reached a newer shell feature or a Linux-only utility underneath them.

**Alternatives rejected.** Requiring a newer Bash on macOS was rejected because it adds a
replacement shell before the promised one-command workflow can begin. Executing the
configuration as shell input was rejected because operator values include shell syntax and
secrets. Shell pattern replacement and general-purpose text substitution were rejected for
operator values because their replacement syntax changes across Bash versions and gives
special meaning to characters the configuration contract declares literal. Requiring one
container runtime on every host was rejected because supported Mac operators commonly have
either Docker Desktop or Podman. Porting the complete Linux suite to Bash 3.2 was rejected
because its installed-machine checks are outside the operator-host boundary and a focused
Mac check exercises the compatibility promise directly.

**Tradeoffs.** Supporting the operating system's built-in tools leaves a small amount of
host-specific behavior to maintain and makes two CI environments part of the release gate.
The focused macOS check does not prove a multi-gigabyte download, a physical write, or a
boot. The Docker-to-Podman retry needs operator input, but it keeps one runtime's failure
from silently changing the tool that handles the operator's personalised installer.

**User-level verification.** On a supported Mac with no replacement shell or checksum
package, the operator checks and renders a configuration containing every literal character
and placeholder-shaped value named above, and obtains the same bytes as the Linux run. With
small installer fixtures, a contributor observes the Docker-only, Podman-only, Docker-first,
accepted-retry, declined-retry, corrupt-download, and corrupt-cache outcomes through the real
commands; the pull request's macOS check repeats those paths under the built-in Bash.

Cites §req:success-criteria (13, 14, 18, 19), §req:user-stories,
§req:quality-attributes (Operator-host portability, Compatibility checks), §req:constraints.

## Flash target safety and write integrity §spec:flash-target-safety

*Status: not started*

On Linux, the flash command preserves its existing target rule: it accepts a whole disk,
including an internal disk, after showing its current identity and receiving exact-path
confirmation. On macOS, the ordinary path accepts only an external whole physical disk. It
refuses an internal disk, a partition, a disk image or other virtual disk, a path that is not
a device, a bare device name, a mount point, an unclassifiable device, and an unknown host
platform. Every refusal names what was rejected and occurs before unmounting or writing.

The operator can make a separate advanced choice to target any existing block or character
device node, including an internal disk, partition, or virtual device that the ordinary
macOS path refuses. This path announces that the safety classification has been bypassed and
expands the possible loss to any data reachable through the chosen device. It still refuses
regular files, mount points, bare names, nonexistent paths, and anything that is not a device
node. The advanced choice does not weaken any confirmation, ordering, or write-integrity
rule.

The target is classified once before installer preparation and again immediately before
confirmation, so a removed device or a path whose identity changed during a download is not
described from stale information. The final prompt shows the current path, model, size, and
risk classification, and proceeds only when the operator types the exact full path they
supplied. A refusal, a different answer, or end of input does not unmount or write the
target.

After exact confirmation, macOS unmounts every volume on the target before opening it for a
write. An unmount failure ends the command without writing any image bytes. When the
personalised image length is divisible by 4 KiB, the command uses macOS's faster unbuffered
device interface; for every other length it uses the buffered interface so the final partial
device sector is written completely. The confirmed identity remains the operator's original
device path regardless of the interface selected for the write.

The command writes every image byte and makes the data durable before reporting the stick
ready. A write or durability failure exits non-zero, never reports success, and warns that a
write which had begun may have left the target incomplete. A successful macOS write tells
the operator to eject the target manually before removing it; failure or success does not
trigger an automatic eject.

**Decision and constraint.** macOS uses positive classification for its ordinary path and
a conspicuous override for broader device access. §req:priorities identifies erasing the
wrong disk as the only unrecoverable failure in the workflow, while §req:success-criteria
requires an intentional escape hatch for real device nodes. The exact-path prompt remains
the last gate because no local device metadata can distinguish a disposable USB stick from
an external backup drive. The adaptive write interface was chosen because
§req:quality-attributes requires byte-complete writes for images of any length, while an
aligned image can safely use the substantially faster macOS path.

**Alternatives rejected.** Applying Linux's accept-any-whole-disk rule to ordinary macOS
flashing was rejected because a stock Mac can identify internal, external, physical, and
virtual devices and the safety priority calls for refusing known high-risk categories.
Removing the advanced path was rejected because operators need controlled access to real
devices outside that common case. Always using the unbuffered interface was rejected because
a partial final sector can fail after the target has already been overwritten. Always using
the buffered interface was rejected because it makes every large write slower when aligned
images can take the fast path without weakening integrity. Automatic eject was rejected in
favor of an unambiguous durable-write result followed by a documented operator action.

**Tradeoffs.** The ordinary macOS rule cannot tell a USB installer from an external backup,
so exact confirmation still carries a destructive choice. The advanced path deliberately
permits the internal system disk and other dangerous device nodes, giving a local operator
with write privileges the ability to erase them. Reclassification narrows device-name reuse
but cannot prevent a physical swap after the operator confirms. Manual eject adds one step
after success. Unaligned images take the slower path to preserve their final bytes.

**User-level verification.** On macOS, the operator lists external physical disks, supplies
a `/dev/diskN` whole-disk path, sees its current identity, types that exact path, and observes
confirmation before unmount, a complete write, durability, and the manual-eject instruction.
The same path refuses an internal disk, partition, virtual disk, mount point, regular file,
bare name, nonexistent path, and incomplete device facts without an unmount or write. A
disposable virtual device proves the advanced opt-in, unmount-failure, aligned unbuffered,
unaligned buffered, partial-write, durability-failure, and successful main-flow outcomes.
The existing Linux whole-disk checks remain green, and small macOS fixtures exercise the
same ordering in CI without exposing a real disk.

Cites §req:success-criteria (1, 15, 16, 17, 19), §req:user-stories,
§req:quality-attributes (Flash safety, Write integrity, Compatibility checks),
§req:constraints, §req:priorities.

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
unattended installation §req:success-criteria item 2 asks for. The medium is identified from
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
the build environment has no virtualisation. One part is unconfirmed rather than merely
unobserved, and is called out under **Tradeoffs** below.

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
§req:success-criteria item 8, and because an update that breaks networking takes SSH with
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

Cites §req:success-criteria (8), §req:quality-attributes, §req:priorities.

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

*Status: in progress* — the Linux rebuild, flash, and verification procedures exist and are
indexed from the README; the flash procedure does not yet cover the supported macOS path.

Three procedures the operator can follow without reconstructing anything from memory: how to
rebuild after changing something, how to write the installer to a USB stick, and how to confirm
Portainer is up after first boot. The third also states what to check when Portainer does not
answer, so that a machine which stopped part-way through installation is distinguishable from one
that is merely still working.

The flash procedure states the supported operator hosts and their prerequisites. For macOS it
shows how to list external physical disks, requires the full `/dev/diskN` path, explains the
ordinary refusal categories and the advanced opt-in, and presents confirmation, unmount, write,
durability, and manual eject in the order the operator experiences them. It explains Docker's
priority, the prompted Podman retry, and the difference between a failure before the write and a
failure that may have left a partial target. The Linux procedure retains its existing whole-disk
selection and Podman behavior.

`scripts/test-docs.sh`, which `just ci` runs, fails when the documentation names a `just` recipe,
a repository path, a `kantainer-*` unit, a configuration field or a relative link this repository
no longer has. It decides names, not meaning: a procedure whose steps have gone stale while every
name in it still resolves passes. Ports and first-boot behaviour are checked by reading, because
nothing in the build environment can reach a machine.

**Decision and constraint.** §req:success-criteria item 12 requires exactly these three documents.
The verification procedure is expanded to cover the not-yet-working case because this system's
install has a legitimate multi-minute window during which correct behaviour and failure look
identical from outside — see §spec:installer-media. A procedure that only describes success would
leave the operator guessing during precisely the interval where guessing is likely.

The macOS instructions live in the same flash procedure because §req:success-criteria item 13
promises the same three commands on both supported hosts. A separate Mac guide would duplicate the
configuration and first-boot contract and allow the destructive steps to drift between documents.

The documentation is written after the system is built, per §req:priorities, so that it describes
what exists. That ordering changed what shipped, in one way worth recording: the first-boot
sequence has never been watched on hardware, for the reason §spec:installer-media gives. Every
claim in the verification procedure is therefore traced to the code path that produces it, and the
procedure states no durations at all — only the signal that ends each phase. Telling an operator
"about two minutes" when nobody has held a stopwatch would be worse than telling them nothing,
because that guess is what decides them the machine is broken.

**Alternatives rejected.** Documenting only the success path was rejected for the reason above.
Deferring documentation entirely was rejected by §req:success-criteria item 12. Stating expected
durations was rejected as unmeasured — an invented number fails the operator exactly where the
procedure is supposed to help. Checking the documentation's prose, ports or upstream unit names
was rejected: none is decidable from what this repository holds, and a check that wrongly passes
is worse than no check.

A separate macOS flash guide was rejected because the one-command workflow has one safety
contract and should have one authoritative procedure. Presenting only the ordinary path was
rejected because the advanced device override is intentionally available and too destructive to
leave discoverable only from command output.

**Tradeoffs.** Documentation written last is documentation that can be cut under pressure.
§req:priorities accepts that ranking while stating the repository is worth little without it.
Host-specific branches make the flash procedure longer, but keep the shared configuration and
first-boot sequence in one place.

**User-level verification.** Starting from the README on either supported host, an operator can
find the flash procedure, install only the named prerequisites, identify an eligible target, run
the command, predict every prompt and target mutation, and follow the success or failure guidance
without consulting source code. Documentation checks prove that every referenced command, path,
configuration field, unit, and link still exists; a semantic review follows both host branches
against §spec:operator-host-support and §spec:flash-target-safety.

Cites §req:success-criteria (12, 13, 15, 16, 17, 18), §req:user-stories,
§req:quality-attributes, §req:constraints, §req:priorities.
