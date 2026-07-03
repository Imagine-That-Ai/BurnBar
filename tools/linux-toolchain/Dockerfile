FROM swift:6.2-noble@sha256:dd349c6dfc3cd3040910a84ab3e5bd5d08efdd547e5fb9f77b765abed16fe5ff

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-transport-https \
        build-essential \
        ca-certificates \
        cargo \
        dbus \
        dbus-x11 \
        desktop-file-utils \
        dpkg-dev \
        fakeroot \
        file \
        git \
        gnupg \
        jq \
        libayatana-appindicator3-dev \
        libatspi2.0-dev \
        libei-dev \
        libgtk-3-dev \
        libkf5wallet-dev \
        libpipewire-0.3-dev \
        libsecret-1-dev \
        libsqlcipher-dev \
        libsqlite3-dev \
        libssl-dev \
        libwebkit2gtk-4.1-dev \
        libx11-dev \
        libxcb1-dev \
        libxkbcommon-dev \
        libxrandr-dev \
        nodejs \
        npm \
        patchelf \
        pipewire \
        pkg-config \
        rpm \
        rustc \
        sqlcipher \
        sqlite3 \
        xdg-desktop-portal \
        xdg-desktop-portal-gtk \
        xz-utils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY smoke.sh /usr/local/bin/openburnbar-linux-toolchain-smoke
RUN chmod +x /usr/local/bin/openburnbar-linux-toolchain-smoke

CMD ["/usr/local/bin/openburnbar-linux-toolchain-smoke"]
