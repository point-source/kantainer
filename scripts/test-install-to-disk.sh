#!/bin/bash
# Tests for the first-stage installer: the drive rule (SPEC.md
# §spec:drive-selection) and the console password's conversion into the form the
# machine stores (SPEC.md §spec:console-password).
#
# REQUIREMENTS.md §req:priorities ranks not destroying data third and notes it
# is the only failure in this system that is not recoverable. Everything else
# here can be fixed by reflashing; a wiped drive cannot. These tests exist to
# make the rule provable without a machine and two disks to lose.
#
# The script is SOURCED rather than run, and the two functions that touch real
# hardware - the disk list and the boot medium - are replaced with fixtures.
# Nothing below can reach coreos-installer: that call lives in main(), which
# sourcing deliberately does not run.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
. "${REPO_ROOT}/scripts/install-to-disk"

failures=0

ok() { echo "ok       - $1"; }
not_ok() {
    echo "NOT OK   - $1"
    failures=$(( failures + 1 ))
}

# lsblk's own shape, so the jq filter under test is the one that runs on the
# machine. zram is included on purpose: Fedora CoreOS carries a zram swap
# device and lsblk reports its type as "disk", so a rule that trusted the type
# alone would count RAM as a drive and stop a single-disk machine at a prompt.
disks_json() {
    local out='{"blockdevices":[' first=1 spec
    for spec in "$@"; do
        IFS='|' read -r name model size serial <<< "${spec}"
        [[ "${first}" -eq 1 ]] || out+=','
        first=0
        out+=$(jq -cn --arg n "${name}" --arg m "${model}" --arg s "${size}" --arg r "${serial}" \
            '{name:$n, type:"disk", model:(if $m == "" then null else $m end),
              size:$s, serial:(if $r == "" then null else $r end)}')
    done
    out+=']}'
    printf '%s\n' "${out}"
}

# Every fixture carries the USB stick the installer booted from, because that is
# what a real machine looks like: the medium is always attached while the rule
# runs.
BOOT_DISK=/dev/sdz
kantainer_boot_disk() { printf '%s\n' "${BOOT_DISK}"; }

# $1 = drive named in the configuration (empty for none)
# $2 = what the operator types at the prompt (empty for none typed)
# rest = disk fixtures, "name|model|size|serial"
select_drive() {
    local target="$1" typed="$2"
    shift 2
    local json
    json="$(disks_json "$@")"
    kantainer_list_disks() { printf '%s\n' "${json}"; }
    # Nothing typed means nobody is at the console: the prompt reads EOF at
    # once, which is the case that must write nothing.
    if [[ -z "${typed}" ]]; then
        ( kantainer_select_drive "${target}" ) < /dev/null
    else
        printf '%s\n' "${typed}" | ( kantainer_select_drive "${target}" )
    fi
}

STICK='sdz|Kingston DataTraveler|28.9G|1C6F654E8B12'

### The configuration names a drive

if got="$(select_drive /dev/sdb "" 'sda|Samsung SSD|465.8G|S3Z8NB' 'sdb|WDC WD10|931.5G|WD-WCC6' "${STICK}" 2>/dev/null)" &&
    [[ "${got}" == "/dev/sdb" ]]; then
    ok "installs to the drive the configuration names"
else
    not_ok "installs to the drive the configuration names (got: ${got:-refused})"
fi

if err="$(select_drive /dev/sdq "" 'sda|Samsung SSD|465.8G|S3Z8NB' "${STICK}" 2>&1 >/dev/null)"; then
    not_ok "refuses a named drive the machine does not have"
else
    ok "refuses a named drive the machine does not have"
    # The operator is at a console with no way to look the value up, so the
    # refusal has to carry both what was asked for and what is actually here.
    if [[ "${err}" == *"/dev/sdq"* && "${err}" == *"/dev/sda"* ]]; then
        ok "names the missing drive and what the machine does have"
    else
        not_ok "names the missing drive and what the machine does have"
    fi
fi

if select_drive "${BOOT_DISK}" "" 'sda|Samsung SSD|465.8G|S3Z8NB' "${STICK}" > /dev/null 2>&1; then
    not_ok "refuses a named drive that is the medium it booted from"
else
    ok "refuses a named drive that is the medium it booted from"
fi

### The configuration names nothing

# The case REQUIREMENTS.md §req:success-criteria item 2 is about: one drive, no
# keyboard. The boot medium must not be counted, or this machine stops at a
# prompt and the whole unattended promise is gone.
if got="$(select_drive "" "" 'sda|Samsung SSD|465.8G|S3Z8NB' "${STICK}" 2>/dev/null)" &&
    [[ "${got}" == "/dev/sda" ]]; then
    ok "installs to the only drive without asking"
