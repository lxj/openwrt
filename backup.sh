#!/bin/sh
set -eu

DISK="/dev/sda"
OUTPUT_DIR="${HOME:-/root}/backup"
IMG_NAME="openwrt"
BLOCK_SIZE_MIB=4
BUFFER_MIB=1024
ROOT_PART_NUM=2
EFI_PART_NUM=""
SHRINK_EXT4=1
SHRINK_MARGIN_MIB=256

PKG_MGR=""
APT_UPDATED=0
OPKG_UPDATED=0
APK_UPDATED=0

log() { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [-d /dev/sdX] [-o /path] [-n name] [--buffer-mib 1024] [--bs-mib 4]
          [--root-part-num 2] [--efi-part-num N] [--no-shrink-ext4] [--shrink-margin-mib 256]

Outputs:
  - <output>/<name>.img.gz
  - <output>/<name>.qcow2
  - <output>/<name>.meta
  - <output>/partition.gpt
  - <output>/mbr.img
EOF
}

part_path() {
  disk="$1"
  num="$2"
  case "$disk" in
    *[0-9]) printf '%sp%s\n' "$disk" "$num" ;;
    *) printf '%s%s\n' "$disk" "$num" ;;
  esac
}

detect_pkg_mgr() {
  if [ -n "$PKG_MGR" ]; then
    return 0
  fi
  if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
  elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
  elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
  else
    PKG_MGR=""
  fi
}

install_pkg() {
  pkg="$1"
  case "$PKG_MGR" in
    apk)
      if [ "$APK_UPDATED" -eq 0 ]; then
        apk update || true
        APK_UPDATED=1
      fi
      apk add "$pkg"
      ;;
    opkg)
      if [ "$OPKG_UPDATED" -eq 0 ]; then
        opkg update || true
        OPKG_UPDATED=1
      fi
      opkg install "$pkg"
      ;;
    apt)
      if [ "$APT_UPDATED" -eq 0 ]; then
        apt-get update || true
        APT_UPDATED=1
      fi
      apt-get install -y "$pkg"
      ;;
    dnf)
      dnf -y install "$pkg"
      ;;
    yum)
      yum -y install "$pkg"
      ;;
    pacman)
      pacman -Sy --noconfirm "$pkg"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_tool() {
  cmd="$1"
  pkgs="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  detect_pkg_mgr
  [ -n "$PKG_MGR" ] || die "missing command: $cmd (no supported package manager found)"

  log "[+] missing dependency: $cmd, trying auto-install via $PKG_MGR"
  for pkg in $pkgs; do
    if install_pkg "$pkg" >/dev/null 2>&1; then
      if command -v "$cmd" >/dev/null 2>&1; then
        log "[+] installed dependency: $cmd ($pkg)"
        return 0
      fi
    fi
  done

  die "failed to auto-install command: $cmd (tried packages: $pkgs)"
}

detect_efi_part_num() {
  disk="$1"
  parted -m -s "$disk" unit s print 2>/dev/null | awk -F: '
    $1 ~ /^[0-9]+$/ {
      fs=tolower($5)
      flags=tolower($7)
      if (index(flags, "esp") > 0) {
        print $1
        exit
      }
      if (bootfat == "" && index(flags, "boot") > 0 && fs ~ /(fat|vfat)/) {
        bootfat=$1
      }
      if (fatonly == "" && fs ~ /(fat|vfat)/) {
        fatonly=$1
      }
    }
    END {
      if (bootfat != "") {
        print bootfat
      } else if (fatonly != "") {
        print fatonly
      }
    }
  '
}

check_e2fsck_result() {
  rc="$1"
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]
}

