# USB\VID_1E0E&PID_3487&MI_00 → Android（SukiSU 模块）移植说明

## 0. 实测结论（2026-10-22，Redmi K Pad / HyperOS 3 / Android 16）

已在真机上跑通，结论和最初设想差别很大，先看这段：

| 项目 | 结果 |
|---|---|
| 设备 | `24091RPADC`（turner），HyperOS `OS3.0.301.0.WPWCNXM` |
| 内核 | `5.10.233-android12-9-g9d81188ebb2f-ab178`（GKI 5.10） |
| 内核里的 RNDIS host | **没有**：`# CONFIG_USB_NET_RNDIS_HOST is not set` |
| 但 `usbnet` / `cdc_ether` / `NCM` / `EEM` | 全部内建 `=y` |
| 编译产物 | `rndis_host.ko`（AOSP `kernel/common` android12-5.10 + 设备 `config.gz` + `LLVM=1 LLVM_IAS=1`，带 CFI/LTO） |
| 必需补丁 | SIMCom 的 CDC 描述符被内核 `usbnet_generic_cdc_bind()` 判定为 `bad CDC descriptors`，驱动里加了“硬连线绑定”兜底（`ko/rndis_host.ko` 已包含，补丁见 `build/rndis-hardwire.patch`） |
| 加载后的网卡名 | **`eth0`**（不是 usb0） |
| 系统接管 | `EthernetTracker` 过滤规则是 `(usb\|eth)\d+`，自动 DHCP → `192.168.0.100/24`、DNS、默认路由，注册成 `ETHERNET` 网络 |
| 实测 | `ping -I eth0 223.5.5.5` → 0% 丢包 |
| 模块默认行为 | **只加载驱动**（`AUTO_NET=0`），网络全部交给系统以太网服务 |

由此得到两条和常见说法相反的经验，后面的旧章节如果与此冲突，以本节为准：

1. **这套 GKI 内核不比对 vermagic**：把厂商模块的 vermagic 改成 `5.10.999-...` 仍能加载；真正卡人的是 CFI（`CONFIG_CFI_CLANG=y`）和符号解析。
2. **`CONFIG_MODVERSIONS=y` 并不意味着必须匹配 CRC**：模块的 `__versions` 段为空（或缺失）时内核直接跳过版本校验——所以用设备 `config.gz` 编译、不带 `Module.symvers` 也能加载。

---

> 结论先行：**这个设备没有“厂商私有驱动”可以搬**。它在 Windows 上用的就是微软内置的
> RNDIS 驱动（`usbrndis6` 服务，二进制 `usb80236.sys`，INF 是 `wceisvista.inf`），
> 在 Linux/Android 上对应的驱动叫 **`rndis_host`**，是内核自带的 GPL 代码。所以“移植”真正要做的是两件事：
>
> 1. 让 Android 内核里有 `rndis_host`（内建，或加载一个和内核版本匹配的 `rndis_host.ko`）；
> 2. 把驱动生成的 `usb0` 网卡配起来（DHCP / 默认路由 / DNS）。
>
> 本目录里的 `module/` 就是干这两件事的 SukiSU/KernelSU/Magisk 通用模块，
> 打包好的刷机包在 `dist/simcom-rndis-otg-v1.0.0.zip`。

---

## 1. 在你机器上查到的证据

我用注册表（`HKLM\SYSTEM\CurrentControlSet\Enum\USB`）和 DriverStore 查了这台 Windows，
设备确实在，而且驱动绑定关系很明确：

| InstanceId | 绑定驱动 (Service) | INF | 说明 |
|---|---|---|---|
| `USB\VID_1E0E&PID_3487` | `usbccgp` | `usb.inf`（`Composite.Dev.NT`） | 复合设备本体，微软 USB 通用父驱动 |
| `USB\VID_1E0E&PID_3487&MI_00` | **`usbrndis6`** | **`wceisvista.inf`**（`RNDIS.NT.5.1`） | 接口 0 = RNDIS 网卡，微软内置 |

