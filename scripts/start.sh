#!/usr/bin/env bash
# Installs/updates Black Mesa Dedicated Server, Metamod:Source, SourceMod,
# Accelerator and SourceCoop into $DATA_DIR, writes configs, then runs srcds.
#
# Mirrors the official SourceCoop Linux installer:
#   https://github.com/ampreeT/SourceCoop/blob/master/scripts/srccoop-bms-linux-install.sh
set -euo pipefail

DATA_DIR="${DATA_DIR:-/serverdata}"
STEAMCMD_DIR="$DATA_DIR/steamcmd"
SERVER_DIR="$DATA_DIR/server"
GAME_DIR="$SERVER_DIR/bms"
VERSIONS_DIR="$DATA_DIR/.versions"
TMP_DIR="$DATA_DIR/.tmp"
APP_ID=346680

# Defaults (the Dockerfile sets these too; repeated so the script is safe under set -u).
: "${SERVER_NAME:=Black Mesa: Cooperative}" "${SERVER_PASSWORD:=}" "${RCON_PASSWORD:=}"
: "${MAXPLAYERS:=32}" "${START_MAP:=bm_c0a0a}" "${PORT:=27015}" "${TV_PORT:=27020}" "${CLIENT_PORT:=27005}"
: "${UPDATE_ON_START:=true}" "${VALIDATE:=false}" "${SOURCECOOP_VERSION:=latest}" "${METAMOD_BRANCH:=1.12}"
: "${SOURCEMOD_URL:=}" "${INSTALL_ACCELERATOR:=true}" "${DELETE_TEXTURE_VPKS:=false}" "${EXTRA_ARGS:=}"

export HOME="${HOME:-$DATA_DIR/home}"

# SourceCoop requires SourceMod 1.12 build 7163 ("DO NOT INSTALL NEWER VERSIONS"
# per upstream). AlliedModders has since pruned it from their mirror, so fall
# back to the archive.org copy and verify it against a known checksum.
SM_PINNED_NAME="sourcemod-1.12.0-git7163-linux.tar.gz"
SM_PINNED_URLS=(
    "https://sm.alliedmods.net/smdrop/1.12/$SM_PINNED_NAME"
    "https://web.archive.org/web/20260502124756id_/https://sm.alliedmods.net/smdrop/1.12/$SM_PINNED_NAME"
)
SM_PINNED_SHA256="56d6a396fae37412c602e86ed163c5e58a45d90b8ee7f3046929aebd2e3b6267"

log()  { echo "[start] $*"; }
warn() { echo "[start] WARNING: $*" >&2; }
die()  { echo "[start] ERROR: $*" >&2; exit 1; }
is_true() { case "${1,,}" in 1|true|yes|on) return 0;; *) return 1;; esac; }

download() { # url dest
    curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$2" "$1"
}

marker_get() { cat "$VERSIONS_DIR/$1" 2>/dev/null || true; }
marker_set() { echo "$2" > "$VERSIONS_DIR/$1"; }

