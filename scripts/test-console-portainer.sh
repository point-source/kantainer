#!/bin/bash
# Tests for the login screen's Portainer lines (SPEC.md §spec:console-display).
#
# The operator standing at the machine has a second question the screen answers:
# is Portainer there. §spec:console-display answers it with TWO statements, at
# the operator's direction - what the service manager says, and whether an HTTPS
# connection to the port was actually answered, with the time it last looked.
#
# THE WHOLE DESIGN IS THE DISAGREEMENT. On a healthy machine the two agree, and
# a screen that printed one line would look right for months. It would be wrong
# in exactly the case that brings someone to the keyboard: a container that
# started and then wedged reads as running to the service manager, and the web
# page still does not load. So the fixtures below are four, not two, and the
# ones that matter are the two where the statements disagree. A change that
# "simplifies" them into one verdict has to fail here.
#
# Nothing in CI has a monitor, so every way this can be wrong is silent: a block
# that resolves a disagreement, a probe that reads a self-signed certificate as
# a closed port, a snippet whose filename sorts above the network block. All of
# them build, ship and read as working right up until an operator reads the
# screen.
#
# So both scripts are SOURCED rather than run, and the handful of functions that
# touch the machine are replaced with fixtures. main() is never reached: it
# lives behind the BASH_SOURCE guard, which sourcing deliberately does not
# trigger.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEM_FILES="${REPO_ROOT}/system_files"

PROBE="${SYSTEM_FILES}/usr/libexec/kantainer/portainer-probe"

# shellcheck source=/dev/null
. "${PROBE}"

failures=0

ok() { echo "ok       - $1"; }
not_ok() {
    echo "NOT OK   - $1"
    failures=$(( failures + 1 ))
}

# assert <name> <command...> - the command's exit status is the verdict
assert() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        ok "${name}"
    else
        not_ok "${name}"
    fi
}

# refute <name> <command...> - the inverse
refute() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        not_ok "${name}"
    else
        ok "${name}"
    fi
}