接口 0 的关键描述符信息：

```
DeviceDesc   = Remote NDIS based Internet Sharing Device
Class        = 网卡 {4d36e972-e325-11ce-bfc1-08002be10318}\0021
ProviderName = Microsoft        DriverVersion = 10.0.26100.1
CompatibleIDs:
  USB\COMPAT_VID_1e0e&Class_e0&SubClass_01&Prot_03   ← RNDIS: Wireless/RF/RNDIS
  USB\COMPAT_VID_1e0e&Class_e0&SubClass_01
  USB\Class_e0&SubClass_01&Prot_03
```

另外两个发现：

* DriverStore 里有一个 `mobile_rndis_network_adapter_(interface_0).inf`，是
  **libwdi（Zadig）生成的 WinUSB INF**，里面写死了 `DeviceID = VID_1E0E&PID_3487&MI_00`。
  说明这个接口在某个时刻被 Zadig 装过 WinUSB 驱动（用来抓包/发原始 USB 请求）。
  现在这条实例绑的还是 `usbrndis6`，也就是 RNDIS。
* 网卡类下面有 3 个 RNDIS 适配器实例（`0020/0021/0022`），`C:\Windows\INF` 里没有任何
  OEM INF 提到 `1E0E` —— **系统里没有装过任何厂商私有驱动**，全靠 Windows 自带。

> 所以“查看这个设备的驱动”这件事本身就说明：它不是那种需要装厂商驱动的设备，
> 而是一个**类标准（class-compliant）** 的 RNDIS 网卡。

---

## 2. 这个设备到底是什么

