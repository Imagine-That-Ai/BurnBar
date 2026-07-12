ARG BASE_IMAGE=archlinux:base-devel
FROM ${BASE_IMAGE}

# Pacman 7's Landlock sandbox is unavailable inside Docker build workers; the
# container boundary remains the package-manager isolation layer here.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
    && pacman -Syu --noconfirm --needed base-devel nodejs libarchive \
    && sed -i "s/^PKGEXT=.*/PKGEXT='.pkg.tar.zst'/" /etc/makepkg.conf \
    && useradd --create-home --uid 1000 openburnbar-builder \
    && pacman -Scc --noconfirm

WORKDIR /workspace
