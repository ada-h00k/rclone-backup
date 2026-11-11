#!/usr/bin/env bash
#
# rclone-backup installer: one systemd user service + one timer. No root, no wrapper.
# Optionally guides you through setting up a Filen remote and a local-encrypted
# (rclone crypt) remote on top of it.
#
#   ./install.sh               install / update
#   ./install.sh --uninstall   remove service and timer
#
# Override settings via environment, e.g.:
#   SOURCE_DIR=$HOME/Documents REMOTE_DEST=filen:Documents ./install.sh
#
set -euo pipefail

RCLONE_BIN="${RCLONE_BIN:-$(command -v rclone || echo /home/linuxbrew/.linuxbrew/bin/rclone)}"
SOURCE_DIR="${SOURCE_DIR:-$HOME/Sync}"
# Both must point to the same *crypt* remote, so that archived files are encrypted too.
REMOTE_DEST="${REMOTE_DEST:-filen-crypt:Sync}"
REMOTE_BACKUP_BASE="${REMOTE_BACKUP_BASE:-filen-crypt:old}"   # changed/deleted files go to <base>/YYYY-MM-DD
ALLOW_UNENCRYPTED="${ALLOW_UNENCRYPTED:-0}"            # set to 1 to skip the crypt check

# Guided remote setup
FILEN_REMOTE="${FILEN_REMOTE:-filen}"                  # name of the Filen remote
CRYPT_TARGET="${CRYPT_TARGET:-$FILEN_REMOTE:encrypted}" # folder the crypt remote stores its data in
SKIP_REMOTE_SETUP="${SKIP_REMOTE_SETUP:-0}"            # set to 1 to never run the guided setup
TTY_DEV="${TTY_DEV:-/dev/tty}"                         # prompts read from here (works with curl | bash)
ON_CALENDAR="${ON_CALENDAR:-*-*-* 03:00:00}"
WAIT_HOST="${WAIT_HOST:-gateway.filen.io}"             # host that must resolve before the backup starts (network ready check)

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--uninstall" ]]; then
  systemctl --user disable --now rclone-backup.timer 2>/dev/null || true
  rm -f "$UNIT_DIR/rclone-backup.service" "$UNIT_DIR/rclone-backup.timer" "$UNIT_DIR/rclone-backup-failure.service"
  systemctl --user daemon-reload
  info "Removed."
  exit 0
fi

[[ $EUID -ne 0 ]] || die "Run this as your normal user, not as root."
command -v systemctl >/dev/null || die "systemd is required."
[[ -x "$RCLONE_BIN" ]] || die "rclone not found. Set RCLONE_BIN=/path/to/rclone"

NOTIFY_BIN="${NOTIFY_BIN:-$(command -v notify-send || true)}"
if [[ -z "$NOTIFY_BIN" ]]; then
  warn "notify-send not found: failure notifications will not show. Install it (Debian/Ubuntu: libnotify-bin, Fedora/Arch: libnotify)."
  NOTIFY_BIN=/usr/bin/notify-send
fi

# ---------- Guided rclone setup (Filen + crypt) ----------
tty_ok() { [[ -r "$TTY_DEV" ]] && { : <"$TTY_DEV"; } 2>/dev/null; }

ask() {            # ask "prompt" [default]
  local ans
  printf '%s' "$1" >&2
  read -r -u 3 ans || ans=""
  echo "${ans:-${2:-}}"
}
ask_secret() {     # ask_secret "prompt"
  local ans
  printf '%s' "$1" >&2
  read -rs -u 3 ans || ans=""
  echo >&2
  echo "$ans"
}
confirm() { [[ "$(ask "$1 [Y/n] " Y)" =~ ^[Yy] ]]; }   # default yes

have_remote() { "$RCLONE_BIN" listremotes | grep -qx "$1:"; }
obscure()     { printf '%s' "$1" | "$RCLONE_BIN" obscure -; }

# Sets CONF to the rclone config path; refuses to touch an encrypted config.
prepare_conf() {
  CONF="$("$RCLONE_BIN" config file | tail -n1)"
  mkdir -p "$(dirname "$CONF")"
  touch "$CONF"
  chmod 600 "$CONF"
  if grep -q '^RCLONE_ENCRYPT_V0' "$CONF"; then
    die "Your rclone.conf is password-protected, so it cannot be edited automatically. Run 'rclone config' manually (see README)."
  fi
}

