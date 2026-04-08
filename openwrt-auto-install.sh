#!/bin/sh

set -eu

SCRIPT_NAME=$(basename "$0")
DEFAULT_IMAGE_URL="https://downloads.openwrt.org/releases/25.12.2/targets/x86/64/openwrt-25.12.2-x86-64-generic-ext4-combined-efi.img.gz"

usage() {
    cat <<EOF
用法:
  $SCRIPT_NAME install [-d /dev/sdX] [-i /path/to/openwrt.img.gz] [-u IMAGE_URL] [--force] [-y]
  $SCRIPT_NAME expand  [-d /dev/sdX] [--part 2] [--grub /boot/grub/grub.cfg] [-y]

说明:
  install  下载或使用本地镜像，将 OpenWrt 镜像写入目标磁盘。
           未指定 -d 时，会先尝试自动选择唯一的非系统盘，失败后进入菜单选择。
           写盘完成后请重启进入目标盘上的 OpenWrt，再执行 expand。
  expand   在首次启动到 OpenWrt 后，将第 2 分区扩展到整盘并同步更新 grub.cfg。
           未指定 -d 时，会尝试自动识别当前启动的系统盘，失败后进入菜单选择。
  -y       跳过交互确认。

示例:
  $SCRIPT_NAME install -d /dev/sdb
  $SCRIPT_NAME install -d /dev/sdb -i /root/openwrt.img.gz
  $SCRIPT_NAME expand -d /dev/sda
EOF
}

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

require_tty() {
    [ -r /dev/tty ] || die "当前没有可交互终端。远程执行时请确保在终端中运行，或使用 -y 并显式传入参数。"
}

tty_print() {
    printf '%s' "$*" >/dev/tty
}

tty_println() {
    printf '%s\n' "$*" >/dev/tty
}

tty_read() {
    var_name="$1"
    require_tty
    IFS= read -r "$var_name" </dev/tty
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行该脚本。"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

ensure_tool() {
    tool_name="$1"
    pkg_name="$2"

    if command -v "$tool_name" >/dev/null 2>&1; then
        return 0
    fi

    command -v opkg >/dev/null 2>&1 || die "缺少命令 $tool_name，且当前系统没有 opkg 可自动安装。"
    log "未找到 $tool_name，尝试通过 opkg 安装 $pkg_name"
    opkg update
    opkg install "$pkg_name"
    command -v "$tool_name" >/dev/null 2>&1 || die "已尝试安装 $pkg_name，但仍未找到命令 $tool_name"
}

disk_suffix() {
    case "$1" in
        *[0-9]) printf 'p' ;;
        *) printf '' ;;
    esac
}

part_path() {
    disk="$1"
    partno="$2"
    printf '%s%s%s' "$disk" "$(disk_suffix "$disk")" "$partno"
}

assert_block_device() {
    [ -b "$1" ] || die "不是有效的块设备: $1"
}

