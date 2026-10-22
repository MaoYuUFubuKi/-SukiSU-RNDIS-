# ko/ 目录说明

把为**你这台设备的内核**编译出来的 `rndis_host.ko` 放这里，然后重新刷一次本模块。

```
ko/
└── rndis_host.ko
```

加载顺序（见 ../post-fs-data.sh）：

1. `modprobe rndis_host`
2. `insmod /vendor/lib/modules/rndis_host.ko`
3. `insmod <module>/ko/rndis_host.ko`   ← 也就是这里
4. 失败则先把 usbnet / cdc_ether / mii 一个个 insmod，再重试 rndis_host

## 放进来之前请确认

```sh
# 1) 内核版本必须完全一致
adb shell su -c 'uname -r'
strings rndis_host.ko | grep vermagic
```

`vermagic=` 后面那串（例如 `5.15.104-android13-8-gki SMP preempt mod_unload modversions aarch64`）
必须和 `uname -r` 对得上，否则内核会直接拒绝：

```
insmod: failed to load rndis_host.ko: Invalid module format
```

## 依赖也要一起放

如果内核开了 `CONFIG_MODVERSIONS`（GKI 默认开），`rndis_host.ko` 还依赖
`usbnet.ko` / `cdc_ether.ko` / `mii.ko`，请把这几个同一次编译出来的 .ko 一起放进来。
只放 rndis_host 一个的话，insmod 会报 `Unknown symbol` 或 `disagrees about version of symbol`。

## 没有现成的 .ko？

看 README 第 9 节（编译方法），或者直接在能上网的 Linux 机器上跑
`build/build-rndis-host.sh`。
