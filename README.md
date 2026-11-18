# Black Mesa Co-Op server (SourceCoop) for Unraid

A Docker image that runs a **Black Mesa Dedicated Server** with
[SourceCoop](https://github.com/ampreeT/SourceCoop), so you and your friends can play the
Black Mesa campaign together.

The image is small. On first start, the container downloads the game server (Steam app
346680, about 30 GB) and installs Metamod:Source, SourceMod, Accelerator and SourceCoop
into your appdata folder. On each restart it checks for updates and only reinstalls a
component when its version has changed. It follows the steps of SourceCoop's
[official Linux installer](https://github.com/ampreeT/SourceCoop/blob/master/scripts/srccoop-bms-linux-install.sh).

## 1. Publish the image (one-time)

1. Push to `main` on https://github.com/BryanBest/blackmesa-coop.
2. The **Build and publish image** workflow builds `ghcr.io/bryanbest/blackmesa-coop:latest`.
   Check its progress in the repository's **Actions** tab.
3. Under **Packages → blackmesa-coop → Package settings**, make sure visibility is **Public**.
   Otherwise, Unraid needs a GitHub token to pull the image.

The workflow also rebuilds weekly to pick up Debian security updates. Game, SourceMod and
SourceCoop updates don't need a new image; restart the container to get them.

## 2. Install on Unraid

1. Copy `unraid/blackmesa-coop.xml` to the flash drive at
   `/boot/config/plugins/dockerMan/templates-user/my-BlackMesa-Coop.xml`.
   You can use the `flash` SMB share at `config/plugins/dockerMan/templates-user/`.
2. In **Docker → Add Container**, choose **BlackMesa-Coop** from the *Template* dropdown.
3. Set the server name and password, then click **Apply**.
4. Open the container's **Logs**. The first start downloads about 30 GB. The server is ready
   when you see the map `bm_c0a0a` load and `VAC secure mode is activated`.
5. On your router, forward **27015 TCP and UDP** to the Unraid server's IP address.

Keep the host ports the same as the container ports (27015). If you need a different port,
change both the port mapping and the `PORT` variable to the same value. This makes the
server advertise the correct port.

## 3. Join

Friends open the console in Black Mesa (enable it under *Options → Keyboard → Advanced*)
and run:

```
connect <your-public-ip>:27015
password <server-password>
```

They can also find the server in the server browser under the **Internet** tab. On your
own LAN, use the Unraid server's local IP address.

## Configuration

### Container variables

| Variable | Default | Purpose |
|---|---|---|
| `SERVER_NAME` | `Black Mesa: Cooperative` | Name shown in the server browser |
| `SERVER_PASSWORD` | *(empty)* | Join password. Empty means an open server |
| `RCON_PASSWORD` | *(empty)* | Empty means RCON is disabled |
| `MAXPLAYERS` | `32` | Number of player slots |
| `START_MAP` | `bm_c0a0a` | Map loaded on startup |
| `UPDATE_ON_START` | `true` | Run a SteamCMD update on each start |
| `VALIDATE` | `false` | Verify all game files on start (slow; use it to repair a broken install) |
| `SOURCECOOP_VERSION` | `latest` | `latest` or a release tag such as `v1.6` |
| `SOURCEMOD_URL` | *(empty)* | Empty means SourceMod 1.12 build 7163 (see below). `latest` means the newest 1.12 build. You can also give a full `.tar.gz` URL |
| `METAMOD_BRANCH` | `1.12` | Metamod:Source branch. The latest build of this branch is used |
| `INSTALL_ACCELERATOR` | `true` | Install the Accelerator crash reporter |
| `DELETE_TEXTURE_VPKS` | `false` | Delete texture packs the server doesn't need (saves about 9 GB) |
| `EXTRA_ARGS` | *(empty)* | Extra srcds arguments, for example `-tickrate 66` |
| `PUID` / `PGID` | `99` / `100` | Owner of the files in appdata |

### Files in appdata (`/mnt/user/appdata/blackmesa-coop`)

| Path | Notes |
|---|---|
| `server/bms/cfg/server.cfg` | Created once; you can edit it freely. Keep `exec docker.cfg` as the **last** line |
| `server/bms/cfg/mapcycle.txt` | Created once with the campaign maps |
| `server/bms/cfg/docker.cfg` | **Regenerated on every start** from the variables above. Don't edit it |
| `server/bms/cfg/sourcemod/srccoop.cfg` | SourceCoop settings (created after the first run) |
| `server/bms/addons/sourcemod/configs/admins_simple.ini` | SourceMod admins |
| `server/bms/custom/` | Workshop or custom maps (`.vpk` files or folders) |
| `.versions/` | Installed addon versions. Delete a file here to force a reinstall |

When SourceMod updates, your files in `addons/sourcemod/configs` and `cfg/sourcemod` are
kept. New default files are added, but existing ones are not overwritten.

### Make yourself an admin

Add your SteamID to `server/bms/addons/sourcemod/configs/admins_simple.ini`:

```
"STEAM_0:1:12345678"  "99:z"
```

Then restart the container, or run `sm_reloadadmins` in the console. Admins can use the
SourceCoop commands and votes listed in the
[SourceCoop README](https://github.com/ampreeT/SourceCoop#-commands).

### Server console

In Unraid, click the container icon and choose **Console**. Then run:

```bash
docker attach BlackMesa-Coop
```

Detach with `Ctrl+P` then `Ctrl+Q`. Don't use `Ctrl+C`, because it stops the server.
Useful commands: `status`, `sm plugins list`, `changelevel bm_c1a0a`.

### Workshop maps

Copy each map's `.vpk` file (or folder) into `server/bms/custom/`. Players must subscribe
to the same workshop item. The
[official SourceCoop collection](https://steamcommunity.com/sharedfiles/filedetails/?id=2375865650)
lists the supported maps. For details, see the
[Server running tips](https://github.com/ampreeT/SourceCoop/wiki/Server-running-tips).

## About the SourceMod version

SourceCoop requires **SourceMod 1.12 build 7163**. Newer builds have a detour-hooking
regression, and the SourceCoop release notes say *"DO NOT INSTALL NEWER VERSIONS"*.
AlliedModders has removed that build from its download mirror. The container first tries
the official URL, then falls back to the archive.org copy. Either way, it checks the file
against a pinned SHA-256 checksum before installing it.

If SourceCoop later supports newer builds, set `SOURCEMOD_URL=latest`.

## Build or test locally

```bash
docker compose up --build
```

(Uncomment `build: .` in `docker-compose.yml` first.) Game data goes to `./serverdata`.
