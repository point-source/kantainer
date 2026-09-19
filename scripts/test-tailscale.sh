#!/bin/bash
# Tests for the Tailscale arrangement (SPEC.md §spec:tailscale).
#
# Every way this can be wrong is silent on the machine, and most of them are
# silent in the direction that matters - the machine looks fine and is not:
#
#   - a tailscaled enabled in the image is a VPN daemon running on machines that
#     never asked for one, with the gate file controlling only whether something
#     logged in
#   - a gate moved onto the authentication key file is a machine that leaves the
#     tailnet the first time an operator tidies up a key that has been spent
#   - a join script that stopped checking whether it is already logged in is a
#     unit that fails on every boot after the operator touches a setting by hand,
#     reporting a settings conflict about a machine that works
#   - a `tailscale up` missing one of its flags is a command that refuses
#     outright: it demands the complete set and errors on any unmentioned flag
#     that would change a setting
#   - a --ssh that became true is a second front door onto the machine, opened by
#     tailnet ACLs rather than by the operator's SSH key, against
#     §spec:remote-access
#   - a Portainer bound to the tailnet that falls back to every interface when
#     there is no tailnet address publishes the administration interface to the
#     whole network at the one moment nobody is looking
#   - a forwarding sysctl that stopped being written is an approved subnet route
#     that drops every packet, with nothing red anywhere
#   - a console block that still offers a LAN URL for a tailnet-only Portainer
#     sends the operator to debug the wrong thing
#
# None of that appears in a build log. These assertions read the files the image
# carries, the fragments the installer appends and the parts of build.sh that
# decide what runs. They cannot prove a machine joins anything - only a booted
# machine and a real tailnet do that, which §spec:tailscale records as not yet
# confirmed on hardware.

# Several assertions search scripts for literal shell text such as
# `${AUTHKEY}`. The single quotes are there so that text is matched as written
# rather than expanded here, which is what the linter warns against.
# shellcheck disable=SC2016

set -oue pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEM_FILES="${REPO_ROOT}/system_files"
BUILD_SH="${REPO_ROOT}/build_files/build.sh"

TAILSCALE_UP="${SYSTEM_FILES}/usr/libexec/kantainer/tailscale-up"
PORTAINER_RUN="${SYSTEM_FILES}/usr/libexec/kantainer/portainer-run"
NETWORK_SNIPPET="${SYSTEM_FILES}/usr/libexec/kantainer/console-network-snippet"
TAILSCALE_SNIPPET="${SYSTEM_FILES}/usr/libexec/kantainer/console-tailscale-snippet"
TAILSCALE_UNIT="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-tailscale.service"
CONSOLE_UNIT="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-console-tailscale.service"
PORTAINER_UNIT="${SYSTEM_FILES}/usr/lib/systemd/system/kantainer-portainer.service"
ZONE="${SYSTEM_FILES}/usr/lib/firewalld/zones/kantainer.xml"

FRAGMENT="${REPO_ROOT}/butane/tailscale.bu.tmpl"
FORWARDING_FRAGMENT="${REPO_ROOT}/butane/tailscale-forwarding.bu.tmpl"
TAILNET_ONLY_FRAGMENT="${REPO_ROOT}/butane/portainer-tailnet-only.bu.tmpl"
RENDER="${REPO_ROOT}/scripts/render-ignition.sh"
CONFIG_LIB="${REPO_ROOT}/scripts/config-lib.sh"

# The two gates, written in one place here and compared against every file that
# names them. A rename that reached three files out of four would otherwise ship.
GATE=/etc/kantainer/tailscale-enabled
AUTHKEY=/etc/kantainer/tailscale-authkey
SETTINGS=/etc/kantainer/tailscale.env
TAILNET_ONLY=/etc/kantainer/portainer-tailnet-only

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

# What a file DOES, with its explanations removed. These scripts discuss the
# flags and paths at length in comments, so grepping the whole file would pass on
# one that only talks about them.
code() {
    grep -vE '^[[:space:]]*#' "$1"
}

echo "# Nothing runs unless the operator asked"

