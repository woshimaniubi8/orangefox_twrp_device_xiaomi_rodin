# rodin OrangeFox 故障排查手册

## 1. 先判断卡在哪一层

| 屏幕/现象 | 主要层级 | 首选日志 |
| --- | --- | --- |
| 设备第一屏后重启，ADB 从未出现 | bootloader/kernel/first-stage ramdisk | pstore、stock header 对比 |
| OrangeFox splash 长时间不动，但 ADB 存在 | recovery userspace/HAL/GUI 初始化 | `/tmp/recovery.log`、logcat |
| 主界面出现但无触摸 | kernel touch + TouchReport | dmesg、getevent、touch properties |
| 输入密码一直等待 | KeyMint/Gatekeeper/Weaver/TEE | logcat、service list、TEE dmesg |
| 解密成功后 recovery 循环重启 | Recovery 进程崩溃 | pstore init service exit、tombstone |
| Recovery 正常但 Android 无法启动 | type-1 platform fragment 被破坏 | stock/platform 文件哈希对比 |

## 2. 设备首屏循环重启

检查：

```bash
adb shell 'ls /sys/fs/pstore'
adb pull /sys/fs/pstore logs/pstore
```

常见原因：

- vendor_boot header 地址、page size、DTB 或 cmdline 不匹配。
- combined vendor ramdisk 过大。
- 使用 zstd recovery fragment；rodin 实机测试在 ADB 前失败。
- OrangeFox 第二遍模块加载器拉起原始 `scp.ko`，在 `scp_region_info_init()` panic。
- 刷入了 recovery-only 中间 vendor_boot，而不是 system-compatible IMG。

## 3. splash 很久才进入界面

已知启动路径会同步执行：

- 两处约 1 秒固定等待。
- metadata-encrypted `/data` 映射和 `fsck.f2fs`。
- DE key 初始化。
- 分区枚举和 `/data` backup size 计算。
- OrangeFox XML、语言和字体资源加载。

触摸等待通常只有约 0.1 秒，不是主要瓶颈。约 4 至 6 秒 splash 可解释；明显更长时记录带时间戳的 logcat。

## 4. 无触摸

先确认控制器供应商。stock 系统可能同时加载 Goodix 和 FocalTech 模块，必须以 SPI driver symlink、input 名称或 probe 日志为准。Goodix 已实机验证；FocalTech 为待验证测试路径，参见 [COMPATIBILITY_CN.md](COMPATIBILITY_CN.md)。

```bash
adb shell getprop vendor.touch.modules.ready
adb shell getprop vendor.touch.service.ready
adb shell 'cat /sys/devices/virtual/touch/touch_dev/enable_touch_raw'
adb shell 'getevent -pl | grep -A25 -E "goodix_ts|focaltech_ts|fts_ts"'
adb shell 'dmesg | grep -iE "goodix|focaltech|fts_ts|touch|scp|11011800" | tail -300'
```

期望：

- `vendor.touch.modules.ready=1`。
- `vendor.touch.service.ready=1`。
- 存在 `goodix_ts`、`focaltech_ts` 或 `fts_ts` input device。
- TouchReport 进程运行并持续处理 raw frames。

只看到 input device 并不代表触摸可用。rodin 使用 THP raw-frame 路径，需要 Android 16 TouchReport 算法把坐标写回 `/dev/xiaomi-touch`。

## 5. FBE 卡住

```bash
adb shell 'service list | grep -E "keymint|gatekeeper|weaver|keystore"'
adb shell 'ps -A | grep -E "tee-supplicant|keymint|gatekeeper|weaver|secure_element|keystore2"'
adb logcat -b all -d | grep -iE 'keymint|gatekeeper|weaver|keystore2|mitee|optee|tee'
```

关键判断：

- `keystore2` 等不到 KeyMint：检查 VINTF 和 KeyMint service。
- `auth ca name error`：HAL 从错误路径启动，必须使用原始 `/vendor/bin/hw`。
- `optee_open_session()` 阻塞/失败：检查 TA、TEE 节点权限和 persist。
- synthetic password 到 Weaver 后阻塞：检查 NXP Weaver、secure-element、OMAPI、`nxp_i2c.ko`、`p73.ko`。
- user 0 成功而 user 999 失败：通常不影响主用户 `/data` 解密。

命令行测试：

```bash
adb shell 'twrp decrypt "你的密码" 0'
```

不要把真实密码写入永久日志或 shell history。

## 6. 解密后崩溃

已确认的 rodin 原因不是 FBE mount 失败，而是 OrangeFox 在发现：

```text
/data/media/0/Fox/.theme
/data/media/0/Fox/.navbar
```

后执行完整 `PageManager::RequestReload()`，Recovery 进程收到 `SIGSEGV`。设备 patch 定义 `OF_SKIP_POST_DECRYPT_THEME_RELOAD`，只跳过这次 late full-package reload。

诊断时可先做可逆重命名，禁止删除：

