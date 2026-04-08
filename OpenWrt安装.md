本次安装采用的安装方法：

电脑上下载<font style="color:rgb(17, 17, 17);background-color:rgb(253, 253, 253);">OpenWRT镜像，通过balenaEtcher将镜像写入U盘</font>

<font style="color:rgb(17, 17, 17);background-color:rgb(253, 253, 253);">在要安装的主机上以U盘启动的方式运行OpenWRT，并配置其能正常联网，ssh链接OpenWRT主机，然后用命令行进行下面的安装操作：</font>

<font style="color:rgb(17, 17, 17);background-color:rgb(253, 253, 253);">目前最新的稳定版本：</font>[https://downloads.openwrt.org/releases/25.12.2/targets/x86/64/openwrt-25.12.2-x86-64-generic-ext4-combined-efi.img.gz](https://downloads.openwrt.org/releases/25.12.2/targets/x86/64/openwrt-25.12.2-x86-64-generic-ext4-combined-efi.img.gz)

```shell
# 下载镜像
root@OpenWrt:~# wget https://downloads.openwrt.org/releases/22.03.5/targets/x86/64/openwrt-22.03.5-x86-64-generic-ext4-combined-efi.img.gz
Downloading 'https://downloads.openwrt.org/releases/22.03.5/targets/x86/64/openwrt-22.03.5-x86-64-generic-ext4-combined-efi.img.gz'
Connecting to 168.119.138.211:443
Writing to 'openwrt-22.03.5-x86-64-generic-ext4-combined-efi.img.gz'
openwrt-22.03.5-x86- 100% |*******************************| 11792k  0:00:00 ETA
Download completed (12075249 bytes)

# 解压
root@OpenWrt:~# gzip -d openwrt-22.03.5-x86-64-generic-ext4-combined-efi.img.gz

```



<font style="color:rgb(17, 17, 17);background-color:rgb(253, 253, 253);">将 OpenWRT 系统镜像写入 </font><font style="color:rgb(17, 17, 17);background-color:rgb(238, 238, 255);">sdb</font><font style="color:rgb(17, 17, 17);background-color:rgb(253, 253, 253);"> 标识的硬盘里</font>

<font style="color:rgb(17, 17, 17);background-color:rgb(253, 253, 253);">没写盘前的硬盘信息</font>

```shell
root@OpenWrt:~# fdisk -l
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
```

/dev/sda 是U盘的信息

/dev/sdb 是即将要安装openwrt电脑硬盘的信息



下面开始写盘

```shell
root@OpenWrt:~# dd if=openwrt-22.03.5-x86-64-generic-ext4-combined-efi.img bs=1M of=/dev/sdb
120+1 records in
120+1 records out
```



写盘后的硬盘信息

```shell
root@OpenWrt:~# fdisk -l
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

Partition table entries are not in disk order.
GPT PMBR size mismatch (246303 != 625142447) will be corrected by write.
The backup GPT table is corrupt, but the primary appears OK, so that will be used.
The backup GPT table is not on the end of the device.


Disk /dev/sdb: 298.09 GiB, 320072933376 bytes, 625142448 sectors
Disk model: WDC WD3200BJKT-0
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: BF7A017B-4794-7EEB-750B-7774328FBD00

Device      Start    End Sectors  Size Type
/dev/sdb1     512  33279   32768   16M Linux filesystem
/dev/sdb2   33280 246271  212992  104M Linux filesystem
/dev/sdb128    34    511     478  239K BIOS boot

Partition table entries are not in disk order.
```

此时 /dev/sdb已被写入openwrt镜像



拔掉U盘，重启电脑

