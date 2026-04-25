#!/bin/sh
set -eu

DISK="/dev/sda"
IMG="${HOME:-/root}/backup/openwrt.img.gz"
META=""
ROOT_PART_NUM="2"
EFI_PART_NUM=""
REPAIR_BOOT=1
ROOT_PART_NUM_CLI=0
EFI_PART_NUM_CLI=0
SELF_CHECK=1
SELF_CHECK_ONLY=0

PKG_MGR=""
APT_UPDATED=0
OPKG_UPDATED=0
APK_UPDATED=0

log() { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [-d /dev/sdX] [-i /path/openwrt.img.gz] [--meta /path/openwrt.meta]
          [--root-part-num 2] [--efi-part-num N] [--no-repair-boot]
          [--self-check-only] [--no-self-check]

Default behavior:
  1) gunzip | dd writes image to disk
  2) sgdisk -e repairs backup GPT location
  3) sync root PARTUUID in grub.cfg
  4) add EFI fallback file if needed
  5) run post-restore self-check (disable with --no-self-check)
EOF
}

read_meta_var() {
  file="$1"
  key="$2"
  awk -F= -v k="$key" '
    $1 == k {
      v=$2
      gsub(/^"/, "", v)
      gsub(/"$/, "", v)
      print v
      exit
    }
  ' "$file"
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

run_self_check() {
  ensure_tool sgdisk "gdisk"
  ensure_tool blkid "blkid util-linux"
  ensure_tool mount "mount util-linux"
  ensure_tool umount "mount util-linux"
  ensure_tool grep "grep"

  log "[+] running post-restore self-check"

  chk_pass=0
  chk_warn=0
  chk_fail=0

  if sgdisk -v "$DISK" >/dev/null 2>&1; then
    log "[OK] GPT structure check passed"
    chk_pass=$((chk_pass + 1))
  else
    warn "GPT structure check reported issues (manual check: sgdisk -v $DISK)"
    chk_warn=$((chk_warn + 1))
  fi

  ROOT_PART="$(part_path "$DISK" "$ROOT_PART_NUM")"
  EFI_PART="$(part_path "$DISK" "$EFI_PART_NUM")"

  if [ ! -b "$ROOT_PART" ]; then
    warn "root partition device not found: $ROOT_PART"
    chk_fail=$((chk_fail + 1))
  fi

  if [ "$chk_fail" -ne 0 ]; then
    log "[SELF-CHECK] PASS=$chk_pass WARN=$chk_warn FAIL=$chk_fail"
    die "self-check failed: critical partition missing"
  fi

  root_type="$(blkid -s TYPE -o value "$ROOT_PART" 2>/dev/null || true)"
  if [ "$root_type" = "ext4" ]; then
    log "[OK] root filesystem type: ext4"
    chk_pass=$((chk_pass + 1))
  else
    warn "root filesystem type: ${root_type:-unknown} (expected: ext4)"
    chk_warn=$((chk_warn + 1))
  fi

  MNT_ROOT="/tmp/openwrt-selfcheck-root.$$"
  MNT_EFI="$MNT_ROOT/boot/efi"
  mounted_root=0
  mounted_efi=0
  mkdir -p "$MNT_ROOT"

  cleanup_selfcheck() {
    if [ "$mounted_efi" -eq 1 ]; then
      umount "$MNT_EFI" 2>/dev/null || true
    fi
    if [ "$mounted_root" -eq 1 ]; then
      umount "$MNT_ROOT" 2>/dev/null || true
    fi
    rm -rf "$MNT_ROOT"
  }
  trap cleanup_selfcheck EXIT INT TERM

  if mount "$ROOT_PART" "$MNT_ROOT"; then
    mounted_root=1
    log "[OK] root partition mount passed"
    chk_pass=$((chk_pass + 1))
  else
    warn "root partition mount failed: $ROOT_PART"
    chk_fail=$((chk_fail + 1))
  fi

  if [ "$chk_fail" -eq 0 ]; then
    GRUB_CFG="$MNT_ROOT/boot/grub/grub.cfg"
    if [ -f "$GRUB_CFG" ]; then
      log "[OK] grub.cfg exists"
      chk_pass=$((chk_pass + 1))
    else
      warn "grub.cfg missing: $GRUB_CFG"
      chk_fail=$((chk_fail + 1))
    fi

    ROOT_UUID="$(blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || true)"
    if [ -n "$ROOT_UUID" ] && [ -f "$GRUB_CFG" ]; then
      if grep -q "root=PARTUUID=$ROOT_UUID" "$GRUB_CFG"; then
        log "[OK] grub root PARTUUID matches root partition"
        chk_pass=$((chk_pass + 1))
      else
        warn "grub root PARTUUID mismatch (may affect boot)"
        chk_warn=$((chk_warn + 1))
      fi
    fi
  fi

  if [ -b "$EFI_PART" ] && [ "$chk_fail" -eq 0 ]; then
    efi_type="$(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || true)"
    if [ "$efi_type" = "vfat" ] || [ "$efi_type" = "fat" ] || [ "$efi_type" = "msdos" ]; then
      mkdir -p "$MNT_EFI"
      if mount "$EFI_PART" "$MNT_EFI"; then
        mounted_efi=1
        chk_pass=$((chk_pass + 1))
        if [ -f "$MNT_EFI/EFI/BOOT/BOOTX64.EFI" ] || [ -f "$MNT_EFI/EFI/openwrt/grubx64.efi" ] || [ -f "$MNT_EFI/EFI/BOOT/grubx64.efi" ]; then
          log "[OK] EFI boot file found"
          chk_pass=$((chk_pass + 1))
        else
          warn "EFI boot file not found (UEFI machine may fail to boot)"
          chk_warn=$((chk_warn + 1))
        fi
      else
        warn "failed to mount EFI partition: $EFI_PART"
        chk_warn=$((chk_warn + 1))
      fi
    else
      warn "EFI partition type is ${efi_type:-unknown}; skip EFI file check"
      chk_warn=$((chk_warn + 1))
    fi
  elif [ "$chk_fail" -eq 0 ]; then
    warn "EFI partition device not found: $EFI_PART (safe to ignore for BIOS-only target)"
    chk_warn=$((chk_warn + 1))
  fi

  trap - EXIT INT TERM
  cleanup_selfcheck

  log "[SELF-CHECK] PASS=$chk_pass WARN=$chk_warn FAIL=$chk_fail"
  if [ "$chk_fail" -eq 0 ]; then
    log "[OK] self-check finished without critical failures"
  else
    die "self-check failed: critical errors found"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--disk)
      [ $# -ge 2 ] || die "option $1 requires a value"
      DISK="$2"
      shift 2
      ;;
    -i|--img)
      [ $# -ge 2 ] || die "option $1 requires a value"
      IMG="$2"
      shift 2
      ;;
    --meta)
      [ $# -ge 2 ] || die "option $1 requires a value"
      META="$2"
      shift 2
      ;;
    --root-part-num)
      [ $# -ge 2 ] || die "option $1 requires a value"
      ROOT_PART_NUM="$2"
      ROOT_PART_NUM_CLI=1
      shift 2
      ;;
    --efi-part-num)
      [ $# -ge 2 ] || die "option $1 requires a value"
      EFI_PART_NUM="$2"
      EFI_PART_NUM_CLI=1
      shift 2
      ;;
    --no-repair-boot)
      REPAIR_BOOT=0
      shift
      ;;
    --self-check-only)
      SELF_CHECK_ONLY=1
      SELF_CHECK=1
      shift
      ;;
    --no-self-check)
      SELF_CHECK=0
      shift
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

case "$ROOT_PART_NUM" in
  ''|*[!0-9]*) die "--root-part-num must be a positive integer" ;;
