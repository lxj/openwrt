# OpenWrt 自动安装与扩容脚本

脚本文件：

`openwrt-auto-install.sh`

适用于 `x86/64 + EFI + ext4 combined image` 的 OpenWrt 安装场景。

当前推荐的脚本直链：

`https://cdn.osyb.cn/gh/lxj/openwrt@main/openwrt-auto-install.sh`

官方 x86/64 镜像列表：

[OpenWrt Downloads x86/64](https://downloads.openwrt.org/releases/25.12.2/targets/x86/64/)

## 快速运行

脚本已经适配远程管道执行场景；即使使用 `curl | sh` 或 `wget | sh`，交互确认和菜单选盘也会直接从当前终端读取。

### 使用 `wget`

```sh
wget -O - "https://cdn.jsdelivr.net/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh
```

### 使用 `curl`

```sh
curl -fsSL "https://cdn.jsdelivr.net/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh
```

## 常用示例

### 先做环境预检

推荐安装前先执行一次预检，确认当前系统盘、候选目标盘、关键命令和 `grub.cfg` 路径是否正常。

```sh
wget -O - "https://cdn.jsdelivr.net/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- check
```

### 交互式安装

脚本会先自动做一轮安装预检；通过后再尝试识别目标盘，若无法确定会弹出菜单让你选择。

```sh
wget -O - "https://cdn.jsdelivr.net/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- install
```

### 安装并跳过确认

适合无人值守场景。该命令只负责写盘，不会自动扩容。

```sh
wget -O - "https://cdn.jsdelivr.net/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- install -y
```

### 指定目标盘安装

```sh
wget -O - "https://cdn.jsdelivr.net/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- install -d /dev/sdb
```

### 单独执行扩容

请先重启进入目标盘上的 OpenWrt，再执行扩容：

```sh
wget -O - "https://cdn.jsdelivr.net/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- expand
```

### 指定磁盘扩容

```sh
wget -O - "https://cdn.jsdelivr.net/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- expand -d /dev/sda
```

## 镜像类型说明

下面这组文件名通常会出现在 OpenWrt 的 x86/64 下载页里。我们当前项目的安装脚本，默认就是围绕其中的 `generic-ext4-combined-efi.img.gz` 设计的。

### 这张图里有哪些镜像

图中列出的镜像名称来自官方 x86/64 发布目录：

- `generic-ext4-combined-efi.img.gz`
- `generic-ext4-combined.img.gz`
- `generic-ext4-rootfs.img.gz`
- `generic-kernel.bin`
- `generic-squashfs-combined-efi.img.gz`
- `generic-squashfs-combined.img.gz`
- `generic-squashfs-rootfs.img.gz`
- `generic-targz-combined-efi.img.gz`
- `generic-targz-combined.img.gz`
- `generic-targz-rootfs.img.gz`
- `rootfs.tar.gz`

### 我们该怎么选

- 对于绝大多数 `x86_64 PC / 工控机 / 软路由 / 虚拟机`，并且使用 `UEFI` 启动时，优先选择 `generic-ext4-combined-efi.img.gz`
- 如果机器是传统 `Legacy BIOS` 启动，不是 UEFI，则优先选择 `generic-ext4-combined.img.gz`
- 如果你明确要用只读根文件系统和 overlay 的 OpenWrt 风格，可以考虑 `generic-squashfs-combined-efi.img.gz` 或 `generic-squashfs-combined.img.gz`
- 如果你只是做高级手工安装、拼装系统、容器或定制根文件系统，不要直接选 `rootfs`、`kernel.bin`、`rootfs.tar.gz` 这些拆分镜像

### 各种镜像分别是干什么的

- `generic-ext4-combined-efi.img.gz`
  适合 `UEFI` 启动。它是完整磁盘镜像，包含引导分区和 ext4 根分区，最适合我们现在这种“直接写盘安装”的流程。
- `generic-ext4-combined.img.gz`
  适合传统 `BIOS/Legacy` 启动。它也是完整磁盘镜像，但不是 EFI 引导版本。
- `generic-ext4-rootfs.img.gz`
  只是 ext4 根文件系统镜像，不含完整磁盘分区布局。通常用于高级手工安装，不适合我们这个脚本的直接写盘方案。
- `generic-kernel.bin`
  只有内核，不含完整 rootfs，也不适合直接拿来整盘安装。通常要和 rootfs 镜像配合做手工部署。
- `generic-squashfs-combined-efi.img.gz`
  适合 `UEFI` 启动，完整磁盘镜像，根文件系统是 squashfs。更接近 OpenWrt 传统只读系统布局。
- `generic-squashfs-combined.img.gz`
  适合传统 `BIOS/Legacy` 启动，完整磁盘镜像，根文件系统是 squashfs。
- `generic-squashfs-rootfs.img.gz`
  只是 squashfs 根文件系统镜像，不适合直接整盘写入安装。
- `generic-targz-combined-efi.img.gz`
  本质上仍是完整磁盘镜像，但用 tar/gzip 形式封装。一般不是最省事的首选，除非你明确需要这种封装格式。
- `generic-targz-combined.img.gz`
  与上面类似，只是对应传统 BIOS 启动场景。
- `generic-targz-rootfs.img.gz`
  只是 tar/gzip 形式的 rootfs，不适合我们当前的自动安装脚本。
- `rootfs.tar.gz`
  纯根文件系统归档包，适合容器、chroot、定制环境或高级恢复场景，不适合直接写盘安装。

### ext4、squashfs、targz 的区别

- `ext4`
  可直接读写，最适合 PC/虚拟机场景下的直接写盘、扩容和后续维护。我们当前脚本就是围绕 ext4 镜像做的。
- `squashfs`
  根文件系统只读，OpenWrt 传统风格更强，运行时通过 overlay 提供可写层。升级和恢复行为更接近很多嵌入式设备。
- `targz`
  重点在“封装格式”，通常用于手工部署或特殊流程，不是本项目的首选。

### BIOS 和 EFI 怎么选

- 文件名里带 `-efi`：用于 `UEFI` 启动
- 文件名里不带 `-efi`：用于传统 `BIOS/Legacy` 启动
- 现在的大多数新机器、NUC、工控机和虚拟机，优先尝试 `-efi`
- 如果你已经确认主机只能用 Legacy BIOS，再选非 `-efi`

### 本项目的推荐结论

- 当前仓库和脚本默认推荐：`generic-ext4-combined-efi.img.gz`
- 如果你的机器不是 UEFI 启动，请把镜像换成：`generic-ext4-combined.img.gz`
- 不建议把当前自动安装脚本直接用于 `rootfs`、`kernel.bin`、`rootfs.tar.gz` 这类拆分镜像
- 如果你后面想支持 `squashfs` 安装流程，可以单独再扩一版脚本

## 脚本行为说明

- `check` 会输出当前环境预检结果，帮助确认现场条件是否满足
- `install` 会下载或使用本地镜像，把 OpenWrt 写入目标磁盘
- `install` 在真正写盘前会先自动执行一轮预检
- `install` 只负责写盘，不会在 Live 环境里直接扩容
- 重启进入目标盘上的 OpenWrt 后，再执行 `expand`
- `expand` 会把第 `2` 分区扩到目标磁盘剩余空间上限
- 扩容后会自动更新 `/boot/grub/grub.cfg` 里的 `root=PARTUUID=...`
- 如果未传 `-d`，脚本会优先自动识别；识别失败时进入菜单选盘

## 建议

- 首次使用建议不要加 `-y`，先走交互模式确认磁盘选择
- 远程执行支持交互模式，例如 `curl ... | sh -s -- install`
- 在生产环境执行前，先确认目标设备名是否正确
- 如果是通过 Live OpenWrt 或 U 盘环境安装，完成后记得拔掉启动介质再重启
- 推荐流程是：`install` -> 重启进目标盘系统 -> `expand`
- 当前 README 使用的是第三方大陆加速镜像 `cdn.osyb.cn`，如果后续可用性变化，建议回退到官方 GitHub 或 jsDelivr 地址

## 镜像备份与恢复（可启动）

仓库已提供：

- `backup.sh`：一键生成可恢复镜像 + 虚拟机镜像
- `restore.sh`：一键恢复到物理磁盘，并做启动一致性修复

### 1. 一键备份

在 OpenWrt 或 Linux 环境执行：

```sh
chmod +x backup.sh restore.sh
./backup.sh -d /dev/sda -n openwrt
```

默认输出：

- `$HOME/backup/openwrt.img.gz`：用于物理机恢复
- `$HOME/backup/openwrt.qcow2`：用于 QEMU/KVM 直接启动
- `$HOME/backup/openwrt.meta`：恢复时容量校验与分区参数
- `$HOME/backup/partition.gpt`：GPT 分区表备份
- `$HOME/backup/mbr.img`：前 1MiB 引导区备份

说明：

- 自动根据“最后一个分区结束扇区”裁剪镜像大小
- 自动附加 buffer（默认 1GiB），无需手算 `dd count`
- 默认尝试对 ext4 根分区做离线 shrink，提高小盘恢复成功率
- 自动识别 EFI 分区号并写入 `meta`（识别失败回退到 `1`）
- 缺失依赖时会自动安装（优先使用 `apk`）
- 可选参数：`--root-part-num 2`、`--efi-part-num N`、`--shrink-margin-mib 256`、`--no-shrink-ext4`

### 2. 一键恢复到物理机

```sh
./restore.sh -d /dev/sda -i "$HOME/backup/openwrt.img.gz"
```

恢复脚本默认会执行：

- 写盘：`gunzip | dd`
- GPT 修复：`sgdisk -e`
- 同步 `/boot/grub/grub.cfg` 的 `root=PARTUUID=...`
- UEFI fallback 修复：补全 `EFI/BOOT/BOOTX64.EFI`（若缺失）
- 若存在 `grub-install`，尝试重装引导（UEFI 或 BIOS）
- 自动执行恢复后自检（GPT、根分区、grub.cfg、EFI 启动文件）
- 自检末尾输出汇总：`PASS/WARN/FAIL`
- 缺失依赖时会自动安装（优先使用 `apk`）
- 默认自动识别 EFI 分区号（识别失败回退到 `1`）
- 若元数据缺失，会跳过容量预检；若有元数据，空间不足会直接终止安装

这能显著提升“整盘恢复后目标硬盘可直接启动”的成功率。

可选参数：

- `--self-check-only`：只执行自检，不写盘
- `--no-self-check`：恢复完成后跳过自检
- `--no-repair-boot`：写盘后不做引导修复
- `--root-part-num N`：手动指定根分区号
- `--efi-part-num N`：手动指定 EFI 分区号

### 3. 虚拟机启动

```sh
qemu-system-x86_64 \
  -m 512 \
  -drive file=openwrt.qcow2,format=qcow2 \
  -net nic -net user \
  -nographic
```

如需 VMware / VirtualBox，可先转 `vmdk`：

```sh
qemu-img convert -O vmdk openwrt.qcow2 openwrt.vmdk
```

### 4. 启动模式注意事项

- 源盘是 `UEFI`，目标机器也应以 `UEFI` 启动
- 源盘是 `Legacy BIOS`，目标机器也应以 `Legacy BIOS` 启动
- 启动模式不一致时，即使分区数据恢复成功，也可能无法引导
