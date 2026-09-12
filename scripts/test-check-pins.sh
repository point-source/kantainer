#!/bin/bash
# Tests for check-pins.sh.
#
# The pin check exists because the Containerfile's FROM line and versions.env
# must agree, and nothing else notices when they stop agreeing. A silent
# disagreement means an unreproducible image, or installer media built from a
# different Fedora CoreOS release than the image expects.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${REPO_ROOT}/scripts/check-pins.sh"

failures=0

# Run the check against a throwaway copy of the repo, after applying `mutate`.
# Asserts the check's exit status matches `want` (0 = pass, 1 = should fail).
expect() {
    local want="$1" name="$2" mutate="$3"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' RETURN

    cp "${REPO_ROOT}/Containerfile" "${REPO_ROOT}/versions.env" "${REPO_ROOT}/cosign.pub" "${tmp}/"
    cp -r "${REPO_ROOT}/build_files" "${tmp}/"
    ( cd "${tmp}" && eval "${mutate}" )

    local got=0
    "${CHECK}" "${tmp}" > /dev/null 2>&1 || got=1

    if [[ "${got}" -eq "${want}" ]]; then
        echo "ok       - ${name}"
    else
        echo "NOT OK   - ${name} (wanted exit ${want}, got ${got})"
        failures=$(( failures + 1 ))
    fi
}

expect 0 "accepts the repository as committed" \
    "true"

expect 1 "rejects a digest that disagrees with versions.env" \
    "sed -i 's/^UCORE_DIGEST=.*/UCORE_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000/' versions.env"

expect 1 "rejects a tag that disagrees with versions.env" \
    "sed -i 's/^UCORE_TAG=.*/UCORE_TAG=stable-19700101/' versions.env"

expect 1 "rejects a floating base tag with no digest" \
    "sed -i 's|^FROM ghcr.io/ublue-os/ucore-minimal.*|FROM ghcr.io/ublue-os/ucore-minimal:stable|' Containerfile"

# Agreement is not the same as being a digest. Both files can carry the same
# nonsense and agree perfectly, which is why the shape is checked on its own.
expect 1 "rejects a base digest that is not a digest, even when both files agree" \
    "sed -i 's|@sha256:[0-9a-f]*|@sha256:latest|' Containerfile
     sed -i 's|^UCORE_DIGEST=.*|UCORE_DIGEST=sha256:latest|' versions.env"

expect 1 "rejects a base image that disagrees with versions.env" \
    "sed -i 's/^UCORE_IMAGE=.*/UCORE_IMAGE=ghcr.io\/ublue-os\/ucore/' versions.env"

expect 1 "rejects a missing Fedora CoreOS pin" \
    "sed -i 's/^FCOS_VERSION=.*/FCOS_VERSION=/' versions.env"

expect 1 "rejects a missing signing public key" \
    "rm -f cosign.pub"

expect 1 "rejects a signing public key that is not a public key" \
    "echo 'not a key' > cosign.pub"

expect 1 "rejects a missing Portainer pin" \
    "sed -i 's/^PORTAINER_DIGEST=.*/PORTAINER_DIGEST=/' versions.env"

expect 1 "rejects a Portainer pin that is not a digest" \
    "sed -i 's|^PORTAINER_DIGEST=.*|PORTAINER_DIGEST=latest|' versions.env"

expect 1 "rejects a Portainer digest hardcoded in the build" \
    "sed -i 's|\${PORTAINER_DIGEST}|sha256:0000000000000000000000000000000000000000000000000000000000000000|' build_files/build.sh"

# The Fedora CoreOS pin is what `just flash` verifies the installer against
# (SPEC.md §spec:installer-media). A checksum that is not a checksum cannot
# refuse anything, and the refusal would arrive at the operator's USB stick.
expect 1 "rejects an ISO checksum that is not a sha256" \
    "sed -i 's|^FCOS_ISO_SHA256=.*|FCOS_ISO_SHA256=notachecksum|' versions.env"

expect 1 "rejects a missing coreos-installer pin" \
    "sed -i 's|^COREOS_INSTALLER_DIGEST=.*|COREOS_INSTALLER_DIGEST=|' versions.env"

expect 1 "rejects a coreos-installer pin that is not a digest" \
    "sed -i 's|^COREOS_INSTALLER_DIGEST=.*|COREOS_INSTALLER_DIGEST=release|' versions.env"

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all pin checks behave as intended"
else
    echo "${failures} pin check(s) misbehaved"
    exit 1
fi
