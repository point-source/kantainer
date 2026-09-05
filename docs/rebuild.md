# Rebuild after a change

How a change to this repository becomes a new published image, and how you know it worked.

The premise worth having first: **the published image is the product.** An installed machine
updates itself by pulling `ghcr.io/point-source/kantainer:latest` overnight, so pushing to the
default branch is how a change reaches a machine that is already running. Nothing is ever
installed onto the machine by hand.

## Once, on your own machine

```bash
mise install
```

That installs the versions of `just`, `hadolint`, `shellcheck`, `actionlint`, `yamllint`,
`cosign` and `butane` pinned in `mise.toml` — the same versions CI runs, so a green gate here
means a green gate on a pull request. The gate also uses the system's `git`, `jq`, `openssl`,
`python3` and GLib.

## 1. Change something

| To change | Edit |
| --- | --- |
| What is in the image | `Containerfile`, `build_files/build.sh` |
| Units, the boot health check, the firewall zone | `system_files/` |
| What the installer writes onto the machine | `butane/*.tmpl`, `scripts/render-ignition.sh`, `scripts/render-installer.sh` |
| The drive-selection rule | `scripts/install-to-disk` |
| The operator's flash command | `scripts/flash.sh`, `scripts/config-lib.sh` |
| Upstream versions — the uCore base, the Fedora CoreOS release, Portainer, coreos-installer | `versions.env` |
| The published image reference and build labels | `image.env` |

`versions.env` and the `Containerfile` both name the base image. They are read by different
consumers, so `just ci` cross-checks them and fails if they disagree — see
`scripts/check-pins.sh`.

## 2. Run the gate

```bash
just ci
```

This is the single gate. Run it before landing anything. It runs Justfile formatting, `hadolint`
over the `Containerfile`, `shellcheck` over every shell script in the repository, `actionlint`
over the workflows, `yamllint`, the pin check, and every `scripts/test-*.sh`.

It deliberately does **not** build the image. The base is around 1.6 GB, so the build belongs in
CI where it runs once rather than in a gate you run on every change. The failures only a build
can catch are caught by the pull request's build job.

`just --list` shows the rest of the recipes. `just fix` reformats the Justfile.

## 3. Build locally, if you want to

```bash
just build
```

Runs `podman build` and tags the result `kantainer:latest`. Optional — CI builds on every pull
request, and this is the slow part.

## 4. Push

Pushing is the whole of the release process. There is no manual build step.

- **A pull request** builds the image and publishes nothing. A change that breaks the build is
  caught before it can reach a machine, and a fork cannot publish under this project's name.
- **A push to the default branch** builds, pushes and signs. This is what changes what installed
  machines pull.

One thing that surprises people: the push trigger in `.github/workflows/build.yml` carries
`paths-ignore: ['**.md']`. **A documentation-only push does not build or publish a new image.**
Run the workflow by hand from the Actions tab (`workflow_dispatch`) if you want one anyway.

The workflow also runs daily on a schedule, which picks up Fedora's updates to the layered
packages. Updates to the base image itself arrive by bumping the pin in `Containerfile` and
`versions.env` — Renovate opens that pull request.

## 5. Where it lands

`ghcr.io/point-source/kantainer`, tagged six ways from one build:

```
latest                    latest-<date>            <date>
latest-<sha>              latest-<date>-<sha>      <date>-<sha>
```

Installed machines pull `:latest`. The other tags exist so you can name a specific build.

The image is signed with cosign after it is pushed. Signing is not optional — the machine refuses
to install an image that is not signed by this repository's key. See
[the Signing section of the README](../README.md#signing) for the key setup.

## 6. How to tell it worked

Watch the **Build and publish image** workflow run. Green through its last step is the answer.

That last step is worth knowing about. It pulls the tag `<image>:sha256-<digest>.sig`, which is
the signature attachment format that `containers/image` — and therefore the machine — actually
reads. `cosign verify` passes on both formats, so it cannot tell you the machine can read the
signature; this step can. A build that pushed successfully but signed in a format no machine
understands fails here rather than stranding every installed machine at once.

Then the change is on the registry. An installed machine picks it up on its own during its
overnight window and reboots into it. Nobody has to do anything else.
