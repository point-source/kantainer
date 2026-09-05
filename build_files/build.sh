#!/bin/bash
# Image customisation. Runs inside the container build, with the repository's
# build_files/ at /ctx and system_files/ at /ctx/system_files.

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf /ctx/system_files/. /