# THE ASSERTION THIS WHOLE FILE EXISTS FOR. ucore-minimal installs tailscale and
# leaves its unit disabled; the gate is the switch only for as long as nothing
# here enables the daemon behind it.
refute "the image does not enable tailscaled" \
    grep -Eq '^[[:space:]]*systemctl enable tailscaled' <(code "${BUILD_SH}")

assert "the join unit is enabled in the image" \
    grep -Fq "systemctl enable kantainer-tailscale.service" <(code "${BUILD_SH}")

assert "the console renderer is enabled in the image" \
    grep -Fq "systemctl enable kantainer-console-tailscale.service" <(code "${BUILD_SH}")

# Requires=, not Wants=. systemd starts a required unit whether or not it is
# enabled, and that is precisely what lets tailscaled stay disabled above while
# still coming up on a machine that asked for it.
assert "the join unit starts tailscaled itself" \
    grep -Eq '^Requires=.*tailscaled\.service' "${TAILSCALE_UNIT}"

assert "the join unit is gated on the enabled file" \
    grep -Fxq "ConditionPathExists=${GATE}" "${TAILSCALE_UNIT}"

assert "the console renderer is gated on the same file" \
    grep -Fxq "ConditionPathExists=${GATE}" "${CONSOLE_UNIT}"

# THE GATE IS NOT THE KEY. An authentication key is single-use by default and
# spent once the machine has joined; deleting it afterwards is hygiene. If the
# key were the gate, that tidy-up would take the machine off its tailnet at the
# next reboot with nothing saying why.
refute "the join unit is not gated on the key, which the operator may delete" \
    grep -Fq "ConditionPathExists=${AUTHKEY}" "${TAILSCALE_UNIT}"

echo
echo "# The key never reaches a command line, a process list or the journal"

assert "the key is handed over as a file path" \
    grep -Fq -- '--auth-key="file:${AUTHKEY}"' <(code "${TAILSCALE_UP}")

# The unit calls the script with no argument, so the DEFAULT is what a machine
# actually reads. The argument exists only so the refusals can be exercised
# below; a default that drifted from the installer's path would leave every
# machine looking for a key that is not there.
assert "the key file defaults to the path the installer writes" \
    grep -Fq "AUTHKEY=\"\${1:-${AUTHKEY}}\"" <(code "${TAILSCALE_UP}")

refute "the unit passes no argument, so the default is what runs" \
    grep -qE '^ExecStart=/usr/libexec/kantainer/tailscale-up[[:space:]]+[^[:space:]]' \
    "${TAILSCALE_UNIT}"

# The fragment stages it as a local file rather than substituting it into the
# Butane body, which is what keeps it out of a sed expression - the same
# arrangement the Portainer password has.
assert "the installer stages the key rather than substituting it" \
    grep -Fq "local: tailscale-authkey" "${FRAGMENT}"

# A function rather than a pipeline in the argument list: a pipe there would
# apply to `assert` itself and send its verdict to grep instead of testing the
# fragment.
authkey_is_root_only() {
    grep -A4 -F "path: ${AUTHKEY}" "${FRAGMENT}" | grep -Fq "mode: 0600"
}

assert "the key is written 0600" authkey_is_root_only

assert "the renderer writes the key with no trailing newline" \
    grep -Fq "printf '%s' \"\${KANTAINER_TAILSCALE_AUTHKEY}\"" "${RENDER}"

echo
echo "# The join runs once, and leaves a working machine alone"

# `tailscale up` demands the complete set of desired settings and errors on any
# unmentioned flag that would change one - so a unit that re-ran it every boot
# would fail on every boot after an operator used `tailscale set`.
assert "the join script reads Tailscale's own backend state" \
    grep -Fq "BackendState" <(code "${TAILSCALE_UP}")

assert "an already-joined machine is left alone" \
    grep -Fq "already logged in" <(code "${TAILSCALE_UP}")

# Empty output from a tailscaled that is not answering must not read as success.
# jq over empty input emits nothing and exits 0, so without this the state would
# be the empty string and fall through to the already-joined arm.
assert "an unreadable state is refused rather than read as joined" \
    grep -Fq 'state="Unknown"' <(code "${TAILSCALE_UP}")

echo
echo "# What the machine asks its tailnet for"