setup_filen() {    # setup_filen <remote-name>
  local name="$1" email pass apikey
  cat >&2 <<EOF

------------------------------------------------------------
 Step 1: Set up Filen as rclone remote '$name'
------------------------------------------------------------
rclone needs three things for Filen: your e-mail, your password and an API key.
The API key can only be created with the Filen CLI:

  1. Download the Filen CLI:  https://github.com/FilenCloudDienste/filen-cli
  2. Log in with it:          filen   (follow the login prompt)
  3. Export the API key:      filen export-api-key

Tip: copy the key into a plain text editor first and copy it again from there
(avoids invisible characters from terminals/web pages).

EOF
  confirm "Do you have your Filen API key ready?" \
    || { warn "Come back when you have it, then re-run this installer."; exit 1; }

  email="$(ask 'Filen e-mail: ')"
  pass="$(ask_secret 'Filen password (hidden): ')"
  apikey="$(ask_secret 'Filen API key (hidden): ')"
  [[ -n "$email" && -n "$pass" && -n "$apikey" ]] || die "E-mail, password and API key are all required."

  prepare_conf
  {
    echo
    echo "[$name]"
    echo "type = filen"
    echo "email = $email"
    echo "password = $(obscure "$pass")"
    echo "api_key = $(obscure "$apikey")"
  } >> "$CONF"
  info "Remote '$name' written to $CONF"

  info "Testing connection to Filen ..."
  if "$RCLONE_BIN" lsd "$name:" >/dev/null 2>&1; then
    info "Filen connection works."
  else
    "$RCLONE_BIN" lsd "$name:" || true
    die "Could not connect to Filen. Check e-mail/password/API key (fix with 'rclone config'), then re-run."
  fi
}

setup_crypt() {    # setup_crypt <remote-name> <target e.g. filen:encrypted>
  local name="$1" target="$2" pass salt mode
  cat >&2 <<EOF

------------------------------------------------------------
 Step 2: Create the encrypted remote '$name'
------------------------------------------------------------
Everything is encrypted on THIS machine (file contents, file names and folder
names) before it is uploaded, independent of Filen's own encryption.
Encrypted data will be stored in: $target

EOF
  mode="$(ask 'Passwords: [g] generate random (recommended) or [e] enter my own? [g/e] ' g)"
  if [[ "$mode" =~ ^[Ee] ]]; then
    pass="$(ask_secret 'Encryption password (hidden): ')"
    [[ "$pass" == "$(ask_secret 'Repeat password: ')" ]] || die "Passwords do not match."
    salt="$(ask_secret 'Salt password (hidden, different from the password): ')"
    [[ "$salt" == "$(ask_secret 'Repeat salt: ')" ]] || die "Salt passwords do not match."
  else
    pass="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
    salt="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
    cat >&2 <<EOF

  Generated credentials. Store them in your password manager NOW:

    Password: $pass
    Salt:     $salt

EOF
  fi
  [[ -n "$pass" && -n "$salt" ]] || die "Password and salt must not be empty."
  cat >&2 <<EOF
WITHOUT THESE TWO VALUES (or a copy of rclone.conf) YOUR BACKUP CANNOT BE DECRYPTED. NOBODY CAN RECOVER IT.
EOF
  [[ "$(ask "Type 'yes' once you have saved them: ")" == "yes" ]] || die "Aborted: credentials not confirmed as saved. Nothing was written."

  prepare_conf
  {
    echo
    echo "[$name]"
    echo "type = crypt"
    echo "remote = $target"
    echo "filename_encryption = standard"
    echo "directory_name_encryption = true"
    echo "password = $(obscure "$pass")"
    echo "password2 = $(obscure "$salt")"
  } >> "$CONF"
  info "Remote '$name' written to $CONF"
  unset pass salt

  info "Testing encrypted remote ..."
  "$RCLONE_BIN" mkdir "$name:" \
    || die "Could not create the encrypted folder. Check the underlying remote with: rclone lsd ${target%%:*}:"
  info "Encrypted remote works."
}

