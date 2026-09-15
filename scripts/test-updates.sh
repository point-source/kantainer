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
    grep -qF 'AutomaticUpdatePolicy=none' <(code "${BUILD_SH}")

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

preflight_with "the preflight allows an update the signing policy governs" 0 0 \
    '{"status":{"booted":{"image":{"image":{"transport":"registry","image":"ghcr.io/point-source/kantainer:latest","signature":"containerPolicy"}}}}}'

preflight_with "the preflight refuses when nothing verifies the signature" 1 0 \
    '{"status":{"booted":{"image":{"image":{"transport":"registry","image":"ghcr.io/point-source/kantainer:latest"}}}}}'

# An ostree remote's GPG key is a different signing arrangement from the cosign
# key this repository publishes with. Verified by something other than our
# policy is not verified by our policy.
preflight_with "the preflight refuses a signing arrangement that is not ours" 1 0 \
    '{"status":{"booted":{"image":{"image":{"transport":"registry","image":"ghcr.io/point-source/kantainer:latest","signature":{"ostreeRemote":"fedora"}}}}}}'

preflight_with "the preflight refuses when bootc cannot report status" 1 1 \
    ''

# If a later bootc renames or moves the field, the query stops matching. The
# only safe direction for that is refusing: updates stop and say why, rather
# than continuing unverified while the check quietly passes everything.
preflight_with "the preflight refuses a status shape it does not recognise" 1 0 \
    '{"status":{"booted":{"image":{"image":{"transport":"registry","image":"ghcr.io/point-source/kantainer:latest","signatureMode":"containerPolicy"}}}}}'

### The boot health check (§spec:boot-health-and-rollback)

HEALTH_CHECK="${SYSTEM_FILES}/usr/lib/greenboot/check/required.d/50_docker_active.sh"
HEALTH_DROPIN="${SYSTEM_FILES}/usr/lib/systemd/system/greenboot-healthcheck.service.d/10-kantainer.conf"

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

# Without this the check is nearly certain to run BEFORE Docker is up, and a
# check that is wrong in the strict direction is the failure this whole section
# exists to avoid. greenboot-healthcheck.service carries no After= of its own -
# only the implicit After=basic.target - while docker.service waits on
# network-online.target and is Type=notify. Both are WantedBy=multi-user.target,
# which orders neither against the other. The check would read Docker as
# inactive on an ordinary boot, and on the boot after an update - the one where
# greenboot has armed the counter - that means reboot, reboot, roll back a
# perfectly good update, forever.
#
# After= alone, deliberately not Requires=: if Docker genuinely fails to start,
# ordering is still satisfied and the check runs and honestly reports it red.
assert "the health check is ordered after the engine it tests" \
    grep -qxF 'After=docker.service' "${HEALTH_DROPIN}"

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

health_check_with "the health check passes while Docker is running" 0 0
health_check_with "the health check fails while Docker is not running" 1 3

### The GRUB boot counter (§spec:boot-health-and-rollback)

SEED="${SYSTEM_FILES}/usr/libexec/kantainer/greenboot-grub-seed"
SEED_UNIT="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-greenboot-grub.service"

assert "the boot-counter seed ships and is executable" \
    test -x "${SEED}"

assert "the build enables the boot-counter seed" \
    grep -qE '^systemctl enable .*kantainer-greenboot-grub\.service' "${BUILD_SH}"

# It has to run before greenboot arms the counter, or the first update after
# installation stages with a counter nothing decrements.
assert "the seed runs before the health check" \
    grep -qxF 'Before=greenboot-healthcheck.service' "${SEED_UNIT}"

# greenboot's countdown is GRUB's: 08_greenboot.cfg decrements boot_counter and
# selects the previous deployment when it runs out. bootupd assembles that
# snippet into /boot/grub2/grub.cfg only at bootloader-INSTALL time
# (`bootupctl backend install --with-static-configs`; `bootupctl update` has no
# such flag). Machines installed the way §spec:installer-media describes - the
# Fedora CoreOS installer, then attach - therefore boot a grub.cfg written
# before kantainer existed, with no counter logic in it at all. greenboot would
# arm a counter nothing decrements and choose a fallback nothing honours: no
# rollback, on every real machine, silently.
#
# These run the seed against a throwaway /boot rather than grepping it. The
# three branches are the whole point, and each one fails invisibly on a machine.
# seed_case <name> <want-exit> <grub.cfg contents>
seed_case() {
    local name="$1" want="$2" grub_cfg="$3"
    local dir
    dir="$(mktemp -d)"

    mkdir -p "${dir}/grub2"
    printf '%s\n' "${grub_cfg}" > "${dir}/grub2/grub.cfg"
    printf 'set boot_success=0\nsave_env boot_success\n' > "${dir}/snippet.cfg"

    local got=0
    "${SEED}" "${dir}/grub2" "${dir}/snippet.cfg" > /dev/null 2>&1 || got=$?

    if [[ "${got}" -ne "${want}" ]]; then
        not_ok "${name} (wanted exit ${want}, got ${got})"
    else
        SEED_DIR="${dir}"
        ok "${name}"
        return 0
    fi
    rm -rf "${dir}"
    return 1
}