shrink_raw_ext4_if_possible() {
  raw_img="$1"

  [ "$SHRINK_EXT4" -eq 1 ] || return 0

  ensure_tool losetup "util-linux"
  ensure_tool blkid "blkid util-linux"
  ensure_tool e2fsck "e2fsprogs"
  ensure_tool resize2fs "e2fsprogs"
  ensure_tool dumpe2fs "e2fsprogs"
  ensure_tool truncate "coreutils"
  ensure_tool stat "coreutils"

  loopdev="$(losetup --find --show -P "$raw_img" 2>/dev/null || true)"
  if [ -z "$loopdev" ]; then
    warn "cannot create loop device; skip offline ext4 shrink"
    return 0
  fi

  root_loop="$(part_path "$loopdev" "$ROOT_PART_NUM")"
  if [ ! -b "$root_loop" ]; then
    warn "root loop partition not found: $root_loop; skip offline ext4 shrink"
    losetup -d "$loopdev" >/dev/null 2>&1 || true
    return 0
  fi

  fs_type="$(blkid -s TYPE -o value "$root_loop" 2>/dev/null || true)"
  if [ "$fs_type" != "ext4" ]; then
    warn "root fs type is '$fs_type' (not ext4); skip offline shrink"
    losetup -d "$loopdev" >/dev/null 2>&1 || true
    return 0
  fi

  log "[+] trying offline ext4 shrink on $root_loop"

  set +e
  e2fsck -fy "$root_loop" >/dev/null 2>&1
  rc="$?"
  set -e
  if ! check_e2fsck_result "$rc"; then
    warn "e2fsck failed (rc=$rc); skip offline shrink"
    losetup -d "$loopdev" >/dev/null 2>&1 || true
    return 0
  fi

  if ! resize2fs -M "$root_loop" >/dev/null; then
    warn "resize2fs -M failed; skip offline shrink"
    losetup -d "$loopdev" >/dev/null 2>&1 || true
    return 0
  fi

  set +e
  e2fsck -fy "$root_loop" >/dev/null 2>&1
  rc="$?"
  set -e
  if ! check_e2fsck_result "$rc"; then
    warn "post-resize e2fsck failed (rc=$rc); skip offline shrink"
    losetup -d "$loopdev" >/dev/null 2>&1 || true
    return 0
  fi

  blk_cnt="$(dumpe2fs -h "$root_loop" 2>/dev/null | awk -F: '/Block count:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
  blk_size="$(dumpe2fs -h "$root_loop" 2>/dev/null | awk -F: '/Block size:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
  if [ -z "$blk_cnt" ] || [ -z "$blk_size" ]; then
    warn "cannot read ext4 block info; skip offline shrink"
    losetup -d "$loopdev" >/dev/null 2>&1 || true
    return 0
  fi

  sector_size="$(parted -m -s "$raw_img" unit s print 2>/dev/null | awk -F: 'NR==2 {print $4; exit}' || true)"
  if [ -z "$sector_size" ]; then
    warn "cannot detect image sector size; skip offline shrink"
    losetup -d "$loopdev" >/dev/null 2>&1 || true
    return 0
  fi

  part_info="$(parted -m -s "$raw_img" unit s print 2>/dev/null | awk -F: -v p="$ROOT_PART_NUM" '
    $1 == p {
      gsub("s", "", $2)
      gsub("s", "", $3)
      print $2 " " $3
      exit
    }
  ' || true)"
  part_start="$(printf '%s' "$part_info" | awk '{print $1}')"
  part_end="$(printf '%s' "$part_info" | awk '{print $2}')"
  if [ -z "$part_start" ] || [ -z "$part_end" ]; then
    warn "cannot read root partition range in image; skip offline shrink"
    losetup -d "$loopdev" >/dev/null 2>&1 || true
    return 0
  fi

  fs_bytes=$((blk_cnt * blk_size))
  margin_bytes=$((SHRINK_MARGIN_MIB * 1024 * 1024))
  need_bytes=$((fs_bytes + margin_bytes))
  need_sectors=$(( (need_bytes + sector_size - 1) / sector_size ))
  new_end=$((part_start + need_sectors - 1))

  if [ "$new_end" -lt "$part_end" ]; then
    if ! parted -s "$raw_img" unit s resizepart "$ROOT_PART_NUM" "${new_end}s" >/dev/null 2>&1; then
      warn "failed to shrink partition boundary; skip offline shrink"
      losetup -d "$loopdev" >/dev/null 2>&1 || true
      return 0
    fi
    log "[+] shrunk partition $ROOT_PART_NUM: ${part_end}s -> ${new_end}s"
  else
    log "[+] partition $ROOT_PART_NUM is already near minimum; no boundary shrink"
  fi

  last_end="$(parted -m -s "$raw_img" unit s print 2>/dev/null | awk -F: '
    $1 ~ /^[0-9]+$/ {
      gsub("s", "", $3)
      end=$3
    }
    END { print end }
  ' || true)"
  if [ -z "$last_end" ]; then
    warn "cannot read last partition end; skip file tail shrink"
    losetup -d "$loopdev" >/dev/null 2>&1 || true
    return 0
  fi

  target_bytes=$(( (last_end + 1) * sector_size + BUFFER_BYTES ))
  raw_size="$(stat -c %s "$raw_img")"
  if [ "$target_bytes" -gt "$raw_size" ]; then
    target_bytes="$raw_size"
  fi

  losetup -d "$loopdev" >/dev/null 2>&1 || true

  if [ "$target_bytes" -lt "$raw_size" ]; then
    truncate -s "$target_bytes" "$raw_img"
    sgdisk -e "$raw_img" >/dev/null 2>&1 || true
    log "[+] shrunk raw file tail: $raw_size -> $target_bytes bytes"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--disk)
      [ $# -ge 2 ] || die "option $1 requires a value"
      DISK="$2"
      shift 2
      ;;
    -o|--output)
      [ $# -ge 2 ] || die "option $1 requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -n|--name)
      [ $# -ge 2 ] || die "option $1 requires a value"
      IMG_NAME="$2"
      shift 2
      ;;
    --buffer-mib)
      [ $# -ge 2 ] || die "option $1 requires a value"
      BUFFER_MIB="$2"
      shift 2
      ;;
    --bs-mib)
      [ $# -ge 2 ] || die "option $1 requires a value"
      BLOCK_SIZE_MIB="$2"
      shift 2
      ;;
    --root-part-num)
      [ $# -ge 2 ] || die "option $1 requires a value"
      ROOT_PART_NUM="$2"
      shift 2
      ;;
    --efi-part-num)
      [ $# -ge 2 ] || die "option $1 requires a value"
      EFI_PART_NUM="$2"
      shift 2
      ;;
    --no-shrink-ext4)
      SHRINK_EXT4=0
      shift
      ;;
    --shrink-margin-mib)
      [ $# -ge 2 ] || die "option $1 requires a value"
      SHRINK_MARGIN_MIB="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "please run as root"
[ -b "$DISK" ] || die "not a block device: $DISK"

ensure_tool parted "parted"
ensure_tool sgdisk "gdisk"
ensure_tool dd "coreutils"
ensure_tool gzip "gzip"
ensure_tool gunzip "gzip"
ensure_tool qemu-img "qemu-img qemu-utils qemu-tools"
ensure_tool blockdev "util-linux util-linux-blockdev"
ensure_tool stat "coreutils"

case "$BUFFER_MIB" in
  ''|*[!0-9]*) die "--buffer-mib must be a positive integer" ;;
