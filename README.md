# OpenWrt 自动安装与扩容脚本

脚本文件：

`openwrt-auto-install.sh`

适用于 `x86/64 + EFI + ext4 combined image` 的 OpenWrt 安装场景。

当前推荐的脚本直链：

`https://cdn.osyb.cn/gh/lxj/openwrt@main/openwrt-auto-install.sh`

## 快速运行

脚本已经适配远程管道执行场景；即使使用 `curl | sh` 或 `wget | sh`，交互确认和菜单选盘也会直接从当前终端读取。

### 使用 `wget`

```sh
wget -O - "https://cdn.osyb.cn/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh
```

### 使用 `curl`

```sh
curl -fsSL "https://cdn.osyb.cn/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh
```

## 常用示例

### 先做环境预检

推荐安装前先执行一次预检，确认当前系统盘、候选目标盘、关键命令和 `grub.cfg` 路径是否正常。

```sh
wget -O - "https://cdn.osyb.cn/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- check
```

### 交互式安装

脚本会先自动做一轮安装预检；通过后再尝试识别目标盘，若无法确定会弹出菜单让你选择。

```sh
wget -O - "https://cdn.osyb.cn/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- install
```

### 安装并跳过确认

适合无人值守场景。该命令只负责写盘，不会自动扩容。

```sh
wget -O - "https://cdn.osyb.cn/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- install -y
```

### 指定目标盘安装

```sh
wget -O - "https://cdn.osyb.cn/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- install -d /dev/sdb
```

### 单独执行扩容

请先重启进入目标盘上的 OpenWrt，再执行扩容：

```sh
wget -O - "https://cdn.osyb.cn/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- expand
```

### 指定磁盘扩容

```sh
wget -O - "https://cdn.osyb.cn/gh/lxj/openwrt@main/openwrt-auto-install.sh" | sh -s -- expand -d /dev/sda
```

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