esac
if [ -n "$EFI_PART_NUM" ]; then
  case "$EFI_PART_NUM" in
    ''|*[!0-9]*) die "--efi-part-num must be a positive integer" ;;
  esac
fi

ensure_tool sgdisk "gdisk"
ensure_tool blockdev "util-linux util-linux-blockdev"
ensure_tool parted "parted"

if [ -z "$META" ]; then
  META="${IMG%.img.gz}.meta"
fi

if [ -f "$META" ]; then
  if [ "$ROOT_PART_NUM_CLI" -eq 0 ]; then
    v="$(read_meta_var "$META" "ROOT_PART_NUM")"
    [ -n "$v" ] && ROOT_PART_NUM="$v"
  fi
  if [ "$EFI_PART_NUM_CLI" -eq 0 ]; then
    v="$(read_meta_var "$META" "EFI_PART_NUM")"
    [ -n "$v" ] && EFI_PART_NUM="$v"
  fi
elif [ "$SELF_CHECK_ONLY" -eq 0 ]; then
  warn "metadata not found: $META; size precheck will be skipped"
fi

if [ "$EFI_PART_NUM_CLI" -eq 0 ] && [ -z "$EFI_PART_NUM" ]; then
  EFI_PART_NUM="$(detect_efi_part_num "$DISK" || true)"
  if [ -z "$EFI_PART_NUM" ]; then
    EFI_PART_NUM="1"
    warn "cannot detect EFI partition, fallback to partition number: $EFI_PART_NUM"
  else
    log "[+] detected EFI partition number: $EFI_PART_NUM"
  fi
fi

