#!/bin/bash
#
# speak-to-paste: press a shortcut, speak, press it again, and the text is pasted at your cursor.
# OpenSuperWhisper + the ivrit.ai Hebrew Whisper model, for macOS.
# Installs or updates the app, downloads and verifies the model, applies the
# recommended configuration on first install and launches the app.
# Safe to re-run: the same command installs and updates. Apple Silicon only.
#
# Usage:
#   bash install.sh                    install, or update to the pinned versions
#   bash install.sh --reset-settings   also restore the recommended settings

set -euo pipefail

APP_NAME="OpenSuperWhisper"
APP_VERSION="0.1.0"
APP_TEAM_ID="8LLDD7HWZK"
APP_DMG_URL="https://github.com/Starmel/OpenSuperWhisper/releases/download/${APP_VERSION}/OpenSuperWhisper.dmg"
APP_DMG_SHA256="af5ca5142c22e5bed3ba7d2642223c0a481e49935f5a5a6cf1bc766c7ecd9d69"

MODEL_URL="https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/2130c78e4a9cb4914cc4df91a1c3031407789705/ggml-model.bin?download=true"
MODEL_SHA256="c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1"
MODEL_BYTES=1624555275
MODEL_FILE="ggml-ivrit-large-v3-turbo.bin"

PREFS_DOMAIN="ru.starmel.OpenSuperWhisper"
SETUP_MARKER_KEY="speakToPasteSetupRevision"
SETUP_REVISION=1
APP_DIR="/Applications"
MODEL_DIR="$HOME/Library/Application Support/$PREFS_DOMAIN/whisper-models"

RESET_SETTINGS=0
APP_PATH=""
WORK_DIR=""
MOUNT_POINT=""

if [ -t 1 ]; then
  BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi

step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$RESET"; }
ok()   { printf '  %sok%s  %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!!%s  %s\n' "$YELLOW" "$RESET" "$1"; }
die()  { printf '\n%sError:%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

cleanup() {
  if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet -force >/dev/null 2>&1 || true
  fi
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}

sha256_of()   { shasum -a 256 "$1" | awk '{print $1}'; }
file_bytes()  { stat -f %z "$1"; }
app_version() { defaults read "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0"; }

version_lt() {
  local IFS=. i x y
  local -a a b
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  for i in 0 1 2 3; do
    x="${a[$i]:-0}"; x="${x%%[!0-9]*}"; x="${x:-0}"
    y="${b[$i]:-0}"; y="${y%%[!0-9]*}"; y="${y:-0}"
    [ "$x" -lt "$y" ] && return 0
    [ "$x" -gt "$y" ] && return 1
  done
  return 1
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --reset-settings) RESET_SETTINGS=1 ;;
      -h|--help)
        printf 'Usage: install.sh [--reset-settings]\n'
        printf '  Installs or updates OpenSuperWhisper with the ivrit.ai Hebrew model.\n'
        printf '  --reset-settings  also restore the recommended settings\n'
        exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

check_platform() {
  step "Checking this Mac"
  [ "$(uname -s)" = "Darwin" ] || die "This setup is for macOS only."
  if [ "$(uname -m)" != "arm64" ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]; then
    die "This setup needs an Apple Silicon Mac (M1 or newer). OpenSuperWhisper does not run on Intel Macs."
  fi
  local version major
  version="$(sw_vers -productVersion)"
  major="${version%%.*}"
  [ "$major" -ge 14 ] || die "macOS 14 (Sonoma) or newer is required. This Mac runs macOS $version."
  ok "Apple Silicon, macOS $version"
}

find_app() {
  local dir
  for dir in "$APP_DIR" "$HOME/Applications"; do
    if [ -d "$dir/$APP_NAME.app" ]; then
      printf '%s\n' "$dir/$APP_NAME.app"
      return 0
    fi
  done
  return 1
}

