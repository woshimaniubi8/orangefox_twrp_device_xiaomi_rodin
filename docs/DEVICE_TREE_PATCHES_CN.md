# rodin 设备树补丁说明

## 范围

`patches/rodin-fbe-global.patch` 是针对本仓库初始 rodin 设备树快照的文本补丁。它补齐了 FBE 所需的 recovery 依赖和 Global 固件构建 profile；不替换 OrangeFox 共享源码 patch，也不携带任何 firmware blob。

补丁涉及：

- `Android.bp`：将 Android 15 vendor 的 secure-element 与 OMAPI NDK 预编译库改为 recovery 专用模块名，保留 Android 16 构建图中的 AIDL 生成头文件，并让 `rodin_omapi_bridge` 显式链接 `librodin_libcxx_compat`。
- `recovery/root/init.recovery.keymint.rc`：为 OMAPI bridge 设置 vendor/system 运行时库搜索路径和 libc++ compatibility preload；在 `tee-supplicant` 就绪后并行启动 KeyMint、secure-element 与 NXP Weaver，不再以 bridge ready 属性阻塞 Weaver。
- `BoardConfig.mk`、`recovery/root/init.recovery.bootctl.rc` 与 post-build repacker：OrangeFox 和 ROM updater 均使用 stock MediaTek AIDL BootControl；重打包器保留 binary，并将其 device VINTF fragment 放到 `/vendor/etc/vintf/manifest`，避免 `/system` framework VINTF 解析失败而使 Keystore2 崩溃。recovery rc 通过 compatibility shim 启动该服务，避免旧 HIDL fallback 的 UFS boot-region ioctl 使 slot 切换失败。
- `BoardConfig.mk`：rodin 不启用 TWRP 的通用 APEX loop loader（`TW_EXCLUDE_APEX := true`）。
  Recovery 的 KeyMint/Weaver/FBE 链路不依赖 system APEX；跳过它可避免 Android 16 APEX
  的失败 loop 绑定残留，并且不修改系统内的 APEX 文件或正常 Android 启动路径。
- `tools/build-system-compatible-vendor-boot.sh`：增加 `RODIN_FIRMWARE_VARIANT=cn|global`，使最终镜像保留与目标系统相匹配的 type-1 platform ramdisk。
- `BoardConfig.mk`、`patches/orangefox-vendor-twrp.patch` 与共享 Recovery patch：CN 保持原有
  atomic DRM 的完整 teardown/rebuild；Global 保留相同的 blanktimer/锁屏状态机，但首次完整 setup
  后锁屏只对 CRTC 提交 `ACTIVE=0`，不撤销 connector、mode 或 plane binding；唤醒时在保留
  这些绑定的前提下重新提交完整 mode/connector/plane 状态，并将扫描面切换到备用 framebuffer。
  切换前会复制上一帧，避免 `gui_forceRender()` 前出现未初始化画面；该 framebuffer handoff 让
  MTK atomic driver 观察到真实 plane 更新并触发面板恢复。该编译开关经
  `vendor/twrp` Soong 显式传给 `libminuitwrp`；仅在 Recovery 退出时完整 teardown 后释放
  mode/FB 资源，`TW_NO_SCREEN_BLANK` 仍禁止使用。
- `.github/workflows/build.yml`：使用 GitHub 托管的 `ubuntu-24.04`，先拉取 Git LFS blob，再以 CN/Global 矩阵构建和发布四个经过 AVB 校验的镜像；同步 OrangeFox 源码时固定 HTTP/1.1，并对完整同步作有限重试。
- 构建前检查、文件哈希清单和构建文档。

这份补丁解决三个已定位的问题：原先 Soong 会把设备树中 Android 15 预编译 NDK 库与 Android 16 AIDL 生成模块混淆，导致 recovery 依赖解析失败；运行时的 bridge 则因找不到 `/vendor/lib64` 内的 NDK 库而无法启动，使 Weaver 被错误的 ready gate 无限阻塞；旧 HIDL BootControl fallback 在 rodin 上会使 UFS boot-region 设置失败并导致 slot 切换失败。它们分别影响可编译性、FBE synthetic-password 流程和 Virtual A/B ROM 更新后的 slot 处理。

## OrangeFox 共享 Recovery patch