mkdir -p "$HOME" "$VERSIONS_DIR" "$TMP_DIR" "$SERVER_DIR"
rm -rf "${TMP_DIR:?}"/*

# --------------------------------------------------------------------------
# SteamCMD + game server
# --------------------------------------------------------------------------
if [ ! -x "$STEAMCMD_DIR/steamcmd.sh" ]; then
    log "Installing SteamCMD into $STEAMCMD_DIR..."
    mkdir -p "$STEAMCMD_DIR"
    cp -a /opt/steamcmd/. "$STEAMCMD_DIR/"
fi

update_server() {
    local validate=""
    is_true "$VALIDATE" && validate="validate"
    local attempt
    for attempt in 1 2 3; do
        log "Updating Black Mesa Dedicated Server (app $APP_ID), attempt $attempt..."
        # SteamCMD sometimes exits non-zero right after self-updating; retry.
        # shellcheck disable=SC2086
        if "$STEAMCMD_DIR/steamcmd.sh" \
            +force_install_dir "$SERVER_DIR" \
            +login anonymous \
            +app_update "$APP_ID" $validate \
            +quit; then
            return 0
        fi
        warn "SteamCMD exited with an error."
    done
    return 1
}

if [ ! -x "$SERVER_DIR/srcds_run" ]; then
    log "Game server not found - first install will download ~30 GB, this can take a while."
    update_server || die "SteamCMD failed to install the game server."
elif is_true "$UPDATE_ON_START"; then
    update_server || warn "SteamCMD update failed; starting the existing install."
else
    log "UPDATE_ON_START=false - skipping game server update."
fi
[ -x "$SERVER_DIR/srcds_run" ] || die "$SERVER_DIR/srcds_run is missing after install."

# The engine looks for the Steam client library here.
mkdir -p "$HOME/.steam/sdk32"
ln -sf "$STEAMCMD_DIR/linux32/steamclient.so" "$HOME/.steam/sdk32/steamclient.so"

if is_true "$DELETE_TEXTURE_VPKS"; then
    log "DELETE_TEXTURE_VPKS=true - removing texture VPKs (~9 GB, not needed server-side)."
    rm -f "$GAME_DIR"/bms_textures* "$SERVER_DIR"/hl2/hl2_textures*
fi

# --------------------------------------------------------------------------
# Addons. Each step: resolve the wanted version, install only if it differs
# from the version recorded in $VERSIONS_DIR. A network failure is fatal only
# when the addon is not installed yet.
# --------------------------------------------------------------------------
addon_failed() { # name
    if [ -n "$(marker_get "$1")" ]; then
        warn "Could not check/update $1; keeping installed version $(marker_get "$1")."
    else
        die "Could not install $1."
    fi
}

install_metamod() {
    local branch="${METAMOD_BRANCH:-1.12}" name url
    name="$(curl -fsSL --retry 3 "https://mms.alliedmods.net/mmsdrop/$branch/mmsource-latest-linux")" || return 1
    [ "$name" = "$(marker_get metamod)" ] && { log "Metamod:Source $name is up to date."; return 0; }
    url="https://mms.alliedmods.net/mmsdrop/$branch/$name"
    log "Installing Metamod:Source $name..."
    download "$url" "$TMP_DIR/mm.tar.gz" || return 1
    tar -xzf "$TMP_DIR/mm.tar.gz" -C "$GAME_DIR" || return 1
    marker_set metamod "$name"
}

install_sourcemod() {
    local want archive="$TMP_DIR/sm.tar.gz"
    if [ -z "${SOURCEMOD_URL:-}" ]; then
        want="$SM_PINNED_NAME"
    elif [ "${SOURCEMOD_URL,,}" = "latest" ]; then
        want="$(curl -fsSL --retry 3 https://sm.alliedmods.net/smdrop/1.12/sourcemod-latest-linux)" || return 1
    else
        want="$SOURCEMOD_URL"
    fi
    [ "$want" = "$(marker_get sourcemod)" ] && { log "SourceMod $want is up to date."; return 0; }

    log "Installing SourceMod $want..."
    if [ -z "${SOURCEMOD_URL:-}" ]; then
        local ok="" u
        for u in "${SM_PINNED_URLS[@]}"; do
            if download "$u" "$archive" \
               && echo "$SM_PINNED_SHA256  $archive" | sha256sum -c --quiet -; then
                ok=1; break
            fi
            warn "SourceMod download/checksum failed from $u"
        done
        [ -n "$ok" ] || return 1
    elif [ "${SOURCEMOD_URL,,}" = "latest" ]; then
        download "https://sm.alliedmods.net/smdrop/1.12/$want" "$archive" || return 1
    else
        download "$SOURCEMOD_URL" "$archive" || return 1
    fi

    # Overwrite binaries/plugins, but never clobber the user's configs
    # (admins, databases, cfg/sourcemod/*.cfg). New config files are added.
    tar -xzf "$archive" -C "$GAME_DIR" \
        --exclude='addons/sourcemod/configs' --exclude='cfg/sourcemod' || return 1
    tar -xzf "$archive" -C "$GAME_DIR" --skip-old-files \
        addons/sourcemod/configs cfg/sourcemod 2>/dev/null || true
    marker_set sourcemod "$want"
}

install_accelerator() {
    local path name
    path="$(curl -fsSL --retry 3 "https://builds.limetech.io/?p=accelerator" \
            | grep -m1 -o 'files/accelerator-[^"]*-linux\.zip')" || return 1
    name="$(basename "$path")"
    [ "$name" = "$(marker_get accelerator)" ] && { log "Accelerator $name is up to date."; return 0; }
    log "Installing Accelerator $name..."
    download "https://builds.limetech.io/$path" "$TMP_DIR/acc.zip" || return 1
    # The zip wraps everything in a top-level linux/ folder.
    rm -rf "$TMP_DIR/acc"
    unzip -oq "$TMP_DIR/acc.zip" -d "$TMP_DIR/acc" || return 1
    local src="$TMP_DIR/acc"
    [ -d "$src/linux/addons" ] && src="$src/linux"
    [ -d "$src/addons" ] || { warn "Unexpected Accelerator archive layout"; return 1; }
    cp -a "$src/addons" "$GAME_DIR/" || return 1
    marker_set accelerator "$name"
}

install_sourcecoop() {
    local api json tag url
    if [ -z "${SOURCECOOP_VERSION:-}" ] || [ "${SOURCECOOP_VERSION,,}" = "latest" ]; then
        api="https://api.github.com/repos/ampreeT/SourceCoop/releases/latest"
    else
        api="https://api.github.com/repos/ampreeT/SourceCoop/releases/tags/$SOURCECOOP_VERSION"
    fi
    json="$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "$api")" || return 1
    tag="$(jq -r '.tag_name' <<<"$json")"
    url="$(jq -r '[.assets[].browser_download_url | select(test("bms\\.zip$"))][0] // empty' <<<"$json")"
    [ -n "$url" ] || { warn "No *bms.zip asset in SourceCoop release $tag"; return 1; }
    [ "$tag" = "$(marker_get sourcecoop)" ] && { log "SourceCoop $tag is up to date."; return 0; }
    log "Installing SourceCoop $tag..."
    download "$url" "$TMP_DIR/sc.zip" || return 1
    unzip -oq "$TMP_DIR/sc.zip" -d "$GAME_DIR" || return 1
    marker_set sourcecoop "$tag"
}

install_metamod    || addon_failed metamod
install_sourcemod  || addon_failed sourcemod
if is_true "$INSTALL_ACCELERATOR"; then
    install_accelerator || addon_failed accelerator
fi
install_sourcecoop || addon_failed sourcecoop
rm -rf "${TMP_DIR:?}"/*

# --------------------------------------------------------------------------
# Configs
# --------------------------------------------------------------------------
CFG_DIR="$GAME_DIR/cfg"
mkdir -p "$CFG_DIR"

# Seeded once; edit them freely in appdata afterwards.
for f in server.cfg mapcycle.txt; do
    if [ ! -f "$CFG_DIR/$f" ]; then
        log "Creating default cfg/$f"
        cp /opt/defaults/"$f" "$CFG_DIR/$f"
    fi
done
for f in autoexec.cfg userconfig.cfg; do
    [ -f "$CFG_DIR/$f" ] || : > "$CFG_DIR/$f"
done
if ! grep -qE '^[[:space:]]*exec[[:space:]]+"?docker(\.cfg)?"?' "$CFG_DIR/server.cfg"; then
    warn "cfg/server.cfg does not 'exec docker.cfg'; container env vars (name/passwords) will be ignored."
fi

# Strip characters that would break out of a quoted cvar value.
q() { local v="${1//\"/}"; v="${v//$'\n'/ }"; printf '"%s"' "$v"; }

# Regenerated on every start from environment variables.
{
    echo "// AUTO-GENERATED by the container on every start from environment variables."
    echo "// Do not edit - change the container settings instead, or override in server.cfg."
    echo "hostname $(q "$SERVER_NAME")"
    echo "sv_password $(q "$SERVER_PASSWORD")"
    echo "rcon_password $(q "$RCON_PASSWORD")"
    echo "sv_lan 0"
} > "$CFG_DIR/docker.cfg"

if [ -n "$SERVER_PASSWORD" ]; then
    log "Server password is set."
else
    log "No server password - anyone can join."
fi

# --------------------------------------------------------------------------
# Launch
# --------------------------------------------------------------------------
cd "$SERVER_DIR"
log "Starting srcds on port $PORT with map $START_MAP (maxplayers $MAXPLAYERS)..."
# EXTRA_ARGS is intentionally word-split.
# shellcheck disable=SC2086
exec ./srcds_run \
    -console \
    -game bms \
    -ip 0.0.0.0 \
    -port "$PORT" \
    -clientport "$CLIENT_PORT" \
    -norestart \
    +tv_port "$TV_PORT" \
    +maxplayers "$MAXPLAYERS" \
    +mp_teamplay 1 \
    +mapcyclefile mapcycle.txt \
    +map "$START_MAP" \
    $EXTRA_ARGS