for flag in --hostname --accept-dns --accept-routes --ssh --advertise-exit-node --advertise-routes --timeout; do
    assert "\`tailscale up\` mentions ${flag}" \
        grep -Fq -- "${flag}=" <(code "${TAILSCALE_UP}")
done

# SPEC.md §spec:remote-access: sshd is the only door, and it is key-only.
# Tailscale SSH authenticates against tailnet ACLs instead, which is a second
# front door with a different lock on it.
assert "Tailscale SSH stays off" \
    grep -Fq -- "--ssh=false" <(code "${TAILSCALE_UP}")

refute "nothing switches Tailscale SSH on" \
    grep -Fq -- "--ssh=true" <(code "${TAILSCALE_UP}")

echo
echo "# Routing for the tailnet needs the kernel's half too"

assert "the forwarding fragment sets IPv4 forwarding" \
    grep -Fq "net.ipv4.ip_forward = 1" "${FORWARDING_FRAGMENT}"

assert "the forwarding fragment sets IPv6 forwarding" \
    grep -Fq "net.ipv6.conf.all.forwarding = 1" "${FORWARDING_FRAGMENT}"

# Written for the two settings that carry other machines' packets, and for
# nothing else: turning on forwarding is not a side effect to hand somebody who
# asked for a VPN.
assert "the renderer writes it for an exit node or advertised routes" \
    grep -Eq 'KANTAINER_TAILSCALE_EXIT_NODE.*==.*"true".*\|\|.*-n "\$\{KANTAINER_TAILSCALE_ROUTES\}"' "${RENDER}"

# A machine where the operator added the setting by hand gets no sysctl from the
# installer, so the join script says so rather than letting them discover it from
# an approved route that drops everything.
assert "the join script warns when forwarding is off but routes are advertised" \
    grep -Fq "ip_forward" <(code "${TAILSCALE_UP}")

echo
echo "# Portainer on the tailnet only binds there, and refuses rather than falling back"

assert "portainer-run reads the tailnet-only gate" \
    grep -Fq "${TAILNET_ONLY}" <(code "${PORTAINER_RUN}")

assert "the gate makes Portainer publish on the tailnet address" \
    grep -Fq -- '--publish "${TAILNET_IP}:9443:9443"' <(code "${PORTAINER_RUN}")

# THE FALLBACK THAT MUST NOT EXIST. Publishing on every interface when the
# tailnet address is missing would answer "on the tailnet only" by putting the
# administration interface on the operator's whole network, at the exact moment
# they cannot see the machine to notice.
assert "no tailnet address is a refusal, not a fallback" \
    grep -Fq "exit 1" <(sed -n '/portainer-tailnet-only/,/^fi$/p' "${PORTAINER_RUN}")

# Ordering only. A Requires= would drag tailscaled onto machines that never asked
# for it, and would stop Portainer on a tailnet machine that could still serve
# perfectly well on its own network.
assert "Portainer is ordered after the join" \
    grep -Fxq "After=kantainer-tailscale.service" "${PORTAINER_UNIT}"

refute "Portainer does not depend on the join" \
    grep -Eq '^Requires=.*kantainer-tailscale\.service' "${PORTAINER_UNIT}"

echo
echo "# The login screen tells the truth about where Portainer is"

assert "the tailnet block offers the tailnet URL" \
    grep -Fq "Portainer at https://%s:%s (tailnet)" <(code "${TAILSCALE_SNIPPET}")

assert "a machine that has not joined says so" \
    grep -Fq "Tailscale: not connected" <(code "${TAILSCALE_SNIPPET}")

# The network block answers "what do I type into a browser" for this machine's
# own network. On a tailnet-only machine that answer is wrong, and a URL that
# refuses every connection sends the operator to debug Portainer, which is
# working, instead of Tailscale, which is not.
assert "the network block knows about the tailnet-only gate" \
    grep -Fq "${TAILNET_ONLY}" <(code "${NETWORK_SNIPPET}")

assert "the network block stops offering a LAN URL for a tailnet-only Portainer" \
    grep -Fq "Portainer is on the tailnet only" <(code "${NETWORK_SNIPPET}")

# 92_ so it lands below the network and Portainer blocks, which are 90_ and 91_.
# agetty version-sorts the directory.
assert "the tailnet block sorts below the other two" \
    grep -Fq "SNIPPET_NAME=92_kantainer_tailscale.issue" <(code "${TAILSCALE_SNIPPET}")

