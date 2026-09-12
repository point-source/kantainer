#!/bin/bash
# Every pin in versions.env must have something that moves it.
#
# THE DRIFT THIS CATCHES, because it already happened once. versions.env started
# with two pins and grew to four as later work added Portainer, the Fedora CoreOS
# installer release and the tool that personalises it. Renovate's configuration
# was extended for one of them. The other two sat unwatched, and nothing in the
# repository noticed - an unwatched pin does not fail, it just quietly stops being
# current until someone flashes a stick from a year-old installer.
#
# So this asserts the invariant rather than today's list: every pin family in
# versions.env is either named in Renovate's configuration, or carries a recorded
# reason for not being.
#
# It reads text, not JSON5 - nothing in this repository's toolchain parses JSON5,
# and a name appearing in that file at all is a deliberate act either way. It
# cannot tell you the configuration is VALID; only that no pin was forgotten.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS="${REPO_ROOT}/versions.env"
RENOVATE="${REPO_ROOT}/.github/renovate.json5"

failures=0

ok() { echo "ok       - $1"; }
not_ok() {
    echo "NOT OK   - $1"
    failures=$(( failures + 1 ))
}

[[ -f "${VERSIONS}" ]] || { echo "no versions.env" >&2; exit 1; }
[[ -f "${RENOVATE}" ]] || { echo "no .github/renovate.json5" >&2; exit 1; }

# Watched somewhere other than versions.env, with the reason. UCORE_* is the base
# image: Renovate rewrites the Containerfile's FROM line natively, and
# check-pins.sh fails the pull request until versions.env is brought into line -
# which is the arrangement, not an oversight.
declare -A EXEMPT=(
    [UCORE]="Renovate rewrites Containerfile's FROM; check-pins.sh forces versions.env to follow"
)

# A pin family is anything with a _IMAGE= line, plus Fedora CoreOS, which is a
# release rather than an image and so has no _IMAGE= line to find.
mapfile -t families < <(
    {
        grep -oE '^[A-Z][A-Z0-9_]*_IMAGE=' "${VERSIONS}" | sed 's/_IMAGE=$//'
        grep -qE '^FCOS_VERSION=' "${VERSIONS}" && echo FCOS
    } | sort -u
)

[[ "${#families[@]}" -gt 0 ]] || not_ok "found no pins at all in versions.env - has it moved?"

for family in "${families[@]}"; do
    if [[ -n "${EXEMPT[${family}]:-}" ]]; then
        if grep -q "${family}" "${RENOVATE}"; then
            ok "${family} is exempt and the reason is recorded in Renovate's configuration"
        else
            not_ok "${family} is exempt from versions.env watching (${EXEMPT[${family}]}) but Renovate's configuration never mentions it, so the next reader cannot tell that was deliberate"
        fi
        continue
    fi

    if grep -q "${family}_" "${RENOVATE}"; then
        ok "${family} is watched by Renovate"
    else
        not_ok "${family} is pinned in versions.env and nothing moves it
           Add a custom manager to .github/renovate.json5, or record here why
           this pin does not need one. An unwatched pin fails silently: it
           simply goes stale until the day someone needs it to be current."
    fi
done

# The Fedora CoreOS checksum is the one pin Renovate CANNOT complete, so the
# network check that catches the half-done bump has to exist and has to run.
if grep -q 'check-installer-pin' "${REPO_ROOT}/.github/workflows/ci.yml"; then
    ok "the Fedora CoreOS checksum check runs in CI"
else
    not_ok "nothing runs check-installer-pin in CI - a Renovate bump of FCOS_VERSION would land with the previous release's checksum and every offline check would pass"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "every pin in versions.env has something that moves it"
else
    echo "${failures} pin coverage check(s) failed"
    exit 1
fi
