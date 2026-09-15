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
GENERATOR="${SYSTEM_FILES}/usr/libexec/kantainer/console-portainer-snippet"

# shellcheck source=/dev/null
. "${PROBE}"
# shellcheck source=/dev/null
. "${GENERATOR}"

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

### The two statements on the screen

# Only the service manager is stubbed. The probe's answer is read from a REAL
# file at STATE_FILE, written the way the probe writes it - so the parser under
# test is the parser that runs on the machine, and the end-to-end check below
# needs no second arrangement.
SERVICE_STATE=active
kantainer_systemctl() {
    printf '%s\n' "${SERVICE_STATE}"
    # systemctl is-active exits non-zero for everything but active, and prints
    # the state either way. A renderer that read the exit status instead of the
    # word would report every stopped Portainer as unknown.
    [[ "${SERVICE_STATE}" == active ]]
}

# probed <yes|no> - the answer the probe last recorded, at a fixed time so the
# assertions can name it.
CHECKED='2026-09-15 14:03:11+01:00'
probed() {
    printf 'ANSWERED=%s\nCHECKED_AT=%s\n' "$1" "${CHECKED}" > "${STATE_FILE}"
}

block() { kantainer_portainer_block; }

# shows <name> <text...> - every argument must appear in the block
shows() {
    local name="$1" rendered
    shift
    rendered="$(block)"
    local want
    for want in "$@"; do
        if [[ "${rendered}" != *"${want}"* ]]; then
            not_ok "${name} (missing: ${want})"
            return
        fi
    done
    ok "${name}"
}

# hides <name> <text...> - no argument may appear in the block
hides() {
    local name="$1" rendered
    shift
    rendered="$(block)"
    local unwanted
    for unwanted in "$@"; do
        if [[ "${rendered}" == *"${unwanted}"* ]]; then
            not_ok "${name} (present: ${unwanted})"
            return
        fi
    done
    ok "${name}"
}

# says_both <name> - the invariant under every fixture below. Two statements,
# always, agreeing or not. This is the check a "simplification" into one verdict
# has to get past.
says_both() {
    shows "$1" 'Portainer service:' "Portainer port ${PORTAINER_PORT}:"
    assert "$1 - and nothing else" test "$(block | wc -l)" = 2
}

# 1. Both agree it is there.
SERVICE_STATE=active
probed yes
says_both "a healthy machine still makes two statements"
shows "a healthy machine says the service manager is happy" 'Portainer service: active'
shows "a healthy machine says the port answered, and when it was asked" \
    "Portainer port ${PORTAINER_PORT}: answering" "${CHECKED}"

# 2. THE CASE THIS BATCH EXISTS FOR. The service manager is happy and the page
# does not load: a container that started and then wedged. A screen that
# resolved this to one verdict would agree with the machine and disagree with
# the operator, who is standing there BECAUSE it did not load.
SERVICE_STATE=active
probed no
says_both "a wedged Portainer is reported as a disagreement, not a verdict"
shows "a wedged Portainer still reports the service manager verbatim" \
    'Portainer service: active'
shows "a wedged Portainer reports the port honestly against it" \
    "Portainer port ${PORTAINER_PORT}: no answer" "${CHECKED}"

# 3. Both agree it is stopped.
SERVICE_STATE=inactive
probed no
says_both "a stopped Portainer still makes two statements"
shows "a stopped Portainer is reported by both" \
    'Portainer service: inactive' "Portainer port ${PORTAINER_PORT}: no answer"

# 4. The other disagreement: the unit gave up, something is still serving the
# port. Reporting the service manager alone would say Portainer is gone while
# the operator's browser is looking at it.
SERVICE_STATE=failed
probed yes
says_both "a failed unit whose port answers is reported as a disagreement"
shows "a failed unit is reported verbatim, not translated into stopped" \
    'Portainer service: failed'
shows "a port that answers is reported even when the unit failed" \
    "Portainer port ${PORTAINER_PORT}: answering"

### Before the first probe lands

# The timer's first run is seconds into the boot, and the renderer runs before
# it. "no answer" here would put a disagreement on the screen that nothing has
# established - during early boot, which is when someone is most likely to be
# reading it.
SERVICE_STATE=activating
rm -f "${STATE_FILE}"
says_both "a boot before the first probe still makes two statements"
shows "an unasked port says it has not been asked" \
    "Portainer port ${PORTAINER_PORT}: not checked yet"
hides "an unasked port is never reported as refusing" 'no answer'

# An answer with no time attached cannot be presented as current, because the
# whole point of the second statement is how old it is.
printf 'ANSWERED=yes\n' > "${STATE_FILE}"
shows "an answer with no time behind it is not presented as current" \
    "Portainer port ${PORTAINER_PORT}: not checked yet"

# systemd is the machine's own verdict (Â§spec:console-display says "what the
# machine's service manager says about it"), so nothing here re-derives it from
# unit properties or the journal. What it cannot answer at all is said plainly
# rather than guessed.
SERVICE_STATE=""
probed yes
shows "a service manager that says nothing is not guessed at" 'Portainer service: unknown'