* **VID `1E0E`**：usb.ids 里登记为 *Qualcomm / Option / Simtech*，实际就是
  **SIMCom（芯讯通）** 的模组在用（[usb-ids 1e0e](https://usb-ids.gowdy.us/read/UD/1e0e)）。
* **PID `3487`**：没有收录在 usb.ids 里，属于模组厂自定义的 USB 组合号。
  SIMCom 的模组用 `AT+CUSBCFG=usbid,1e0e,xxxx` 切换 USB 组合，
  例如 SIM7600/SIM8200 切到 RNDIS 组合就是 `1e0e,9011`
  （见 [Waveshare SIM820X RNDIS 拨号](https://www.waveshare.com/wiki/SIM820X_RNDIS_Dail-up)）。
* **接口 0 的 `e0/01/03`**：USB-IF 定义的 *Wireless Controller / RF / RNDIS*，
  也就是微软 RNDIS 规范里规定的三元组。插到 Linux 上会自动生成 `usb0`，
  跑一次 DHCP 就能上网（Waveshare 的文档就是这么做的：`sudo dhclient usb0`）。

一句话：**这是 SIMCom 4G/5G 模组的 RNDIS 复合设备，接口 0 是一张免驱的 USB 网卡。**

---

## 3. 三个平台的“驱动”对照

| 层次 | Windows | Linux / Android |
|---|---|---|
| USB 复合设备 | `usbccgp.sys` | `usbcore` + `usb-storage` 等 |
| 网卡功能驱动 | `usbrndis6` 服务（`usb80236.sys`，`wceisvista.inf`） | **`rndis_host.ko`**（`drivers/net/usb/rndis_host.c`） |
| 底层公共层 | NDIS | `usbnet.ko`（+ `cdc_ether.ko` / `mii.ko` 依赖） |
| 配置 IP | 网络和共享中心 / DHCP | `ip` + `udhcpc` |

`rndis_host` 匹配的就是 `bInterfaceClass=0xE0 / SubClass=0x01 / Protocol=0x03`
这个组合，和你 MI_00 的 CompatibleID 完全对应。源码：
[rndis_host.c (v6.6)](https://elixir.bootlin.com/linux/v6.6/source/drivers/net/usb/rndis_host.c)。

---

## 4. 为什么不能把 `.sys` 直接“挂载”到 Android

这是最关键、也最容易被误解的一点：

1. **内核态二进制不通用。** `.sys` 是 PE/COFF 格式的 Windows 内核驱动，Android 内核只认
   ELF 格式的 `.ko`（或者编进 `vmlinux` 的代码）。这不是“包装一下”能解决的，是两套内核 API。
2. **`.ko` 也不是随便拿一个就能用。** 内核加载时会校验：
   * `vermagic`（内核版本、SMP、preempt、modversions 等标志）；
   * 符号 CRC（开了 `CONFIG_MODVERSIONS` 时，每个外部符号都有版本号）；
   * 模块签名（开了 `CONFIG_MODULE_SIG_FORCE` 时，未签名直接拒绝）。
   所以**必须用目标设备的内核源码 + 同一份配置 + 同一个编译器**来编。
3. **SukiSU/KernelSU 的“挂载”只覆盖文件。** 它的 overlayfs/magic mount 能把
   `/system`、`/vendor` 下的文件替换成模块里的同名文件，但**不会**帮你把
   “Windows 驱动”翻译成“Linux 驱动”，也不会让内核去加载一个不匹配的 `.ko`。

能“挂载”的东西只有三类：`.ko` 文件本身、`ueventd.rc` 之类的配置文件、以及 `post-fs-data.sh`
这类开机脚本。本模块走的是 **脚本 + insmod** 路线，不依赖 `system/` 覆盖，
所以不需要装 meta-overlayfs 这类元模块，装完就能用
（KernelSU 模块机制见 [官方文档](https://kernelsu.org/guide/module.html)，
SukiSU 是它的分支，模块格式一致）。

---

## 5. 模块做了什么

```
           开机
            │
   post-fs-data.sh ──► 内核里有 rndis_host？没有就 modprobe / insmod
            │            （顺序：modprobe → 各目录 rndis_host.ko → 模块自带 ko/）
            │
        service.sh ──► 拉起后台守护进程 bin/net-up.sh
            │
      net-up.sh（每 5 秒轮询）
            │
            ├─ 找到 driver=rndis_host 的网卡（一般是 usb0）
            ├─ ip link up + 关 IPv6
            ├─ DHCP（busybox udhcpc）→ 失败则固定地址 + ping 探测网关
            ├─ ip route replace default via <gw> dev usb0
            ├─ DNS：resetprop net.dns1/net.dns2
            ├─ 可选：EXCLUSIVE=1 时关 Wi-Fi/数据；USE_NDC=1 时用 ndc 注册 netd 网络
            └─ 状态写入 /data/local/tmp/simcom_rndis.state
```

特性：

* **支持热插拔**：开机后再插、拔了再插都会重新配置。
* **不阻塞开机**：`post-fs-data.sh` 只做 insmod，网络配置在 `service.sh` 的后台进程里。
* **失败不会变砖**：所有失败只写日志，不 `abort`、不循环重启。
* **零依赖**：只用系统自带 `ip`/`ndc` 和 KernelSU 自带 busybox。

### 目录结构

```
module/
├── module.prop              # 模块元数据
├── customize.sh             # 安装时：修权限 + 打印内核支持情况 + 校验自带 ko 的 vermagic
├── post-fs-data.sh          # 开机最早：加载 rndis_host
├── service.sh               # late_start：起守护进程
├── action.sh                # 管理器里点“执行”看状态
├── uninstall.sh             # 卸载清理
├── config.conf              # ★ 用户配置（网卡名 / DHCP / DNS / 独占模式）
├── bin/net-up.sh            # 守护进程主体
├── bin/udhcpc.script        # udhcpc 事件脚本：写地址/路由/DNS
├── ko/                      # 自己编的 rndis_host.ko 放这里
└── preinit.conf.sample      # 可选：SELinux 挡 insmod 时的更早加载方案
```

---

## 6. 安装与验证

### 6.1 安装

1. 把 `dist/simcom-rndis-otg-v1.0.0.zip` 传到手机；
2. SukiSU 管理器 → 模块 → 从本地安装 → 选这个 zip；
3. 重启。

> 不要用第三方 recovery 刷（KernelSU 系模块管理器安装，官方文档明确说不兼容 recovery 安装）。
### 6.2 验证

```sh
# 1) 驱动在不在
adb shell su -c 'ls -d /sys/bus/usb/drivers/rndis_host'
adb shell su -c 'ls /sys/module | grep -E "rndis_host|usbnet"'

# 2) 设备认没认出来
adb shell su -c 'lsusb'
adb shell su -c 'for d in /sys/bus/usb/devices/*; do cat $d/idVendor $d/idProduct; done | grep -A1 1e0e'

# 3) 网卡和地址
adb shell su -c 'ip -br addr; ip route'

# 4) 一键状态（最省事）
adb shell su -c 'sh /data/adb/modules/simcom_rndis_otg/action.sh'

# 5) 日志
adb shell su -c 'cat /data/local/tmp/simcom_rndis.log'
```

连通性测试（指定走 usb0，绕开 Android 的策略路由）：

```sh
adb shell su -c 'ping -I usb0 -c 3 223.5.5.5'
```

### 6.3 常见状态

| 现象 | 原因 | 处理 |
|---|---|---|
| `action.sh` 显示 `rndis_host: 未注册 ✗` | 内核没有这个驱动（见第 8 节） | 编 `.ko` 放进 `ko/`，或换内核 |
| 有 `usb0` 但没地址 | DHCP 没拿到 | 看日志；把 `DHCP=0` 用固定地址试（网关先用 `192.168.0.1`） |
| 有地址但 App 上不了网 | Android 策略路由（见第 10 节） | `EXCLUSIVE=1` 关掉 Wi-Fi/数据 |
| `insmod: Invalid module format` | vermagic 不匹配 | 用设备内核源码重编 |
| `Unknown symbol` / `disagrees about version of symbol` | 依赖 ko 缺失或 CRC 不匹配 | 把 `usbnet.ko`/`cdc_ether.ko`/`mii.ko` 一起放进来，且必须同一次编译 |
| `module verification failed: signature ... missing` | 内核开了 `MODULE_SIG_FORCE` | 需要签名或换内核，见 9.4 |

---

## 7. 先做这一步：判断你的内核到底支不支持

```sh
adb shell su -c 'sh /data/local/tmp/probe.sh'   # 先 adb push tools/probe.sh 进去
```

或者手动看：

```sh
# A. 驱动已注册（内建或已加载）→ 最省事，模块直接能用
adb shell su -c 'ls -d /sys/bus/usb/drivers/rndis_host'

# B. 内核配置（有 /proc/config.gz 才行）
adb shell su -c 'zcat /proc/config.gz | grep -E "USB_NET_RNDIS_HOST|USB_USBNET"'

# C. 有没有现成的 ko
adb shell su -c 'ls /vendor/lib/modules | grep -E "rndis|usbnet|cdc_ether"'
```

三种结果：

* **A 有** → 什么都别编，装上本模块即可（模块会自动跳过加载步骤）。
* **A 没有、C 有** → 模块会 `modprobe`/`insmod` `/vendor/lib/modules/rndis_host.ko`。
* **A 没有、C 也没有** → 需要自己编，见第 9 节。

> 补充：AOSP GKI 的 `gki_defconfig`（我核对了 [android14-6.1 分支](https://raw.githubusercontent.com/aosp-mirror/kernel_common/android14-6.1/arch/arm64/configs/gki_defconfig)）
> 里**没有** `CONFIG_USB_NET_RNDIS_HOST`，所以“纯 GKI 内核”很可能真的没有这个驱动；
> 不少厂商内核、类原生/第三方内核会自己打开它。你的设备属于哪种，用上面三条命令一测便知。

---

## 8. 关于“把驱动挂载过去”这件事的正确姿势

如果你坚持“用 SukiSU 模块把驱动带过去”，正确的形态是：

```
模块 zip
├── post-fs-data.sh        ← 开机脚本，负责 insmod
├── ko/rndis_host.ko       ← 和内核严格匹配的驱动二进制
├── ko/usbnet.ko
├── ko/cdc_ether.ko
└── ko/mii.ko
```

而不是：

```
✗ 模块 zip
  └── system/vendor/lib/modules/rndis_host.ko   ← 只覆盖文件，init 不会去加载它
```

原因：Android 的 `modprobe` 是在 **first stage init**（`/vendor/lib/modules/modules.load`）
里跑的，那时模块的 overlayfs 根本还没挂上；覆盖 `/vendor/lib/modules` 里的 ko 文件
对“开机自动加载”没有任何帮助。必须由 `post-fs-data.sh` 自己 `insmod`（本模块的做法），
或者用 KernelSU 的 `preinit`（SELinux 之前加载，见 `preinit.conf.sample`）。

---

## 9. 自编 `rndis_host.ko`

### 9.1 前提

* 内核源码（**必须和设备的 `uname -r` 对应**）；
* 这个内核编译时的 `.config`；
* 同一个编译器（GKI 用 AOSP 的 hermetic clang；厂商内核用它自己的 prebuilts）；
* 如果是 `CONFIG_MODVERSIONS=y` 的内核（GKI 默认开），还需要那次编译产出的
  `Module.symvers`，否则符号 CRC 对不上。

### 9.2 厂商内核（有源码）

```bash
export KERNEL_DIR=~/kernel            # 内核源码根目录
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64
./build/build-rndis-host.sh
```

脚本会：检查/打开 `CONFIG_USB_NET_RNDIS_HOST=m` → `modules_prepare` → 编
`drivers/net/usb` → 把 `rndis_host.ko`/`usbnet.ko`/`cdc_ether.ko`/`mii.ko`
复制到 `module/ko/`。

> 注意：如果之前从没完整编译过这个内核，`Module.symvers` 是空的，
> 编出来的 ko 在 `MODVERSIONS` 内核上会加载失败。先完整编一次内核
> （`make -j$(nproc)`）再编模块。

### 9.3 GKI 内核

GKI 的内核模块必须来自**同一个 KMI**（例如 `android13-5.15`、`android14-6.1`、
`android15-6.6`），用 AOSP 的 `kernel/common` + `bazel` 构建：

```bash
repo init -u https://android.googlesource.com/kernel/manifest -b common-android14-6.1
repo sync -j8
tools/bazel build //common:kernel_aarch64_modules
# 产物在 bazel-bin/common/kernel_aarch64_modules/ 下，找 rndis_host.ko
```

GKI 的 `vermagic` 里带 `-gki` 和 KMI 版本号，和设备的 `uname -r` 一致才能加载。
设备如果是“GKI + 厂商 vendor 模块”的结构，还可以直接把编出来的 ko 丢进模块的 `ko/` 目录。

### 9.4 签名

如果 `dmesg` 里看到：

```
rndis_host: module verification failed: signature and/or required key missing - tainting kernel
```

说明内核开了 `CONFIG_MODULE_SIG`（没开 `FORCE` 时只是警告，仍能加载）。
看到 `module verification failed: ... - rejecting` 或者 `-EKEYREJECTED`，就是开了
`CONFIG_MODULE_SIG_FORCE`，未签名模块会被直接拒绝，这种情况只能：
换一个关了强制签名的内核，或者用厂商私钥签（拿不到）。

---

## 10. 为什么“配了 IP 还是走 Wi-Fi”

Android 不是“有默认路由就走”，它用**策略路由**：App 的 socket 会被打上
`fwmark`（表示“我要走哪个网络”），netd 用 `ip rule` 按 mark 选路由表。
`usb0` 没有在 ConnectivityService 里注册成 Network，所以：

* Wi-Fi / 移动数据开着时，App 的流量按 mark 走 Wi-Fi/数据，**完全不看 usb0**；
* 只有“没有任何默认网络”时，未打 mark 的流量才会落到 `main` 表，
  这时 `ip route add default dev usb0` 才生效。

所以本模块给了两个开关：

```sh
# config.conf
EXCLUSIVE=1   # 联网成功后 svc wifi disable; svc data disable
USE_NDC=1     # 实验性：ndc network create/interface add/route add/default set
              # 让 netd 也认这个网络，DNS 才能被系统解析器用上
```

`EXCLUSIVE=1` 是最稳的做法（这也是社区里 USB 4G 模块上安卓的常用手段，
参考 [dji-4g-modem-android](https://github.com/sjfzWer12/dji-4g-modem-android) 的结论：
有 root 时 `ip link/ip addr/ip route` 三条命令即可，无 root 时被 ROM 锁死）。

### 更“原生”的做法：QMI + RIL

如果目标不是“临时上网”，而是把模组当成系统级 4G（状态栏信号、流量统计、
短信/拨号），那正确路线是走 **QMI/MBIM**：内核 `qmi_wwan`（或厂商 GobiNet）→
`rmnet` → RIL HAL → ConnectivityService。这需要：

* 把模组的 USB 组合切到 QMI（SIMCom 一般是 `AT+CUSBCFG=usbid,1e0e,9001` 之类，
  **切之前确认还有 AT 口可用**，切错了可能只剩 QMI 口，得用串口救回来）；
* 一个能对接这个模组的 RIL（Android 的 `libril`/HIDL/AIDL 版本要和系统匹配）；
* 大概率还要改 `init` 脚本和 SELinux 策略。

这是一整个 RIL 移植工程，不在本模块范围内；本模块解决的是“驱动 + 能上网”。

---

## 11. 硬件注意事项

* **供电**：4G/5G 模组峰值电流可到 2A，手机 OTG 口一般只给 500mA 左右。
  供电不足会表现为：设备反复枚举、`usb0` 时有时无、`dmesg` 里 `over-current`。
  解决：带供电的 USB Hub / Y 型线。
* **OTG**：确认手机支持 USB Host（大部分支持，但有些 ROM 关了）。
* **线材**：必须是数据线，很多“充电线”没有 D+/D-。

---

## 12. 卸载 / 回滚

* 管理器里禁用或删除模块即可（`/data/adb/modules/simcom_rndis_otg`）；
* 模块没有改任何系统分区，也不会改内核；
* 如果 `EXCLUSIVE=1` 关掉了 Wi-Fi/数据，卸载后手动打开即可。

---

## 13. 文件清单

```
usb-1e0e-3487-sukisu/
├── README.md                     ← 本文件
├── dist/simcom-rndis-otg-v1.0.0.zip   ← 刷这个
├── module/                       ← 模块源码
├── tools/probe.sh                ← 设备端一键体检
└── build/build-rndis-host.sh     ← 交叉编译 rndis_host.ko
```

---

## 参考

* KernelSU 模块开发文档：<https://kernelsu.org/guide/module.html>
* SukiSU-Ultra 文档：<https://sukisu.org/zh/guide/>
* `rndis_host.c`（Linux 6.6）：<https://elixir.bootlin.com/linux/v6.6/source/drivers/net/usb/rndis_host.c>
* SIMCom RNDIS 拨号流程（Waveshare）：<https://www.waveshare.com/wiki/SIM820X_RNDIS_Dail-up>
* USB ID 库 1e0e：<https://usb-ids.gowdy.us/read/UD/1e0e>
* USB 4G 模块上安卓的实战记录：<https://github.com/sjfzWer12/dji-4g-modem-android>
* GKI defconfig（android14-6.1）：<https://raw.githubusercontent.com/aosp-mirror/kernel_common/android14-6.1/arch/arm64/configs/gki_defconfig>