# The qcow2 path: bootupd already assembled greenboot's snippet into
# grub.cfg. Writing custom.cfg too would decrement the counter TWICE per
# boot, rolling the machine back after two failed boots instead of three.
# GRUB config, not shell. $prefix and ${boot_counter} are GRUB's own
# variables and must reach the file unexpanded.
# shellcheck disable=SC2016
if seed_case "the seed leaves a bootloader that already counts boots alone" 0 \
    'insmod increment
if [ -n "${boot_counter}" -a "${boot_success}" = "0" ]; then
  decrement boot_counter
fi'; then
    refute "the seed writes nothing when the counter is already there" \
        test -e "${SEED_DIR}/grub2/custom.cfg"
    rm -rf "${SEED_DIR}"
else
    not_ok "the seed writes nothing when the counter is already there"
fi

# The real machines: FCOS's grub.cfg, whose only extension point is the
# custom.cfg that bootupd's own 41_custom.cfg sources.
# GRUB config, not shell. $prefix and ${boot_counter} are GRUB's own
# variables and must reach the file unexpanded.
# shellcheck disable=SC2016
if seed_case "the seed installs the counter through the bootloader's own seam" 0 \
    'if [ -f $prefix/custom.cfg ]; then
  source $prefix/custom.cfg
fi'; then
    assert "the seed writes greenboot's snippet, not its own copy of it" \
        grep -qxF 'set boot_success=0' "${SEED_DIR}/grub2/custom.cfg"

    # Running every boot, it must not churn /boot on a machine that is
    # already correct.
    before="$(cat "${SEED_DIR}/grub2/custom.cfg")"
    "${SEED}" "${SEED_DIR}/grub2" "${SEED_DIR}/snippet.cfg" > /dev/null 2>&1 || true
    if [[ "${before}" == "$(cat "${SEED_DIR}/grub2/custom.cfg")" ]]; then
        ok "the seed is unchanged by running twice"
    else
        not_ok "the seed is unchanged by running twice"
    fi
    rm -rf "${SEED_DIR}"
else
    not_ok "the seed writes greenboot's snippet, not its own copy of it"
    not_ok "the seed is unchanged by running twice"
fi

# No counter and no seam. Writing custom.cfg would achieve nothing, and
# exiting 0 would report a rollback this machine does not have. A failed
# unit is the only honest outcome.
seed_case "the seed fails loudly when the bootloader has no seam to use" 1 \
    'blscfg' && rm -rf "${SEED_DIR}"

# greenboot ships the snippet; if it is not there, greenboot is not there,
# and nothing about rollback works. Say which file is missing rather than
# letting cp say it.
seed_missing="$(mktemp -d)"
mkdir -p "${seed_missing}/grub2"
# shellcheck disable=SC2016
printf 'source $prefix/custom.cfg\n' > "${seed_missing}/grub2/grub.cfg"
got=0
"${SEED}" "${seed_missing}/grub2" "${seed_missing}/absent.cfg" > /dev/null 2>&1 || got=$?
if [[ "${got}" -eq 1 ]]; then
    ok "the seed fails when greenboot's snippet is missing"
else
    not_ok "the seed fails when greenboot's snippet is missing (wanted exit 1, got ${got})"
fi
rm -rf "${seed_missing}"

### Data durability across updates (§spec:os-updates)
#
# Almost all of this is already true and already guarded rather than built here.
# /var is shared across bootc deployments, so Docker's /var/lib/docker and
# Portainer's /var/lib/portainer survive an update - and a ROLLBACK, which means
# returning the operating system to its previous version does not take the
# operator's containers back with it. `bootc container lint --fatal-warnings`
# already fails the build on anything baked into /var without a tmpfiles entry,
# which is the change that would break this.
#
# The one thing nothing else asserts is the tmpfiles entry itself. Content baked
# into /var is unpacked only from the image a machine INSTALLED, never from a
# later one, so without this line a machine that updated into a new image would
# come up with no /var/lib/portainer and Portainer would start over with no
# settings and no administrator - §req:sc:data-survives-updates, broken by an
# update, which is the case this batch exists to keep working.
assert "Portainer's data directory is recreated on machines that updated into this image" \
    grep -qE '^d[[:space:]]+/var/lib/portainer[[:space:]]' \
    "${SYSTEM_FILES}/usr/lib/tmpfiles.d/kantainer.conf"

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all update and boot-health checks behave as intended"
else
    echo "${failures} update or boot-health check(s) misbehaved"
    exit 1
fi