verify_app_signature() {
  local app="$1" team
  codesign --verify --deep --strict "$app" >/dev/null 2>&1 || die "Signature check failed for $app."
  team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ "$team" = "$APP_TEAM_ID" ] || die "Unexpected developer signature on $app (team '$team')."
}

download_app_dmg() {
  curl -fL --retry 3 --progress-bar -o "$1" "$APP_DMG_URL"
}

quit_app_if_running() {
  pgrep -xq "$APP_NAME" || return 0
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  local waited=0
  while [ "$waited" -lt 10 ]; do
    pgrep -xq "$APP_NAME" || return 0
    sleep 1
    waited=$((waited + 1))
  done
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 1
}

install_app() {
  step "$APP_NAME app"
  local existing="" installed="" target_dir="$APP_DIR"
  if existing="$(find_app)"; then
    installed="$(app_version "$existing")"
    if ! version_lt "$installed" "$APP_VERSION"; then
      APP_PATH="$existing"
      ok "Up to date: version $installed at $APP_PATH"
      return 0
    fi
    target_dir="$(dirname "$existing")"
    printf '  updating %s -> %s\n' "$installed" "$APP_VERSION"
  fi

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/speak-to-paste.XXXXXX")" || die "Could not create a temporary folder."
  local dmg="$WORK_DIR/$APP_NAME.dmg"
  download_app_dmg "$dmg" || die "Could not download $APP_NAME. Check your internet connection and run the script again."
  [ "$(sha256_of "$dmg")" = "$APP_DMG_SHA256" ] || die "The downloaded $APP_NAME installer failed its checksum."

  MOUNT_POINT="$WORK_DIR/mnt"
  mkdir -p "$MOUNT_POINT"
  hdiutil attach "$dmg" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT_POINT" -quiet \
    || die "Could not open the $APP_NAME installer image."
  local src="$MOUNT_POINT/$APP_NAME.app"
  [ -d "$src" ] || die "The installer image does not contain $APP_NAME.app."
  verify_app_signature "$src"

  if [ ! -w "$target_dir" ]; then
    [ -z "$existing" ] || die "No write access to $target_dir to update $APP_NAME."
    target_dir="$HOME/Applications"
    mkdir -p "$target_dir"
    warn "No write access to $APP_DIR, installing into $target_dir instead"
  fi

  local staged="$target_dir/.$APP_NAME.app.new"
  rm -rf "$staged"
  ditto "$src" "$staged" || die "Could not copy $APP_NAME into $target_dir."
  hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  MOUNT_POINT=""

  quit_app_if_running
  rm -rf "${target_dir:?}/$APP_NAME.app"
  mv "$staged" "$target_dir/$APP_NAME.app"

  APP_PATH="$target_dir/$APP_NAME.app"
  ok "Installed $APP_NAME $APP_VERSION at $APP_PATH"
}

check_disk_space() {
  local have_bytes=0 free_kb need_kb
  [ -f "$1" ] && have_bytes="$(file_bytes "$1")"
  free_kb="$(df -k "$MODEL_DIR" | awk 'NR==2 {print $4}')"
  need_kb=$(( (MODEL_BYTES - have_bytes) / 1024 + 512000 ))
  [ "$free_kb" -ge "$need_kb" ] || die "Not enough free disk space. About 2 GB is needed for the Hebrew model."
}

download_model() {
  curl -fL -C - --retry 5 --retry-delay 3 --progress-bar -o "$1" "$MODEL_URL"
}

