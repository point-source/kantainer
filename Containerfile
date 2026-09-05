# Build context: carries build_files/ and system_files/ into the build without
# leaving either of them in the final image.
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# uCore MINIMAL, pinned by tag AND digest.
#
# The tag is what a human reads; the digest is what makes a rebuild a rebuild
# (SPEC.md §spec:image-publication). Both must match versions.env — `just ci`
# fails the build if they drift apart.
#
# MINIMAL is deliberate (SPEC.md §spec:base-image): the full and hyperconverged
# variants add Samba, NFS, snapraid and mergerfs, which REQUIREMENTS.md
# §req:constraints places out of scope. Wireless support, which only the larger
# variants carry, is restored by hand in build_files/build.sh instead.
FROM ghcr.io/ublue-os/ucore-minimal:stable-20260904@sha256:25b1f5a867c1e1272be0fec0e5523bc3395c409b1ddca5a9257d74b819f719b7

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# Fails the build on bootc layout violations.
RUN bootc container lint
