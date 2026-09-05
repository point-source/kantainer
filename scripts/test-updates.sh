#!/bin/bash
# Tests for the automatic-update and boot-health arrangement
# (SPEC.md §spec:os-updates, §spec:boot-health-and-rollback).
#
# Everything this batch ships is inert until a machine boots, and every way it
# can be wrong is silent on that machine: a timer that never fires, a staging
# service left enabled beside the applying one, a health check that rolls back a
# working update because it tested something it should not have. None of that
# shows up in a build log.
#
# So these assertions read the files the image actually carries, and the parts
# of build.sh that decide what runs. They cannot prove the machine reboots at
# 03:00 - only a booted machine does that - but they catch the mistakes that
# would otherwise be found by a machine quietly not updating for months.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEM_FILES="${REPO_ROOT}/system_files"
BUILD_SH="${REPO_ROOT}/build_files/build.sh"

TIMER_DROPIN="${SYSTEM_FILES}/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/10-kantainer-overnight.conf"
SERVICE_DROPIN="${SYSTEM_FILES}/usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-kantainer.conf"

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
# DOES have to read what it runs, not what it explains: build.sh sets out at
# length why it does not install a package, and the health check sets out at
# length why it does not look at Portainer.
code() {
    grep -vE '^[[:space:]]*#' "$1"
}

# The last value systemd would read for a directive, drop-in semantics aside.
directive() {
    local file="$1" key="$2"
    grep -E "^${key}=" "${file}" 2> /dev/null | tail -n1 | cut -d= -f2- || true
}

# A systemd time span, in seconds. Deliberately narrow: it understands the forms
# this repository uses, and returns nothing for anything else, which fails the
# window assertion rather than passing it on a value nobody parsed.
timespan_seconds() {
    local span="$1"
    case "${span}" in
        *h) echo $(( ${span%h} * 3600 )) ;;
        *min) echo $(( ${span%min} * 60 )) ;;
        *s) echo "${span%s}" ;;
        '') echo 0 ;;
        *[!0-9]*) return 1 ;;
        *) echo "${span}" ;;
    esac
}

### The applying timer (§spec:os-updates)

assert "the update timer carries a kantainer drop-in" \
    test -f "${TIMER_DROPIN}"

# The base timer is OnBootSec=1h / OnUnitInactiveSec=8h. systemd ACCUMULATES
# timer triggers across drop-ins rather than replacing them, so a drop-in that
# adds OnCalendar without blanking those two leaves a machine that also updates
# an hour after every boot and every eight hours - in the middle of the day,
# which is exactly what §req:quality-attributes rules out.
assert "the drop-in clears the base timer's boot trigger" \
    grep -qxF 'OnBootSec=' "${TIMER_DROPIN}"

assert "the drop-in clears the base timer's interval trigger" \
    grep -qxF 'OnUnitInactiveSec=' "${TIMER_DROPIN}"

assert "the drop-in sets a calendar trigger" \
    grep -qE '^OnCalendar=.' "${TIMER_DROPIN}"

# The whole window - the calendar hour plus the randomised spread - has to stay
# overnight. A drop-in that sets 03:00 and inherits the base image's
# RandomizedDelaySec=2h reboots the machine as late as 05:00, and one that let
# the spread grow further would reboot it during the operator's morning.
window_name="the update window stays overnight"
on_calendar="$(directive "${TIMER_DROPIN}" OnCalendar)"
delay="$(directive "${TIMER_DROPIN}" RandomizedDelaySec)"
if [[ -z "${delay}" ]]; then
    not_ok "${window_name} (drop-in does not set RandomizedDelaySec, so the base image's 2h spread applies)"
elif ! delay_seconds="$(timespan_seconds "${delay}")"; then
    not_ok "${window_name} (RandomizedDelaySec=${delay} is not a time span this test understands)"
elif [[ ! "${on_calendar}" =~ ([0-9]{1,2}):([0-9]{2}):([0-9]{2})$ ]]; then
    not_ok "${window_name} (OnCalendar=${on_calendar} has no hh:mm:ss)"