guided_setup() {
  local crypt_name="${REMOTE_DEST%%:*}" base="${CRYPT_TARGET%%:*}"
  have_remote "$crypt_name" && return 0     # already there, nothing to do

  if ! tty_ok; then
    warn "Remote '$crypt_name' does not exist and no terminal is available for the guided setup."
    return 0                                # check_crypt will print the final error
  fi

  exec 3<"$TTY_DEV"                         # keep one handle open so sequential reads advance
  echo >&2
  info "The encrypted remote '$crypt_name' does not exist yet."
  confirm "Set it up now (guided)?" || return 0

  if have_remote "$base"; then
    info "Using existing remote '$base' as storage."
  else
    setup_filen "$base"
  fi
  setup_crypt "$crypt_name" "$CRYPT_TARGET"
}
[[ "$SKIP_REMOTE_SETUP" == "1" ]] || guided_setup

# Make sure the destination is an rclone crypt remote (otherwise data would be stored unencrypted)
check_crypt() {
  local remote="${1%%:*}"
  "$RCLONE_BIN" listremotes | grep -qx "$remote:" \
    || die "rclone remote '$remote' not found. Create it first (see README, 'Set up encryption')."
  if ! "$RCLONE_BIN" config show "$remote" | grep -qE '^type *= *crypt'; then
    [[ "$ALLOW_UNENCRYPTED" == "1" ]] \
      || die "Remote '$remote' is not a crypt remote. Refusing to install (set ALLOW_UNENCRYPTED=1 to override)."
    warn "Remote '$remote' is NOT encrypted."
  fi
}
check_crypt "$REMOTE_DEST"
check_crypt "$REMOTE_BACKUP_BASE"

mkdir -p "$UNIT_DIR"

info "Writing $UNIT_DIR/rclone-backup.service"
# Note: in systemd unit files "$$" = literal "$" and "%%" = literal "%".
cat > "$UNIT_DIR/rclone-backup.service" <<'EOF'
[Unit]
Description=Daily rclone backup
# Desktop notification if the run fails
OnFailure=rclone-backup-failure.service

[Service]
Type=oneshot
# Fail (and notify) if the source is missing, e.g. unmounted, so an empty folder is never synced
ExecStartPre=/usr/bin/test -d "@SOURCE_DIR@"
# User services cannot wait for network-online.target, so wait here (max. 5 min) until DNS works,
# e.g. after a catch-up run right after login/boot
ExecStartPre=/bin/bash -c 'for i in $$(seq 1 60); do getent hosts "@WAIT_HOST@" >/dev/null && exit 0; sleep 5; done; echo "Network not ready: cannot resolve @WAIT_HOST@" >&2; exit 1'
ExecStart=/bin/bash -c 'exec "@RCLONE_BIN@" sync "@SOURCE_DIR@" "@REMOTE_DEST@" \
  --backup-dir "@REMOTE_BACKUP_BASE@/$$(date +%%Y-%%m-%%d)" \
  --exclude ".stversions/**" \
  --exclude ".stfolder/**" \
  --exclude ".stfolder.removed*/**"'
Nice=10
IOSchedulingClass=idle
EOF
sed -i \
  -e "s#@RCLONE_BIN@#$RCLONE_BIN#g" \
  -e "s#@SOURCE_DIR@#$SOURCE_DIR#g" \
  -e "s#@WAIT_HOST@#$WAIT_HOST#g" \
  -e "s#@REMOTE_DEST@#$REMOTE_DEST#g" \
  -e "s#@REMOTE_BACKUP_BASE@#$REMOTE_BACKUP_BASE#g" \
  "$UNIT_DIR/rclone-backup.service"

info "Writing $UNIT_DIR/rclone-backup-failure.service"
cat > "$UNIT_DIR/rclone-backup-failure.service" <<EOF
[Unit]
Description=Desktop notification for failed rclone backup

[Service]
Type=oneshot
ExecStart=$NOTIFY_BIN --urgency=critical --icon=dialog-error "rclone backup failed" "Check logs: journalctl --user -u rclone-backup.service"
EOF

info "Writing $UNIT_DIR/rclone-backup.timer"
cat > "$UNIT_DIR/rclone-backup.timer" <<EOF
[Unit]
Description=Run rclone backup daily

[Timer]
OnCalendar=$ON_CALENDAR
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now rclone-backup.timer

if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)" != "yes" ]]; then
  loginctl enable-linger "$USER" 2>/dev/null \
    || warn "Could not enable linger. Run once: sudo loginctl enable-linger $USER"
fi

info "Installed. Test backup:        systemctl --user start rclone-backup.service"
info "Test notification:   systemctl --user start rclone-backup-failure.service"