echo
echo "# The firewall lets Tailscale make a direct connection"

assert "the zone opens Tailscale's listening port" \
    grep -Fq '<port port="41641" protocol="udp"/>' "${ZONE}"

echo
echo "# The configuration contract"

for field in KANTAINER_TAILSCALE_AUTHKEY KANTAINER_TAILSCALE_HOSTNAME \
    KANTAINER_TAILSCALE_EXIT_NODE KANTAINER_TAILSCALE_ROUTES \
    KANTAINER_PORTAINER_TAILNET_ONLY; do
    assert "${field} is a field the configuration may set" \
        grep -Fq "    ${field}" "${CONFIG_LIB}"

    assert "${field} is documented in the example" \
        grep -Fq "${field}=" "${REPO_ROOT}/kantainer.conf.example"
done

assert "the settings file is written where the unit reads it" \
    grep -Fq "EnvironmentFile=-${SETTINGS}" "${TAILSCALE_UNIT}"

assert "the installer writes that settings file" \
    grep -Fq "local: tailscale.env" "${FRAGMENT}"

# The fragments are entries of the base template's storage.files list. One that
# started its own top-level key would produce a config that is valid YAML and
# means something else entirely.
for fragment in "${FRAGMENT}" "${FORWARDING_FRAGMENT}" "${TAILNET_ONLY_FRAGMENT}"; do
    assert "$(basename "${fragment}") continues the files list rather than starting a key" \
        grep -Eq '^    - path:' "${fragment}"
done

echo
echo "# Tailscale is the base image's, and the build says so if it ever stops being"

# No pin of our own: ucore-minimal installs the package, so UCORE_DIGEST is
# already the pin. The risk that leaves is uCore dropping it, which no test of
# the repository's own text can see - hence the build-time assertion.
assert "the build asserts the Tailscale binaries exist" \
    grep -Fq "test -x /usr/sbin/tailscaled" "${BUILD_SH}"

assert "the build asserts the Tailscale CLI exists" \
    grep -Fq "test -x /usr/bin/tailscale" "${BUILD_SH}"

assert "the build asserts jq, which the join script parses state with" \
    grep -Fq "test -x /usr/bin/jq" "${BUILD_SH}"

assert "the build asserts the join script is executable" \
    grep -Fq "test -x /usr/libexec/kantainer/tailscale-up" "${BUILD_SH}"

assert "the build asserts the console renderer is executable" \
    grep -Fq "test -x /usr/libexec/kantainer/console-tailscale-snippet" "${BUILD_SH}"

refute "versions.env carries no second, weaker Tailscale pin" \
    grep -Eq '^TAILSCALE_[A-Z]+=' "${REPO_ROOT}/versions.env"

echo
echo "# The join script, run rather than read"
#
# Everything above this line asserts that the source says the right words. That
# passes on a file which still says them and has stopped doing them, so the three
# decisions that can leave a machine wrong are exercised here against a stubbed
# Tailscale: refusing when the state cannot be read, refusing when there is no
# key, and leaving an already-joined machine alone.
#
# tailscale-up takes the key file as an argument for exactly this, and resolves
# `tailscale` from PATH, the way watchtower-preflight resolves `docker`.

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

STUB="${WORK}/bin"
mkdir -p "${STUB}"

# Records what it was asked to do and answers from the environment, so each case
# below is one variable rather than one stub.
cat > "${STUB}/tailscale" <<'STUBBED'
#!/bin/bash
printf '%s\n' "$*" >> "${TS_ARGV_LOG}"
case "${1:-}" in
    status)
        # Nothing on stdout is what a tailscaled that is not answering produces,
        # and it is the case that must not read as success.
        [[ -n "${TS_STUB_STATE:-}" ]] || exit 1
        printf '{"BackendState":"%s"}\n' "${TS_STUB_STATE}"
        ;;
    ip)
        [[ -n "${TS_STUB_IP:-}" ]] || {
            echo "no current Tailscale IPs; state: NeedsLogin" >&2
            exit 1
        }
        printf '%s\n' "${TS_STUB_IP}"
        ;;
    up) exit "${TS_STUB_UP_STATUS:-0}" ;;
