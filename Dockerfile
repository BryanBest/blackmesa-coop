# Black Mesa Dedicated Server + SourceCoop
#
# The image itself is small: it only contains the runtime libraries, SteamCMD
# and the startup scripts. The ~30 GB game server, Metamod:Source, SourceMod
# and SourceCoop are installed into the /serverdata volume on first start and
# kept up to date on every restart.

FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# Source dedicated servers and SteamCMD are 32-bit binaries.
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gosu \
      jq \
      tini \
      unzip \
      lib32gcc-s1 \
      lib32stdc++6 \
      lib32z1 \
      libncurses5 \
      libncurses5:i386 \
      libtinfo5:i386 \
      libcurl3-gnutls:i386 \
 && rm -rf /var/lib/apt/lists/*

# Bundled copy of SteamCMD; copied into the volume on first start so it can
# self-update as the unprivileged user.
RUN mkdir -p /opt/steamcmd \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C /opt/steamcmd

COPY scripts/  /opt/scripts/
COPY defaults/ /opt/defaults/
RUN sed -i 's/\r$//' /opt/scripts/*.sh /opt/defaults/* \
 && chmod +x /opt/scripts/*.sh

ENV DATA_DIR=/serverdata \
    PUID=99 \
    PGID=100 \
    UMASK=000 \
    SERVER_NAME="Black Mesa: Cooperative" \
    SERVER_PASSWORD="" \
    RCON_PASSWORD="" \
    MAXPLAYERS=32 \
    START_MAP=bm_c0a0a \
    PORT=27015 \
    TV_PORT=27020 \
    CLIENT_PORT=27005 \
    UPDATE_ON_START=true \
    VALIDATE=false \
    SOURCECOOP_VERSION=latest \
    METAMOD_BRANCH=1.12 \
    SOURCEMOD_URL="" \
    INSTALL_ACCELERATOR=true \
    DELETE_TEXTURE_VPKS=false \
    EXTRA_ARGS=""

EXPOSE 27015/tcp 27015/udp 27020/udp
VOLUME ["/serverdata"]

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/scripts/entrypoint.sh"]
