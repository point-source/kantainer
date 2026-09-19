#!/bin/bash
# Tests for the container-update arrangement (SPEC.md §spec:container-updates).
#
# Every way this can be wrong is silent on the machine, and several of them are
# silent for MONTHS - which is the shape of mistake this file exists for:
#
#   - a Portainer that lost its exclusion label is a Portainer that Watchtower
#     replaces with an unsigned image from Docker Hub, then fights systemd over,
#     until the unit's start limit gives up and the machine serves nothing
#   - a Watchtower that lost its own exclusion label updates itself out of the
#     version this repository pinned, and nothing anywhere says so
#   - a run script that lost its --security-opt line is a container that cannot
#     reach the socket, reporting a permission error with no cause attached
#   - a schedule moved into the operating system's update window is a container
#     that gets deleted rather than updated, on whichever night the reboot lands
#     between Watchtower stopping it and recreating it
#   - a load unit that gained the enabled-gate is a machine where "deploy it
#     from Portainer" silently pulls from ghcr.io instead
#   - a default moved from the env file onto the command line is an operator
#     override that is accepted and ignored: Watchtower lets a flag beat its own
#     environment variable, so WATCHTOWER_LABEL_ENABLE=false would do nothing
#     and the operator would be told nothing
#
# None of that appears in a build log. These assertions read the files the image
# carries and the parts of build.sh that decide what runs. They cannot prove the
# machine updates anything - only a booted machine does that.

# Several assertions below search watchtower-run for the literal text
# `--env-file "${DEFAULTS}"`. The single quotes are there so that text is matched
# as written rather than expanded here, which is what the linter warns against.
# shellcheck disable=SC2016

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEM_FILES="${REPO_ROOT}/system_files"
BUILD_SH="${REPO_ROOT}/build_files/build.sh"

PORTAINER_RUN="${SYSTEM_FILES}/usr/libexec/kantainer/portainer-run"
WATCHTOWER_RUN="${SYSTEM_FILES}/usr/libexec/kantainer/watchtower-run"
WATCHTOWER_PREFLIGHT="${SYSTEM_FILES}/usr/libexec/kantainer/watchtower-preflight"
WATCHTOWER_UNIT="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-watchtower.service"
WATCHTOWER_LOAD_UNIT="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-watchtower-load.service"
OVERNIGHT="${SYSTEM_FILES}/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/10-kantainer-overnight.conf"
PORTAINER_UNIT="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-portainer.service"
DOCS="${REPO_ROOT}/docs/watchtower.md"
BUTANE_FRAGMENT="${REPO_ROOT}/butane/watchtower.bu.tmpl"
DEFAULTS_ENV="${SYSTEM_FILES}/usr/lib/kantainer/watchtower-defaults.env"

# The gate, written in one place here and compared against every file that names
# it. A rename that reached three of the four would otherwise ship.
GATE=/etc/kantainer/watchtower-enabled
EXCLUDE_LABEL=com.centurylinklabs.watchtower.enable=false
DOMAIN=kantainer_socket_client_t

failures=0

ok() { echo "ok       - $1"; }
not_ok() {
    echo "NOT OK   - $1"
    failures=$(( failures + 1 ))
}

assert() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        ok "${name}"
    else
        not_ok "${name}"
    fi
}

refute() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        not_ok "${name}"
    else
        ok "${name}"
    fi
}

# What a script DOES, with its explanations removed. Both run scripts discuss
# these labels and flags at length in comments, so grepping the whole file would
# pass on a script that only talks about them.
code() {
    grep -vE '^[[:space:]]*#' "$1"
}

echo "# The two containers this repository owns are out of Watchtower's reach"

assert "Portainer carries the exclusion label" \
    grep -Fq -- "${EXCLUDE_LABEL}" <(code "${PORTAINER_RUN}")

assert "Watchtower excludes itself" \
    grep -Fq -- "${EXCLUDE_LABEL}" <(code "${WATCHTOWER_RUN}")

# --pull=never on both is what keeps a digest pin meaning something. Without it
# docker run defaults to --pull=missing and a pruned store becomes a silent
# unsigned fetch by tag.
assert "Portainer still refuses to pull" \
    grep -Fq -- "--pull=never" <(code "${PORTAINER_RUN}")