else
    not_ok "installs to the only drive without asking (got: ${got:-refused})"
fi

if got="$(select_drive "" "" 'sda|Samsung SSD|465.8G|S3Z8NB' 'zram0||8G|' "${STICK}" 2>/dev/null)" &&
    [[ "${got}" == "/dev/sda" ]]; then
    ok "does not count zram as a drive"
else
    not_ok "does not count zram as a drive (got: ${got:-refused})"
fi

if select_drive "" "" "${STICK}" > /dev/null 2>&1; then
    not_ok "refuses when the machine has no drive at all"
else
    ok "refuses when the machine has no drive at all"
fi

### More than one drive, and nothing named

TWO=('sda|Samsung SSD 860 EVO|465.8G|S3Z8NB0K123456X' 'sdb|WDC WD10EZEX|931.5G|WD-WCC6Y1234567' "${STICK}")

# Nobody is there to answer: the prompt reads EOF. Writing nothing is the whole
# point of this branch.
if out="$(select_drive "" "" "${TWO[@]}" 2>&1)"; then
    not_ok "writes nothing when more than one drive and none named"
else
    ok "writes nothing when more than one drive and none named"
fi

for field in "Samsung SSD 860 EVO" "465.8G" "S3Z8NB0K123456X" "WDC WD10EZEX" "931.5G" "WD-WCC6Y1234567"; do
    if [[ "${out}" == *"${field}"* ]]; then
        ok "lists ${field}"
    else
        not_ok "lists ${field}"
    fi
done

if [[ "${out}" != *"Kingston DataTraveler"* ]]; then
    ok "does not offer the medium it booted from"
else
    not_ok "does not offer the medium it booted from"
fi

# The operator picks one, and that is the whole of the exception SPEC.md
# §spec:drive-selection carves out of unattended installation.
if got="$(select_drive "" "2" "${TWO[@]}" 2>/dev/null)" && [[ "${got}" == "/dev/sdb" ]]; then
    ok "installs to the drive the operator selects"
else
    not_ok "installs to the drive the operator selects (got: ${got:-refused})"
fi

if got="$(select_drive "" $'9\nx\n1' "${TWO[@]}" 2>/dev/null)" && [[ "${got}" == "/dev/sda" ]]; then
    ok "asks again when the answer is not one of the drives"
else
    not_ok "asks again when the answer is not one of the drives (got: ${got:-refused})"
fi

### A drive with nothing to identify it

# Virtual machines report neither model nor serial. Saying so beats printing an
# empty column the operator cannot interpret.
if out="$(select_drive "" "" 'vda||64G|' 'vdb||64G|' "${STICK}" 2>&1)"; then
    not_ok "still refuses to guess between two anonymous drives"
else
    ok "still refuses to guess between two anonymous drives"
fi

if [[ "${out}" == *"/dev/vda"* && "${out}" == *"/dev/vdb"* && "${out}" == *unknown* ]]; then
    ok "says a drive's model and serial are unknown rather than printing nothing"
else
    not_ok "says a drive's model and serial are unknown rather than printing nothing"
fi

### The console password, converted on the machine

# SPEC.md §spec:console-password. The operator writes the password in readable
# form; the machine turns it into its stored form during installation, because
# the Bash and the OpenSSL macOS ships cannot produce the modern form and
# §req:constraints forbids requiring a Mac operator to install anything extra.
#
# This is the step that makes that true, and it is the step that decides whether
# a readable copy ever reaches the installed machine. Everything below drives it
# without a disk.

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# What scripts/render-ignition.sh produces for a machine with a console
# password: the locked placeholder, and no password anywhere in the document.
locked_ignition() {
    jq -cn '{ignition:{version:"3.5.0"},
             passwd:{users:[{name:"operator", passwordHash:"*",
                             sshAuthorizedKeys:["ssh-ed25519 AAAA test"]}]}}'
}

# ...and for a machine without one: no passwordHash key at all.
unlocked_ignition() {
    jq -cn '{ignition:{version:"3.5.0"},
             passwd:{users:[{name:"operator",
                             sshAuthorizedKeys:["ssh-ed25519 AAAA test"]}]}}'
}

# Every character the configuration file promises to take literally, because the
# password reaches this function exactly as the operator typed it.
CONSOLE_PASSWORD='console-secret-$`"'"'"'\ &|%'

locked_ignition > "${WORK}/machine.ign"
printf '%s' "${CONSOLE_PASSWORD}" > "${WORK}/console-password"