esac
case "$BLOCK_SIZE_MIB" in
  ''|*[!0-9]*) die "--bs-mib must be a positive integer" ;;
esac
case "$ROOT_PART_NUM" in
  ''|*[!0-9]*) die "--root-part-num must be a positive integer" ;;
esac
if [ -n "$EFI_PART_NUM" ]; then
  case "$EFI_PART_NUM" in
    ''|*[!0-9]*) die "--efi-part-num must be a positive integer" ;;
  esac
fi
case "$SHRINK_MARGIN_MIB" in
  ''|*[!0-9]*) die "--shrink-margin-mib must be a positive integer" ;;
esac

BLOCK_SIZE_BYTES=$((BLOCK_SIZE_MIB * 1024 * 1024))
BUFFER_BYTES=$((BUFFER_MIB * 1024 * 1024))
BLOCK_SIZE_ARG="${BLOCK_SIZE_MIB}M"

DD_SUPPORT_PROGRESS=0
if dd --help 2>&1 | grep -q "status="; then
  DD_SUPPORT_PROGRESS=1
fi

log "[+] reading disk info: $DISK"
SECTOR_SIZE="$(blockdev --getss "$DISK")"
TOTAL_BYTES="$(blockdev --getsize64 "$DISK")"

END_SECTOR="$(parted -m -s "$DISK" unit s print | awk -F: '
  $1 ~ /^[0-9]+$/ {
    gsub("s", "", $3)
    end=$3
  }
  END {
    if (end == "") exit 1
    print end
  }
