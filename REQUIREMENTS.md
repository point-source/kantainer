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

## User stories §req:user-stories

- As the operator, I fill in one configuration file from a template in the repository,
  write it and the installer image to a USB stick with one command, and boot my machine
  from it, so that I get a working container host without typing anything on that
  machine.
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
inventing anything.

**Second: the machine keeps itself alive.** Automatic updates, automatic rollback, and
data that survives both. This is the reason to build on this base rather than a plain
Docker install, so it is close behind. Most of it should come from the platform's own
behaviour rather than custom machinery — which makes it cheap if the platform delivers,
and worth a careful look before writing anything.

**Third: not destroying data.** The multi-drive rule — name a drive, or get a list and a
halt. This ranks below first boot only because the operator's own machine has one drive,
so it costs nothing today. It moves up the moment the installer meets unfamiliar
hardware, and getting it wrong is the only failure here that is not recoverable.

**Fourth: a pre-set Portainer password.** Convenience that removes a timing trap. It has
a working fallback — restart and claim the account — so it can slip without blocking
anything.

**Fifth: documentation.** Rebuild, flash, verify. Small, but the repository is worth
little to a future reader without it, and it is written last because it describes what
was actually built.