if out="$(kantainer_apply_console_password "${WORK}/console-password" "${WORK}/machine.ign")"; then
    hash="$(jq -r '.passwd.users[0].passwordHash' < "${out}")"

    case "${hash}" in
        \$6\$*) ok "hashes the console password into the modern stored form" ;;
        *) not_ok "hashes the console password into the modern stored form (got: ${hash})" ;;
    esac

    if [[ "${hash}" != "*" ]]; then
        ok "replaces the locked placeholder rather than leaving it"
    else
        not_ok "replaces the locked placeholder rather than leaving it"
    fi

    # The whole of §spec:console-password's promise about the installed machine:
    # "the password exists on the machine only in its own account database".
    if grep -Fq "${CONSOLE_PASSWORD}" "${out}"; then
        not_ok "writes no readable copy of the password onto the installed machine"
    else
        ok "writes no readable copy of the password onto the installed machine"
    fi

    # The real caller removes this on the way out; so does the test, or the
    # suite leaves a file carrying a password hash behind on every run.
    rm -f "${out}"
else
    not_ok "hashes the console password into the modern stored form (it failed)"
    not_ok "replaces the locked placeholder rather than leaving it"
    not_ok "writes no readable copy of the password onto the installed machine"
fi

# A machine with no console password is installed from exactly the document the
# operator's host rendered. Nothing is patched, so nothing can go wrong here.
unlocked_ignition > "${WORK}/blank.ign"
: > "${WORK}/blank-password"

if out="$(kantainer_apply_console_password "${WORK}/blank-password" "${WORK}/blank.ign")" &&
    cmp -s "${out}" "${WORK}/blank.ign"; then
    ok "a blank console password installs the specification untouched"
else
    not_ok "a blank console password installs the specification untouched"
fi

# The sentinel is written in butane/kantainer.bu.tmpl and matched here: two
# files, one string, and nothing that makes them agree. If they drift, jq matches
# nothing and succeeds, and the machine installs with no console password at all.
sed 's/"\*"/"!"/' "${WORK}/machine.ign" > "${WORK}/drifted.ign"
if ( kantainer_apply_console_password "${WORK}/console-password" "${WORK}/drifted.ign" ) > /dev/null 2>&1; then
    not_ok "refuses when the password did not reach the specification"
else
    ok "refuses when the password did not reach the specification"
fi

# The one thing about the live installer environment this repository cannot
# check offline. If the tool that makes the hash is not there, the operator asked
# for a console password and must not get a machine that quietly has none:
# kantainer-install.service carries OnFailure=emergency.target, so failing here
# is a failure they can see.
if (
    # Called by kantainer_apply_console_password, not from here - which is the
    # whole point of the override, and why shellcheck cannot see the call.
    # shellcheck disable=SC2329
    kantainer_hash_password() { return 127; }
    kantainer_apply_console_password "${WORK}/console-password" "${WORK}/machine.ign"
) > /dev/null 2>&1; then
    not_ok "refuses to install when the password cannot be hashed"
else
    ok "refuses to install when the password cannot be hashed"
fi

### The whole of main(), on the success path

# Everything above drives one function. This drives the program, because the bug
# this catches lives in the seam between them: an EXIT trap that referred to a
# local of main() aborted the script AFTER a successful install, which failed
# kantainer-install.service and fired its OnFailure=emergency.target. The
# operator would have watched a correct install end in emergency mode, with no
# way to tell it from a real failure.
#
# coreos-installer and systemctl are replaced: nothing here may write to a disk
# or reboot anything.
locked_ignition > "${WORK}/main.ign"
: > "${WORK}/main-target"

if (
    # shellcheck disable=SC2329  # called by main(), which shellcheck cannot see
    coreos-installer() { printf '%s\n' "$3" > "${WORK}/installed-from"; }
    # shellcheck disable=SC2329
    systemctl() { :; }
    # shellcheck disable=SC2329
    kantainer_list_disks() { disks_json 'sda|Samsung SSD|465.8G|S3Z8NB' "${STICK}"; }
    main "${WORK}/main-target" "${WORK}/main.ign" "${WORK}/console-password"
) > /dev/null 2>&1; then
    ok "a successful install with a console password exits cleanly"
else
    not_ok "a successful install with a console password exits cleanly"
fi

# ...and the copy carrying the hash does not outlive it.
if [[ -s "${WORK}/installed-from" ]] && [[ ! -e "$(cat "${WORK}/installed-from")" ]]; then
    ok "removes the patched specification on the way out"
else
    not_ok "removes the patched specification on the way out"
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all first-stage installer checks behave as intended"
else
    echo "${failures} first-stage installer check(s) misbehaved"
    exit 1
fi
