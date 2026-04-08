#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./sign-all-files-gpg.sh DIRECTORY [GPG_KEY_ID]

Description:
  Recursively signs all regular files inside DIRECTORY with GPG detached
  armored signatures, creating one .asc file for each input file.

Behavior:
  - walks all subdirectories
  - skips existing .asc signature files
  - skips directories and special files
  - overwrites existing signature files
  - preserves the original files unchanged

Arguments:
  DIRECTORY   Root directory whose files will be signed recursively
  GPG_KEY_ID  Optional GPG key ID, fingerprint, or email to use explicitly

Examples:
  ./sign-all-files-gpg.sh ./reports
  ./sign-all-files-gpg.sh ./reports 0xDEADBEEFCAFEBABE
  ./sign-all-files-gpg.sh ./reports "your@email.com"
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

[[ $# -lt 1 || $# -gt 2 ]] && usage && exit 1

TARGET_DIR="$(readlink -f "$1")"
GPG_KEY_ID="${2:-}"

[[ -d "$TARGET_DIR" ]] || die "Directory not found: $TARGET_DIR"

need_cmd gpg
need_cmd find
need_cmd readlink

if ! gpg --list-secret-keys >/dev/null 2>&1; then
    die "No GPG secret key available in the current user keyring"
fi

declare -a GPG_ARGS
GPG_ARGS=(gpg --batch --yes --armor --detach-sign)

if [[ -n "$GPG_KEY_ID" ]]; then
    GPG_ARGS+=(--local-user "$GPG_KEY_ID")
fi

log "Target directory: $TARGET_DIR"
if [[ -n "$GPG_KEY_ID" ]]; then
    log "Using explicit GPG identity: $GPG_KEY_ID"
else
    log "Using default GPG secret key"
fi

SIGNED_COUNT=0
SKIPPED_COUNT=0

while IFS= read -r -d '' file; do
    # Skip signature files themselves
    if [[ "$file" == *.asc ]]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    sig_file="${file}.asc"
    log "Signing: $file"
    "${GPG_ARGS[@]}" -o "$sig_file" "$file"
    SIGNED_COUNT=$((SIGNED_COUNT + 1))
done < <(find "$TARGET_DIR" -type f -print0)

log "Done."
log "Files signed: $SIGNED_COUNT"
log "Files skipped (.asc): $SKIPPED_COUNT"