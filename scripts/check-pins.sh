#!/bin/bash
# Checks that the repository's version pins agree with each other.
#
# SPEC.md §spec:image-publication requires that a rebuild be a rebuild. That
# holds only while three things stay true, and nothing else in the repository
# notices when one stops:
#
#   - the base image is pinned by digest, not just a moving tag
#   - the Containerfile's FROM and versions.env name the same base image
#   - versions.env records the Fedora CoreOS release the installer comes from
#
# Usage: check-pins.sh [repo-root]

set -oue pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

fail() {
    echo "check-pins: $*" >&2
    exit 1
}

[[ -f "${ROOT}/Containerfile" ]] || fail "no Containerfile in ${ROOT}"
[[ -f "${ROOT}/versions.env" ]] || fail "no versions.env in ${ROOT}"

# shellcheck source=/dev/null
. "${ROOT}/versions.env"

for var in UCORE_IMAGE UCORE_TAG UCORE_DIGEST FCOS_STREAM FCOS_VERSION FCOS_ISO_SHA256 \
    PORTAINER_IMAGE PORTAINER_TAG PORTAINER_DIGEST; do
    [[ -n "${!var:-}" ]] || fail "versions.env does not set ${var}"
done

# The base image is the only FROM that is not the scratch build-context stage.
from_line="$(grep -E '^FROM ' "${ROOT}/Containerfile" | grep -v '^FROM scratch' || true)"
[[ -n "${from_line}" ]] || fail "Containerfile has no base image FROM line"
[[ "$(wc -l <<< "${from_line}")" -eq 1 ]] || fail "Containerfile has more than one base image FROM line"

from_ref="${from_line#FROM }"

case "${from_ref}" in
    *@sha256:*) ;;
    *) fail "base image is not pinned by digest: ${from_ref}
    A moving tag makes a rebuild a different image. Pin it as image:tag@sha256:..." ;;
esac

from_digest="${from_ref#*@}"
from_image_tag="${from_ref%@*}"
from_image="${from_image_tag%:*}"
from_tag="${from_image_tag##*:}"

[[ "${from_image}" == "${UCORE_IMAGE}" ]] ||
    fail "base image disagrees with versions.env
    Containerfile: ${from_image}
    versions.env:  ${UCORE_IMAGE}"

[[ "${from_tag}" == "${UCORE_TAG}" ]] ||
    fail "base tag disagrees with versions.env
    Containerfile: ${from_tag}
    versions.env:  ${UCORE_TAG}"

[[ "${from_digest}" == "${UCORE_DIGEST}" ]] ||
    fail "base digest disagrees with versions.env
    Containerfile: ${from_digest}
    versions.env:  ${UCORE_DIGEST}"

# Portainer is pulled by digest alone - skopeo refuses a reference carrying both
# a tag and a digest, so the tag beside it is documentation and the digest is the
# only thing that decides which bytes ship. A digest that is not a digest would
# quietly become a floating tag, and the image would stop being reproducible.
case "${PORTAINER_DIGEST}" in
    sha256:*) ;;
    *) fail "PORTAINER_DIGEST is not a digest: ${PORTAINER_DIGEST}
    Portainer is pulled by digest alone. Pin it as sha256:..." ;;
esac

# A malformed cosign.pub already fails closed at publish time, when the workflow
# verifies its own signature against it. Checking here buys the same answer on
# the pull request instead of after merge. It cannot detect the case that
# matters more - a key that parses but does not match SIGNING_SECRET - which
# only that publish-time verify catches.
[[ -f "${ROOT}/cosign.pub" ]] || fail "cosign.pub is missing"
openssl pkey -pubin -noout -in "${ROOT}/cosign.pub" 2> /dev/null ||
    fail "cosign.pub does not parse as a public key"

echo "check-pins: ${UCORE_IMAGE}:${UCORE_TAG} pinned by digest; Fedora CoreOS ${FCOS_STREAM} ${FCOS_VERSION}; Portainer ${PORTAINER_TAG} pinned by digest"