esac
STUBBED

cat > "${STUB}/docker" <<'STUBBED'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_ARGV_LOG}"
STUBBED

chmod +x "${STUB}/tailscale" "${STUB}/docker"

# run_up <key-file> -> status in $status, output in $out, argv in $WORK/ts.argv
run_up() {
    : > "${WORK}/ts.argv"
    status=0
    out="$(
        PATH="${STUB}:${PATH}" \
        TS_ARGV_LOG="${WORK}/ts.argv" \
        TS_STUB_STATE="${TS_STUB_STATE:-}" \
        TS_STUB_IP="" \
        KANTAINER_TAILSCALE_HOSTNAME="${KANTAINER_TAILSCALE_HOSTNAME:-}" \
        KANTAINER_TAILSCALE_EXIT_NODE="${KANTAINER_TAILSCALE_EXIT_NODE:-}" \
        KANTAINER_TAILSCALE_ROUTES="${KANTAINER_TAILSCALE_ROUTES:-}" \
        "${TAILSCALE_UP}" "$1" 2>&1
    )" || status=$?
}

KEY_FILE="${WORK}/authkey"
printf '%s' 'tskey-auth-fixture0CNTRL-authenticatesnothing' > "${KEY_FILE}"

# A machine that has already joined. `tailscale up` demands the complete set of
# settings and errors on any unmentioned flag that would change one, so a unit
# that re-ran it every boot would fail on every boot after the operator touched
# anything with `tailscale set` - reporting a conflict about a working machine.
TS_STUB_STATE=Running run_up "${KEY_FILE}"
if [[ "${status}" -eq 0 ]]; then
    ok "an already-joined machine is left alone, and the unit goes green"
else
    not_ok "an already-joined machine is left alone, and the unit goes green (exit ${status}: ${out})"
fi

refute "an already-joined machine is not asked to join again" \
    grep -q '^up' "${WORK}/ts.argv"

# THE ONE THAT MUST NOT READ AS SUCCESS. jq over empty input emits nothing and
# exits 0, so a single substitution would yield the empty string and fall through
# to the already-joined arm - the unit would go green on a machine that never
# joined anything.
TS_STUB_STATE="" run_up "${KEY_FILE}"
if [[ "${status}" -ne 0 ]]; then
    ok "a tailscaled that cannot be asked is a refusal, not a green unit"
else
    not_ok "a tailscaled that cannot be asked is a refusal, not a green unit (exited 0: ${out})"
fi

assert "that refusal points at tailscaled rather than at the key" \
    grep -qi "tailscaled" <<< "${out}"

refute "nothing is asked to join when the state could not be read" \
    grep -q '^up' "${WORK}/ts.argv"

# A spent key that the operator deleted, on a machine that has since been logged
# out. `tailscale up --auth-key=file:` on a missing file does not say "no such
# file" - it falls through to an interactive login and refuses with a paragraph
# about mentioning all non-default flags, which sends the reader elsewhere.
TS_STUB_STATE=NeedsLogin run_up "${WORK}/no-such-key"
if [[ "${status}" -ne 0 ]]; then
    ok "a logged-out machine with no key refuses rather than hanging"
else
    not_ok "a logged-out machine with no key refuses rather than hanging (exited 0)"
fi

assert "that refusal names the file it looked for" \
    grep -qF "${WORK}/no-such-key" <<< "${out}"

refute "nothing is asked to join without a key" \
    grep -q '^up' "${WORK}/ts.argv"

# The join itself, with every setting the operator asked for.
TS_STUB_STATE=NeedsLogin \
    KANTAINER_TAILSCALE_HOSTNAME=garage-box \
    KANTAINER_TAILSCALE_EXIT_NODE=true \
    KANTAINER_TAILSCALE_ROUTES=192.168.1.0/24 \
    run_up "${KEY_FILE}"

if [[ "${status}" -eq 0 ]]; then
    ok "a logged-out machine with a key joins"
else
    not_ok "a logged-out machine with a key joins (exit ${status}: ${out})"
fi

joined="$(grep '^up' "${WORK}/ts.argv" || true)"

