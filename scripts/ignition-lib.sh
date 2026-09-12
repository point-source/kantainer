# shellcheck shell=bash
# Reads file contents back out of a rendered Ignition config, the way Ignition
# itself would.
#
# Sourced by the tests, which assert against what the machine will actually
# receive rather than against the bytes we handed butane. Deliberately NOT
# named test-*.sh: the Justfile's `test` recipe runs every scripts/test-*.sh,
# and a library is not a test.
#
# Two things have to be undone, and both are butane's choice rather than ours:
# contents arrive as a data: URL in one of two forms, and anything past a size
# threshold is gzipped. A second copy of this decoding would drift the moment
# butane changed either, and the test that reads through the stale copy would
# fail for a reason that has nothing to do with the code under test.

kantainer_ignition_decode() {
    local source="$1"
    case "${source}" in
        "data:;base64,"*)
            printf '%s' "${source#data:;base64,}" | base64 -d
            ;;
        "data:,"*)
            local body="${source#data:,}"
            body="${body//\\/\\\\}"
            printf '%b' "${body//%/\\x}"
            ;;
        *)
            printf '%s' "${source}"
            ;;
    esac
}

# Contents of <path> in the rendered Ignition config <file>.
kantainer_ignition_file() {
    local ign="$1" path="$2" source compression
    source="$(jq -r --arg p "${path}" \
        '.storage.files[] | select(.path == $p) | .contents.source' < "${ign}")"
    compression="$(jq -r --arg p "${path}" \
        '.storage.files[] | select(.path == $p) | .contents.compression // ""' < "${ign}")"

    if [[ "${compression}" == "gzip" ]]; then
        kantainer_ignition_decode "${source}" | gzip -d
    else
        kantainer_ignition_decode "${source}"
    fi
}