else
    start=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))
    if [[ "${start}" -ge 0 && $(( start + delay_seconds )) -le $(( 6 * 3600 )) ]]; then
        ok "${window_name}"
    else
        not_ok "${window_name} (${on_calendar} plus ${delay} can fire after 06:00)"
    fi
fi

# Persistent=true replays a missed window at the next boot. A machine that was
# off overnight would then reboot itself in the middle of the operator's day,
# which is the one thing §req:quality-attributes rules out. A missed night is
# picked up the next night instead.
refute "the drop-in does not replay a missed window during the day" \
    grep -qiE '^Persistent=(1|yes|true|on)$' "${TIMER_DROPIN}"

# The service has no network ordering of its own. A machine that boots just
# before the window would otherwise spend its single nightly attempt on a
# network that is not up yet, and try again in 24 hours.
assert "the update service waits for the network" \
    grep -qxF 'After=network-online.target' "${SERVICE_DROPIN}"

assert "the update service pulls the network in" \
    grep -qxF 'Wants=network-online.target' "${SERVICE_DROPIN}"

### Retiring the base image's prepare-but-never-apply arrangement

assert "the build enables the applying timer" \
    grep -qE '^systemctl enable .*bootc-fetch-apply-updates\.timer' "${BUILD_SH}"

# Masking alone leaves /etc/systemd/system/timers.target.wants/ pointing at the
# unit, so the machine still reports a staging timer as enabled. Both are needed.
assert "the build disables the staging timer" \
    grep -qE '^systemctl disable .*rpm-ostreed-automatic\.timer' "${BUILD_SH}"

assert "the build masks the staging timer" \
    grep -qE '^systemctl mask .*rpm-ostreed-automatic\.timer' "${BUILD_SH}"

assert "the build masks the update agent the base image leaves installed" \
    grep -qE '^systemctl mask .*zincati\.service' "${BUILD_SH}"

assert "the build stops rpm-ostree from staging updates" \
    grep -qF 'AutomaticUpdatePolicy=none' "${BUILD_SH}"

### Signature-verified updates (§spec:os-updates)

PREFLIGHT="${SYSTEM_FILES}/usr/libexec/kantainer/update-preflight"

assert "the update preflight ships and is executable" \
    test -x "${PREFLIGHT}"

# Plumbing with no consumer is plumbing that never runs. The preflight only
# means anything if the update service refuses to start without it.
assert "the update service runs the preflight before updating" \
    grep -qxF 'ExecStartPre=/usr/libexec/kantainer/update-preflight' "${SERVICE_DROPIN}"

# The preflight's verdict comes from `bootc status`, so it can be tested for
# real: give it a bootc that says a chosen thing and assert what it does. What
# matters is the DIRECTION it fails in. bootc does not enforce the container
# signing policy unless the machine was attached with
# --enforce-container-sigpolicy, and a preflight that passed when it could not
# tell would leave every machine updating itself unsigned, forever, silently.
STUB="$(mktemp -d)"
trap 'rm -rf "${STUB}"' EXIT

# preflight_with <name> <want-exit> <bootc-exit> <bootc-stdout>
preflight_with() {
    local name="$1" want="$2" stub_exit="$3" stub_out="$4"

    cat > "${STUB}/bootc" <<STUBEOF
#!/bin/bash
cat <<'PAYLOAD'
${stub_out}
PAYLOAD
exit ${stub_exit}
STUBEOF
    chmod +x "${STUB}/bootc"

    local got=0
    PATH="${STUB}:${PATH}" "${PREFLIGHT}" > /dev/null 2>&1 || got=$?

    if [[ "${got}" -eq "${want}" ]]; then
        ok "${name}"
    else
        not_ok "${name} (wanted exit ${want}, got ${got})"
    fi
}

