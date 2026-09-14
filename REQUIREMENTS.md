# kantainer — Requirements

## Problem statement §req:problem-statement

Running containers at home needs a machine that is boring. Today, getting one takes a
manual OS install, a package manager, a Docker setup, a Portainer deploy, and a return
visit every time patches land. Every step is a chance to do it differently than last
time, and the knowledge lives in the operator's head rather than in a file.

kantainer is a repository that builds one bootable installer image. Flash it, boot the
target machine, walk away. The machine installs itself, comes up running Docker with
Portainer's web interface already serving, and keeps its own operating system patched
from then on. The operator never types a command on the box to get there.

That first step currently assumes the operator is using Linux. On a stock Apple-silicon
Mac, configuration checking and rendering stop on shell features the built-in Bash does
not have, and flashing cannot identify or prepare a target disk. An operator who uses
macOS therefore cannot reach the same flash, boot, and walk-away outcome without replacing
parts of the documented workflow themselves.

The box does one job: run containers the operator deploys through Portainer. It is not
a desktop, not a storage appliance, and not a dashboard platform. Its second job is to
stay alive without attention — patching itself, and recovering on its own when a patch
goes wrong.

## Success criteria §req:success-criteria

1. Flashing the installer to a USB stick takes one documented command, given the built
   image and the operator's filled-in configuration file.
2. A machine booted from that stick installs itself to disk and reaches a running state
   with no keyboard input, in the single-disk case.
3. After that first boot, typing the machine's address into a browser on the same
   network reaches Portainer's web interface over HTTPS.
4. The operator can log in to Portainer without having watched the boot — either with a
   password set ahead of time in the configuration file, or by following a documented
   step to reopen account setup.
5. A container deployed through Portainer runs, and is still running after the machine
   is rebooted.
6. The machine installs operating system updates without the operator initiating them.
7. Containers, their stored data, and Portainer's own settings are unchanged after an
   operating system update.
8. When an update leaves the machine unable to come up healthy, it returns to the last
   working version on its own, with no operator action.
9. Where the target machine has more than one drive and the configuration file does not
   name one, the machine lists the drives it found with enough detail to tell them apart
   and waits, rather than erasing one.
10. The operator can reach the machine over SSH using the key named in the configuration
    file. Password logins are refused.
11. Changing a file in the repository and pushing produces a new published image and a
    new installer image, without a manual build step.
12. The repository documents three things: how to rebuild after a change, how to write
    the installer to a USB stick, and how to confirm Portainer is up after first boot.
13. On an Apple-silicon Mac running macOS 26 or newer, the operator can check a
   configuration, render it, and flash an installer through the documented commands while
   using the operating system's built-in Bash and checksum tools.
14. Given the same configuration, macOS and Linux render byte-identical machine
   specifications. Quotes, ampersands, backslashes, tabs, spaces, dollar signs, backticks,
   and text that resembles a placeholder remain literal values.
15. The ordinary macOS flash path accepts an external whole physical disk and refuses an
   internal disk, a partition, a virtual disk, a path that is not a device, and a device
   it cannot classify. Every refusal names what was rejected and happens before the target
   is unmounted or written.
16. An operator who deliberately chooses the advanced path can flash any existing block
   or character device, including a target the ordinary path refuses. The command requires
   a separate explicit opt-in, shows the stronger risk, and still requires the operator to
   type the exact full device path before it unmounts or writes anything. Regular files,
   mount points, bare device names, and nonexistent paths remain ineligible.
17. Flashing an automatically mounted macOS target first asks for confirmation and then
   unmounts it. If unmounting fails, no bytes are written. A successful command writes the
   complete installer, makes the data durable, and tells the operator to eject the device
   manually before removing it.
18. On macOS, the flash command can build the personalised installer with Docker Desktop
   or Podman. It prefers Docker when both are available, names a missing or failed runtime,
   and asks before retrying a failed Docker build with Podman. Declining the retry writes
   nothing.
19. The macOS support check runs the actual configuration, rendering, and flash command
   paths under the built-in Bash in CI. It proves the accepted and refused device cases,
   ordering before destructive actions, runtime choices, unmount failure, complete writes,
   and sync using small fixtures rather than downloading or writing the full installer.

