#!/bin/bash
# Tests for the login screen's network lines (SPEC.md §spec:console-display).
#
# This is the one thing in the repository whose only consumer is a person
# standing at the machine with a monitor plugged in, and nothing in CI has a
# monitor. Every way it can be wrong is therefore silent here: a block that
# names docker0's address, a wireless line that says "kantainer-wireless"
# instead of the network the operator joined, a machine with no lease showing a
# bare "https://:9443", a snippet whose filename sorts above Fedora CoreOS's own
# lines. All of those build, ship, and read as working right up until the
# operator reads the screen and types the wrong thing into a browser.
#
# So the generator is SOURCED rather than run, and the one function that reads
# the machine - kantainer_nmcli - is replaced with fixtures in nmcli's own terse
# output shape, so the parser under test is the parser that runs on the machine.
# main() is never reached: it lives behind the BASH_SOURCE guard, which sourcing
# deliberately does not trigger.

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEM_FILES="${REPO_ROOT}/system_files"

GENERATOR="${SYSTEM_FILES}/usr/libexec/kantainer/console-network-snippet"

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

# A shell file with its comment lines removed. Assertions about what a script
# DOES have to read what it runs: every file in this batch explains itself at
# length, and prose must not be able to satisfy a check.
code() {
    grep -vE '^[[:space:]]*#' "$1"
}

# The fixture state the stubbed nmcli answers from. DEVICE_SHOW is the terse
# `device show` output; SSIDS maps a connection profile name to its SSID, which
# is a SEPARATE nmcli call on the machine because the profile this repository
# installs is called "kantainer-wireless" and not the network's name
# (butane/wireless.nmconnection.tmpl).
DEVICE_SHOW=""
declare -A SSIDS=()

kantainer_nmcli() {
    local last="${*: -1}"
    case "$*" in
        *802-11-wireless.ssid*) printf '%s\n' "${SSIDS[${last}]-}" ;;
        *"device show"*) printf '%s' "${DEVICE_SHOW}" ;;
        *) return 1 ;;
    esac
}

# The block a machine in the current fixture state would show on its screen.
block() { kantainer_network_block; }

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

### A wired machine with a lease

DEVICE_SHOW="GENERAL.DEVICE:ens18
GENERAL.TYPE:ethernet
GENERAL.STATE:100 (connected)
GENERAL.CONNECTION:Wired connection 1
IP4.ADDRESS[1]:192.168.1.50/24
IP6.ADDRESS[1]:fe80::be24:11ff:fe52:a7c1/64
"
SSIDS=()

# The whole point of the line: what the operator types into a browser. An
# address without the scheme or without Portainer's port is an address the
# operator has to know how to decorate, which is the knowledge this display
# exists to remove.
shows "a wired lease is shown as a complete browser address" "https://192.168.1.50:9443"
shows "a wired connection says it is wired" "wired"

# A link-local address cannot be typed into a browser without a zone index, so
# it is not an address for this purpose - and it is present on EVERY interface,
# so a renderer that took the first address would show it on every machine.
hides "an IPv6 link-local address is not offered as a browser address" "fe80"

### A wireless machine

DEVICE_SHOW="GENERAL.DEVICE:wlan0
GENERAL.TYPE:wifi
GENERAL.STATE:100 (connected)
GENERAL.CONNECTION:kantainer-wireless
IP4.ADDRESS[1]:192.168.1.51/24
"
SSIDS=([kantainer-wireless]="Kitchen")

shows "a wireless lease is shown as a complete browser address" "https://192.168.1.51:9443"
# The profile this repository writes is named kantainer-wireless regardless of
# the network. Reporting the profile name would put a kantainer-internal string
# on the operator's screen where the name of their own network belongs.
shows "a wireless connection names the network that was joined" "Kitchen"
hides "a wireless connection does not name the profile" "kantainer-wireless"

# agetty reads a backslash as the start of an escape sequence, and an SSID is
# whatever the operator typed into their configuration file. Unescaped, a
# network called "Up\Stairs" would put "Up" followed by agetty's idea of \S on
# the screen. Nothing else about the name is second-guessed - the operator owns
# what they named their network.
DEVICE_SHOW="GENERAL.DEVICE:wlan0
GENERAL.TYPE:wifi
GENERAL.STATE:100 (connected)
GENERAL.CONNECTION:kantainer-wireless
IP4.ADDRESS[1]:192.168.1.51/24
"
SSIDS=([kantainer-wireless]='Up\Stairs')

shows "a backslash in the network's name is escaped for agetty" 'Up\\Stairs'

# A profile whose SSID cannot be read at all. The line says wireless and stops,
# rather than trailing off after a colon with nothing behind it - the same rule
# as the no-address case.
SSIDS=()