assert "Watchtower refuses to pull" \
    grep -Fq -- "--pull=never" <(code "${WATCHTOWER_RUN}")

echo
echo "# Watchtower can reach the Docker socket, and by the named domain"

assert "the run script opts into the socket-client domain" \
    grep -Fq -- "label=type:${DOMAIN}" <(code "${WATCHTOWER_RUN}")

# The domain has to be one the build actually compiles. A typo here is a
# container that fails to start with a message about an invalid label.
#
# The type is not declared with a `type` line - container_domain_template()
# generates it from the prefix - so the template call is what is asserted.
assert "that domain is created by a policy module" \
    grep -rq "container_domain_template(${DOMAIN%_t}," "${REPO_ROOT}/selinux/" --include='*.te'

# The exemption itself, and the single line whose absence would leave a domain
# that exists, starts, and is denied the socket exactly like container_t.
assert "that domain is granted the Docker socket" \
    grep -rqF "container_stream_connect(${DOMAIN})" "${REPO_ROOT}/selinux/" --include='*.te'

assert "the run script mounts the Docker socket" \
    grep -Fq -- "/run/docker.sock:/var/run/docker.sock" <(code "${WATCHTOWER_RUN}")

# Portainer's domain is NOT what Watchtower runs in: that domain also owns
# Portainer's database, administrator hash and TLS key.
refute "the run script does not borrow Portainer's domain" \
    grep -Fq -- "kantainer_portainer_t" <(code "${WATCHTOWER_RUN}")

echo
echo "# Watchtower touches only what the operator labelled, and the operator can change that"

assert "the image's default scope is opt-in by label" \
    grep -Fxq "WATCHTOWER_LABEL_ENABLE=true" "${DEFAULTS_ENV}"

assert "the run script passes the image's defaults" \
    grep -Fq -- '--env-file "${DEFAULTS}"' <(code "${WATCHTOWER_RUN}")

assert "the run script passes the operator's file when there is one" \
    grep -Fq -- '--env-file "${OPERATOR}"' <(code "${WATCHTOWER_RUN}")

# Docker lets a LATER env file override an earlier one, and that is the entire
# mechanism by which the operator's file wins. Reversed, the image's defaults
# would silently beat everything the operator wrote.
defaults_line="$(grep -n -- '--env-file "${DEFAULTS}"' "${WATCHTOWER_RUN}" | head -1 | cut -d: -f1)"
operator_line="$(grep -n -- '--env-file "${OPERATOR}"' "${WATCHTOWER_RUN}" | head -1 | cut -d: -f1)"
if [[ -n "${defaults_line}" && -n "${operator_line}" && "${defaults_line}" -lt "${operator_line}" ]]; then
    ok "the operator's file is passed after the defaults, so it wins"
else
    not_ok "the operator's file is not passed after the image's defaults (defaults line ${defaults_line:-?}, operator line ${operator_line:-?})
           Docker lets a later --env-file override an earlier one. In any other
           order the operator's overrides are accepted and silently ignored."
fi

# THE GUARD FOR THE MISTAKE THAT LOOKS LIKE A TIDY-UP. Anything after the image
# reference is an argument to Watchtower, and every Watchtower flag beats the
# environment variable of the same name - so a default written there could never
# be overridden, and the operator would never be told. The image reference must
# therefore be the last argument: its line carries no continuation.
if code "${WATCHTOWER_RUN}" | grep -Eq '^[[:space:]]*"\$\{IMAGE_REF\}"[[:space:]]*$'; then
    ok "nothing follows the image, so no Watchtower flag can override the operator"
else
    not_ok "something follows the image reference in watchtower-run
           Watchtower flags beat environment variables. Put defaults in
           watchtower-defaults.env, where the operator's file can change them."
fi

echo
echo "# Nothing runs Watchtower unless the operator asked"

assert "the service is gated on the operator's file" \
    grep -Fxq "ConditionPathExists=${GATE}" "${WATCHTOWER_UNIT}"

assert "the installer writes exactly that path" \
    grep -Fq -- "path: ${GATE}" "${BUTANE_FRAGMENT}"

# The load unit deliberately has no gate: loading the image is what makes
# "deploy it yourself from Portainer" work without reaching a registry.
refute "the load unit is NOT gated" \
    grep -q "^ConditionPathExists=" "${WATCHTOWER_LOAD_UNIT}"