```bash
adb shell 'mv /data/media/0/Fox/.theme /data/media/0/Fox/.theme.disabled-test 2>/dev/null || true'
adb shell 'mv /data/media/0/Fox/.navbar /data/media/0/Fox/.navbar.disabled-test 2>/dev/null || true'
```

## 7. MiSans 导致全局卡顿

```bash
adb shell 'top -b -n 1 | head -20'
adb shell 'file /twres/fonts/MiSans.ttf'
```

如果字体实际为 CFF OpenType，旧 FreeType/Pixelflinger 路径会持续高 CPU。当前设备树要求 TrueType `glyf` 子集，预检脚本会拒绝 CFF 版本。

另外检查 `minuitwrp/truetype.cpp` patch 是否存在。原始 string cache 在 400 项时使用错误的 `||` 条件整批清空，文件列表会反复重新光栅化文本。

## 8. 截屏后进入电源菜单

原因是截屏渲染耗时超过长按阈值后，组合键 repeat 被转换成 `hkey=power`。设备 patch 在组合键激活期间禁止 key repeat，并在截屏后重置计时。

截图保存位置：

```text
/data/media/0/Fox/screenshots/
```

## 9. 解密前英文、解密后中文

`TW_DEFAULT_LANGUAGE=zh_CN` 只设置 DataManager 默认值。OrangeFox 原流程会先用英文加载 UI，并在解密页面退出后才调用 `LoadLanguage()`。

设备 patch 使用 `OF_LOAD_DEFAULT_LANGUAGE_BEFORE_DECRYPT`，在第一次 `Decrypt_Page()` 前加载 `zh_CN`。如果仍是英文，检查编译命令中是否同时存在：

```text
-DTW_DEFAULT_LANGUAGE=zh_CN
-DOF_LOAD_DEFAULT_LANGUAGE_BEFORE_DECRYPT=1
```

## 10. Global 锁屏后屏幕仍亮或无法唤醒

Global 仍使用标准的 `blanktimer -> gr_fb_blank() -> atomic DRM` 链路，不使用亮度归零
workaround。它只在完成首次完整 atomic setup 后，让锁屏提交 CRTC `ACTIVE=0` 并保留
connector、mode 和 plane binding；唤醒时重新提交完整 mode/connector/plane 状态，使 MTK
驱动执行面板恢复链路。这修复的是 Global stock 6.6.89 的完整 teardown/rebuild 后无法恢复
面板的问题，而非绕开锁屏链路。
Recovery 退出时则会先完整 teardown，再释放 mode blob 和 framebuffer，避免仍被 DRM 状态
引用的资源被提前释放。

不要定义 `TW_NO_SCREEN_BLANK`：它会跳过 CRTC blank，并移除“屏幕关闭时普通输入不应唤醒”的
保护，导致日志中出现 `brightness=0` 后立即恢复 `brightness=1000`，表现为已锁屏但屏幕仍亮。

新的 Recovery 会在真实 atomic commit 处记录请求方向、connector/CRTC/plane 标识及返回值；
锁屏和唤醒各应出现一行
`DRM blank retained pipeline: ACTIVE=0`，随后是
`DRM blank restore retained pipeline: full setup` 和成功 commit。若 stock Global
仍无法唤醒，保留这组日志再修正 atomic 属性，不能重新启用亮度替代路径。

从 ADB 进行一次可重复验证，再用物理电源键重复一次：

```bash
adb shell input keyevent 26
sleep 2
adb shell input keyevent 26
adb pull /tmp/recovery.log logs/global-screen-wake-recovery.log
adb shell dmesg > logs/global-screen-wake-dmesg.txt
adb logcat -b kernel -d > logs/global-screen-wake-kernel.log
```

## 11. Recovery 正常但系统无法启动

必须确认最终刷入的是 `OrangeFox-...-system-compatible.img`。正常 Android boot 只选择 type-1 platform fragment；它必须保留 stock first-stage init、linker、libc、fstab、SELinux、firmware 和全部 244 个模块。

若 pstore 中出现下列组合：

```text
device-mapper: verity: ... metadata block ... is corrupted
reboot: Restarting system with command 'dm-verity device corrupted'
```

则故障位于当前槽位的 `/system`/super 完整性校验，不是 `/data` 格式化，也不是 Recovery
进程崩溃。此时 `make_f2fs` 的失败不会写入 userdata，更不会损坏 system。使用与当前地区、
版本和槽位匹配的完整官方 fastboot 包修复 system/super 与相应 vbmeta；不要在 Recovery 中
关闭或绕过 dm-verity。

立即回退：

```bash
fastboot flash vendor_boot device/xiaomi/rodin/prebuilt/vendor_boot_stock.img
fastboot reboot
```

不要在未确认原因前刷另一槽位。

## 12. 刷 ROM 后无法 Format Data / `Unable to unmap dynamic partitions`

先区分是否在同一 Recovery 会话内操作。Virtual A/B ROM 更新完后，OrangeFox 会提示：

