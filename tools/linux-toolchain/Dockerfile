# syntax=docker/dockerfile:1.7

FROM swift:6.2-noble@sha256:dd349c6dfc3cd3040910a84ab3e5bd5d08efdd547e5fb9f77b765abed16fe5ff

ARG DEBIAN_FRONTEND=noninteractive
ARG SQLCIPHER_VERSION=4.5.6
ARG SQLCIPHER_SHA256=e4a527e38e67090c1d2dc41df28270d16c15f7ca5210a3e7ec4c4b8fda36e28f
ARG SQLCIPHER_PREFIX=/opt/openburnbar/sqlcipher
ARG RUST_TOOLCHAIN=1.96.0

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 update \
    && apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 install -y --no-install-recommends \
        apt-transport-https \
        ayatana-indicator-application \
        build-essential \
        ca-certificates \
        curl \
        dbus \
        dbus-x11 \
        at-spi2-core \
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
        libpam0g-dev \
        libpipewire-0.3-dev \
        libsecret-1-dev \
        libsecret-tools \
        libglib2.0-bin \
        libreadline-dev \
        librsvg2-dev \
        libsqlite3-dev \
        libssl-dev \
        libwebkit2gtk-4.1-dev \
        libx11-dev \
        libxcb1-dev \
        libxkbcommon-dev \
        libxrandr-dev \
        nodejs \
        npm \
        openbox \
        orca \
        patchelf \
        pipewire \
        pkg-config \
        procps \
        python3-pyatspi \
        rpm \
        scrot \
        squashfs-tools \
        sqlite3 \
        tcl \
        x11-utils \
        xauth \
        xdotool \
        xfce4-panel \
        xfce4-sntray-plugin \
        xvfb \
        xdg-desktop-portal \
        xdg-desktop-portal-gtk \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo
ENV PATH="${CARGO_HOME}/bin:${PATH}"

RUN set -eux; \
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}" \
        --component clippy --component rustfmt; \
    rm /tmp/rustup-init.sh; \
    rustc --version; \
    cargo --version; \
    rustup show active-toolchain

RUN set -eux; \
    mkdir -p /usr/local/share/openburnbar "${SQLCIPHER_PREFIX}"; \
    curl -fsSLo /tmp/sqlcipher.tar.gz "https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v${SQLCIPHER_VERSION}.tar.gz"; \
    echo "${SQLCIPHER_SHA256}  /tmp/sqlcipher.tar.gz" > /tmp/sqlcipher.tar.gz.sha256; \
    sha256sum -c /tmp/sqlcipher.tar.gz.sha256; \
    mkdir -p /tmp/sqlcipher-src; \
    tar -xzf /tmp/sqlcipher.tar.gz --strip-components=1 -C /tmp/sqlcipher-src; \
    cd /tmp/sqlcipher-src; \
    ./configure \
        --prefix="${SQLCIPHER_PREFIX}" \
        --enable-tempstore=yes \
        --enable-fts3 \
        --enable-fts4 \
        --enable-fts5 \
        --enable-rtree \
        --with-crypto-lib=openssl \
        CFLAGS="-O2 -fPIC -DSQLITE_HAS_CODEC -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_STAT4" \
        LDFLAGS="-lcrypto"; \
    make -j"$(nproc)"; \
    make install; \
    echo "${SQLCIPHER_PREFIX}/lib" > /etc/ld.so.conf.d/openburnbar-sqlcipher.conf; \
    ldconfig; \
    { \
        echo "sqlcipher_version=${SQLCIPHER_VERSION}"; \
        echo "source_url=https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v${SQLCIPHER_VERSION}.tar.gz"; \
        echo "source_sha256=${SQLCIPHER_SHA256}"; \
        echo "prefix=${SQLCIPHER_PREFIX}"; \
        echo "configure=--enable-tempstore=yes --enable-fts3 --enable-fts4 --enable-fts5 --enable-rtree --with-crypto-lib=openssl"; \
        echo "cflags=-O2 -fPIC -DSQLITE_HAS_CODEC -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_STAT4"; \
        echo "ldflags=-lcrypto"; \
    } > /usr/local/share/openburnbar/sqlcipher-build.txt; \
    sha256sum /tmp/sqlcipher.tar.gz > /usr/local/share/openburnbar/sqlcipher-source.sha256; \
    rm -rf /tmp/sqlcipher-src /tmp/sqlcipher.tar.gz /tmp/sqlcipher.tar.gz.sha256

ENV PATH="${SQLCIPHER_PREFIX}/bin:${CARGO_HOME}/bin:${PATH}"
ENV PKG_CONFIG_PATH="${SQLCIPHER_PREFIX}/lib/pkgconfig"
ENV LD_LIBRARY_PATH="${SQLCIPHER_PREFIX}/lib"
ENV OPENBURNBAR_SQLCIPHER_PREFIX="${SQLCIPHER_PREFIX}"

WORKDIR /workspace
COPY smoke.sh /usr/local/bin/openburnbar-linux-toolchain-smoke
RUN chmod +x /usr/local/bin/openburnbar-linux-toolchain-smoke

CMD ["/usr/local/bin/openburnbar-linux-toolchain-smoke"]
