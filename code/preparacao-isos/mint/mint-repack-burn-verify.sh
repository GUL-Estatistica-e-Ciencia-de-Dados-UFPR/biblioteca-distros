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
  5. Collects a detailed physical device report
  6. Runs a destructive badblocks test before burning
  7. Rebuilds the ISO as <original>-repacked.iso
  8. Burns the rebuilt ISO to the target device
  9. Fills remaining device space with zeros
  10. Verifies the ISO area byte-for-byte
  11. Generates SHA-256, SHA-512, and BLAKE2b hashes of the full device
  12. Generates an ISO SHA-256 report
  13. Signs all generated report files with GPG detached armored signatures
  14. Boots the pendrive in QEMU for visual verification

Notes:
  - DEVICE must be the whole device, for example /dev/sdb, not /dev/sdb1
  - This will DESTROY all data on DEVICE
  - badblocks is destructive and can take a long time
  - In a raw ISO workflow, bad blocks cannot be "marked" in a persistent filesystem structure.
    Instead, the script aborts if any bad blocks are found.
  - GPG_KEY_ID is optional; if omitted, the default secret key is used
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

section() {
    echo
    printf '%*s\n' "${COLUMNS:-100}" '' | tr ' ' '='
    echo "$*"
    printf '%*s\n' "${COLUMNS:-100}" '' | tr ' ' '='
}