')" || die "cannot detect last partition end sector"

if [ -z "$EFI_PART_NUM" ]; then
  EFI_PART_NUM="$(detect_efi_part_num "$DISK" || true)"
  if [ -z "$EFI_PART_NUM" ]; then
    EFI_PART_NUM="1"
    warn "cannot detect EFI partition, fallback to partition number: $EFI_PART_NUM"
  else
    log "[+] detected EFI partition number: $EFI_PART_NUM"
  fi
fi

USED_BYTES=$(( (END_SECTOR + 1) * SECTOR_SIZE ))
COPY_BYTES=$(( USED_BYTES + BUFFER_BYTES ))
if [ "$COPY_BYTES" -gt "$TOTAL_BYTES" ]; then
  COPY_BYTES="$TOTAL_BYTES"
fi
COUNT=$(( (COPY_BYTES + BLOCK_SIZE_BYTES - 1) / BLOCK_SIZE_BYTES ))

log "[+] calculated values"
log "    END_SECTOR: $END_SECTOR"
log "    SECTOR_SIZE: $SECTOR_SIZE"
log "    USED_BYTES: $USED_BYTES"
log "    COPY_BYTES: $COPY_BYTES"
log "    DD bs/count: $BLOCK_SIZE_ARG / $COUNT"

mkdir -p "$OUTPUT_DIR"

META_FILE="$OUTPUT_DIR/$IMG_NAME.meta"
RAW_TMP="$OUTPUT_DIR/$IMG_NAME.img"
IMG_GZ="$OUTPUT_DIR/$IMG_NAME.img.gz"
QCOW2="$OUTPUT_DIR/$IMG_NAME.qcow2"

cleanup() {
  [ -f "$RAW_TMP" ] && rm -f "$RAW_TMP"
}
trap cleanup EXIT INT TERM

log "[+] backup GPT"
sgdisk --backup="$OUTPUT_DIR/partition.gpt" "$DISK"

log "[+] backup first 1MiB (MBR + boot area)"
dd if="$DISK" of="$OUTPUT_DIR/mbr.img" bs=512 count=2048

log "[+] create RAW image"
if [ "$DD_SUPPORT_PROGRESS" -eq 1 ]; then
  dd if="$DISK" of="$RAW_TMP" bs="$BLOCK_SIZE_ARG" count="$COUNT" status=progress
else
  dd if="$DISK" of="$RAW_TMP" bs="$BLOCK_SIZE_ARG" count="$COUNT"
fi

shrink_raw_ext4_if_possible "$RAW_TMP"
FINAL_COPY_BYTES="$(stat -c %s "$RAW_TMP")"
FINAL_COUNT=$(( (FINAL_COPY_BYTES + BLOCK_SIZE_BYTES - 1) / BLOCK_SIZE_BYTES ))

cat > "$META_FILE" <<EOF
# Auto-generated by backup.sh
DISK="$DISK"
SECTOR_SIZE="$SECTOR_SIZE"
TOTAL_BYTES="$TOTAL_BYTES"
END_SECTOR="$END_SECTOR"
USED_BYTES="$USED_BYTES"
COPY_BYTES="$FINAL_COPY_BYTES"
BLOCK_SIZE_MIB="$BLOCK_SIZE_MIB"
COUNT="$FINAL_COUNT"
ROOT_PART_NUM="$ROOT_PART_NUM"
EFI_PART_NUM="$EFI_PART_NUM"
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EOF

log "[+] create compressed image"
gzip -c "$RAW_TMP" > "$IMG_GZ"

log "[+] create qcow2"
qemu-img convert -f raw -O qcow2 "$RAW_TMP" "$QCOW2"

log "[+] create checksum file"
if command -v sha256sum >/dev/null 2>&1; then
  (
    cd "$OUTPUT_DIR"
    sha256sum "$(basename "$IMG_GZ")" "$(basename "$QCOW2")" > "$IMG_NAME.sha256"
  )
else
  warn "sha256sum not found; skip checksum generation"
fi

log "[OK] done"
log "outputs:"
log " - $IMG_GZ"
log " - $QCOW2"
log " - $META_FILE"
log " - $OUTPUT_DIR/partition.gpt"
log " - $OUTPUT_DIR/mbr.img"
