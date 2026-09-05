# kantainer

A uCore image just for hosting docker containers. Meant to be as simple to deploy as possible.

Built from [uCore](https://github.com/ublue-os/ucore)'s minimal variant and published to
`ghcr.io/point-source/kantainer`. See [REQUIREMENTS.md](REQUIREMENTS.md) for what it is for
and [SPEC.md](SPEC.md) for how it works.

## Operator documentation

- [Rebuild after a change](docs/rebuild.md) — what to edit, the gate to run, what pushing does,
  and how to tell a build published.
- [Flash the installer to a USB stick](docs/flash.md) — filling in the configuration file, the
  single flash command, and what it asks before it erases anything.
- [Confirm Portainer is up after first boot](docs/verify.md) — the two reboots, the certificate
  warning, the login page, and what to check when Portainer does not answer.

## Working on this repository

Install the tooling and run the gate:

```bash
mise install
just ci
```

`just ci` is the single gate: Justfile formatting, Containerfile and shell lint, workflow and
YAML lint, a check that the pinned base image in `Containerfile` still agrees with
`versions.env`, and every `scripts/test-*.sh`. Run it before landing anything.

`just build` builds the image locally with podman. `just --list` shows the rest.

`versions.env` pins both halves of the system: the uCore base this image is built from, and
the Fedora CoreOS release the installer media is produced from. Both are pinned so a rebuild
is a rebuild.

## Signing

Published images are signed with cosign, and the machine refuses to install an image that is
not (SPEC.md §spec:os-updates). The public key is committed as `cosign.pub` and baked into the
image's container-signing policy.

The matching private key is **not** in this repository and must never be. Publishing needs it
as a repository secret named `SIGNING_SECRET`, set once:

```bash
COSIGN_PASSWORD="" cosign generate-key-pair   # writes cosign.key and cosign.pub
gh secret set SIGNING_SECRET < cosign.key     # then commit cosign.pub, and keep cosign.key safe
```

`cosign.key` is gitignored. Until `SIGNING_SECRET` is set, the publish workflow's signing step
fails — deliberately, because an unsigned image is one no machine will install.