# The key is handed over as a path. It must not appear in the argv the stub
# recorded, which is the same list `ps` and the journal would show.
refute "the key itself never reaches the command line" \
    grep -qF 'tskey-auth-fixture0CNTRL-authenticatesnothing' "${WORK}/ts.argv"

for want in "--auth-key=file:${KEY_FILE}" "--hostname=garage-box" \
    "--advertise-exit-node=true" "--advertise-routes=192.168.1.0/24" \
    "--ssh=false" "--accept-dns=true" "--accept-routes=false" "--timeout=60s"; do
    if [[ "${joined}" == *"${want}"* ]]; then
        ok "the join passes ${want%%=*}"
    else
        not_ok "the join passes ${want%%=*} (wanted ${want}, got: ${joined})"
    fi
done

# The defaults a machine gets when the installer wrote no settings file, which is
# the machine of an operator who ran `tailscale up` by hand. `kantainer` rather
# than the system hostname, which nothing here sets and which Fedora CoreOS
# leaves as localhost.
TS_STUB_STATE=NeedsLogin run_up "${KEY_FILE}"
joined="$(grep '^up' "${WORK}/ts.argv" || true)"

assert "a machine with no settings file still gets a name" \
    grep -qF -- "--hostname=kantainer" <<< "${joined}"

assert "a machine with no settings file advertises no routes" \
    grep -qF -- "--advertise-routes=" <<< "${joined}"

echo
echo "# The tailnet-only refusal, run rather than read"
#
# This is the one place portainer-run can put the administration interface
# somewhere the operator did not ask for, so reading the source for an `exit 1`
# is not good enough.

IMAGE_FILE="${WORK}/portainer-image"
printf '%s\n' 'portainer/portainer-ce:2.45.0' > "${IMAGE_FILE}"

GATE_FILE="${WORK}/portainer-tailnet-only"

# run_portainer <gate-file> -> status, out, $WORK/docker.argv
run_portainer() {
    : > "${WORK}/docker.argv"
    status=0
    out="$(
        PATH="${STUB}:${PATH}" \
        TS_ARGV_LOG="${WORK}/ts.argv" \
        DOCKER_ARGV_LOG="${WORK}/docker.argv" \
        TS_STUB_IP="${TS_STUB_IP:-}" \
        TS_STUB_STATE="" \
        "${PORTAINER_RUN}" "${IMAGE_FILE}" "$1" 2>&1
    )" || status=$?
}

# An ordinary machine, so the default is proved rather than assumed.
rm -f "${GATE_FILE}"
run_portainer "${GATE_FILE}"

assert "an ordinary machine publishes Portainer on every address" \
    grep -qF -- "--publish 9443:9443" "${WORK}/docker.argv"

# The gate, with a tailnet that is up.
: > "${GATE_FILE}"
TS_STUB_IP=100.101.102.103 run_portainer "${GATE_FILE}"

assert "a tailnet-only machine publishes on the tailnet address" \
    grep -qF -- "--publish 100.101.102.103:9443:9443" "${WORK}/docker.argv"

refute "a tailnet-only machine does not also publish on every address" \
    grep -qE -- "--publish 9443:9443" "${WORK}/docker.argv"

# THE REFUSAL. Falling back to publishing everywhere would answer a request for
# "on the tailnet only" by putting the administration interface on the operator's
# whole network, at the exact moment they cannot see the machine to notice.
TS_STUB_IP="" run_portainer "${GATE_FILE}"

if [[ "${status}" -ne 0 ]]; then
    ok "no tailnet address refuses rather than falling back"
else
    not_ok "no tailnet address refuses rather than falling back (exited 0)"
fi

if [[ ! -s "${WORK}/docker.argv" ]]; then
    ok "nothing is published when there is no tailnet address"
else
    not_ok "nothing is published when there is no tailnet address (ran: $(cat "${WORK}/docker.argv"))"
fi

assert "the refusal names the gate file to remove" \
    grep -qF "${GATE_FILE}" <<< "${out}"

assert "the refusal says Portainer was not started everywhere instead" \
    grep -qi "not being started on every address" <<< "${out}"

echo
if [[ "${failures}" -gt 0 ]]; then
    echo "${failures} Tailscale assertion(s) failed."
    exit 1
fi

echo "the Tailscale arrangement is as specified"