get_disk_from_part() {
    case "$1" in
        /dev/nvme*n[0-9]p[0-9]*|/dev/mmcblk*p[0-9]*)
            printf '%s\n' "${1%p[0-9]*}"
            ;;
        /dev/*[0-9])
            printf '%s\n' "${1%%[0-9]*}"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

list_physical_disks() {
    for sysdev in /sys/class/block/*; do
        name=$(basename "$sysdev")
        [ -e "$sysdev" ] || continue
        [ -f "$sysdev/partition" ] && continue
        case "$name" in
            loop*|ram*|fd*|sr*|md*|dm-*)
                continue
                ;;
        esac
        [ -b "/dev/$name" ] || continue
        printf '/dev/%s\n' "$name"
    done
}

get_cmdline_root_value() {
    for item in $(cat /proc/cmdline 2>/dev/null); do
        case "$item" in
            root=*)
                printf '%s\n' "${item#root=}"
                return 0
                ;;
        esac
    done
    return 1
}

find_part_by_partuuid() {
    partuuid="$1"
    blkid | awk -F: -v key="PARTUUID=\"$partuuid\"" 'index($0, key) { print $1; exit }'
}

detect_current_root_part() {
    root_value=$(get_cmdline_root_value || true)
    case "$root_value" in
        PARTUUID=*)
            find_part_by_partuuid "${root_value#PARTUUID=}"
            return 0
            ;;
        /dev/*)
            printf '%s\n' "$root_value"
            return 0
            ;;
    esac

    mount_src=$(awk '$2 == "/" { print $1; exit }' /proc/mounts 2>/dev/null || true)
    case "$mount_src" in
        /dev/*)
            printf '%s\n' "$mount_src"
            return 0
            ;;
    esac

    return 1
}

detect_system_disk() {
    root_part=$(detect_current_root_part || true)
    [ -n "$root_part" ] || return 1
    get_disk_from_part "$root_part"
}

count_lines() {
    count=0
    while IFS= read -r _line; do
        count=$((count + 1))
    done
    echo "$count"
}

auto_detect_install_disk() {
    system_disk=$(detect_system_disk || true)
    removable_candidates=""
    other_candidates=""

    for disk in $(list_physical_disks); do
        [ "$disk" = "$system_disk" ] && continue
        disk_name=$(basename "$disk")
        removable=0
        if [ -r "/sys/class/block/$disk_name/removable" ]; then
            removable=$(cat "/sys/class/block/$disk_name/removable")
        fi

        if [ "$removable" = "1" ]; then
            removable_candidates="${removable_candidates}${disk}\n"
        else
            other_candidates="${other_candidates}${disk}\n"
        fi
    done

    removable_count=$(printf '%b' "$removable_candidates" | sed '/^$/d' | count_lines)
    other_count=$(printf '%b' "$other_candidates" | sed '/^$/d' | count_lines)

    if [ "$removable_count" -eq 1 ]; then
        printf '%b' "$removable_candidates" | sed '/^$/d' | head -n 1
        return 0
    fi

    if [ "$removable_count" -eq 0 ] && [ "$other_count" -eq 1 ]; then
        printf '%b' "$other_candidates" | sed '/^$/d' | head -n 1
        return 0
    fi

    warn "自动识别安装目标盘失败。当前系统盘: ${system_disk:-未知}"
    warn "可见磁盘如下:"
    list_physical_disks >&2
    return 1
}

confirm_or_die() {
    message="$1"
    assume_yes="${2:-0}"

    if [ "$assume_yes" -eq 1 ]; then
        return 0
    fi

    tty_println "$message"
    tty_print '输入 YES 继续: '
    tty_read answer
    [ "$answer" = "YES" ] || die "已取消操作。"
}

print_disk_summary() {
    disk="$1"
    if command -v fdisk >/dev/null 2>&1; then
        fdisk -l "$disk" 2>/dev/null || true
    fi
}

get_disk_partition_overview() {
    disk="$1"

    if ! command -v fdisk >/dev/null 2>&1; then
        printf 'unknown'
        return 0
    fi

    overview=$(
        fdisk -l "$disk" 2>/dev/null | awk -v disk="$disk" '
            BEGIN { capture=0; out="" }
            /^Device[[:space:]]+Start/ { capture=1; next }
            capture && $1 ~ "^" disk {
                size=""
                type=""
                if (NF >= 5) {
                    size=$(NF-1)
                    type=$NF
                }
                if (NF >= 6) {
                    type=$(NF-1) " " $NF
                }
                if (out != "") out=out "; "
                out=out $1 " " size " " type
            }
            END {
                if (out == "") print "no partitions"
                else print out
            }
        '
    )

    printf '%s\n' "$overview" | sed 's/  */ /g'
}

get_disk_size_human() {
    disk_name=$(basename "$1")
    size_file="/sys/class/block/$disk_name/size"
    [ -r "$size_file" ] || {
        printf 'unknown'
        return 0
    }
    sectors=$(cat "$size_file")
    awk "BEGIN { printf \"%.1f GiB\", ($sectors * 512) / 1024 / 1024 / 1024 }"
}

get_disk_model() {
    disk_name=$(basename "$1")
    for model_file in \
        "/sys/class/block/$disk_name/device/model" \
        "/sys/class/block/$disk_name/device/name"; do
        if [ -r "$model_file" ]; then
            tr -s ' ' <"$model_file" | sed 's/^ *//;s/ *$//'
            return 0
        fi
    done
    printf 'unknown'
}

get_disk_removable() {
    disk_name=$(basename "$1")
    removable_file="/sys/class/block/$disk_name/removable"
    if [ -r "$removable_file" ] && [ "$(cat "$removable_file")" = "1" ]; then
        printf 'yes'
    else
        printf 'no'
    fi
}

show_disk_table() {
    system_disk="${1:-}"
    index=1

    tty_println '可选磁盘:'
    for disk in $(list_physical_disks); do
        marker=""
        [ -n "$system_disk" ] && [ "$disk" = "$system_disk" ] && marker=" [当前系统盘]"
        printf '  %s) %s | %s | removable:%s | model:%s%s\n' \
            "$index" \
            "$disk" \
            "$(get_disk_size_human "$disk")" \
            "$(get_disk_removable "$disk")" \
            "$(get_disk_model "$disk")" \
            "$marker" >/dev/tty
        printf '     parts: %s\n' "$(get_disk_partition_overview "$disk")" >/dev/tty
        index=$((index + 1))
    done
}