if [[ -x "${PREFLIGHT}" ]]; then
    preflight_with "the preflight allows an update the signing policy governs" 0 0 \
        '{"status":{"booted":{"image":{"image":{"transport":"registry","image":"ghcr.io/point-source/kantainer:latest","signature":"containerPolicy"}}}}}'

    preflight_with "the preflight refuses when nothing verifies the signature" 1 0 \
        '{"status":{"booted":{"image":{"image":{"transport":"registry","image":"ghcr.io/point-source/kantainer:latest"}}}}}'

    # An ostree remote's GPG key is a different signing arrangement from the
    # cosign key this repository publishes with. Verified by something other
    # than our policy is not verified by our policy.
    preflight_with "the preflight refuses a signing arrangement that is not ours" 1 0 \
        '{"status":{"booted":{"image":{"image":{"transport":"registry","image":"ghcr.io/point-source/kantainer:latest","signature":{"ostreeRemote":"fedora"}}}}}}'

    preflight_with "the preflight refuses when bootc cannot report status" 1 1 \
        ''

    # If a later bootc renames or moves the field, the query stops matching. The
    # only safe direction for that is refusing: updates stop and say why, rather
    # than continuing unverified while the check quietly passes everything.
    preflight_with "the preflight refuses a status shape it does not recognise" 1 0 \
        '{"status":{"booted":{"image":{"image":{"transport":"registry","image":"ghcr.io/point-source/kantainer:latest","signatureMode":"containerPolicy"}}}}}'
else
    not_ok "the preflight allows an update the signing policy governs"
    not_ok "the preflight refuses when nothing verifies the signature"
    not_ok "the preflight refuses a signing arrangement that is not ours"
    not_ok "the preflight refuses when bootc cannot report status"
    not_ok "the preflight refuses a status shape it does not recognise"
fi

### The boot health check (§spec:boot-health-and-rollback)

HEALTH_CHECK="${SYSTEM_FILES}/usr/lib/greenboot/check/required.d/50_docker_active.sh"

assert "the health check ships where greenboot requires it and is executable" \
    test -x "${HEALTH_CHECK}"

assert "the build installs greenboot" \
    grep -qE '^dnf5 -y install greenboot$' "${BUILD_SH}"

# greenboot-default-health-checks makes 01_repository_dns_check.sh a REQUIRED
# check. A home network with flaky DNS would then fail the boot and roll back a
# working update - the check wrong in the strict direction, which
# §spec:boot-health-and-rollback rejects because the machine quietly stops
# receiving fixes while appearing to run normally.
#
# Comments are stripped first, here and below. build.sh explains at length why
# that package is not installed, and a test that could not tell the explanation
# from the deed would forbid writing the explanation down.
refute "the build does not install the default health checks" \
    grep -qF 'greenboot-default-health-checks' <(code "${BUILD_SH}")

# Enabling the health check also enables greenboot-set-rollback-trigger.service
# through its Also=, which is what arms the boot counter when an update stages.
assert "the build enables the greenboot health check" \
    grep -qE '^systemctl enable .*greenboot-healthcheck\.service' "${BUILD_SH}"

assert "the health check asks about the Docker engine" \
    grep -qF 'docker.service' "${HEALTH_CHECK}"

# The narrowness is the design, not an omission. A check that failed a boot
# because Portainer was slow to start would roll back a perfectly good operating
# system update, and keep doing it. §spec:boot-health-and-rollback records that
# a Portainer-broken machine is deliberately NOT caught here: it is visible in
# the operator's browser and recoverable over SSH.
refute "the health check does not test anything above Docker" \
    grep -qiE 'portainer|9443' <(code "${HEALTH_CHECK}")

# Run it for real against a systemctl that reports what we choose.
# health_check_with <name> <want-exit> <systemctl-exit>
health_check_with() {
    local name="$1" want="$2" stub_exit="$3"

    cat > "${STUB}/systemctl" <<STUBEOF
#!/bin/bash
exit ${stub_exit}
STUBEOF
    chmod +x "${STUB}/systemctl"

    local got=0
    PATH="${STUB}:${PATH}" "${HEALTH_CHECK}" > /dev/null 2>&1 || got=$?

    if [[ "${got}" -eq "${want}" ]]; then
        ok "${name}"
    else
        not_ok "${name} (wanted exit ${want}, got ${got})"
    fi
}

if [[ -x "${HEALTH_CHECK}" ]]; then
    health_check_with "the health check passes while Docker is running" 0 0
    health_check_with "the health check fails while Docker is not running" 1 3
else
    not_ok "the health check passes while Docker is running"
    not_ok "the health check fails while Docker is not running"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all update and boot-health checks behave as intended"
else
    echo "${failures} update or boot-health check(s) misbehaved"
    exit 1
fi
