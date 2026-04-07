#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  sudo ./mint-repack-burn-verify-sign.sh ISO_PATH WORKDIR DEVICE [bios|uefi] [GPG_KEY_ID]

Examples:
  sudo ./mint-repack-burn-verify-sign.sh \
    linuxmint-22.3-cinnamon-64bit.iso \
    working_dir \
    /dev/sdb \
    uefi

  sudo ./mint-repack-burn-verify-sign.sh \
    linuxmint-22.3-cinnamon-64bit.iso \
    working_dir \
    /dev/sdb \
    uefi \
    0xDEADBEEFCAFEBABE

What it does:
  1. Extracts the ISO into WORKDIR/extract
  2. Extracts boot images into WORKDIR/boot_images
  3. Adds "nopersistent" to boot=casper lines
  4. Locks GRUB editing and CLI with a random password that is discarded
  5. Rebuilds the ISO as <original>-repacked.iso
  6. Burns the rebuilt ISO to the target device
  7. Fills remaining device space with zeros
  8. Verifies the ISO area byte-for-byte
  9. Generates SHA-256, SHA-512, and BLAKE2b hashes of the full device
  10. Generates an ISO SHA-256 report
  11. Signs all generated report files with GPG detached armored signatures
  12. Boots the pendrive in QEMU for visual verification

Notes:
  - DEVICE must be the whole device, for example /dev/sdb, not /dev/sdb1
  - This will DESTROY all data on DEVICE
  - GPG_KEY_ID is optional; if omitted, the default secret key is used
  - GRUB locking applies to the GRUB path
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

confirm() {
    local prompt="$1"
    local reply
    read -r -p "$prompt [yes/NO]: " reply
    [[ "$reply" == "yes" ]]
}

backup_file() {
    local f="$1"
    if [[ -f "$f" && ! -f "$f.bak" ]]; then
        cp -a "$f" "$f.bak"
    fi
}

generate_random_password() {
    python3 - <<'PY'
import secrets
import string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(20)))
PY
}

make_pbkdf2_hash() {
    local plain="$1"
    local hash

    hash="$(
expect <<EOF
log_user 0
set timeout 30
spawn env LC_ALL=C LANG=C grub-mkpasswd-pbkdf2

expect {
    -re {Enter password:.*} {}
    timeout { exit 10 }
    eof { exit 11 }
}
send -- "$plain\r"

expect {
    -re {Reenter password:.*} {}
    timeout { exit 12 }
    eof { exit 13 }
}
send -- "$plain\r"

expect {
    -re {(grub\.pbkdf2\.[^\r\n ]+)} {
        puts \$expect_out(1,string)
    }
    timeout { exit 14 }
    eof { exit 15 }
}
EOF
    )" || die "grub-mkpasswd-pbkdf2 interaction failed"

    [[ -n "$hash" ]] || die "Failed to extract GRUB PBKDF2 hash"
    printf '%s\n' "$hash"
}

patch_nopersistent_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    backup_file "$f"

    perl -0pi -e '
        s{
            ^(.*\bboot=casper\b)(?![^\n]*\bnopersistent\b)(.*)$
        }{$1 nopersistent$2}mgx
    ' "$f"
}

patch_grub_file() {
    local f="$1"
    local pbkdf2_hash="$2"
    [[ -f "$f" ]] || return 0
    backup_file "$f"

    perl -0pi -e '
        s{
            ^(.*\bboot=casper\b)(?![^\n]*\bnopersistent\b)(.*)$
        }{$1 nopersistent$2}mgx
    ' "$f"

    if ! grep -q '^set superusers=' "$f"; then
        local tmpfile
        tmpfile="$(mktemp)"
        {
            printf 'set superusers="grpadmin"\n'
            printf 'password_pbkdf2 grpadmin %s\n' "$pbkdf2_hash"
            printf '\n'
            cat "$f"
        } > "$tmpfile"
        mv "$tmpfile" "$f"
    fi

    perl -0pi -e '
        s{
            ^(\s*menuentry)(?![^\n]*--unrestricted)(?![^\n]*--users)(\s+)
        }{$1 --unrestricted$2}mgx
    ' "$f"
}

hr() {
    printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
}

safe_unmount_children() {
    local dev="$1"
    mapfile -t CHILD_PARTS < <(lsblk -lnpo NAME,TYPE "$dev" | awk '$2=="part"{print $1}')
    for part in "${CHILD_PARTS[@]:-}"; do
        if lsblk -lnpo MOUNTPOINT "$part" | grep -q .; then
            umount "$part" || die "Failed to unmount $part"
        fi
    done
}