pick_disk_from_menu() {
    prompt="$1"
    system_disk="${2:-}"
    forbid_system="${3:-0}"
    count=0

    for _disk in $(list_physical_disks); do
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || die "没有找到可选磁盘。"

    while :; do
        show_disk_table "$system_disk"
        tty_print "$prompt"
        tty_read selection

        case "$selection" in
            ''|*[!0-9]*)
                warn "请输入有效的数字序号。"
                continue
                ;;
        esac

        index=1
        chosen_disk=""
        for disk in $(list_physical_disks); do
            if [ "$index" = "$selection" ]; then
                chosen_disk="$disk"
                break
            fi
            index=$((index + 1))
        done

        [ -n "$chosen_disk" ] || {
            warn "序号超出范围，请重新输入。"
            continue
        }

        if [ "$forbid_system" -eq 1 ] && [ -n "$system_disk" ] && [ "$chosen_disk" = "$system_disk" ]; then
            warn "安装目标盘不能是当前系统盘，请重新选择。"
            continue
        fi

        printf '%s\n' "$chosen_disk"
        return 0
    done
}

download_image() {
    image_url="$1"
    out_path="$2"

    require_cmd wget
    if [ -f "$out_path" ]; then
        log "镜像已存在，跳过下载: $out_path"
        return 0
    fi

    log "下载镜像: $image_url"
    wget -O "$out_path" "$image_url"
}

write_image() {
    image_path="$1"
    target_disk="$2"

    assert_block_device "$target_disk"

    case "$image_path" in
        *.gz)
            require_cmd gzip
            log "写入压缩镜像到 $target_disk"
            gzip -dc "$image_path" | dd of="$target_disk" bs=4M conv=fsync status=progress
            ;;
        *)
            log "写入镜像到 $target_disk"
            dd if="$image_path" of="$target_disk" bs=4M conv=fsync status=progress
            ;;
    esac

    sync
    log "镜像写入完成: $target_disk"
}

get_part_start_sector() {
    fdisk -l "$1" | awk '$1 == "'"$2"'" { print $2; exit }'
}

get_disk_last_sector() {
    disk_name=$(basename "$1")
    sys_size="/sys/class/block/$disk_name/size"
    [ -r "$sys_size" ] || die "无法读取磁盘扇区数: $sys_size"
    total_sectors=$(cat "$sys_size")
    [ -n "$total_sectors" ] || die "无法获取磁盘总扇区数: $1"
    echo $((total_sectors - 34))
}

find_free_loop() {
    if losetup -f >/dev/null 2>&1; then
        losetup -f
        return 0
    fi

    for loopdev in /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3 /dev/loop4 /dev/loop5 /dev/loop6 /dev/loop7; do
        if [ -b "$loopdev" ] && ! losetup "$loopdev" >/dev/null 2>&1; then
            echo "$loopdev"
            return 0
        fi
    done

    return 1
}

update_grub_partuuid() {
    grub_cfg="$1"
    new_partuuid="$2"
    backup_file="${grub_cfg}.bak.$(date +%Y%m%d%H%M%S)"
    tmp_file="${grub_cfg}.tmp.$$"

    [ -f "$grub_cfg" ] || die "未找到 grub 配置文件: $grub_cfg"
    cp "$grub_cfg" "$backup_file"

    sed "s#root=PARTUUID=[^ ]*#root=PARTUUID=$new_partuuid#g" "$grub_cfg" >"$tmp_file"
    mv "$tmp_file" "$grub_cfg"

    log "已更新 grub PARTUUID，备份文件: $backup_file"
}