`patches/orangefox-recovery.patch` 由 `tools/apply-orangefox-patches.sh` 应用于 pinned
`bootable/recovery`。其中的 Virtual A/B 修复保留第一轮对当前槽位
`system_a`、`vendor_a` 等逻辑分区和 `-cow` 的精确清理；仅在后续兜底扫描中跳过
`Super_Partition_List` 中的无槽位 mapper alias，例如
`/dev/block/mapper/vendor -> vendor_a`。

这些 alias 由 Recovery 的 image-flashing 兼容逻辑建立，不是第二个可删除的逻辑分区。
因此修复不会关闭 `Check_Pending_Merges()`，也不会绕过 Virtual A/B 的 snapshot merge
安全检查。构建后若 Format Data 日志出现
`skipping logical partition alias: vendor`，说明已命中该保护；若仍出现
`removing dynamic partition: vendor`，刷入的仍是旧镜像或共享 patch 未应用。

rodin 的 `mi_ext` 是另一个需要保留 fstab 原始分区名的逻辑分区：它挂载到
`/mnt/vendor/mi_ext`，但逻辑分区名是 `mi_ext`，不是由挂载路径去掉 `/` 后得到的名称。
共享 patch 会保存 v2 fstab 第一列并用于 mapper 创建和拆除；Recovery 专用 fstab 则排除
Android init 专用的 `ro,bind` 和 `overlay` 行。这样不会把 `/mi_ext` 误解析为文件系统，也
不会在 Format Data / pending-merge 路径上错误处理 `mi_ext_b`。

`persist` 由 stock KeyMint init 路径以 `ro,noload` 挂载到 `/mnt/vendor/persist`。设备树
在 Recovery 根目录创建 `/persist` 的只读 bind alias，`twrp.flags` 同样固定为
`ro,noload`；共享 patch 因此只从该路径读取早期 OrangeFox 设置，而不会回放 journal 或写入
安全存储。不得将其改成普通可写的 `/persist` fstab 项。

FBE 已解密后的 `userdata` mapper 与动态分区不是同一类对象，不能由
`Unmap_Super_Devices()` 的兜底扫描删除。rodin 在 `BoardConfig.mk` 启用
`OF_USE_DMCTL := 1`，将 `dmctl` 放入 Recovery；共享 patch 只在确认格式化 `/data` 时
删除 `/dev/block/mapper/userdata`。命令失败或节点在最多一秒后仍存在时会终止格式化，
不会继续向仍被映射占用的物理 userdata 块设备执行 `make_f2fs`。

共享 patch 还实现了 rodin 单 Type-C 口的 USB OTG 状态机。此机型在 host 尚未被请求时
不会打开 `otg_enable` 供电，因此不能以自动 Type-C source/partner 检测作为入口。用户在
“挂载”页点 USB 浮动按钮后，状态机先把 `typec/port0/preferred_role` 设为 `source`，再将
`sys.usb.config` 设为 `none`、启用 `otg_enable`、通过 `vbus_switch` 打开 stock DTB 中的
`usb-otg-vbus` regulator，并把 `11201000.usb0` role switch 置为
`host`；此时再于二十秒内插入 U 盘，按钮会变为 X，可显式停止。这避免 stock 的 sink
偏好把被动 OTG 转接器错误协商为 `Attached.SNK`。随后只接受 `/sys/block` 中解析路径包含
`/usb` 的 SCSI 盘，故内部 UFS `sda`、`sdb`、`sdc` 不会被误挂载。超时未枚举、按 X 或
介质拔出时，状态机均会恢复 `device` role、之前的 MTP 状态和 sink 偏好；host 期间 ADB
断开属于端口角色切换的预期行为。状态机绝不在 host 模式读取 role-switch 的 `role` 文件，
避免这个内核上可能无限阻塞的 sysfs read。

CN 运行时进一步证明 stock DTB 的 `xhci0@11200000` 带有
`mediatek,usb-offload = <0x15b>`。该属性会令 MTU3 等待 Android USB audio offload
provider；Recovery 中 provider 及其音频/基带依赖均未运行，因此 source 协商成功后仍会出现
`offload not ready`，不会注册 USB host bus。`tools/patch-vendor-boot-dtb.py` 保留 MTK
64-byte wrapper 与所有其他 DTB 节点，只从临时 inner FDT 删除该属性并同步 wrapper 的 DTB
和总长度。`build-system-compatible-vendor-boot.sh` 只将这份临时 DTB 写入标准和
disable-AVB 成品，绝不改写 `prebuilt/dtb/mt6899-rodin.dtb`。这避免将 ABI 相关的
`usb_offload.ko`、音频和基带模块加入 Recovery。

