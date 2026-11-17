FROM ghcr.io/linuxserver/baseimage-kasmvnc:debianbookworm

# set version label
ARG BUILD_DATE
ARG VERSION
LABEL build_version="Metatrader Docker:- ${VERSION} Build-date:- ${BUILD_DATE}"
LABEL maintainer="gmartin"

ENV TITLE=Metatrader5
ENV WINEPREFIX="/config/.wine"
ENV WINEDEBUG=-all

# Install all packages in a single layer to reduce image size
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    wget \
    curl \
    gnupg2 \
    software-properties-common \
    ca-certificates \
    && mkdir -pm755 /etc/apt/keyrings \
    && wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
    && wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
    && dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install --install-recommends -y winehq-staging \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /etc/apt/keyrings/winehq-archive.key

# KasmVNC client bug in the base image: inside LinuxServer's kclient iframe the
# client starts a 5 second keep-alive interval that reads UI.rfb.lastActiveAt,
# but disconnectFinished() sets UI.rfb = undefined as soon as the websocket
# drops (idle tab, laptop sleep, network blip, container restart). The interval
# then throws "Cannot read properties of undefined (reading 'lastActiveAt')"
# and KasmVNC replaces the whole session with its error overlay. Guard the
# interval so a dropped session stops updating instead of crashing the client.
# Remove this once the base image ships a fixed KasmVNC (1.3.4+ / 1.4+).
RUN set -eux; \
    bundle="/usr/local/share/kasmvnc/www/dist/main.bundle.js"; \
    if [ ! -f "$bundle" ]; then bundle="/usr/share/kasmvnc/www/dist/main.bundle.js"; fi; \
    test -f "$bundle"; \
    grep -q 'UI\._sessionTimeoutInterval = setInterval(function *() *{' "$bundle"; \
    sed -i '/UI\._sessionTimeoutInterval = setInterval(function *() *{/a\        if (!UI.rfb) { return; }' "$bundle"; \
    grep -q 'if (!UI.rfb) { return; }' "$bundle"

COPY /Metatrader /Metatrader
RUN chmod +x /Metatrader/start.sh
COPY /root /

EXPOSE 3000 8001
VOLUME /config