subsection() {
    echo
    printf '%*s\n' "${COLUMNS:-100}" '' | tr ' ' '-'
    echo "$*"
    printf '%*s\n' "${COLUMNS:-100}" '' | tr ' ' '-'
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
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

run_cmd() {
    echo "+ $*"
    "$@"
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
    printf '%*s\n' "${COLUMNS:-100}" '' | tr ' ' '-'
}

safe_unmount_children() {
    local dev="$1"
    mapfile -t CHILD_PARTS < <(lsblk -lnpo NAME,TYPE "$dev" | awk '$2=="part"{print $1}')
    for part in "${CHILD_PARTS[@]:-}"; do
        if lsblk -lnpo MOUNTPOINT "$part" | grep -q .; then
            log "Unmounting child partition: $part"
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

setup_gpg_cmd() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        GPG_CMD=(sudo -u "$SUDO_USER" gpg)
        GPG_OWNER="$SUDO_USER"
    else
        GPG_CMD=(gpg)
        GPG_OWNER="$(id -un)"
    fi
}

gpg_has_secret_key() {
    "${GPG_CMD[@]}" --list-secret-keys >/dev/null 2>&1
}

sign_report_files() {
    local key_id="$1"
    shift
    local reports=("$@")

    [[ ${#reports[@]} -gt 0 ]] || return 0

    local gpg_args=(--yes --armor --detach-sign)
    if [[ -n "$key_id" ]]; then
        gpg_args+=(--local-user "$key_id")
    fi

    subsection "Signing report files with GPG"
    log "Using GPG identity context of user: $GPG_OWNER"

    for f in "${reports[@]}"; do
        [[ -f "$f" ]] || die "Cannot sign missing report file: $f"
        log "Signing report: $f"
        "${GPG_CMD[@]}" "${gpg_args[@]}" -o "${f}.asc" "$f" || die "GPG signing failed for: $f"
        log "Created detached signature: ${f}.asc"
    done
}

collect_device_report() {
    local dev="$1"
    local report_file="$2"

    local base
    base="$(basename "$dev")"

    {
        hr
        echo "PHYSICAL DEVICE REPORT"
        hr
        printf "%-24s %s\n" "Timestamp:" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf "%-24s %s\n" "Device:" "$dev"
        printf "%-24s %s\n" "Kernel name:" "$base"
        printf "%-24s %s\n" "Resolved path:" "$(readlink -f "$dev")"
        hr

        echo "LSBLK SHORT"
        hr
        lsblk -o NAME,PATH,SIZE,TYPE,TRAN,MODEL,VENDOR,SERIAL,ROTA,HOTPLUG,MOUNTPOINT "$dev" || true
        hr

        echo "LSBLK FULL"
        hr
        lsblk -O "$dev" || true
        hr

        echo "BLOCKDEV"
        hr
        blockdev --report "$dev" || true
        echo
        echo "Size bytes: $(blockdev --getsize64 "$dev" 2>/dev/null || echo N/A)"
        echo "Logical sector size: $(blockdev --getss "$dev" 2>/dev/null || echo N/A)"
        echo "Physical sector size: $(blockdev --getpbsz "$dev" 2>/dev/null || echo N/A)"
        hr

        echo "BLKID"
        hr
        blkid "$dev" || true
        lsblk -lnpo NAME "$dev" | tail -n +2 | while read -r part; do
            blkid "$part" || true
        done
        hr

        echo "UDEVADM INFO"
        hr
        udevadm info --query=all --name="$dev" || true
        hr

        echo "SYSFS SNAPSHOT"
        hr
        for p in \
            "/sys/class/block/$base/device/model" \
            "/sys/class/block/$base/device/vendor" \
            "/sys/class/block/$base/device/rev" \
            "/sys/class/block/$base/removable" \
            "/sys/class/block/$base/ro" \
            "/sys/class/block/$base/size" \
            "/sys/class/block/$base/stat" \
            "/sys/class/block/$base/device/state" \
            "/sys/class/block/$base/queue/logical_block_size" \
            "/sys/class/block/$base/queue/physical_block_size" \
            "/sys/class/block/$base/queue/read_ahead_kb" \
            "/sys/class/block/$base/queue/rotational" \
            "/sys/class/block/$base/queue/max_hw_sectors_kb" \
            "/sys/class/block/$base/queue/max_sectors_kb" \
        ; do
            if [[ -f "$p" ]]; then
                printf "%s: %s\n" "$p" "$(cat "$p")"
            fi
        done
        hr

        echo "FDISK"
        hr
        fdisk -l "$dev" 2>/dev/null || true
        hr

        if have_cmd lsusb; then
            echo "LSUSB"
            hr
            lsusb || true
            echo
            echo "LSUSB TREE"
            hr
            lsusb -t || true
            hr
        fi

        if have_cmd smartctl; then
            echo "SMARTCTL"
            hr
            smartctl -a "$dev" 2>&1 || true
            hr
        fi

        if have_cmd hdparm; then
            echo "HDPARM IDENTIFY"
            hr
            hdparm -I "$dev" 2>&1 || true
            hr
        fi

        echo "DMESG TAIL BEFORE TEST"
        hr
        dmesg | tail -n 100 || true
        hr
    } | tee "$report_file"
}

run_badblocks_check() {
    local dev="$1"
    local report_file="$2"
    local badblocks_list="$3"

    : > "$badblocks_list"

    {
        hr
        echo "BADBLOCKS REPORT"
        hr
        printf "%-24s %s\n" "Timestamp:" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf "%-24s %s\n" "Device:" "$dev"
        printf "%-24s %s\n" "Mode:" "destructive read-write"
        printf "%-24s %s\n" "Command:" "badblocks -wsv -o \"$badblocks_list\" \"$dev\""
        printf "%-24s %s\n" "Note:" "In a raw ISO workflow, bad blocks cannot be persistently marked in a filesystem structure."
        printf "%-24s %s\n" "Policy:" "Abort if any bad blocks are found."
        hr
    } | tee "$report_file"

    badblocks -wsv -o "$badblocks_list" "$dev" 2>&1 | tee -a "$report_file"

    {
        hr
        echo "BADBLOCKS RESULT SUMMARY"
        hr
        if [[ -s "$badblocks_list" ]]; then
            echo "Bad blocks were detected."
            echo
            cat "$badblocks_list"
        else
            echo "No bad blocks were reported."
        fi
        hr
        echo "DMESG TAIL AFTER BADBLOCKS"
        hr
        dmesg | tail -n 100 || true
        hr
    } | tee -a "$report_file"

    if [[ -s "$badblocks_list" ]]; then
        die "badblocks found one or more bad blocks; device is not suitable for this workflow"
    fi
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
        echo "DMESG TAIL AFTER HASHING"
        hr
        dmesg | tail -n 100 || true
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
        hr
    } | tee "$report_file"

    log "Burn report saved to: $report_file"
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
need_cmd udevadm
need_cmd badblocks

setup_gpg_cmd
gpg_has_secret_key || die "No GPG secret key available for user context: $GPG_OWNER"

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

PROCESS_LOG="${WORKDIR}/process-report.log"
DEVICE_REPORT="${WORKDIR}/device-report.txt"
BADBLOCKS_REPORT="${WORKDIR}/badblocks-report.txt"
BADBLOCKS_LIST="${WORKDIR}/badblocks-found.txt"
PATCH_LOG="${WORKDIR}/patch-report.txt"
BUILD_LOG="${WORKDIR}/rebuild-report.txt"
BURN_REPORT="${WORKDIR}/burn-report.txt"
HASH_REPORT="${WORKDIR}/$(basename "$DEV").hash-report.txt"
ISO_HASH_REPORT="${WORKDIR}/repacked-iso-sha256.txt"

mkdir -p "$EXTRACT_DIR" "$BOOT_IMAGES_DIR"

touch "$PROCESS_LOG"
exec > >(tee -a "$PROCESS_LOG") 2>&1

section "INITIAL PARAMETERS"
log "Input ISO: $ISO_INPUT"
log "Working directory: $WORKDIR"
log "Target device: $DEV"
log "Output repacked ISO: $ISO_OUTPUT"
log "Boot mode for QEMU: $BOOT_MODE"
if [[ -n "$GPG_KEY_ID" ]]; then
    log "GPG signing key: $GPG_KEY_ID"
else
    log "GPG signing key: default secret key for user context $GPG_OWNER"
fi
echo
echo "Current block device layout:"
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,VENDOR,SERIAL,MOUNTPOINT "$DEV"
echo
echo "This workflow includes a destructive badblocks test before burning."
echo "It can take a long time and will erase all existing data on the device."
confirm "Continue?" || exit 1

section "DEVICE PREPARATION"
safe_unmount_children "$DEV"

subsection "Collecting detailed physical device report"
collect_device_report "$DEV" "$DEVICE_REPORT"

subsection "Running destructive badblocks test"
run_badblocks_check "$DEV" "$BADBLOCKS_REPORT" "$BADBLOCKS_LIST"

section "ISO EXTRACTION AND PATCHING"

log "Cleaning working extraction directories..."
rm -rf "$EXTRACT_DIR" "$BOOT_IMAGES_DIR"
mkdir -p "$EXTRACT_DIR" "$BOOT_IMAGES_DIR"

subsection "Generating GRUB lock credentials"
GRUB_PASSWORD="$(generate_random_password)"
GRUB_PBKDF2_HASH="$(make_pbkdf2_hash "$GRUB_PASSWORD")"
[[ -n "$GRUB_PBKDF2_HASH" ]] || die "Failed to capture GRUB PBKDF2 hash"
log "Generated GRUB PBKDF2 hash successfully"
log "Plaintext GRUB password will be discarded after patching"

subsection "Extracting ISO filesystem"
run_cmd xorriso -osirrox on -indev "$ISO_INPUT" -extract / "$EXTRACT_DIR"

subsection "Extracting boot images"
run_cmd xorriso -osirrox on -indev "$ISO_INPUT" -extract_boot_images "$BOOT_IMAGES_DIR"

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

subsection "Patching GRUB configuration"
for f in "${GRUB_CANDIDATES[@]}"; do
    if [[ -f "$f" ]]; then
        log "Patching GRUB file: $f"
        patch_grub_file "$f" "$GRUB_PBKDF2_HASH"
        echo "PATCHED GRUB: $f" >> "$PATCH_LOG"
    fi
done

subsection "Patching BIOS/ISOLINUX configuration"
for f in "${NOPERSIST_CANDIDATES[@]}"; do
    if [[ -f "$f" ]]; then
        log "Patching BIOS/ISOLINUX file: $f"
        patch_nopersistent_file "$f"
        echo "PATCHED NOPERSISTENT: $f" >> "$PATCH_LOG"
    fi
done

subsection "Searching for additional boot=casper configuration files"
while IFS= read -r -d '' f; do
    already_done=0
    for c in "${GRUB_CANDIDATES[@]}" "${NOPERSIST_CANDIDATES[@]}"; do
        [[ "$f" == "$c" ]] && already_done=1 && break
    done
    if [[ $already_done -eq 0 ]]; then
        if grep -q 'menuentry' "$f"; then
            log "Patching additional GRUB-like file: $f"
            patch_grub_file "$f" "$GRUB_PBKDF2_HASH"
            echo "PATCHED EXTRA GRUB: $f" >> "$PATCH_LOG"
        else
            log "Patching additional boot config file: $f"
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

log "Patch validation succeeded"
unset GRUB_PASSWORD

section "ISO REBUILD"

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

log "Rebuilding ISO with explicit hybrid BIOS+UEFI parameters..."
run_cmd xorriso -as mkisofs \
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
  "$EXTRACT_DIR"

[[ -f "$ISO_OUTPUT" ]] || die "Rebuilt ISO was not created"
log "Repacked ISO created at: $ISO_OUTPUT"

section "BURN TO DEVICE"

safe_unmount_children "$DEV"

REPACKED_ISO_SIZE=$(stat -c '%s' "$ISO_OUTPUT")
DEV_SIZE=$(blockdev --getsize64 "$DEV")
(( DEV_SIZE > REPACKED_ISO_SIZE )) || die "Device is too small for rebuilt ISO"

REMAINING=$((DEV_SIZE - REPACKED_ISO_SIZE))

log "Repacked ISO size: $REPACKED_ISO_SIZE bytes"
log "Device size: $DEV_SIZE bytes"
log "Tail that will be zero-filled after ISO write: $REMAINING bytes"

subsection "Writing repacked ISO to device"
run_cmd dd if="$ISO_OUTPUT" of="$DEV" bs=4M status=progress conv=fsync
sync

subsection "Zero-filling the remaining device space"
if (( REMAINING > 0 )); then
    run_cmd dd if=/dev/zero \
       of="$DEV" \
       bs=4M \
       seek="${REPACKED_ISO_SIZE}B" \
       count="${REMAINING}B" \
       status=progress \
       conv=notrunc,fsync
    sync
else
    log "No remaining tail space to zero-fill"
fi

subsection "Verifying ISO area byte-for-byte"
if cmp -n "$REPACKED_ISO_SIZE" "$ISO_OUTPUT" "$DEV" >/dev/null; then
    log "ISO area verification: OK"
else
    rc=$?
    if [[ $rc -eq 2 ]]; then
        die "ISO area verification failed due to device I/O error"
    else
        die "ISO area verification failed due to content mismatch"
    fi
fi

write_burn_report "$BURN_REPORT" "$ISO_OUTPUT" "$DEV" "$REPACKED_ISO_SIZE" "$DEV_SIZE" "$REMAINING"

section "POST-BURN REPORTING"

subsection "Computing whole-device hashes"
compute_hash_report "$DEV" "$HASH_REPORT"

subsection "Computing repacked ISO SHA-256"
compute_iso_sha256_report "$ISO_OUTPUT" "$ISO_HASH_REPORT"

section "SIGNING REPORT FILES"

REPORT_FILES=(
    "$PROCESS_LOG"
    "$DEVICE_REPORT"
    "$BADBLOCKS_REPORT"
    "$PATCH_LOG"
    "$BUILD_LOG"
    "$BURN_REPORT"
    "$HASH_REPORT"
    "$ISO_HASH_REPORT"
)

sign_report_files "$GPG_KEY_ID" "${REPORT_FILES[@]}"

section "QEMU BOOT TEST"
launch_qemu "$DEV" "$BOOT_MODE" "$OVMF_CODE"

section "COMPLETED"
log "All steps completed successfully."
log "Artifacts:"
printf '  %s\n' \
  "$ISO_OUTPUT" \
  "$PROCESS_LOG" "${PROCESS_LOG}.asc" \
  "$DEVICE_REPORT" "${DEVICE_REPORT}.asc" \
  "$BADBLOCKS_REPORT" "${BADBLOCKS_REPORT}.asc" \
  "$PATCH_LOG" "${PATCH_LOG}.asc" \
  "$BUILD_LOG" "${BUILD_LOG}.asc" \
  "$BURN_REPORT" "${BURN_REPORT}.asc" \
  "$HASH_REPORT" "${HASH_REPORT}.asc" \
  "$ISO_HASH_REPORT" "${ISO_HASH_REPORT}.asc"