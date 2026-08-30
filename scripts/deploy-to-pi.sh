#!/bin/bash
# Sync this working tree to a Raspberry Pi and restart KlipperScreen.
#
# KlipperScreen is pure Python, so there is nothing to build or cross compile.
# The only native code lives in the dependencies (PyGObject, pycairo, sdbus) and
# those are built on the Pi against its own GTK and girepository by the normal
# installer. This script just puts the source on the target and restarts it.
#
# Requires KlipperScreen to already be installed on the Pi via
# scripts/KlipperScreen-install.sh.

set -euo pipefail

SCRIPTPATH="$(dirname -- "$(readlink -f -- "$0")")"
KSPATH="$(dirname "$SCRIPTPATH")"

HOST="${KS_PI_HOST:-}"
REMOTE_DIR="${KS_PI_DIR:-KlipperScreen}"
REMOTE_VENV="${KS_PI_VENV:-.KlipperScreen-env}"
SERVICE="${KS_PI_SERVICE:-KlipperScreen}"
DO_DEPS=0
DO_LOGS=0
DO_ROLLBACK=0
DO_RESTART=1
DRY_RUN=0
ASSUME_YES=0

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; OFF=$'\e[0m'
info() { echo "${BOLD}==>${OFF} $*"; }
warn() { echo "${YELLOW}warning:${OFF} $*" >&2; }
die()  { echo "${RED}error:${OFF} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [user@host]

Sync the working tree to a Pi and restart KlipperScreen.

Options:
  -H, --host USER@HOST   Target (or set KS_PI_HOST)
  -d, --dir PATH         Remote checkout, relative to \$HOME  (default: $REMOTE_DIR)
  -e, --venv PATH        Remote venv, relative to \$HOME      (default: $REMOTE_VENV)
  -s, --service NAME     systemd unit                        (default: $SERVICE)
      --deps             Reinstall Python requirements in the remote venv
      --no-restart       Sync only, leave the running service alone
  -l, --logs             Follow journalctl after restarting
  -r, --rollback         Restore the previous sync and restart
  -n, --dry-run          Show what would be transferred, change nothing
  -y, --yes              Do not prompt for confirmation
  -h, --help             This message

Examples:
  $(basename "$0") pi@printer.local
  $(basename "$0") -n pi@printer.local            # preview the file list
  $(basename "$0") --deps --logs pi@printer.local
  $(basename "$0") --rollback pi@printer.local
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host)    HOST="$2"; shift 2 ;;
        -d|--dir)     REMOTE_DIR="$2"; shift 2 ;;
        -e|--venv)    REMOTE_VENV="$2"; shift 2 ;;
        -s|--service) SERVICE="$2"; shift 2 ;;
        --deps)       DO_DEPS=1; shift ;;
        --no-restart) DO_RESTART=0; shift ;;
        -l|--logs)    DO_LOGS=1; shift ;;
        -r|--rollback) DO_ROLLBACK=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -y|--yes)     ASSUME_YES=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "unknown option: $1 (try --help)" ;;
        *)            HOST="$1"; shift ;;
    esac
done

[ -n "$HOST" ] || { usage >&2; echo >&2; die "no target host given"; }
command -v rsync >/dev/null || die "rsync is not installed locally"

SSH=(ssh -o ConnectTimeout=10 -o BatchMode=yes)
BACKUP_DIR="${REMOTE_DIR}.deploy-bak"

remote() { "${SSH[@]}" "$HOST" "$@"; }

# Restart via sudo, falling back to an interactive prompt when passwordless
# sudo is not configured for this user.
remote_sudo() {
    if remote "sudo -n true" 2>/dev/null; then
        remote "sudo -n $*"
    else
        warn "passwordless sudo unavailable on $HOST, prompting"
        ssh -t "$HOST" "sudo $*"
    fi
}

info "Checking $HOST"
remote true 2>/dev/null || die "cannot reach $HOST over ssh with key auth"

REMOTE_ARCH="$(remote 'uname -m')"
REMOTE_HOME="$(remote 'echo "$HOME"')"
[ -n "$REMOTE_HOME" ] || die "could not determine the remote home directory"
case "$REMOTE_ARCH" in
    aarch64) ;;
    armv7l|armv6l) warn "remote is 32 bit ($REMOTE_ARCH), not the 64 bit Pi OS you asked about" ;;
    *) warn "unexpected remote architecture: $REMOTE_ARCH" ;;
esac

REMOTE_PATH="$REMOTE_HOME/$REMOTE_DIR"
VENV_PATH="$REMOTE_HOME/$REMOTE_VENV"
BACKUP_PATH="$REMOTE_HOME/$BACKUP_DIR"