# The fragment is inert unless render-ignition.sh appends it, and it does so only
# for the exact string config-lib.sh permits.
assert "the renderer appends the fragment only for true" \
    grep -Fq 'KANTAINER_WATCHTOWER_ENABLED}" == "true"' "${REPO_ROOT}/scripts/render-ignition.sh"

assert "the configuration field is one the parser knows" \
    grep -Fxq "    KANTAINER_WATCHTOWER_ENABLED" "${REPO_ROOT}/scripts/config-lib.sh"

echo
echo "# A Watchtower that was asked to stop stays stopped"

# WATCHTOWER_RUN_ONCE=true is an operator override docs/watchtower.md lists, and
# the pinned Watchtower honours it by doing a single pass and exiting 0. Under
# Restart=always systemd would start it again five seconds later and keep doing
# so - continuous unattended updating on a machine whose pass outlasts
# RestartSec, and a unit in "failed" on one whose pass does not. The operator's
# setting would be accepted and silently turned into something else, which is
# the same failure shape the env-file ordering above exists to prevent.
assert "a clean exit is not restarted, so run-once means once" \
    grep -Fxq "Restart=on-failure" "${WATCHTOWER_UNIT}"

refute "the unit does not restart a Watchtower that exited cleanly" \
    grep -Fxq "Restart=always" "${WATCHTOWER_UNIT}"

# The other direction of the same line. A Watchtower killed out from under
# systemd - `docker rm --force`, an OOM kill, a daemon restart - exits non-zero,
# and nothing else on the machine would bring it back.
assert "a Watchtower that died is still restarted" \
    grep -q "^Restart=on-failure$" "${WATCHTOWER_UNIT}"

echo
echo "# Both units reach the machine"

assert "build.sh enables the service" \
    grep -Fq "systemctl enable kantainer-watchtower.service" <(code "${BUILD_SH}")

assert "build.sh enables the load unit" \
    grep -Fq "systemctl enable kantainer-watchtower-load.service" <(code "${BUILD_SH}")

assert "build.sh carries the image as an archive" \
    grep -Fq "watchtower.tar" <(code "${BUILD_SH}")

# Without it `docker run --env-file` fails, and Watchtower never starts on any
# machine that switched it on.
assert "build.sh checks the defaults file shipped" \
    grep -Fq "test -f /usr/lib/kantainer/watchtower-defaults.env" <(code "${BUILD_SH}")

echo
echo "# A second Watchtower is refused, and a first one is not"

assert "the preflight ships and is executable" \
    test -x "${WATCHTOWER_PREFLIGHT}"

# Plumbing with no consumer never runs.
assert "the unit runs the preflight before starting Watchtower" \
    grep -Fxq "ExecStartPre=/usr/libexec/kantainer/watchtower-preflight" "${WATCHTOWER_UNIT}"

# THE REFUSAL, RUN RATHER THAN READ. Everything the preflight decides comes from
# `docker ps`, so it can be given one that says a chosen thing. Each of the three
# parts below is silent when it breaks: a filter that stopped matching, or a
# self-name exclusion that stopped excluding, both leave a machine that looks
# exactly like a healthy one - either two Watchtowers racing over every container
# the operator labelled, or a unit that can never start again after its own
# restart.
STUB="$(mktemp -d)"
trap 'rm -rf "${STUB}"' EXIT

TEST_IMAGE=ghcr.io/example/watchtower:1.2.3
printf '%s\n' "${TEST_IMAGE}" > "${STUB}/watchtower-image"

# preflight_with <name> <want-exit> <names docker ps reports> [expected ancestor]
#
# The stub asserts its own --filter argument: a preflight that stopped filtering
# by image would otherwise pass every case here by accident.
preflight_with() {
    local name="$1" want="$2" names="$3" ancestor="${4:-ancestor=${TEST_IMAGE}}"

    cat > "${STUB}/docker" <<STUBEOF
#!/bin/bash
# Only \`docker ps --filter <ancestor> --format ...\` is understood here.
[[ "\$1" == ps ]] || exit 64
[[ " \$* " == *" ${ancestor} "* ]] || exit 65
cat <<'PAYLOAD'
${names}
PAYLOAD
STUBEOF
    chmod +x "${STUB}/docker"

    local got=0 out
    out="$(PATH="${STUB}:${PATH}" "${WATCHTOWER_PREFLIGHT}" "${STUB}/watchtower-image" 2>&1)" || got=$?

    if [[ "${got}" -eq "${want}" ]]; then
        ok "${name}"
    else
        not_ok "${name} (wanted exit ${want}, got ${got})
           ${out}"
    fi
}

