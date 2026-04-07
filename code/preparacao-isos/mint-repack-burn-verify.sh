#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  sudo ./mint-repack-burn-verify.sh /path/to/linuxmint.iso /path/to/workdir /dev/sdX [bios|uefi]

Examples:
  sudo ./mint-repack-burn-verify.sh \
    ~/Downloads/linuxmint-22.3-cinnamon-64bit.iso \
    ~/work/mint-build \
    /dev/sdb \
    uefi

What it does:
  1. Extracts the ISO
  2. Adds "nopersistent" to boot=casper lines
  3. Locks GRUB editing and CLI with a random password that is discarded
  4. Rebuilds the ISO as <original>-repacked.iso
  5. Burns the rebuilt ISO to the target device
  6. Fills remaining device space with zeros
  7. Verifies the ISO area byte-for-byte
  8. Computes SHA-256, SHA-512, and BLAKE2b hashes of the full device
  9. Boots the pendrive in QEMU for visual verification

Notes:
  - The target must be the whole device, for example /dev/sdb, not /dev/sdb1
  - This will DESTROY all data on the target device
  - GRUB locking applies only to the GRUB path, not necessarily every BIOS boot path
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

    [[ -n "$hash" ]] || die "Failed to extract GRUB PBKDF2 hash from grub-mkpasswd-pbkdf2 output"
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
        echo
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
    echo
    log "Hash report saved to: $report_file"
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

rebuild_iso_explicit() {
    local extract_dir="$1"
    local output_iso="$2"
    local volume_id="$3"

    local mbr_bin=""
    local efi_img=""
    local bios_bin=""
    local boot_cat="isolinux/boot.cat"

    [[ -f "$extract_dir/isolinux/isohdpfx.bin" ]] && mbr_bin="$extract_dir/isolinux/isohdpfx.bin"
    [[ -f "$extract_dir/boot/grub/efi.img" ]] && efi_img="boot/grub/efi.img"
    [[ -f "$extract_dir/isolinux/isolinux.bin" ]] && bios_bin="isolinux/isolinux.bin"

    [[ -n "$mbr_bin" ]] || die "Could not find isolinux/isohdpfx.bin in extracted ISO"
    [[ -n "$efi_img" ]] || die "Could not find boot/grub/efi.img in extracted ISO"
    [[ -n "$bios_bin" ]] || die "Could not find isolinux/isolinux.bin in extracted ISO"

    xorriso -as mkisofs \
      -r \
      -V "$volume_id" \
      -o "$output_iso" \
      -J -joliet-long -l \
      -iso-level 3 \
      -isohybrid-mbr "$mbr_bin" \
      -c "$boot_cat" \
      -b "$bios_bin" \
      -no-emul-boot \
      -boot-load-size 4 \
      -boot-info-table \
      -eltorito-alt-boot \
      -e "$efi_img" \
      -no-emul-boot \
      -isohybrid-gpt-basdat \
      "$extract_dir"
}

[[ $# -lt 3 || $# -gt 4 ]] && usage && exit 1

ISO_INPUT="$(readlink -f "$1")"
WORKDIR="$(readlink -f "$2")"
DEV="$3"
BOOT_MODE="${4:-bios}"

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
need_cmd isoinfo

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

TMP_ROOT="$(mktemp -d)"
EXTRACT_DIR="${TMP_ROOT}/extract"
PATCH_LOG="${WORKDIR}/patch-report.txt"
HASH_REPORT="${WORKDIR}/$(basename "$DEV").hash-report.txt"
BUILD_LOG="${WORKDIR}/rebuild-command.txt"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$EXTRACT_DIR"

log "Input ISO: $ISO_INPUT"
log "Working directory: $WORKDIR"
log "Target device: $DEV"
log "Output repacked ISO: $ISO_OUTPUT"
log "Boot mode for QEMU: $BOOT_MODE"
echo

echo "Current block device layout:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$DEV"
echo
confirm "This will erase ALL data on $DEV. Continue?" || exit 1

log "Generating random GRUB password and PBKDF2 hash..."
GRUB_PASSWORD="$(generate_random_password)"
GRUB_PBKDF2_HASH="$(make_pbkdf2_hash "$GRUB_PASSWORD")"
[[ -n "$GRUB_PBKDF2_HASH" ]] || die "Failed to capture GRUB PBKDF2 hash"

log "Extracting ISO contents..."
xorriso -osirrox on -indev "$ISO_INPUT" -extract / "$EXTRACT_DIR" >/dev/null 2>&1 || \
    die "Failed to extract ISO contents"

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

log "Patched files:"
cat "$PATCH_LOG"

unset GRUB_PASSWORD

VOLUME_ID="$(isoinfo -d -i "$ISO_INPUT" 2>/dev/null | awk -F': ' '/Volume id:/ {print $2; exit}')"
[[ -n "${VOLUME_ID:-}" ]] || VOLUME_ID="Custom Mint Repacked"

log "Rebuilding ISO with explicit xorriso parameters..."
{
    echo "Volume ID: $VOLUME_ID"
    echo "Output ISO: $ISO_OUTPUT"
    echo "Source tree: $EXTRACT_DIR"
} > "$BUILD_LOG"

rebuild_iso_explicit "$EXTRACT_DIR" "$ISO_OUTPUT" "$VOLUME_ID" || die "ISO rebuild failed"

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
if cmp -n "$REPACKED_ISO_SIZE" "$ISO_OUTPUT" "$DEV" >/dev/null; then
    log "ISO area verification: OK"
else
    die "ISO area verification failed"
fi

compute_hash_report "$DEV" "$HASH_REPORT"

launch_qemu "$DEV" "$BOOT_MODE" "$OVMF_CODE"

log "All steps completed successfully."
log "Artifacts:"
printf '  %s\n' "$ISO_OUTPUT" "$PATCH_LOG" "$HASH_REPORT" "$BUILD_LOG"