shows "an unreadable network name leaves no empty slot" \
    "https://192.168.1.51:9443 (wireless)"

### Two networks at once

DEVICE_SHOW="GENERAL.DEVICE:ens18
GENERAL.TYPE:ethernet
GENERAL.STATE:100 (connected)
GENERAL.CONNECTION:Wired connection 1
IP4.ADDRESS[1]:192.168.1.50/24

GENERAL.DEVICE:wlan0
GENERAL.TYPE:wifi
GENERAL.STATE:100 (connected)
GENERAL.CONNECTION:kantainer-wireless
IP4.ADDRESS[1]:10.0.0.7/24
"
SSIDS=([kantainer-wireless]="Kitchen")

shows "a machine on two networks lists both" \
    "https://192.168.1.50:9443" "https://10.0.0.7:9443" "wired" "Kitchen"

### Docker's networks are not networks the operator can reach the machine on

# This machine runs Docker and Portainer creates more bridges as the operator
# deploys. Every one of them is a connected device with an address as far as
# NetworkManager is concerned, and 172.17.0.1 reaches Portainer from nowhere.
DEVICE_SHOW="GENERAL.DEVICE:ens18
GENERAL.TYPE:ethernet
GENERAL.STATE:100 (connected)
GENERAL.CONNECTION:Wired connection 1
IP4.ADDRESS[1]:192.168.1.50/24

GENERAL.DEVICE:docker0
GENERAL.TYPE:bridge
GENERAL.STATE:100 (connected (externally))
GENERAL.CONNECTION:docker0
IP4.ADDRESS[1]:172.17.0.1/16

GENERAL.DEVICE:br-06a5d5197bf5
GENERAL.TYPE:bridge
GENERAL.STATE:100 (connected (externally))
GENERAL.CONNECTION:br-06a5d5197bf5
IP4.ADDRESS[1]:172.19.0.1/16

GENERAL.DEVICE:lo
GENERAL.TYPE:loopback
GENERAL.STATE:100 (connected (externally))
GENERAL.CONNECTION:lo
IP4.ADDRESS[1]:127.0.0.1/8
IP6.ADDRESS[1]:::1/128
"
SSIDS=()

hides "Docker's bridges and the loopback are not offered as browser addresses" \
    "172.17.0.1" "172.19.0.1" "127.0.0.1"
shows "the machine's own network survives the filter" "https://192.168.1.50:9443"

# A cable that is plugged in but has not been given an address yet, alongside
# one that has. The half-up device must not produce a line of its own.
DEVICE_SHOW="GENERAL.DEVICE:ens18
GENERAL.TYPE:ethernet
GENERAL.STATE:100 (connected)
GENERAL.CONNECTION:Wired connection 1
IP4.ADDRESS[1]:192.168.1.50/24

GENERAL.DEVICE:ens19
GENERAL.TYPE:ethernet
GENERAL.STATE:30 (disconnected)
GENERAL.CONNECTION:
"
SSIDS=()

shows "a disconnected second interface does not hide the connected one" \
    "https://192.168.1.50:9443"
hides "a disconnected interface produces no line of its own" "ens19"

### A machine with no address at all

# §req:success-criteria 20 is about a specific bad screen: one that shows
# "https://:9443" or an address from a network the machine left. The requirement
# is not that the block be empty - it is that the block SAY SO, because a
# missing line reads as a display that is broken rather than a machine that has
# no address.
DEVICE_SHOW="GENERAL.DEVICE:ens18
GENERAL.TYPE:ethernet
GENERAL.STATE:30 (disconnected)
GENERAL.CONNECTION:

GENERAL.DEVICE:lo
GENERAL.TYPE:loopback
GENERAL.STATE:100 (connected (externally))
GENERAL.CONNECTION:lo
IP4.ADDRESS[1]:127.0.0.1/8
"
SSIDS=()

shows "a machine with no address says so in words" "no network address"
hides "a machine with no address shows no half-written address" "https://"

assert "a machine with no address still writes a line" \
    test -n "$(block)"

# A cable that is in but has not been given a lease yet is the same screen: the
# interface is connected, so the platform's own line for it is already there
# with nothing after it, and ours must not sit beside it saying the same
# nothing.
DEVICE_SHOW="GENERAL.DEVICE:ens18
GENERAL.TYPE:ethernet
GENERAL.STATE:100 (connected)
GENERAL.CONNECTION:Wired connection 1
IP6.ADDRESS[1]:fe80::be24:11ff:fe52:a7c1/64
"
SSIDS=()

shows "a connected interface with no usable address says so in words" \
    "no network address"

