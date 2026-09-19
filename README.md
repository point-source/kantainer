# kantainer

A uCore image just for hosting docker containers. Meant to be as simple to deploy as possible.

Built from [uCore](https://github.com/ublue-os/ucore)'s minimal variant and published to
`ghcr.io/point-source/kantainer`. See [REQUIREMENTS.md](REQUIREMENTS.md) for what it is for
and [SPEC.md](SPEC.md) for how it works.

## Operator documentation

- [Rebuild after a change](docs/rebuild.md) — what to edit, the gate to run, what pushing does,
  and how to tell a build published.
- [Flash the installer to a USB stick](docs/flash.md) — the Linux and Apple-silicon macOS paths,
  target selection, the single flash command, and every step that can stop or alter the disk.
- [Confirm Portainer is up after first boot](docs/verify.md) — the two reboots, the address on the
  machine's own login screen, the certificate warning, the login page, and what to check when
  Portainer does not answer.
- [Keep your containers updated](docs/watchtower.md) — what Watchtower does when it is on, what
  it never touches, the two ways to switch it on, and the one line that matters if you run it
  from Portainer yourself.
- [Reach the machine from anywhere](docs/tailscale.md) — joining your Tailscale network from the
  configuration file, what an auth key costs you when it expires, advertising routes and an exit
  node, and what you give up by putting Portainer on the tailnet alone.

## Working on this repository

Install the tooling and run the gate:

```bash
mise install
just ci
```

`just ci` is the single gate: Justfile formatting, Containerfile and shell lint, workflow and
YAML lint, a check that the pinned base image in `Containerfile` still agrees with
`versions.env`, and every `scripts/test-*.sh`. Run it before landing anything.

Pull requests also run `just test-macos-compat` through the Bash built into macOS 26 on an
Apple-silicon runner. It checks the real configuration, rendering and flash commands with small
fixtures and compares the rendered bytes with Linux; it does not download the full installer or
write a physical disk.

`just build` builds the image locally with podman. `just --list` shows the rest.

`versions.env` pins both halves of the system: the uCore base this image is built from, and
the Fedora CoreOS release the installer media is produced from. Both are pinned so a rebuild
is a rebuild.

## Signing

Published images are signed with cosign, and the machine refuses to install an image that is
not (SPEC.md §spec:os-updates). The public key is committed as `cosign.pub` and baked into the
image's container-signing policy.

The matching private key is **not** in this repository and must never be. It lives in one place
only: a repository secret named `SIGNING_SECRET`.

### Creating the signing key

Do this **on a machine you control**, not in a build agent or a throwaway checkout. This keypair
is the project's root of trust: every machine you ever install decides whether to accept an
update by checking it.

```bash
cd <this repository>
rm -f cosign.key cosign.pub                   # replacing an existing pair? clear it out first
COSIGN_PASSWORD="" cosign generate-key-pair   # writes cosign.key and cosign.pub here
gh secret set SIGNING_SECRET < cosign.key     # the private half, into the repository secret
git add cosign.pub && git commit -m "chore(signing): rotate the image signing key"
```

Then put `cosign.key` somewhere you will still have it in two years — a password manager is
fine — and delete the working copy. `cosign.key` is gitignored, so it will not be committed by
accident, but nothing stops you from losing it.

`COSIGN_PASSWORD=""` creates an unencrypted private key on purpose: CI has to use it
unattended, so there is nobody to type a passphrase. That is why where you keep the file
matters.

### If the private key is lost

Generate a new pair with the steps above and commit the new `cosign.pub`. Nothing else needs to
change — but be aware of what it costs once machines exist in the field: an installed machine
carries a copy of the public key from the day it was flashed, so after a rotation it will
**refuse every update** rather than accept images signed by the new key. Those machines have to
be reflashed. Before the first machine is installed, rotating costs nothing.

Until `SIGNING_SECRET` is set, the publish workflow's signing step fails — deliberately, because
an unsigned image is one no machine will install.

## License

[Apache-2.0](LICENSE), matching [uCore](https://github.com/ublue-os/ucore) and the wider
Universal Blue project this image is built from.