install_model() {
  step "Hebrew model (ivrit.ai whisper-large-v3-turbo, 1.6 GB)"
  mkdir -p "$MODEL_DIR"
  local dest="$MODEL_DIR/$MODEL_FILE"
  local part="$dest.part"

  if [ -f "$dest" ]; then
    if [ "$(file_bytes "$dest")" = "$MODEL_BYTES" ] && [ "$(sha256_of "$dest")" = "$MODEL_SHA256" ]; then
      ok "Up to date and verified"
      return 0
    fi
    warn "The model file is out of date or corrupted, downloading it again"
    rm -f "$dest"
  fi

  check_disk_space "$part"
  if [ ! -f "$part" ] || [ "$(file_bytes "$part")" -lt "$MODEL_BYTES" ]; then
    printf '  downloading, this takes a few minutes...\n'
    download_model "$part" || die "The model download was interrupted. Run the same command again, it resumes where it stopped."
  fi

  printf '  verifying checksum...\n'
  if [ "$(sha256_of "$part")" != "$MODEL_SHA256" ]; then
    rm -f "$part"
    die "The downloaded model failed its checksum and was deleted. Run the same command again."
  fi
  mv -f "$part" "$dest"
  ok "Saved to $dest"
}

read_pref() { defaults read "$PREFS_DOMAIN" "$1" 2>/dev/null || true; }

write_pref() {
  defaults write "$PREFS_DOMAIN" "$1" "$2" "$3" >/dev/null 2>&1 || die "Could not save the $APP_NAME setting '$1'."
}

apply_settings() {
  step "Settings"
  local model_path="$MODEL_DIR/$MODEL_FILE" current_model

  if [ -n "$(read_pref "$SETUP_MARKER_KEY")" ] && [ "$RESET_SETTINGS" != "1" ]; then
    current_model="$(read_pref selectedWhisperModelPath)"
    if [ -z "$current_model" ] || [ ! -f "$current_model" ]; then
      quit_app_if_running
      write_pref selectedWhisperModelPath -string "$model_path"
      ok "Model selection repaired"
    fi
    ok "Kept your current settings (add --reset-settings to restore the recommended ones)"
    return 0
  fi

  quit_app_if_running
  write_pref selectedEngine -string whisper
  write_pref selectedWhisperModelPath -string "$model_path"
  write_pref whisperLanguage -string auto
  write_pref holdToRecord -bool true
  write_pref modifierOnlyHotkey -string none
  write_pref KeyboardShortcuts_toggleRecord -string '{"carbonModifiers":2048,"carbonKeyCode":50}'
  write_pref KeyboardShortcuts_escape -string '{"carbonModifiers":0,"carbonKeyCode":53}'
  write_pref playSoundOnRecordStart -bool false
  write_pref showTimestamps -bool false
  write_pref hasCompletedOnboarding -bool true
  write_pref "$SETUP_MARKER_KEY" -int "$SETUP_REVISION"
  ok "Hebrew model selected, language auto, shortcut Option + \`"
}

launch_app() {
  step "Launching $APP_NAME"
  open "$APP_PATH" || die "Could not launch $APP_PATH. Open it from the Applications folder."
  ok "Opened"
}

print_next_steps() {
  cat <<EOF

${BOLD}Done. If this is the first install, grant two one-time permissions in the
$APP_NAME window ("Required Permissions"):${RESET}
  1. Microphone Access: click "Grant Access" and allow.
  2. Accessibility Access: click "Grant Access", then switch $APP_NAME ON in the
     list that opens. This is what lets it paste the text where your cursor is.

${BOLD}How to use:${RESET}
  Put the cursor in any text field, press Option + \` (the key left of 1),
  speak, press it again. The text is pasted at the cursor.
  You can also hold the shortcut while speaking and release at the end.
  The first transcription after launch is slower while the model loads.
  Dictating mostly in English for a while? Pick English from the Language
  menu of the menu bar icon.

${BOLD}To update later:${RESET} run the same command again.
EOF
}

main() {
  parse_args "$@"
  trap cleanup EXIT
  printf '%sspeak-to-paste: OpenSuperWhisper + ivrit.ai%s\n' "$BOLD" "$RESET"
  check_platform
  install_app
  install_model
  apply_settings
  launch_app
  print_next_steps
}

[ "${OSW_SETUP_NO_MAIN:-}" = "1" ] || main "$@"
