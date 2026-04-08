这里以U 盘为列，U 盘安装了OpenWrt，但给OpenWrt 的空间只有 2.1G，但真个U 盘是 60 个G 呢，所以需要把剩下的空间给到OpenWrt

```shell
root@OpenWrt:~# opkg update  // 更新最新包

root@OpenWrt:~# opkg install fdisk losetup resize2fs blkid //安装一些基础的工具

root@OpenWrt:~# fdisk -l // 查看当前硬盘信息
GPT PMBR size mismatch (4440638 != 121110527) will be corrected by write.
Disk /dev/sda: 57.75 GiB, 62008590336 bytes, 121110528 sectors
Disk model: DataTraveler 3.0
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: BF7A017B-4794-7EEB-750B-7774328FBD00

Device     Start     End Sectors  Size Type
/dev/sda1    512   33279   32768   16M Linux filesystem
/dev/sda2  33280 4440605 4407326  2.1G Linux filesystem
/dev/sda3     34     511     478  239K BIOS boot

Partition table entries are not in disk order.


Disk /dev/sdb: 298.09 GiB, 320072933376 bytes, 625142448 sectors
Disk model: WDC WD3200BJKT-0
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: BF546B90-6462-4880-8899-F0B87FE9ED1D

Device       Start       End   Sectors   Size Type
/dev/sdb1     2048   1050623   1048576   512M EFI System
/dev/sdb2  1050624 625141759 624091136 297.6G Linux filesystem


root@OpenWrt:~# fdisk /dev/sda  // 开始对sda硬盘进行分区

Welcome to fdisk (util-linux 2.37.4).
Changes will remain in memory only, until you decide to write them.
Be careful before using the write command.

GPT PMBR size mismatch (4440638 != 121110527) will be corrected by write.
This disk is currently in use - repartitioning is probably a bad idea.
It's recommended to umount all file systems, and swapoff all swap
partitions on this disk.


Command (m for help): p  //查看当前硬盘信息

Disk /dev/sda: 57.75 GiB, 62008590336 bytes, 121110528 sectors
Disk model: DataTraveler 3.0
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: BF7A017B-4794-7EEB-750B-7774328FBD00

Device     Start     End Sectors  Size Type
/dev/sda1    512   33279   32768   16M Linux filesystem
/dev/sda2  33280 4440605 4407326  2.1G Linux filesystem
/dev/sda3     34     511     478  239K BIOS boot

Partition table entries are not in disk order.

Command (m for help): d   // 开始删除分区
Partition number (1-3, default 3): 2   // 删除2分区，及sda2

Partition 2 has been deleted.

Command (m for help): n  // 新建分区
Partition number (2,4-128, default 2): 2   //新建的分区号为2
First sector (33280-121110494, default 34816): 33280  // 分区起始点
Last sector, +/-sectors or +/-size{K,M,G,T,P} (33280-121110494, default 121110494): 121110494 //分区结束点

Created a new partition 2 of type 'Linux filesystem' and of size 57.7 GiB.
Partition #2 contains a ext4 signature.

Do you want to remove the signature? [Y]es/[N]o: n  // 不删除签名

Command (m for help): w  // 保存新的分区表

The partition table has been altered.
Syncing disks.

root@OpenWrt:~# fdisk -l // 在查看sda信息
Disk /dev/sda: 57.75 GiB, 62008590336 bytes, 121110528 sectors
Disk model: DataTraveler 3.0
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: BF7A017B-4794-7EEB-750B-7774328FBD00

Device     Start       End   Sectors  Size Type
/dev/sda1    512     33279     32768   16M Linux filesystem
/dev/sda2  33280 121110494 121077215 57.7G Linux filesystem
/dev/sda3     34       511       478  239K BIOS boot

// 操作到这里，系统还不会识别这个新空间，还需要下面的操作
root@OpenWrt:~# losetup  // 看下有误挂载的循坏设备，一般情况下是没有的，如果有的话就不要使用这个设备路径即可

root@OpenWrt:~# losetup /dev/loop0 /dev/sda2

root@OpenWrt:~# resize2fs -f /dev/loop0

resize2fs 1.46.5 (30-Dec-2021)
Resizing the filesystem on /dev/loop0 to 15134651 (4k) blocks.
The filesystem on /dev/loop0 is now 15134651 (4k) blocks long.

// 由于使用的是 openwrt-22.03.5-x86-64-generic-ext4-combined-efi.img 固件，这里还需要进行一些额外的操作
// 如果不进行下面操作的话，重启路由了后 将出现 openwrt waiting for root device partuuid=xxxxxxx 问题（起始这里的xxx就是旧的/dev/sda2的值） 导致卡柱进不了系统
root@OpenWrt:~# blkid
/dev/sdb2: UUID="ac2dd26c-bb32-4c1a-9a87-55ebc41ca5a6" BLOCK_SIZE="4096" TYPE="ext4" PARTUUID="4b81f3f0-db60-4794-874b-11a609515390"
/dev/sdb1: UUID="F531-409E" BLOCK_SIZE="512" TYPE="vfat" PARTLABEL="EFI System Partition" PARTUUID="572b82d6-b5fc-438d-8dc7-5cc7488e2d06"
/dev/loop0: LABEL="rootfs" UUID="ff313567-e9f1-5a5d-9895-3ba130b4a864" BLOCK_SIZE="4096" TYPE="ext4"
/dev/sda2: LABEL="rootfs" UUID="ff313567-e9f1-5a5d-9895-3ba130b4a864" BLOCK_SIZE="4096" TYPE="ext4" PARTUUID="150c36c4-081a-f241-b4ce-17b60116bbfb"
/dev/sda3: PARTUUID="bf7a017b-4794-7eeb-750b-7774328fbd80"
/dev/sda1: SEC_TYPE="msdos" LABEL_FATBOOT="kernel" LABEL="kernel" UUID="1234-ABCD" BLOCK_SIZE="512" TYPE="vfat" PARTUUID="bf7a017b-4794-7eeb-750b-7774328fbd01"

// 这里 复制 /dev/sda2 中PARTUUID中的值 替换掉 /boot/grub/grub.cfg文件中的 PARTUUID中的值
root@OpenWrt:~# vi /boot/grub/grub.cfg

root@OpenWrt:~# cat /boot/grub/grub.cfg  // 查看核对下文件内容 看下是不是已经改成最新的了
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1 --rtscts=off
terminal_input console serial; terminal_output console serial

set default="0"
set timeout="5"
search -l kernel -s root

menuentry "OpenWrt" {
        linux /boot/vmlinuz root=PARTUUID=150c36c4-081a-f241-b4ce-17b60116bbfb rootwait   console=tty0 console=ttyS0,115200n8 noinitrd
}
menuentry "OpenWrt (failsafe)" {
        linux /boot/vmlinuz failsafe=true root=PARTUUID=150c36c4-081a-f241-b4ce-17b60116bbfb rootwait   console=tty0 console=ttyS0,115200n8 noinitrd
}

// 地址 PARTUUID中的值已经是最新/dev/sda2分区的值了
root@OpenWrt:~# reboot

```

当然也可以通过scp将grub.cfg文件下载到本地，修改后再上传上去

```bash
# 下在grub.cfg到本地
scp root@10.1.3.99:/boot/grub/grub.cfg到本地 .

# 上传grub.cfg到远程覆盖
scp grub.cfg root@10.1.3.99:/boot/grub/grub.cfg
```

**vi /boot/grub/grub.cfg**

```shell
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1 --rtscts=off
terminal_input console serial; terminal_output console serial

set default="0"
set timeout="5"
search -l kernel -s root

menuentry "OpenWrt" {
        linux /boot/vmlinuz root=PARTUUID=bf7a017b-4794-7eeb-750b-7774328fbd02 rootwait   console=tty0 console=ttyS0,115200n8 noinitrd
}
menuentry "OpenWrt (failsafe)" {
        linux /boot/vmlinuz failsafe=true root=PARTUUID=bf7a017b-4794-7eeb-750b-7774328fbd02 rootwait   console=tty0 console=ttyS0,115200n8 noinitrd
}
```