if [ "$SELF_CHECK_ONLY" -eq 0 ]; then
  [ -f "$IMG" ] || die "image not found: $IMG"

  ensure_tool dd "coreutils"
  ensure_tool gunzip "gzip"

  if [ -f "$META" ]; then
    NEED_BYTES="$(read_meta_var "$META" "COPY_BYTES")"
  else
    NEED_BYTES=""
  fi

  TARGET_BYTES="$(blockdev --getsize64 "$DISK")"
  if [ -n "$NEED_BYTES" ] && [ "$TARGET_BYTES" -lt "$NEED_BYTES" ]; then
    die "target disk does not have enough space, abort: target=$TARGET_BYTES, need>=$NEED_BYTES"
  fi

  log "[+] restoring image to $DISK"
  if dd --help 2>&1 | grep -q "status="; then
    gunzip -c "$IMG" | dd of="$DISK" bs=4M status=progress conv=fsync
  else
    gunzip -c "$IMG" | dd of="$DISK" bs=4M conv=fsync
  fi
  sync

  log "[+] repairing backup GPT location"
  sgdisk -e "$DISK"

  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$DISK" || true
  fi

  if [ "$REPAIR_BOOT" -eq 1 ]; then
    ensure_tool mount "mount util-linux"
    ensure_tool umount "mount util-linux"
    ensure_tool blkid "blkid util-linux"
    ensure_tool sed "sed"
    ensure_tool cp "coreutils"
    ensure_tool mv "coreutils"

    log "[+] running boot consistency repair"
    ROOT_PART="$(part_path "$DISK" "$ROOT_PART_NUM")"
    EFI_PART="$(part_path "$DISK" "$EFI_PART_NUM")"

    [ -b "$ROOT_PART" ] || die "root partition not found: $ROOT_PART"

    MNT_ROOT="/tmp/openwrt-restore-root.$$"
    MNT_EFI="$MNT_ROOT/boot/efi"
    mkdir -p "$MNT_ROOT"

    mounted_root=0
    mounted_efi=0
    cleanup_restore() {
      if [ "$mounted_efi" -eq 1 ]; then
        umount "$MNT_EFI" 2>/dev/null || true
      fi
      if [ "$mounted_root" -eq 1 ]; then
        umount "$MNT_ROOT" 2>/dev/null || true
      fi
      rm -rf "$MNT_ROOT"
    }
    trap cleanup_restore EXIT INT TERM

    mount "$ROOT_PART" "$MNT_ROOT"
    mounted_root=1

    GRUB_CFG="$MNT_ROOT/boot/grub/grub.cfg"
    ROOT_UUID="$(blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || true)"
    if [ -f "$GRUB_CFG" ] && [ -n "$ROOT_UUID" ]; then
      cp "$GRUB_CFG" "$GRUB_CFG.bak.$(date +%Y%m%d%H%M%S)"
      sed "s#root=PARTUUID=[^ ]*#root=PARTUUID=$ROOT_UUID#g" "$GRUB_CFG" > "$GRUB_CFG.tmp"
      mv "$GRUB_CFG.tmp" "$GRUB_CFG"
      log "[+] synced grub root PARTUUID -> $ROOT_UUID"
    else
      warn "grub.cfg or PARTUUID not available, skipping PARTUUID sync"
    fi

    if [ -b "$EFI_PART" ]; then
      EFI_TYPE="$(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || true)"
      if [ "$EFI_TYPE" = "vfat" ] || [ "$EFI_TYPE" = "fat" ] || [ "$EFI_TYPE" = "msdos" ]; then
        mkdir -p "$MNT_EFI"
        if mount "$EFI_PART" "$MNT_EFI"; then
          mounted_efi=1
          if [ ! -f "$MNT_EFI/EFI/BOOT/BOOTX64.EFI" ]; then
            fallback_src=""
            if [ -f "$MNT_EFI/EFI/openwrt/grubx64.efi" ]; then
              fallback_src="$MNT_EFI/EFI/openwrt/grubx64.efi"
            elif [ -f "$MNT_EFI/EFI/BOOT/grubx64.efi" ]; then
              fallback_src="$MNT_EFI/EFI/BOOT/grubx64.efi"
            elif [ -f "$MNT_ROOT/boot/grub/grubx64.efi" ]; then
              fallback_src="$MNT_ROOT/boot/grub/grubx64.efi"
            fi
          fi
          if [ -n "${fallback_src:-}" ] && [ ! -f "$MNT_EFI/EFI/BOOT/BOOTX64.EFI" ]; then
            mkdir -p "$MNT_EFI/EFI/BOOT"
            cp "$fallback_src" "$MNT_EFI/EFI/BOOT/BOOTX64.EFI"
            log "[+] added UEFI fallback file EFI/BOOT/BOOTX64.EFI"
          fi
        else
          warn "failed to mount EFI partition: $EFI_PART"
        fi
      fi
    fi

    if command -v grub-install >/dev/null 2>&1; then
      if [ "$mounted_efi" -eq 1 ]; then
        grub-install --target=x86_64-efi --efi-directory="$MNT_EFI" --boot-directory="$MNT_ROOT/boot" --removable --recheck || warn "UEFI grub-install failed (image may still boot)"
      else
        warn "EFI partition not mounted, skip UEFI grub-install"
      fi
      grub-install --target=i386-pc --boot-directory="$MNT_ROOT/boot" "$DISK" || warn "BIOS grub-install failed (image may still boot)"
    else
      warn "grub-install not found, skipping bootloader reinstall"
    fi

    trap - EXIT INT TERM
    cleanup_restore
  fi
fi

if [ "$SELF_CHECK" -eq 1 ]; then
  run_self_check
fi

log "[OK] restore finished"
log "tip: run fsck + resize2fs on first boot if you need to expand filesystem"