expand_disk() {
    target_disk="$1"
    grub_cfg="$2"
    partno="$3"
    assume_yes="$4"

    assert_block_device "$target_disk"
    target_part=$(part_path "$target_disk" "$partno")
    assert_block_device "$target_part"

    ensure_tool fdisk fdisk
    ensure_tool losetup losetup
    ensure_tool resize2fs resize2fs
    ensure_tool blkid blkid
    require_cmd sed
    require_cmd awk

    start_sector=$(get_part_start_sector "$target_disk" "$target_part")
    [ -n "$start_sector" ] || die "无法识别 $target_part 的起始扇区"
    last_sector=$(get_disk_last_sector "$target_disk")

    log "准备重建分区表: $target_part"
    log "起始扇区: $start_sector, 结束扇区: $last_sector"
    log "扩容策略: 第 $partno 分区将使用目标磁盘上的全部剩余空间。"

    confirm_or_die "即将扩容磁盘
目标磁盘: $target_disk
目标分区: $target_part
grub 配置: $grub_cfg
当前分区: $(get_disk_partition_overview "$target_disk")

脚本会删除并重建第 $partno 分区，但会保留原有起始扇区和文件系统签名。" "$assume_yes"
    print_disk_summary "$target_disk"
    printf 'd\n%s\nn\n%s\n%s\n%s\nn\nw\n' \
        "$partno" "$partno" "$start_sector" "$last_sector" | fdisk "$target_disk"

    sync
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --rereadpt "$target_disk" >/dev/null 2>&1 || true
    fi
    if command -v partx >/dev/null 2>&1; then
        partx -u "$target_disk" >/dev/null 2>&1 || true
    fi
    sleep 2

    loopdev=$(find_free_loop) || die "未找到可用的 loop 设备"
    log "使用循环设备: $loopdev"

    losetup "$loopdev" "$target_part"
    trap 'losetup -d "$loopdev" >/dev/null 2>&1 || true' EXIT INT TERM

    resize2fs -f "$loopdev"

    new_partuuid=$(blkid -s PARTUUID -o value "$target_part")
    [ -n "$new_partuuid" ] || die "无法读取 $target_part 的 PARTUUID"
    update_grub_partuuid "$grub_cfg" "$new_partuuid"

    losetup -d "$loopdev"
    trap - EXIT INT TERM

    log "expand 步骤完成。分区已扩至目标磁盘剩余空间上限。"
}

run_install() {
    target_disk=""
    image_path=""
    image_url="$DEFAULT_IMAGE_URL"
    force_write=0
    assume_yes=0
    system_disk=$(detect_system_disk || true)

    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--disk)
                target_disk="$2"
                shift 2
                ;;
            -i|--image)
                image_path="$2"
                shift 2
                ;;
            -u|--url)
                image_url="$2"
                shift 2
                ;;
            --force)
                force_write=1
                shift
                ;;
            -y|--yes)
                assume_yes=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "install 不支持的参数: $1"
                ;;
        esac
    done

    if [ -z "$target_disk" ]; then
        if target_disk=$(auto_detect_install_disk); then
            log "自动识别到安装目标盘: $target_disk"
        else
            target_disk=$(pick_disk_from_menu "请选择要写入镜像的目标磁盘序号: " "$system_disk" 1)
            log "你选择的安装目标盘: $target_disk"
        fi
    fi
    assert_block_device "$target_disk"

    if [ "$force_write" -ne 1 ] && [ -n "$system_disk" ] && [ "$target_disk" = "$system_disk" ]; then
        die "目标磁盘 $target_disk 与当前系统盘相同。请确认后加 --force。"
    fi

    if [ -z "$image_path" ]; then
        image_name=$(basename "$image_url")
        image_path="/tmp/$image_name"
        download_image "$image_url" "$image_path"
    else
        [ -f "$image_path" ] || die "镜像文件不存在: $image_path"
    fi

    confirm_or_die "即将把镜像写入 $target_disk
镜像文件: $image_path
当前系统盘: ${system_disk:-未知}
当前分区: $(get_disk_partition_overview "$target_disk")

警告: 该操作会清空目标磁盘上的现有数据。" "$assume_yes"
    print_disk_summary "$target_disk"
    write_image "$image_path" "$target_disk"
    log "install 步骤完成。请拔掉启动 U 盘并重启到 $target_disk 上的新 OpenWrt。"
    log "进入目标盘系统后，再执行: $SCRIPT_NAME expand -d $target_disk"
}

run_expand() {
    target_disk=""
    grub_cfg="/boot/grub/grub.cfg"
    partno="2"
    assume_yes=0

    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--disk)
                target_disk="$2"
                shift 2
                ;;
            --grub)
                grub_cfg="$2"
                shift 2
                ;;
            --part)
                partno="$2"
                shift 2
                ;;
            -y|--yes)
                assume_yes=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "expand 不支持的参数: $1"
                ;;
        esac
    done

    if [ -z "$target_disk" ]; then
        target_disk=$(detect_system_disk || true)
        if [ -n "$target_disk" ]; then
            log "自动识别到当前系统盘: $target_disk"
        else
            target_disk=$(pick_disk_from_menu "请选择要扩容的系统磁盘序号: ")
            log "你选择的扩容磁盘: $target_disk"
        fi
    fi
    expand_disk "$target_disk" "$grub_cfg" "$partno" "$assume_yes"
    log "建议现在执行 reboot。"
}

main() {
    [ $# -gt 0 ] || {
        usage
        exit 1
    }

    subcommand="$1"
    shift

    case "$subcommand" in
        -h|--help|help)
            usage
            ;;
        install)
            require_root
            run_install "$@"
            ;;
        expand)
            require_root
            run_expand "$@"
            ;;
        *)
            die "不支持的子命令: $subcommand"
            ;;
    esac
}

main "$@"
