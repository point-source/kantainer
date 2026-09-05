#!/bin/bash
# The boot health check (SPEC.md §spec:boot-health-and-rollback).
#
# greenboot runs every script in required.d after a boot. If one exits non-zero
# the boot is unhealthy, and after GREENBOOT_MAX_BOOT_ATTEMPTS such boots the
# machine returns to the deployment it was running before the update.
#
# This is the whole check, and its narrowness is the design rather than an
# omission. §spec:boot-health-and-rollback: "A health check that is wrong in the
# strict direction is worse than none: it rolls back working updates
# indefinitely, and the machine quietly stops receiving fixes while appearing to
# run normally - the one failure mode nobody would notice."
#
# So it does not test Portainer, the Portainer units, port 9443, or anything
# else above Docker. An update that leaves the machine booting and Docker
# running but Portainer broken is deliberately NOT caught here: that failure is
# visible in the operator's browser and recoverable over SSH, which is what
# §spec:remote-access exists for.
#
# The other half of the check - that the machine reached a running state - needs
# no assertion. greenboot-healthcheck.service is WantedBy=multi-user.target, so
# a machine that never gets there never runs this script, never clears
# boot_success, and rolls back on the counter alone.

set -oue pipefail

if ! systemctl is-active --quiet docker.service; then
    cat >&2 <<'MSG'
Boot health check failed: the Docker engine is not running.

This machine's one job is running the operator's containers, so a boot without
Docker is a failed boot. If this repeats, the machine returns to the version it
was running before the update.

  systemctl status docker.service
MSG
    exit 1
fi