## User stories §req:user-stories

- As the operator, I fill in one configuration file from a template in the repository,
  write it and the installer image to a USB stick with one command, and boot my machine
  from it, so that I get a working container host without typing anything on that
  machine.
- As an operator using a stock Apple-silicon Mac, I check and render that same
  configuration and create the same installer with Docker Desktop or Podman, so that I do
  not need a Linux machine or a replacement shell to prepare the stick.
- As an operator choosing a target on macOS, I see uncertain and high-risk devices refused
  before they are touched, and I can make a separate deliberate choice when I truly need
  to write to a device outside the ordinary external-disk path.
- As an operator whose USB stick macOS mounted automatically, I confirm it, let the flash
  command unmount and write it, and receive a clear instruction to eject it when the data
  is durable.
- As the operator, I open my router's device list, find the new machine's address, type
  it into a browser, and get Portainer's login page, so that I can start deploying
  containers minutes after first boot.
- As the operator, I deploy a container through Portainer's web interface and see it
  running, so that I know the host is doing its actual job.
- As the operator, I set my Portainer admin password ahead of time in the configuration
  file, so that I can leave the machine installing and log in whenever I get back to it.
- As the operator, I leave the machine alone for months and find it patched, so that I
  am not the reason it falls behind on fixes.
- As the operator, I come back after a bad update and find the machine already running
  its previous version, so that a broken release costs me nothing.
- As the operator, I put the stick into a machine with two drives without having named
  one, and I see a list of the drives it found instead of a wiped disk, so that I never
  lose data to an unattended installer.
- As the operator, I SSH in with my key on the rare occasion something needs a look, so
  that I am not locked out of my own machine.
- As the operator, I change something in the repository, push it, and get a new
  installer image built for me, so that rebuilding is not a ritual I have to remember.
- As a contributor, I see a small macOS CI check exercise the real operator commands, so
  that Linux-only shell, device, and runtime assumptions do not return without requiring a
  multi-gigabyte write in CI.
- As the operator, I read the repository's documentation and can rebuild, flash, and
  verify without reconstructing any of it from memory.

## Quality attributes §req:quality-attributes

**Unattended operation.** No keyboard input between powering the machine on and Portainer
serving. The single documented exception is the multi-drive case with no drive named,
where stopping to ask is the correct behaviour.

**Self-maintenance.** The machine applies operating system updates on its own for the
long term. If the base platform already schedules this, its schedule stands. If it does
not, updates apply automatically overnight, accepting a short reboot.

**Recoverability.** An update that leaves the machine unhealthy is undone automatically.
The operator learns about it by looking, not by being paged.

**Data durability.** Deployed containers, their volumes, and Portainer's settings survive
reboots and operating system updates.

**Confidentiality of the operator's material.** The repository is public. No SSH private
key, password, password hash, or other operator-specific value is ever committed. The
repository carries a template; the filled-in copy stays on the operator's machine.

**Security posture.** Portainer serves over HTTPS from first boot. SSH accepts the
pre-set key only and refuses password logins.

**Reproducibility.** Building twice from the same repository state produces an installer
that behaves the same way. The build runs in CI so it does not depend on the operator's
machine.

**Operator-host portability.** The existing Linux operator workflow and the supported
macOS workflow produce the same installer from the same inputs. The commands used to check,
render, and flash remain compatible with Bash 3.2, the version supplied by macOS, and treat
configuration values literally on both hosts.

**Flash safety.** On macOS, the normal workflow fails closed unless the target is known to
be an external whole physical disk. Nothing changes on the target before the operator
confirms its current identity. The advanced path is conspicuous and deliberate because it
can reach any real device node, including internal disks, partitions, and virtual devices.

**Write integrity.** Automatically mounted volumes do not prevent a confirmed flash, and
an unmount failure leaves the target unwritten. Installer images of any byte length are
written completely and synced before success is reported. The operator is responsible for
the final manual eject after the command says the device is ready.

**Compatibility checks.** CI exercises the real operator-facing paths on macOS with small,
deterministic fixtures, including values that have changed meaning across Bash releases and
the failure paths that protect a device from writes. A 3 GB installer write and a physical
USB boot are not release gates for macOS support.