本仓库固定了 `relink_libraries` 对 `libprocessgroup_setup.so` 的一个增量构建问题。
原规则把 `TARGET_RECOVERY_ROOT_OUT/system/lib64` 同时作为来源和目标；当恢复目录被清理后
重建时，可能生成 ELF 大小正确但内容全零的文件。Recovery 的二阶段 `/system/bin/init`
会在 OrangeFox 启动前加载该库，结果触发 `Attempted to kill init` kernel panic。共享 patch
改从 `TARGET_OUT_SHARED_LIBRARIES` 的已链接库复制；post-build repacker 还会解压 recovery
fragment 并验证该库以 `7f 45 4c 46` 开头。检查失败时不会替换最终的
`*-system-compatible.img`。

## 应用

先保存完整设备树和现有工作，再在 OrangeFox 源码根目录执行。补丁文件必须在目标设备树外部，因为应用前目标树中尚不存在该文件。

```bash
PATCH=/path/to/rodin-fbe-global.patch
patch -d device/xiaomi/rodin -p1 --dry-run < "$PATCH"
patch -d device/xiaomi/rodin -p1 < "$PATCH"
```

只对与本项目初始快照相同的设备树直接应用。若 `--dry-run` 有上下文冲突，不要使用 `.rej` 继续构建；先按各文件的功能块人工 rebase，并重新运行完整预检。

应用后仍按常规方式执行：

```bash
device/xiaomi/rodin/tools/apply-orangefox-patches.sh "$PWD"
```

该脚本继续负责 `build/make`、`vendor/twrp` 和 `bootable/recovery` 的三个 Git patch；`rodin-fbe-global.patch` 只修改设备树，不能由该脚本对非 Git 设备目录自动应用。

## Global 固件输入

Global OS3.0.301.0.WOJMIXM 的 244 个 type-1 platform 内核模块与 CN OS3.0.303.0.WOJCNXM 不同。两者 DTB、fstab、first-stage init、SELinux 数据和 type-2 stock recovery fragment 相同，但 type-1 fragment 不能交叉使用。

补丁不包含 29,235,080 字节的 `prebuilt/global/vendor_ramdisk00`。从完整 Global 固件包导入：

```bash
device/xiaomi/rodin/tools/import-global-firmware-inputs.sh \
  /path/to/rodin_global_images_OS3.0.301.0.WOJMIXM_16.0/images/vendor_boot.img
```

导入器固定校验以下值，失败时不会覆盖现有输入：

| 项目 | 值 |
| --- | --- |
| Global `vendor_boot.img` 大小 | `67108864` |
| Global `vendor_boot.img` SHA-256 | `72b8ae7637af1924de8312855790de91f99abbc9c8c8ab6003ddce14abc4d956` |
| type-1 fragment 大小 | `29235080` |
| type-1 fragment SHA-256 | `349cc6598f70ae401afe3071abed6de00815af39c5aded3551cff23364208731` |
| DTB SHA-256 | `38369239c984fc191e36d043d19ccbea4c1cd09ee6c80f8646d9493f650a30ae` |

`prebuilt/global/modules/` 的七个 6.6.89 Recovery-only 模块通过 Git LFS 保存。文本 patch
只包含它们的 LFS pointer，不包含模块字节；推送设备树前必须把实际模块一并加入并上传 LFS，
否则 GitHub Actions 的 `git lfs pull` 无法取得 Global 构建输入：

```bash
git add .gitattributes prebuilt/global/modules/ prebuilt/README.md
git lfs status
```

然后使用：

```bash
RODIN_FIRMWARE_VARIANT=global OF_BUILD_JOBS=16 GOMEMLIMIT=12GiB \
  device/xiaomi/rodin/build-lowmem.sh vendorbootimage
```

CN 3.0.303 默认不设置 `RODIN_FIRMWARE_VARIANT`。两个 profile 都必须先通过：

```bash
RODIN_FIRMWARE_VARIANT=global \
  device/xiaomi/rodin/tools/verify-build-inputs.sh "$PWD"
```

Global 输出为 `OrangeFox-R12.0-Unofficial-rodin-global-system-compatible.img`，不能用于 CN；默认 CN 输出也不能用于 Global。repacker 会将最终 Recovery fragment 中的 7 个 ABI 相关模块与由 Global 输入和固定偏移 patch 生成的预期内容逐字节比较；若复用了 CN 的 recovery fragment，构建会停止而不会输出 Global 成品。