preflight_with "a machine running no Watchtower starts one" 0 ""

# The case the whole script exists for: a Watchtower the operator deployed from
# Portainer, under a name only they chose, from the image already in the store.
preflight_with "a Watchtower under another name refuses a second one" 1 "operator-watchtower"

preflight_with "a name that merely contains ours is still another Watchtower" 1 "my-kantainer-watchtower"

# Our own container is the one the unit's `docker rm --force` deals with. If the
# exclusion stopped excluding, a restart would refuse on the strength of the
# copy it is about to replace - and the unit could never start again.
preflight_with "our own stale container is not mistaken for a second Watchtower" 0 "kantainer-watchtower"

preflight_with "ours among others still refuses" 1 "kantainer-watchtower
operator-watchtower"

# FAILING OPEN IS THE WRONG DIRECTION. A `docker ps` that cannot reach the engine
# and a `docker ps` that found nothing both produce no names, and a guard that
# cannot tell them apart starts a second Watchtower on the strength of a question
# it never got an answer to. The stub below refuses the filter it is given, which
# is how a wrong image reference or an unreachable engine reads from here.
cat > "${STUB}/docker" <<'STUBEOF'
#!/bin/bash
echo "Cannot connect to the Docker daemon" >&2
exit 1
STUBEOF
chmod +x "${STUB}/docker"

engine_status=0
engine_out="$(PATH="${STUB}:${PATH}" "${WATCHTOWER_PREFLIGHT}" "${STUB}/watchtower-image" 2>&1)" ||
    engine_status=$?

if [[ "${engine_status}" -ne 0 ]]; then
    ok "an engine that cannot be asked is refused, not waved through"
else
    not_ok "an engine that cannot be asked is waved through (exit 0)
           docker ps failing is not the same answer as no other Watchtower."
fi

assert "that refusal says the engine could not be asked" \
    grep -Fq "could not be asked" <<< "${engine_out}"

# The refusal has to name the container the operator has to go and look at.
# "One is already running" with no name sends them to `docker ps` to find out
# which, which is the sentence this message replaces.
cat > "${STUB}/docker" <<'STUBEOF'
#!/bin/bash
echo operator-watchtower
STUBEOF
chmod +x "${STUB}/docker"
refusal="$(PATH="${STUB}:${PATH}" "${WATCHTOWER_PREFLIGHT}" "${STUB}/watchtower-image" 2>&1 || true)"

assert "the refusal names the container already running" \
    grep -Fq "operator-watchtower" <<< "${refusal}"

assert "the refusal names the image it matched on" \
    grep -Fq "${TEST_IMAGE}" <<< "${refusal}"

# The argument the cases above pass is a default, not a requirement: the unit
# passes none. So the default has to be the path build.sh writes, or every test
# here would be exercising a file no machine ever reads.
assert "the preflight's default is the path build.sh writes" \
    grep -Fq 'IMAGE_FILE="${1:-/usr/lib/kantainer/watchtower-image}"' "${WATCHTOWER_PREFLIGHT}"

assert "build.sh writes that path" \
    grep -Fq "/usr/lib/kantainer/watchtower-image" <(code "${BUILD_SH}")

echo
echo "# The two update windows do not overlap"

# THE ASSERTION THAT NEEDS THE MOST EXPLAINING. The OS update window opens at
# the drop-in's OnCalendar hour and stays open for RandomizedDelaySec, then ends
# by rebooting the machine. A reboot landing between Watchtower stopping a
# container and recreating it leaves that container GONE - no restart policy
# brings back a container that no longer exists.
#
# So the requirement is not "different hours", it is "Watchtower starts after the
# OS window has closed". Both numbers are read from the files rather than written
# down here, so moving either one is what trips this.
#
# This guards the image's DEFAULT. An operator can move the hour in their own env
# file, and docs/watchtower.md tells them what the window costs if they do.
os_hour="$(sed -n 's/^OnCalendar=\*-\*-\* \([0-9]\{2\}\):.*/\1/p' "${OVERNIGHT}")"
os_jitter_h="$(sed -n 's/^RandomizedDelaySec=\([0-9][0-9]*\)h$/\1/p' "${OVERNIGHT}")"
wt_hour="$(sed -n 's/^WATCHTOWER_SCHEDULE=0 0 \([0-9][0-9]*\) .*/\1/p' "${DEFAULTS_ENV}")"