remote "[ -d '$REMOTE_PATH' ]" \
    || die "$REMOTE_PATH does not exist, install KlipperScreen there first"

if [ "$DO_ROLLBACK" -eq 1 ]; then
    remote "[ -d '$BACKUP_PATH' ]" || die "no backup at $BACKUP_PATH to roll back to"
    info "Rolling $REMOTE_PATH back to the previous sync"
    remote "command -v rsync >/dev/null" || die "rsync is not installed on $HOST"
    remote "rsync -a --delete --exclude KlipperScreen.conf '$BACKUP_PATH/' '$REMOTE_PATH/'"
    remote "find '$REMOTE_PATH' -name __pycache__ -type d -prune -exec rm -rf {} +"
    if [ "$DO_RESTART" -eq 1 ]; then
        info "Restarting $SERVICE"
        remote_sudo "systemctl restart $SERVICE"
    fi
    echo "${GREEN}Rolled back.${OFF}"
    exit 0
fi

EXCLUDES=(
    --exclude '.git'
    --exclude '__pycache__'
    --exclude '*.py[cod]'
    --exclude 'KlipperScreen.conf'   # the Pi's own config, never overwrite it
    --exclude '.venv'
    --exclude 'venv'
    --exclude 'docs/extra'
    --exclude '.idea'
    --exclude '.vscode'
)

info "Changes to be sent to $HOST:$REMOTE_PATH"
RAW_CHANGES="$(rsync -ai --dry-run "${EXCLUDES[@]}" "$KSPATH/" "$HOST:$REMOTE_PATH/")" \
    || die "rsync could not reach $HOST:$REMOTE_PATH"
# Drop the directory-mtime-only lines, they are noise on every run.
CHANGES="$(echo "$RAW_CHANGES" | grep -v '^\.d\.\.t' || true)"
if [ -z "$CHANGES" ]; then
    echo "  (nothing to transfer, remote is already up to date)"
else
    echo "$CHANGES" | sed 's/^/  /'
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    info "Dry run, nothing was changed on $HOST"
    exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    echo
    if [ "$DO_RESTART" -eq 1 ]; then
        echo "This overwrites $REMOTE_PATH on $HOST and restarts $SERVICE."
    else
        echo "This overwrites $REMOTE_PATH on $HOST."
    fi
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" =~ ^[yY]$ ]] || { echo "Aborted."; exit 1; }
fi

info "Backing up $REMOTE_PATH to $BACKUP_PATH"
if remote "command -v rsync >/dev/null"; then
    remote "rsync -a --delete '$REMOTE_PATH/' '$BACKUP_PATH/'"
else
    die "rsync is not installed on $HOST, install it with: sudo apt install rsync"
fi

info "Syncing"
rsync -a --info=stats1 "${EXCLUDES[@]}" "$KSPATH/" "$HOST:$REMOTE_PATH/"
remote "find '$REMOTE_PATH' -name __pycache__ -type d -prune -exec rm -rf {} +"

if [ "$DO_DEPS" -eq 1 ]; then
    remote "[ -x '$VENV_PATH/bin/pip' ]" || die "no venv at $VENV_PATH"
    info "Reinstalling requirements in $VENV_PATH"
    remote "'$VENV_PATH/bin/pip' --disable-pip-version-check install \
        --extra-index-url https://www.piwheels.org/simple \
        -r '$REMOTE_PATH/scripts/KlipperScreen-requirements.txt' --prefer-binary"
fi

if [ "$DO_RESTART" -eq 0 ]; then
    echo "${GREEN}Synced.${OFF} Service left untouched."
    exit 0
fi

info "Restarting $SERVICE"
remote_sudo "systemctl restart $SERVICE"

# The unit has Restart=always, so a crash loop still reports active. Wait a
# moment and check that it stayed up rather than trusting the first reading.
sleep 3
if ! remote "systemctl is-active --quiet $SERVICE"; then
    warn "$SERVICE is not active"
    remote "systemctl status --no-pager -n 30 $SERVICE" || true
    die "deploy landed but the service did not come up, --rollback restores the previous tree"
fi
RESTARTS="$(remote "systemctl show -p NRestarts --value $SERVICE" || echo 0)"

echo "${GREEN}Deployed.${OFF} $SERVICE is active (NRestarts=$RESTARTS)."
echo "Watch it with: ssh $HOST journalctl -u $SERVICE -f"
echo "Undo it with:  $(basename "$0") --rollback $HOST"

if [ "$DO_LOGS" -eq 1 ]; then
    echo
    info "Following logs, ctrl-c to stop"
    ssh -t "$HOST" "journalctl -u $SERVICE -f -n 50"
fi