### The renderer reads the probe, and the probe writes what the renderer reads

# Â§spec:console-display item 5: run the probe the way the timer would, and the
# block reflects it on the next read - no reboot, no login. The REAL writer
# against the REAL parser, over one file.
SERVICE_STATE=active
ANSWERS=yes
kantainer_probe_once
shows "a probe that was answered reaches the screen on the next read" \
    "Portainer port ${PORTAINER_PORT}: answering"

BEFORE="$(block)"
ANSWERS=no
kantainer_probe_once
shows "a probe that was refused reaches the screen on the next read" \
    "Portainer port ${PORTAINER_PORT}: no answer"
refute "the port statement moves when the answer moves" \
    test "$(block)" = "${BEFORE}"

### What the image ships, rather than what the renderer produces

SNIPPET_UNIT="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-console-portainer.service"
NETWORK_GENERATOR="${SYSTEM_FILES}/usr/libexec/kantainer/console-network-snippet"

# Beneath the platform's own output AND beneath batch 2's address lines. agetty
# version-sorts /etc/issue.d, so this is decidable here: read both filenames out
# of the two generators and sort them.
network_snippet="$(sed -n 's/^SNIPPET_NAME=//p' <(code "${NETWORK_GENERATOR}"))"
portainer_snippet="$(sed -n 's/^SNIPPET_NAME=//p' <(code "${GENERATOR}"))"

assert "the Portainer block sorts below batch 2's address block" \
    test "$(printf '%s\n%s\n' "${portainer_snippet}" "${network_snippet}" | sort -V | head -1)" \
    = "${network_snippet}"

# 30_ is the highest prefix the base image and Fedora CoreOS write. A lower one
# would interleave these lines with Ignition's instead of following them.
assert "the Portainer block sorts below every snippet the base image writes" \
    grep -qE '^SNIPPET_NAME=9[0-9]_kantainer_' <(code "${GENERATOR}")

# Lose this and the block is written correctly and never drawn: the login prompt
# keeps whatever was on it when the machine booted.
assert "rewriting the block redraws the login prompt" \
    grep -qF 'agetty --reload' <(code "${GENERATOR}")

# The platform stages the file under /run, renames it into place and relabels
# it. Writing the snippet ourselves would put a half-written block on the screen
# and reproduce machinery the base image maintains.
assert "the block is written through the platform's own atomic writer" \
    grep -qF 'write_via_tempfile' <(code "${GENERATOR}")

### Nothing on this path waits for a monitor

# Â§req:constraints: the machine has a screen and a keyboard only when the
# operator attaches them. The block is produced either way.
assert "the renderer runs on an ordinary multi-user boot" \
    grep -qF 'WantedBy=multi-user.target' "${SNIPPET_UNIT}"

for waits_for_a_person in 'StandardInput=' 'TTYPath=' 'getty' 'graphical.target'; do
    refute "the renderer does not wait for a display (${waits_for_a_person})" \
        grep -qF "${waits_for_a_person}" <(code "${SNIPPET_UNIT}")
done

# The renderer is restarted by the probe every minute and by Portainer on every
# start and stop. Portainer restarts three times in a minute before giving up,
# so systemd's default five-starts-in-ten-seconds is reachable - and a renderer
# parked in "failed" freezes the screen at a wrong value with nothing to surface
# it, because greenboot's default checks are deliberately not installed.
assert "a restarting Portainer cannot rate-limit the block into staleness" \
    grep -qE '^StartLimitIntervalSec=0' "${SNIPPET_UNIT}"

### Portainer starting, stopping or failing reaches the screen

# Â§spec:console-display: "Portainer starting, stopping or failing are all
# reflected on the screen without a reboot and without anyone logging in". The
# probe timer alone would get there within a minute; the operator who just
# restarted Portainer is watching now.
DROPIN="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-portainer.service.d/10-console.conf"

for event in ExecStartPost ExecStopPost; do
    assert "Portainer ${event} redraws the screen" \
        grep -qE "^${event}=.*kantainer-console-portainer\.service" "${DROPIN}"
done

assert "a Portainer that fails redraws the screen" \
    grep -qE '^OnFailure=kantainer-console-portainer\.service' "${DROPIN}"

# The redraw must never be able to fail Portainer or hold up its start. The `-`
# prefix makes systemd ignore the result; --no-block makes it not wait.
assert "the redraw cannot fail Portainer" \
    grep -qE '^Exec(Start|Stop)Post=-' "${DROPIN}"
assert "the redraw cannot delay Portainer" \
    grep -qF -- '--no-block' "${DROPIN}"

assert "the build enables the renderer" \
    grep -qF 'systemctl enable kantainer-console-portainer.service' \
    <(code "${REPO_ROOT}/build_files/build.sh")

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all console Portainer display checks behave as intended"
else
    echo "${failures} console Portainer display check(s) misbehaved"
    exit 1
fi
