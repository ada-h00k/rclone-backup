# rclone-backup

One systemd **user** service + one timer that backs up a folder once a day with
[rclone](https://rclone.org/). Changed or deleted files are moved into a dated
archive folder instead of being destroyed. No root, no wrapper script.

It runs:

```bash
rclone sync ~/Sync filen-crypt:Sync \
  --backup-dir filen-crypt:old/$(date +%Y-%m-%d) \
  --exclude ".stversions/**" \
  --exclude ".stfolder/**" \
  --exclude ".stfolder.removed*/**"
```

## Requirements

- Linux with systemd
- `rclone` 1.73+ installed (needed for the Filen backend)
- A Filen account and its API key (the installer explains how to get it)
- `curl` and `bash`

Files and file names are encrypted client-side by rclone's
[crypt](https://rclone.org/crypt/) backend before they leave your machine.

## Guided setup (Filen + local encryption)

When you run the installer and the encrypted remote does not exist yet, it offers to
set everything up for you, step by step. This also works with `curl | bash`, because
the prompts are read from your terminal (`/dev/tty`).

1. **Filen remote** (only if it does not exist yet). rclone needs your e-mail, your
   password and an **API key**. The key can only be created with the
   [Filen CLI](https://github.com/FilenCloudDienste/filen-cli): log in there and run
   `filen export-api-key`. The installer stores your password and key obscured in
   `rclone.conf` (via `rclone obscure`, never on a command line) and tests the connection.
2. **Encrypted remote** (`filen-crypt`, a rclone *crypt* remote on top of
   `filen:encrypted`). File contents, file names and folder names are encrypted on your
   machine before upload, independent of Filen's own encryption. You can let the
   installer generate a strong password and salt, or enter your own. It shows them once
   and only continues after you type `yes` to confirm you saved them.

Both `REMOTE_DEST` and `REMOTE_BACKUP_BASE` use the crypt remote, so the dated archive
folders are encrypted too.

> **Save your password and salt (or a copy of `~/.config/rclone/rclone.conf`) in a
> password manager.** Without them the backup **cannot be decrypted** by anyone.
> The values in `rclone.conf` are only obscured, not secure: keep that file private
> (the installer sets mode `600`).

Notes:

- Requires rclone **1.73 or newer** for the `filen` backend (check `rclone version`).
- If your `rclone.conf` is password-protected, the installer cannot edit it. Create the
  remotes yourself with `rclone config` (names `filen` and `filen-crypt`, crypt target
  `filen:encrypted`), and add `Environment=RCLONE_CONFIG_PASS=...` or
  `RCLONE_PASSWORD_COMMAND=...` to the service.
- Without a terminal (e.g. cron, CI) the guided setup is skipped and the installer
  stops with a hint. The destination must always be a crypt remote, otherwise the
  installer refuses to continue (override: `ALLOW_UNENCRYPTED=1`).
- Skip the guided setup entirely with `SKIP_REMOTE_SETUP=1`.
- If you entered a wrong key, the remote is already saved: fix it with `rclone config`
  (or delete it with `rclone config delete filen`) and re-run the installer.

## Install

> Replace `YOURUSER/rclone-backup` with the place where you host `install.sh`.

```bash
curl -fsSL https://raw.githubusercontent.com/YOURUSER/rclone-backup/main/install.sh | bash
```

With custom settings (variables go **after** the pipe):

```bash
curl -fsSL https://raw.githubusercontent.com/YOURUSER/rclone-backup/main/install.sh \
  | SOURCE_DIR="$HOME/Documents" REMOTE_DEST="filen-crypt:Documents" ON_CALENDAR="*-*-* 02:30:00" bash
```

Or download and inspect first (recommended):

```bash
curl -fsSLO https://raw.githubusercontent.com/YOURUSER/rclone-backup/main/install.sh
less install.sh && bash install.sh
```

| Variable             | Default             | Description                                  |
|----------------------|---------------------|----------------------------------------------|
| `RCLONE_BIN`         | `rclone` from PATH  | Path to the rclone binary                    |
| `SOURCE_DIR`         | `$HOME/Sync`        | Local folder to back up                      |
| `REMOTE_DEST`        | `filen-crypt:Sync`  | Crypt remote target for the mirror           |
| `REMOTE_BACKUP_BASE` | `filen-crypt:old`   | Old/deleted files go to `<base>/YYYY-MM-DD`  |
| `ALLOW_UNENCRYPTED`  | `0`                 | Set `1` to skip the crypt-remote check       |
| `FILEN_REMOTE`       | `filen`             | Name of the Filen remote (guided setup)      |
| `CRYPT_TARGET`       | `filen:encrypted`   | Where the crypt remote stores its data       |
| `SKIP_REMOTE_SETUP`  | `0`                 | Set `1` to skip the guided setup             |
| `WAIT_HOST`          | `gateway.filen.io`  | Host that must resolve before a run starts   |
| `ON_CALENDAR`        | `*-*-* 03:00:00`    | systemd calendar expression                  |

## What gets installed

- `~/.config/systemd/user/rclone-backup.service`
- `~/.config/systemd/user/rclone-backup-failure.service` (desktop notification, started via `OnFailure=` when a backup fails)
- `~/.config/systemd/user/rclone-backup.timer` (daily, `Persistent=true`: a missed run is caught up after boot)

The installer also runs `loginctl enable-linger` so the timer fires while you are logged out.
If that fails, run `sudo loginctl enable-linger $USER` once.

## Failure notifications

If a run fails (full storage, no network, wrong credentials, missing source folder, ...)
the service shows a critical desktop notification via `notify-send`. Test it with:

```bash
systemctl --user start rclone-backup-failure.service
```

Requirements: `notify-send` (Debian/Ubuntu: `libnotify-bin`, Fedora/Arch: `libnotify`) and a
running graphical session. If you are logged out when the backup runs (lingering), there is
no desktop to show the message on; check the log instead.

## Catch-up runs after boot

With `Persistent=true` a missed run starts right after you log in, often before the network
and DNS are ready. User services cannot wait for `network-online.target`, so the service
waits up to 5 minutes until `WAIT_HOST` resolves before starting rclone. If the network
never comes up, the run fails and you get the notification.

## Usage

```bash
systemctl --user start rclone-backup.service        # run now
journalctl --user -u rclone-backup.service -f       # logs
systemctl --user list-timers rclone-backup.timer    # next run
systemctl --user disable --now rclone-backup.timer  # pause schedule
```

## Changing settings

Edit the unit files directly, then reload:

```bash
systemctl --user edit --full rclone-backup.service   # command, excludes, paths
systemctl --user edit --full rclone-backup.timer     # schedule
systemctl --user daemon-reload && systemctl --user restart rclone-backup.timer
```

Inside the unit, `$$` means a literal `$` and `%%` a literal `%` (systemd escaping),
which is why the date reads `$$(date +%%Y-%%m-%%d)`.

Tip: add `--dry-run` to the `ExecStart` line to test safely first.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/YOURUSER/rclone-backup/main/install.sh | bash -s -- --uninstall
```

## Notes

- `rclone sync` makes the remote an exact mirror. Deleted/overwritten files are moved to
  `<REMOTE_BACKUP_BASE>/<date>`. Old archive folders are **not** pruned automatically,
  e.g. `rclone purge filen-crypt:old/2025-01-01`.
- The backup dir must not be inside the destination (defaults are fine: `Sync` and `old` are separate folders).
- If the source folder is missing (e.g. unmounted drive), the service fails
  (`ExecStartPre=test -d`) and you get a notification, instead of syncing an empty folder.
