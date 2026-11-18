#!/usr/bin/env bash
# Runs as root: aligns the "steam" user with PUID/PGID (Unraid defaults 99:100),
# fixes volume ownership, then drops privileges and runs start.sh.
set -euo pipefail

PUID="${PUID:-99}"
PGID="${PGID:-100}"
DATA_DIR="${DATA_DIR:-/serverdata}"

if [ "$(id -u)" -ne 0 ]; then
    # Already unprivileged (e.g. --user was passed); just run.
    exec /opt/scripts/start.sh
fi

if ! getent group "$PGID" >/dev/null; then
    groupadd -o -g "$PGID" steam
fi
GROUP_NAME="$(getent group "$PGID" | cut -d: -f1)"

if id steam >/dev/null 2>&1; then
    usermod -o -u "$PUID" -g "$PGID" -d "$DATA_DIR/home" steam
else
    useradd -o -u "$PUID" -g "$PGID" -d "$DATA_DIR/home" -M -s /bin/bash steam
fi

mkdir -p "$DATA_DIR/home"

# Only chown when needed: a recursive chown over 30 GB is slow.
if [ "$(stat -c '%u:%g' "$DATA_DIR")" != "$PUID:$PGID" ] \
   || [ -n "$(find "$DATA_DIR" -maxdepth 2 \( ! -uid "$PUID" -o ! -gid "$PGID" \) -print -quit)" ]; then
    echo "[entrypoint] Fixing ownership of $DATA_DIR to $PUID:$PGID ($GROUP_NAME)..."
    chown -R "$PUID:$PGID" "$DATA_DIR"
fi

umask "${UMASK:-000}"
export HOME="$DATA_DIR/home"
exec gosu "$PUID:$PGID" /opt/scripts/start.sh