**Minimality.** No desktop environment. Nothing installed that is not needed to run
containers, serve Portainer, and keep the machine patched.

**Scope of hardware.** One target profile: a 64-bit x86 machine with UEFI firmware and
onboard graphics, on a wired or wireless network that hands out addresses automatically.
Older BIOS-only machines, ARM boards, and GPU passthrough are out of scope.

## Constraints §req:constraints

- **Deployment status: greenfield.** Nothing has been built, published, or installed.
  There are no users, no running machines, and no external consumers. Breaking changes
  are free until the first release. No backwards compatibility work is warranted.
- **Governance: symphony-native** — REQUIREMENTS.md and SPEC.md are durable artifacts and
  ship in the pull request. The repository has no ADRs, RFCs, or design documents to
  convert to.
- Supported operator hosts include the existing Linux environment and Apple-silicon Macs
  running macOS 26 or newer. Intel Macs and older macOS releases are out of scope.
- Operator commands invoked by `just config-check`, `just render`, and `just flash` have a
  Bash 3.2 portability floor so they run with the Bash included in supported macOS.
- Docker Desktop and Podman are supported for local installer production on macOS. Docker
  has priority when both are present; a failed Docker attempt never falls back to Podman
  without the operator choosing that retry.
- A supported Mac needs no separately installed checksum utility. Verification uses tools
  included with macOS 26.
- macOS CI with small fixtures is sufficient release evidence. Writing the full installer
  to a physical USB stick and booting it are useful hands-on checks, but neither is a
  release gate.
- The repository is public. Operator-specific material must stay out of it.
- The image is built and published by CI on push, because the machine gets its updates by
  pulling that published image.
- Flashing takes two inputs: the built installer image, and the operator's filled-in
  configuration file. The repository ships the template; the operator keeps their copy
  untracked. One command combines them onto the USB stick.
- The configuration file is the only place machine-specific values live: the login
  account, the SSH public key, optionally the target drive, and optionally the Portainer
  admin password. Everything else belongs in the image.
- The image is built on uCore, from the Universal Blue custom image template.
- Portainer ships inside the image. It is not installed after first boot.
- The machine's network address is assigned automatically. The operator finds it from
  their router. The image assumes no fixed address.
- One operator, one machine. Fleet management, multi-tenancy, and hardware variety are
  not requirements.

**Not in scope:** any dashboard or application catalogue beyond Portainer; network
storage or file-server features; an interactive installer; a configuration server the
machine contacts at boot; internet exposure of Portainer.

## Priorities §req:priorities

**First: zero-touch boot to Portainer.** Flash, boot, browse, log in. This is the single
bar that makes the project useful at all, and it is the one the operator named. Nothing
else is worth building until a stranger's browser reaches Portainer on a machine nobody
touched. It is also the highest-confidence piece: the base platform, the image template,
and Portainer are all established parts, so the work is assembling them rather than
inventing anything. The flash step must be available from every supported operator host;
leaving Mac operators unable to check, render, or flash blocks this outcome at its first
step.

**Second: the machine keeps itself alive.** Automatic updates, automatic rollback, and
data that survives both. This is the reason to build on this base rather than a plain
Docker install, so it is close behind. Most of it should come from the platform's own
behaviour rather than custom machinery — which makes it cheap if the platform delivers,
and worth a careful look before writing anything.

**Third: not destroying data.** The multi-drive rule — name a drive, or get a list and a
halt. This ranks below first boot only because the operator's own machine has one drive,
so it costs nothing today. It moves up the moment the installer meets unfamiliar
hardware, and getting it wrong is the only failure here that is not recoverable.

The same priority governs the Mac that writes the stick. The common path accepts only a
known external whole disk and stops before touching anything uncertain. The advanced path
can intentionally cross that boundary for an operator who needs direct device access, so
its extra opt-in and exact-path confirmation carry the safety decision instead of a guess
by the command.

**Fourth: a pre-set Portainer password.** Convenience that removes a timing trap. It has
a working fallback — restart and claim the account — so it can slip without blocking
anything.

**Fifth: documentation.** Rebuild, flash, verify. Small, but the repository is worth
little to a future reader without it, and it is written last because it describes what
was actually built.
