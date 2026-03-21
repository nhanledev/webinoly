#!/usr/bin/env bash
set -euo pipefail

# Non-destructive local installer for Webinoly project files.
# Mirrors weby "install" phase after download/extract:
# - place project files in /opt/webinoly
# - ensure permissions
# - install command entrypoints to /usr/bin
# Differences from upstream weby:
# - no download logic
# - no "sudo rm weby"
# - no destructive replace of /opt/webinoly

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_OPT="/opt/webinoly"
INSTALL_BIN_DIR="/usr/bin"
INSTALL_WEBY_BIN_DIR="/usr/local/bin"
SKIP_BIN=0
SKIP_WEBY_BIN=0
RUN_VERIFY=1

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-bin)
			SKIP_BIN=1
			shift
			;;
		--skip-weby-bin)
			SKIP_WEBY_BIN=1
			shift
			;;
		--skip-verify)
			RUN_VERIFY=0
			shift
			;;
		-h|--help)
			cat <<'EOF'
Usage: ./scripts/deploy-safe.sh [--skip-bin] [--skip-weby-bin] [--skip-verify]

Options:
  --skip-bin       Do not install command scripts into /usr/bin.
  --skip-weby-bin  Do not install weby into /usr/local/bin.
  --skip-verify    Do not run "webinoly -verify=critical" at the end.
  -h, --help       Show this help.
EOF
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
	esac
done

if [[ ! -d "$REPO_DIR/lib" || ! -d "$REPO_DIR/templates" || ! -d "$REPO_DIR/usr" || ! -f "$REPO_DIR/weby" ]]; then
	echo "This script must run from a valid Webinoly repository checkout." >&2
	exit 1
fi

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "Missing required command: $1" >&2
		exit 1
	}
}

need_cmd sudo
need_cmd rsync
need_cmd install

echo "[1/5] Ensuring destination directories..."
sudo mkdir -p "$DEST_OPT"
sudo mkdir -p "$DEST_OPT/templates/source"

echo "[2/5] Syncing repository files into $DEST_OPT (non-destructive)..."
sudo rsync -a "$REPO_DIR/lib/" "$DEST_OPT/lib/"
sudo rsync -a "$REPO_DIR/templates/" "$DEST_OPT/templates/"
sudo rsync -a "$REPO_DIR/usr/" "$DEST_OPT/usr/"
sudo rsync -a "$REPO_DIR/weby" "$DEST_OPT/weby"
sudo rsync -a "$REPO_DIR/README.md" "$DEST_OPT/README.md"
sudo rsync -a "$REPO_DIR/LICENSE" "$DEST_OPT/LICENSE"

echo "[3/5] Applying permissions (matching upstream installer)..."
sudo find "$DEST_OPT" -type d -exec chmod 755 {} \;
sudo find "$DEST_OPT" -type f -exec chmod 644 {} \;
sudo chmod -f 744 "$DEST_OPT"/lib/ex-* 2>/dev/null || true
sudo chmod -f 755 "$DEST_OPT"/usr/* 2>/dev/null || true
sudo chmod -f 755 "$DEST_OPT/weby" || true

echo "[4/5] Initializing webinoly.conf for local install..."
if [[ ! -f "$DEST_OPT/webinoly.conf" ]]; then
	sudo cp -a "$DEST_OPT/templates/general/conf" "$DEST_OPT/webinoly.conf"
fi

APP_VERSION="$(awk -F'"' '/readonly app_version=/{print $2; exit}' "$REPO_DIR/lib/general")"
if [[ -z "$APP_VERSION" ]]; then
	echo "Could not detect app_version from $REPO_DIR/lib/general" >&2
	exit 1
fi

if sudo grep -qE "^[#[:space:]]*app-version:.*$" "$DEST_OPT/webinoly.conf"; then
	sudo sed -i -E "s|^[#[:space:]]*app-version:.*$|app-version:$APP_VERSION|" "$DEST_OPT/webinoly.conf"
else
	echo "app-version:$APP_VERSION" | sudo tee -a "$DEST_OPT/webinoly.conf" >/dev/null
fi

if [[ "$SKIP_BIN" -eq 0 ]]; then
	echo "[4.5/5] Installing command scripts into $INSTALL_BIN_DIR..."
	sudo install -m 0755 "$DEST_OPT/usr/stack" "$INSTALL_BIN_DIR/stack"
	sudo install -m 0755 "$DEST_OPT/usr/log" "$INSTALL_BIN_DIR/log"
	sudo install -m 0755 "$DEST_OPT/usr/site" "$INSTALL_BIN_DIR/site"
	sudo install -m 0755 "$DEST_OPT/usr/webinoly" "$INSTALL_BIN_DIR/webinoly"
	sudo install -m 0755 "$DEST_OPT/usr/httpauth" "$INSTALL_BIN_DIR/httpauth"
else
	echo "[4.5/5] Skipping command scripts (--skip-bin)."
fi

if [[ "$SKIP_WEBY_BIN" -eq 0 ]]; then
	sudo install -m 0755 "$DEST_OPT/weby" "$INSTALL_WEBY_BIN_DIR/weby"
else
	echo "[4.6/5] Skipping weby binary install (--skip-weby-bin)."
fi

if [[ "$SKIP_BIN" -eq 0 ]]; then
	# weby installer ends by purging /opt/webinoly/usr after moving binaries.
	sudo rm -rf "$DEST_OPT/usr"
fi

echo "[5/5] Quick verification of required paths..."
required_paths=(
	"$DEST_OPT/lib/verify"
	"$DEST_OPT/templates/nginx/nginx.conf"
	"$DEST_OPT/templates/source"
)

for path in "${required_paths[@]}"; do
	if [[ ! -e "$path" ]]; then
		echo "Missing expected path: $path" >&2
		exit 1
	fi
done

echo
echo "Install completed."
echo
if [[ "$RUN_VERIFY" -eq 1 ]]; then
	echo "Running: sudo webinoly -verify=critical"
	sudo webinoly -verify=critical
else
	echo "Verify skipped (--skip-verify)."
	echo "Run manually: sudo webinoly -verify=critical"
fi