get_volume_id() {
    local iso="$1"
    local vid
    vid="$(isoinfo -d -i "$iso" 2>/dev/null | awk -F': ' '/Volume id:/ {print $2; exit}')"
    [[ -n "$vid" ]] || vid="LINUX_MINT_REPACKED"
    printf '%s\n' "$vid"
}

compute_hash_report() {
    local dev="$1"
    local report_file="$2"

    local dev_size_bytes dev_size_mib model vendor serial timestamp
    dev_size_bytes=$(blockdev --getsize64 "$dev")
    dev_size_mib=$(awk "BEGIN {printf \"%.2f\", $dev_size_bytes/1024/1024}")
    model=$(lsblk -dn -o MODEL "$dev" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    vendor=$(lsblk -dn -o VENDOR "$dev" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    serial=$(lsblk -dn -o SERIAL "$dev" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')

    local tmpdir
    tmpdir=$(mktemp -d)

    {
        hr
        echo "WHOLE-DEVICE CRYPTOGRAPHIC HASH REPORT"
        hr
        printf "%-18s %s\n" "Device:" "$dev"
        printf "%-18s %s\n" "Timestamp:" "$timestamp"
        printf "%-18s %s bytes (%s MiB)\n" "Size:" "$dev_size_bytes" "$dev_size_mib"
        printf "%-18s %s\n" "Vendor:" "${vendor:-N/A}"
        printf "%-18s %s\n" "Model:" "${model:-N/A}"
        printf "%-18s %s\n" "Serial:" "${serial:-N/A}"
        hr
        echo "Computing hashes. This may take a while."
        echo
    } | tee "$report_file"

    echo "Calculating SHA-256..."
    local sha256
    sha256=$(dd if="$dev" bs=16M iflag=fullblock status=progress 2>"$tmpdir/dd.sha256.log" | sha256sum | awk '{print $1}')
    echo

    echo "Calculating SHA-512..."
    local sha512
    sha512=$(dd if="$dev" bs=16M iflag=fullblock status=progress 2>"$tmpdir/dd.sha512.log" | sha512sum | awk '{print $1}')
    echo

    echo "Calculating BLAKE2b-512..."
    local blake2b
    blake2b=$(dd if="$dev" bs=16M iflag=fullblock status=progress 2>"$tmpdir/dd.b2.log" | b2sum | awk '{print $1}')
    echo

    {
        hr
        echo "HASH RESULTS"
        hr
        printf "%-12s %s\n" "SHA-256:" "$sha256"
        printf "%-12s %s\n" "SHA-512:" "$sha512"
        printf "%-12s %s\n" "BLAKE2b:" "$blake2b"
        hr
        echo "Machine-readable lines:"
        printf "sha256  %s  %s\n" "$sha256" "$dev"
        printf "sha512  %s  %s\n" "$sha512" "$dev"
        printf "blake2b %s  %s\n" "$blake2b" "$dev"
        hr
    } | tee -a "$report_file"

    rm -rf "$tmpdir"
    log "Hash report saved to: $report_file"
}

compute_iso_sha256_report() {
    local iso="$1"
    local report_file="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    {
        hr
        echo "REPACKED ISO SHA-256 REPORT"
        hr
        printf "%-18s %s\n" "Timestamp:" "$ts"
        printf "%-18s %s\n" "ISO:" "$iso"
        printf "%-18s %s bytes\n" "Size:" "$(stat -c '%s' "$iso")"
        hr
        sha256sum "$iso"
        hr
    } | tee "$report_file"

    log "ISO SHA-256 report saved to: $report_file"
}

write_burn_report() {
    local report_file="$1"
    local iso="$2"
    local dev="$3"
    local iso_size="$4"
    local dev_size="$5"
    local remaining="$6"

    {
        hr
        echo "BURN AND VERIFY REPORT"
        hr
        printf "%-18s %s\n" "Timestamp:" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf "%-18s %s\n" "ISO:" "$iso"
        printf "%-18s %s\n" "Device:" "$dev"
        printf "%-18s %s bytes\n" "ISO size:" "$iso_size"
        printf "%-18s %s bytes\n" "Device size:" "$dev_size"
        printf "%-18s %s bytes\n" "Zero-filled tail:" "$remaining"
        printf "%-18s %s\n" "ISO area verify:" "OK"
        hr
    } | tee "$report_file"

    log "Burn report saved to: $report_file"
}

sign_report_files() {
    local key_id="$1"
    shift
    local reports=("$@")

    [[ ${#reports[@]} -gt 0 ]] || return 0

    local gpg_args=(gpg --batch --yes --armor --detach-sign)
    if [[ -n "$key_id" ]]; then
        gpg_args+=(--local-user "$key_id")
    fi

    for f in "${reports[@]}"; do
        [[ -f "$f" ]] || die "Cannot sign missing report file: $f"
        "${gpg_args[@]}" -o "${f}.asc" "$f" || die "GPG signing failed for: $f"
        log "Signed: ${f}.asc"
    done
}

launch_qemu() {
    local dev="$1"
    local mode="$2"
    local ovmf_code="$3"

    echo
    log "Launching QEMU for visual boot verification..."
    echo "Close the QEMU window when you are done testing."
    echo

    local qemu_common=(
        qemu-system-x86_64
        -m 4096
        -device qemu-xhci
        -drive "if=none,id=usbstick,format=raw,readonly=on,file=$dev"
        -device usb-storage,drive=usbstick
    )

    if [[ -e /dev/kvm && -w /dev/kvm ]]; then
        qemu_common+=(-enable-kvm)
    fi

    if [[ "$mode" == "bios" ]]; then
        "${qemu_common[@]}"
    else
        "${qemu_common[@]}" \
            -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
    fi
}

[[ $# -lt 3 || $# -gt 5 ]] && usage && exit 1

ISO_INPUT="$(readlink -f "$1")"
WORKDIR="$(readlink -f "$2")"
DEV="$3"
BOOT_MODE="${4:-bios}"
GPG_KEY_ID="${5:-}"

[[ -f "$ISO_INPUT" ]] || die "ISO file not found: $ISO_INPUT"
mkdir -p "$WORKDIR"
[[ -b "$DEV" ]] || die "Target is not a block device: $DEV"
[[ "$BOOT_MODE" == "bios" || "$BOOT_MODE" == "uefi" ]] || die "Boot mode must be bios or uefi"
[[ $EUID -eq 0 ]] || die "Run as root with sudo"

case "$DEV" in
    /dev/sd[a-z]|/dev/sd[a-z][a-z]|/dev/nvme[0-9]n[0-9]|/dev/mmcblk[0-9])
        ;;
    *)
        die "Refusing unusual device path: $DEV"
        ;;
esac

need_cmd xorriso
need_cmd rsync
need_cmd perl
need_cmd sed
need_cmd awk
need_cmd grep
need_cmd mktemp
need_cmd find
need_cmd grub-mkpasswd-pbkdf2
need_cmd python3
need_cmd expect
need_cmd tr
need_cmd dd
need_cmd cmp
need_cmd sha256sum
need_cmd sha512sum
need_cmd b2sum
need_cmd stat
need_cmd blockdev
need_cmd lsblk
need_cmd umount
need_cmd qemu-system-x86_64
need_cmd gpg
need_cmd isoinfo

if ! gpg --list-secret-keys >/dev/null 2>&1; then
    die "No GPG secret key available. Import or create one before running the script."
fi

OVMF_CODE=""
if [[ "$BOOT_MODE" == "uefi" ]]; then
    for f in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/ovmf/OVMF.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd
    do
        if [[ -f "$f" ]]; then
            OVMF_CODE="$f"
            break
        fi
    done
    [[ -n "$OVMF_CODE" ]] || die "UEFI mode requested, but OVMF firmware file was not found"
fi

ISO_BASENAME="$(basename "$ISO_INPUT")"
ISO_DIR="$(dirname "$ISO_INPUT")"
ISO_STEM="${ISO_BASENAME%.iso}"
ISO_OUTPUT="${ISO_DIR}/${ISO_STEM}-repacked.iso"

EXTRACT_DIR="${WORKDIR}/extract"
BOOT_IMAGES_DIR="${WORKDIR}/boot_images"

PATCH_LOG="${WORKDIR}/patch-report.txt"
BUILD_LOG="${WORKDIR}/rebuild-report.txt"
BURN_REPORT="${WORKDIR}/burn-report.txt"
HASH_REPORT="${WORKDIR}/$(basename "$DEV").hash-report.txt"
ISO_HASH_REPORT="${WORKDIR}/repacked-iso-sha256.txt"

mkdir -p "$EXTRACT_DIR" "$BOOT_IMAGES_DIR"

log "Input ISO: $ISO_INPUT"
log "Working directory: $WORKDIR"
log "Target device: $DEV"
log "Output repacked ISO: $ISO_OUTPUT"
log "Boot mode for QEMU: $BOOT_MODE"
if [[ -n "$GPG_KEY_ID" ]]; then
    log "GPG signing key: $GPG_KEY_ID"
else
    log "GPG signing key: default secret key"
fi
echo

echo "Current block device layout:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$DEV"
echo
confirm "This will erase ALL data on $DEV. Continue?" || exit 1

rm -rf "$EXTRACT_DIR" "$BOOT_IMAGES_DIR"
mkdir -p "$EXTRACT_DIR" "$BOOT_IMAGES_DIR"

log "Generating random GRUB password and PBKDF2 hash..."
GRUB_PASSWORD="$(generate_random_password)"
GRUB_PBKDF2_HASH="$(make_pbkdf2_hash "$GRUB_PASSWORD")"
[[ -n "$GRUB_PBKDF2_HASH" ]] || die "Failed to capture GRUB PBKDF2 hash"

log "Extracting ISO filesystem..."
xorriso -osirrox on -indev "$ISO_INPUT" -extract / "$EXTRACT_DIR" >/dev/null 2>&1 || \
    die "Failed to extract ISO contents"

log "Extracting boot images..."
xorriso -osirrox on -indev "$ISO_INPUT" -extract_boot_images "$BOOT_IMAGES_DIR" >/dev/null 2>&1 || \
    die "Failed to extract boot images"

MBR_IMAGE="${BOOT_IMAGES_DIR}/mbr_code_isohybrid.img"
[[ -f "$MBR_IMAGE" ]] || die "Expected MBR image not found: $MBR_IMAGE"

: > "$PATCH_LOG"

declare -a GRUB_CANDIDATES=(
    "$EXTRACT_DIR/boot/grub/grub.cfg"
    "$EXTRACT_DIR/EFI/BOOT/grub.cfg"
)

declare -a NOPERSIST_CANDIDATES=(
    "$EXTRACT_DIR/isolinux/txt.cfg"
    "$EXTRACT_DIR/isolinux/isolinux.cfg"
    "$EXTRACT_DIR/boot/isolinux/isolinux.cfg"
    "$EXTRACT_DIR/boot/isolinux/txt.cfg"
)

log "Patching GRUB config files..."
for f in "${GRUB_CANDIDATES[@]}"; do
    if [[ -f "$f" ]]; then
        patch_grub_file "$f" "$GRUB_PBKDF2_HASH"
        echo "PATCHED GRUB: $f" >> "$PATCH_LOG"
    fi
done

log "Patching BIOS/ISOLINUX config files for nopersistent..."
for f in "${NOPERSIST_CANDIDATES[@]}"; do
    if [[ -f "$f" ]]; then
        patch_nopersistent_file "$f"
        echo "PATCHED NOPERSISTENT: $f" >> "$PATCH_LOG"
    fi
done

log "Searching for additional config files containing boot=casper..."
while IFS= read -r -d '' f; do
    already_done=0
    for c in "${GRUB_CANDIDATES[@]}" "${NOPERSIST_CANDIDATES[@]}"; do
        [[ "$f" == "$c" ]] && already_done=1 && break
    done
    if [[ $already_done -eq 0 ]]; then
        if grep -q 'menuentry' "$f"; then
            patch_grub_file "$f" "$GRUB_PBKDF2_HASH"
            echo "PATCHED EXTRA GRUB: $f" >> "$PATCH_LOG"
        else
            patch_nopersistent_file "$f"
            echo "PATCHED EXTRA NOPERSISTENT: $f" >> "$PATCH_LOG"
        fi
    fi
done < <(grep -RIlZ 'boot=casper' "$EXTRACT_DIR" --include='*.cfg' --include='grub.cfg' || true)

grep -RIn 'boot=casper.*nopersistent' "$EXTRACT_DIR" >/dev/null 2>&1 || \
    die "No boot=casper lines were successfully patched with nopersistent"

grep -RIn '^set superusers=' "$EXTRACT_DIR" >/dev/null 2>&1 || \
    die "GRUB superuser block was not inserted"

grep -RIn '^password_pbkdf2 ' "$EXTRACT_DIR" >/dev/null 2>&1 || \
    die "GRUB password_pbkdf2 line was not inserted"

unset GRUB_PASSWORD

VOLUME_ID="$(get_volume_id "$ISO_INPUT")"
rm -f "$ISO_OUTPUT"

{
    hr
    echo "REBUILD REPORT"
    hr
    printf "%-18s %s\n" "Timestamp:" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf "%-18s %s\n" "Input ISO:" "$ISO_INPUT"
    printf "%-18s %s\n" "Output ISO:" "$ISO_OUTPUT"
    printf "%-18s %s\n" "Volume ID:" "$VOLUME_ID"
    printf "%-18s %s\n" "Extract dir:" "$EXTRACT_DIR"
    printf "%-18s %s\n" "Boot images dir:" "$BOOT_IMAGES_DIR"
    printf "%-18s %s\n" "MBR image:" "$MBR_IMAGE"
    hr
    cat "$PATCH_LOG"
    hr
    echo "xorriso -as mkisofs \\"
    echo "  -r \\"
    echo "  -V \"$VOLUME_ID\" \\"
    echo "  -o \"$ISO_OUTPUT\" \\"
    echo "  -J -joliet-long -l \\"
    echo "  -iso-level 3 \\"
    echo "  -isohybrid-mbr \"$MBR_IMAGE\" \\"
    echo "  -c isolinux/boot.cat \\"
    echo "  -b isolinux/isolinux.bin \\"
    echo "  -no-emul-boot \\"
    echo "  -boot-load-size 4 \\"
    echo "  -boot-info-table \\"
    echo "  -eltorito-alt-boot \\"
    echo "  -e boot/grub/efi.img \\"
    echo "  -no-emul-boot \\"
    echo "  -isohybrid-gpt-basdat \\"
    echo "  \"$EXTRACT_DIR\""
    hr
} | tee "$BUILD_LOG"

log "Rebuilding ISO..."
xorriso -as mkisofs \
  -r \
  -V "$VOLUME_ID" \
  -o "$ISO_OUTPUT" \
  -J -joliet-long -l \
  -iso-level 3 \
  -isohybrid-mbr "$MBR_IMAGE" \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$EXTRACT_DIR" || die "ISO rebuild failed"

[[ -f "$ISO_OUTPUT" ]] || die "Rebuilt ISO was not created"
log "Repacked ISO created at: $ISO_OUTPUT"

safe_unmount_children "$DEV"

REPACKED_ISO_SIZE=$(stat -c '%s' "$ISO_OUTPUT")
DEV_SIZE=$(blockdev --getsize64 "$DEV")
(( DEV_SIZE > REPACKED_ISO_SIZE )) || die "Device is too small for rebuilt ISO"

REMAINING=$((DEV_SIZE - REPACKED_ISO_SIZE))

log "Writing repacked ISO to device..."
dd if="$ISO_OUTPUT" of="$DEV" bs=4M status=progress conv=fsync
sync

log "Filling remaining device space with zeros..."
if (( REMAINING > 0 )); then
    dd if=/dev/zero \
       of="$DEV" \
       bs=4M \
       seek="${REPACKED_ISO_SIZE}B" \
       count="${REMAINING}B" \
       status=progress \
       conv=notrunc,fsync
    sync
fi

log "Verifying ISO area byte-for-byte..."
cmp -n "$REPACKED_ISO_SIZE" "$ISO_OUTPUT" "$DEV" >/dev/null || die "ISO area verification failed"
log "ISO area verification: OK"

write_burn_report "$BURN_REPORT" "$ISO_OUTPUT" "$DEV" "$REPACKED_ISO_SIZE" "$DEV_SIZE" "$REMAINING"
compute_hash_report "$DEV" "$HASH_REPORT"
compute_iso_sha256_report "$ISO_OUTPUT" "$ISO_HASH_REPORT"

log "Signing generated report files with GPG..."
REPORT_FILES=(
    "$PATCH_LOG"
    "$BUILD_LOG"
    "$BURN_REPORT"
    "$HASH_REPORT"
    "$ISO_HASH_REPORT"
)
sign_report_files "$GPG_KEY_ID" "${REPORT_FILES[@]}"

launch_qemu "$DEV" "$BOOT_MODE" "$OVMF_CODE"

log "All steps completed successfully."
log "Artifacts:"
printf '  %s\n' \
  "$ISO_OUTPUT" \
  "$PATCH_LOG" "${PATCH_LOG}.asc" \
  "$BUILD_LOG" "${BUILD_LOG}.asc" \
  "$BURN_REPORT" "${BURN_REPORT}.asc" \
  "$HASH_REPORT" "${HASH_REPORT}.asc" \
  "$ISO_HASH_REPORT" "${ISO_HASH_REPORT}.asc"