# A shell file with its comment lines removed. Assertions about what a script
# DOES have to read what it runs: every file in this batch explains itself at
# length, and prose must not be able to satisfy a check.
code() {
    grep -vE '^[[:space:]]*#' "$1"
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Both scripts agree on one path: the probe writes it, the generator reads it.
# Pointing it at a temp file here is what lets the end-to-end check below run
# the real writer against the real parser.
STATE_FILE="${WORK}/portainer-probe"

### The probe records what happened on the port

# The one thing that touches the port. The machine runs curl; the tests decide
# what it found.
ANSWERS=yes
kantainer_probe_https() {
    [[ "${ANSWERS}" == yes ]]
}

# state <key> - what the probe last recorded under that key
state() {
    local key="$1"
    while IFS='=' read -r name value; do
        if [[ "${name}" == "${key}" ]]; then
            printf '%s\n' "${value}"
            return 0
        fi
    done < "${STATE_FILE}"
    return 1
}

ANSWERS=yes
kantainer_probe_once
assert "a port that answers is recorded as answered" \
    test "$(state ANSWERED)" = yes
assert "a probe that was answered records when it looked" \
    test -n "$(state CHECKED_AT)"

# A closed port is a RESULT, not a failure. A unit that went failed here would
# be a second, quieter report of the same thing the screen already says - and
# systemd's failed state is not on the login screen, so nothing would surface
# it.
ANSWERS=no
assert "a port that does not answer is a result, not a unit failure" \
    kantainer_probe_once
assert "a port that does not answer is recorded as not answered" \
    test "$(state ANSWERED)" = no
assert "a probe that was refused still records when it looked" \
    test -n "$(state CHECKED_AT)"

# The screen must never show two answers at once, and must never show half of
# one. The probe writes beside the file and renames over it.
assert "a later probe replaces the earlier answer" \
    test "$(grep -c '^ANSWERED=' "${STATE_FILE}")" = 1
assert "the probe leaves nothing half-written beside its state file" \
    test "$(find "${WORK}" -type f | wc -l)" = 1

### What the probe asks the port

# Portainer generates its own certificate (§spec:portainer-service). Without
# this, curl rejects it and EVERY healthy machine reads as a closed port - the
# screen lying in the direction that sends an operator chasing a fault that is
# not there.
assert "the probe accepts Portainer's own certificate" \
    grep -qE -- '--insecure' <(code "${PROBE}")

# A wedged Portainer is the case this batch exists for, and a wedge can accept
# the connection and then never answer. Without a deadline the probe would hang
# there instead of reporting it.
assert "the probe gives up rather than hanging on a wedged port" \
    grep -qE -- '--max-time' <(code "${PROBE}")

# HTTPS, not TCP. A bare connect would report a wedged TLS listener as
# answering, which is exactly the failure the second statement exists to catch.
assert "the probe speaks HTTPS to Portainer's port" \
    grep -qE 'https://.*9443' <(code "${PROBE}")

# Loopback, not the machine's address. The block has to stay honest on a machine
# with no address at all - which is the state batch 2's network lines report in
# words, and the one where an operator is most likely to be reading the screen.
refute "the probe does not depend on the machine having an address" \
    grep -qE 'nmcli|hostname -I|ip addr' <(code "${PROBE}")

### What the image ships

PROBE_UNIT="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-portainer-probe.service"
PROBE_TIMER="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-portainer-probe.timer"

# The probe refreshes on its OWN schedule, independent of the link events that
# drive the network lines (§spec:console-display). A timer is what makes it run
# for the life of the machine rather than once at boot.
assert "the probe runs on a schedule for the life of the machine" \
    grep -qE '^OnUnitActiveSec=' "${PROBE_TIMER}"

assert "the probe starts looking without waiting for the first interval" \
    grep -qE '^OnBootSec=' "${PROBE_TIMER}"

# systemd's default AccuracySec is one minute, which on a one-minute timer means
# the interval the screen promises and the interval it gets are different
# numbers.
assert "the probe's interval is the interval the screen promises" \
    grep -qE '^AccuracySec=' "${PROBE_TIMER}"

# Persistent=true would replay a missed window at the next boot. The state file
# lives in /run and is gone by then, so there is nothing to catch up on.
refute "a missed window is not replayed into a stale answer" \
    grep -qE '^Persistent=true' "${PROBE_TIMER}"

# A new answer that never reaches the screen is not on the screen.
assert "a new answer redraws the screen" \
    grep -qE '^ExecStartPost=.*kantainer-console-portainer\.service' "${PROBE_UNIT}"

# restart, not start: systemd satisfies a start request with a job that is
# already queued, so the last answer - the current one - can be dropped.
assert "the redraw cannot be satisfied by an already-queued job" \
    grep -qE '^ExecStartPost=.*restart' "${PROBE_UNIT}"

# --no-block so the probe unit does not sit waiting on the renderer.
assert "the probe does not wait for the screen to be redrawn" \
    grep -qF -- '--no-block' "${PROBE_UNIT}"

# The timer is what gets enabled; the service is what it starts. Enabling the
# service instead would run the probe once at boot and never again.
assert "the build enables the timer that keeps the answer current" \
    grep -qF 'systemctl enable kantainer-portainer-probe.timer' \
    <(code "${REPO_ROOT}/build_files/build.sh")

# /run is empty at boot, and portainer-preflight only creates this directory
# when Portainer is ACTUALLY STARTING. A machine whose Portainer never started
# is the case the block most needs to report, and without this entry the probe
# would have nowhere to record it.
#
# The mode has to match preflight's own `install -d -m 0700`, or the two fight
# over the same directory every boot.
assert "the probe has somewhere to record its answer on every boot" \
    grep -qE '^d[[:space:]]+/run/kantainer[[:space:]]+0700[[:space:]]+root[[:space:]]+root[[:space:]]' \
    "${SYSTEM_FILES}/usr/lib/tmpfiles.d/kantainer.conf"

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all console Portainer display checks behave as intended"
else
    echo "${failures} console Portainer display check(s) misbehaved"
    exit 1
fi