### The block keeps up with the machine

# §req:success-criteria 21 is about events, not about a boot snapshot. These run
# the dispatcher the way NetworkManager runs it, with a stubbed systemctl, and
# read back what it asked for.
DISPATCHER="${SYSTEM_FILES}/usr/lib/NetworkManager/dispatcher.d/90-kantainer-console-network"
STUB="$(mktemp -d)"
trap 'rm -rf "${STUB}"' EXIT

cat > "${STUB}/systemctl" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
STUBEOF
chmod +x "${STUB}/systemctl"

# dispatched <name> <interface> <action> - what the dispatcher asked systemctl
# for, or the empty string if it asked for nothing.
dispatched() {
    local interface="$1" action="$2" log
    log="$(mktemp)"
    SYSTEMCTL_LOG="${log}" PATH="${STUB}:${PATH}" \
        "${DISPATCHER}" "${interface}" "${action}" > /dev/null 2>&1 || true
    cat "${log}"
    rm -f "${log}"
}

for action in up down dhcp4-change dhcp6-change; do
    # restart rather than start: systemd satisfies a start request with a job
    # that is already queued, so a burst of events could drop the last one -
    # which is the one that describes where the machine actually ended up.
    assert "a ${action} event rewrites the block" \
        grep -qE 'restart .*kantainer-console-network\.service' \
        <(dispatched ens18 "${action}")

    # NetworkManager waits for a dispatcher script to finish. The generator
    # talks to NetworkManager, so running it inline would be NetworkManager
    # waiting on a script waiting on NetworkManager.
    assert "a ${action} event does not block NetworkManager's dispatcher" \
        grep -qF -- '--no-block' <(dispatched ens18 "${action}")
done

assert "an event the block does not depend on is ignored" \
    test -z "$(dispatched ens18 connectivity-change)"

# The whole design of the block's currency rests on this call: the platform's
# own per-interface line is an agetty escape, so the reload re-expands it from
# the same event and it cannot sit stale beside a correct kantainer line. Lose
# the call and both lines silently freeze at their boot values.
assert "rewriting the block redraws the login prompt" \
    grep -qF 'agetty --reload' <(code "${GENERATOR}")

# A deadlock here would hang NetworkManager's dispatcher queue, not just this
# display.
refute_nmcli() {
    if grep -qE '(^|[^_])nmcli' <(code "${DISPATCHER}"); then
        not_ok "the dispatcher does not call nmcli itself"
    else
        ok "the dispatcher does not call nmcli itself"
    fi
}
refute_nmcli

### Nothing on this path waits for a monitor

# §req:constraints: the machine has a screen and a keyboard only when the
# operator attaches them. The block is produced either way, so a unit that
# ordered itself against a getty, or read from a tty, would make the zero-touch
# path depend on hardware that is usually not there.
UNIT="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-console-network.service"

assert "the unit runs on an ordinary multi-user boot" \
    grep -qF 'WantedBy=multi-user.target' "${UNIT}"

for waits_for_a_person in 'StandardInput=' 'TTYPath=' 'getty' 'graphical.target'; do
    if grep -qF "${waits_for_a_person}" <(code "${UNIT}"); then
        not_ok "the unit does not wait for a display (found: ${waits_for_a_person})"
    else
        ok "the unit does not wait for a display (${waits_for_a_person})"
    fi
done

### What the image ships, rather than what the renderer produces

# agetty version-sorts /etc/issue.d. The base image writes 21_clhm_*, 22_clhm_*
# and Fedora CoreOS's own 30_coreos_ignition_* and 30_ssh_authorized_keys there,
# so a prefix below 30 would put the kantainer block in the middle of what the
# platform prints instead of beneath it - which is the one thing
# §spec:console-display asked for by name.
assert "the snippet sorts below every snippet the base image writes" \
    grep -qE '^SNIPPET_NAME=90_kantainer_' <(code "${GENERATOR}")

assert "the build enables the unit that writes the block at boot" \
    grep -qF 'systemctl enable kantainer-console-network.service' \
    <(code "${REPO_ROOT}/build_files/build.sh")

# /etc/issue.d is persistent, so without this a machine moved to another network
# would show the address it had on the old one until the generator next ran -
# during early boot, which is when someone is most likely to be reading it.
assert "a snippet from the last boot is removed before the screen is drawn" \
    grep -qE '^r[[:space:]]+/etc/issue\.d/\*_kantainer_\*\.issue[[:space:]]' \
    "${SYSTEM_FILES}/usr/lib/tmpfiles.d/kantainer.conf"

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "all console network display checks behave as intended"
else
    echo "${failures} console network display check(s) misbehaved"
    exit 1
fi