if [[ -z "${os_hour}" || -z "${os_jitter_h}" || -z "${wt_hour}" ]]; then
    not_ok "could not read both schedules (os=${os_hour:-?} jitter=${os_jitter_h:-?}h watchtower=${wt_hour:-?})
           One of the two files changed shape. Read them before trusting this."
else
    # Stripped of leading zeros: 08 and 09 are not octal here, whatever bash thinks.
    os_end=$(( 10#${os_hour} + 10#${os_jitter_h} ))
    if [[ "$(( 10#${wt_hour} ))" -gt "${os_end}" ]]; then
        ok "Watchtower at ${wt_hour}:00 starts after the OS window closes at ${os_end}:00"
    else
        not_ok "Watchtower runs at ${wt_hour}:00, inside or at the edge of the OS update window (${os_hour}:00-${os_end}:00)
           The OS window ends by rebooting. A reboot between Watchtower stopping a
           container and recreating it deletes that container outright."
    fi
fi

echo
echo "# The documented stack matches the image the machine carries"

# docs/watchtower.md gives a compose stack for operators who would rather own
# Watchtower themselves. It names a tag, and a tag that drifted from versions.env
# would send them to ghcr.io for a different Watchtower than the one already in
# Docker's store - which is the whole point of carrying the archive.
# shellcheck source=/dev/null
. "${REPO_ROOT}/versions.env"
assert "docs/watchtower.md names the pinned Watchtower" \
    grep -Fq "${WATCHTOWER_IMAGE}:${WATCHTOWER_TAG}" "${REPO_ROOT}/docs/watchtower.md"

assert "docs/watchtower.md names the domain an operator must set" \
    grep -Fq "label=type:${DOMAIN}" "${DOCS}"

# The stack the guide hands the operator must refuse to reach a registry, for the
# same reason watchtower-run passes --pull=never. Compose defaults to `missing`,
# which fetches the tag from ghcr.io the moment the carried image is not there -
# unsigned, by tag, past the digest versions.env pinned, and silently.
assert "the documented stack refuses to pull" \
    grep -Fq "pull_policy: never" "${DOCS}"

# The guide's refusal is one-directional and has to say so. The preflight runs at
# the unit's start-up, so it cannot govern a stack deployed afterwards - an
# operator told only that "a second one is refused" would deploy one on top of a
# running unit and be told nothing.
assert "the guide says to stop the unit before deploying your own" \
    grep -Fq "systemctl disable --now kantainer-watchtower" "${DOCS}"

echo
echo "# Portainer does not serve before the image it would deploy is loaded"

# "Deploy it yourself from Portainer" only avoids a registry while the image is
# in Docker's store. Portainer answering is the moment an operator can ask for
# it, so a boot that serves Portainer first is a boot where the documented stack
# falls back to ghcr.io - and pull_policy: never turns that into a failed
# deployment rather than a silent one, which is better but still not right.
assert "the loader is ordered before Portainer" \
    grep -Fxq "Before=kantainer-portainer.service" "${WATCHTOWER_LOAD_UNIT}"

# Ordering only. A load that failed must leave Portainer late, not absent:
# Portainer serving is the machine's job and Watchtower is what it can do
# without.
refute "Portainer does not depend on the Watchtower image loading" \
    grep -qE '^(Requires|Requisite|BindsTo)=.*kantainer-watchtower-load' "${PORTAINER_UNIT}"

refute "the loader does not pull Portainer in behind it" \
    grep -qE '^(Requires|Requisite|BindsTo)=.*kantainer-portainer\.service' "${WATCHTOWER_LOAD_UNIT}"

# Portainer now waits for this unit, so an unbounded wait here is a machine that
# never serves.
assert "the loader cannot block Portainer forever" \
    grep -qE '^TimeoutStartSec=[0-9]' "${WATCHTOWER_LOAD_UNIT}"

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "the container-update arrangement holds together"
else
    echo "${failures} container-update check(s) failed"
    exit 1
fi