```text
Devices on super may not mount until after rebooting recovery.
To flash additional zips, please reboot recovery to switch to the updated slot.
```

收到这条提示后不要立即 Format Data。先重启到 Recovery，确认新会话中的
`ro.boot.slot_suffix`，再执行格式化。当前日志中 `Unable to unmap dynamic
partitions` 发生在 `Check_Pending_Merges()` 内、真正擦除 `/data` 之前。

本设备树的当前 `orangefox-recovery.patch` 会在精确清理当前槽位
`vendor_a` 等分区后，跳过 `vendor`、`system` 等无槽位 mapper alias。
正常日志应出现 `skipping logical partition alias: vendor`，随后才是
`checking for merges` 和实际的 Data wipe。若仍出现
`removing dynamic partition: vendor` 后立刻报错，说明运行的是未应用此 patch 的旧镜像。

### `make_f2fs: Error: In use by the system`

这与 `Unable to unmap dynamic partitions` 不同：若日志已出现 `checking for merges`，
随后显示物理 `/data` 设备（rodin 常为 `/dev/block/sdc92`）的 `make_f2fs` 被占用，说明
FBE 解密创建的 `/dev/block/mapper/userdata` 仍持有该物理设备。

当前构建在 `make_f2fs` 前必须显示：

```text
OrangeFox: running dmctl before formatting...
```

随后才可以继续格式化。没有这行说明仍在运行旧镜像，或 `OF_USE_DMCTL := 1` 未进入构建。
若出现 `Unable to release decrypted userdata` 或 `Decrypted userdata is still busy`，Recovery
会安全中止；保存该次 `/tmp/recovery.log`，不要手工删除 `/dev/block/mapper` 节点，也不要
擦写 `super` 来规避。

如果已经重启 Recovery 后仍失败，必须采集那一次失败的完整日志；不要复用刷包前的
日志。连接 ADB 后执行：

```bash
adb shell getprop ro.boot.slot_suffix
adb shell /system/bin/bootctl get-current-slot
adb shell /system/bin/bootctl get-active-boot-slot
adb shell 'ls -l /dev/block/mapper; cat /proc/mounts | grep -E "dm-|/system|/vendor"'
adb pull /tmp/recovery.log logs/recovery-after-reboot.log
adb logcat -b all -d > logs/logcat-after-reboot.txt
```

若日志同时出现 `bootctl set-active-boot-slot` 返回 `Operation failed`，使用保留
stock AIDL BootControl 的新构建；旧 HIDL fallback 会在 rodin 上把 UFS boot-region
ioctl 失败报告为 slot 切换失败。不要通过手工删除 mapper 节点或强制擦写 `super` 来
绕过该错误。

## 13. `mi_ext` 等非同名逻辑分区无法挂载

rodin 的 stock fstab 将逻辑分区 `mi_ext` 挂载到 `/mnt/vendor/mi_ext`。旧版
Recovery 从挂载路径生成逻辑分区名，错误请求 `mnt/vendor/mi_ext_b`；实际设备只存在
`mi_ext_b`，所以日志会显示：

```text
Trying to prepare mnt/vendor/mi_ext from super partition
unable to update logical partition: /mnt/vendor/mi_ext
```

当前 patch 保留 v2 fstab 第一列的原始逻辑名，并在映射与卸载 super 分区时使用它，
因此应显示 `Trying to prepare mi_ext from super partition`。Recovery 专用 fstab 同时
删除 `ro,bind` 和 `overlay` 这类仅由 Android init 处理的行，避免 TWRP 把 `/mi_ext`
误认为文件系统类型。该修复不改写 super、userdata 或 stock first-stage fstab。

同一启动日志中，`/persist` 以前会因 `/mnt/vendor/persist` 已由 KeyMint 的 init 脚本
以 `ro,noload` 挂载，又被 TWRP 尝试挂载到 `/persist` 而失败。Recovery 现在仅将已有
的安全只读挂载 bind 到 `/persist`，并跳过 OrangeFox 对该路径的写入；原始
`/mnt/vendor/persist`、journal 策略和 KeyMint 路径均不变。

未插入 SD 卡或 USB 存储设备时，`/auto*`、`/external_sd`、`/usb_otg` 的挂载失败是
预期状态，不是分区错误。

## 14. 最小日志包

```bash
LOGDIR="logs/$(date +%F-%H%M%S)"
mkdir -p "$LOGDIR"
adb pull /tmp/recovery.log "$LOGDIR/recovery.log"
adb logcat -b all -d > "$LOGDIR/logcat.txt"
adb shell dmesg > "$LOGDIR/dmesg.txt"
adb shell getprop > "$LOGDIR/getprop.txt"
adb pull /sys/fs/pstore "$LOGDIR/pstore" || true
```

记录测试镜像 SHA-256、当前槽位、系统版本、是否解密、是否存在 ADB，以及屏幕停在哪一层。没有这些信息时不要同时修改多个变量。
