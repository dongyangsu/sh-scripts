# 【Linux排障】59服务器Ubuntu重启后黑屏进不去-用systemd.unit进命令行并通过fsck修复根分区的完整过程

> 日期：2026-10-17（现场处理）／2026-10-20（整理归档）
> 设备：HP ProLiant DL380p Gen8（主机名 `admin1-ProLiant-DL380p-Gen8`，`192.168.0.59`）
> 系统：Ubuntu 桌面版，ext4 根分区 `/dev/sda2`
> 板载显卡：Matrox MGA G200EH（与 iLO 视频共用）

---

## 一、故障现象

用户描述：**“关机前用得好好的，点了重启之后黑屏，不显示登录界面。”**

现场逐项确认：

| 环节 | 表现 |
|---|---|
| POST | 正常 |
| Ubuntu 启动界面 / GRUB 菜单 | 能看到，但进不去系统 |
| 选 `Ubuntu` 回车 | **黑屏，进不去** |
| 选 `Advanced options` 回车 | 同样黑屏（连子菜单都不显示） |
| GRUB 编辑模式（`e`） | **能进入**，可修改 `linux` 内核启动行 |
| GRUB 命令行（`c`） | **能进入** |
| 只加 `nomodeset` | **无效**，仍然黑屏 |

**判断**：GRUB 菜单、`e`、`c` 都能进 → **引导链（BIOS → GRUB → 内核）完好**；问题在**内核之后**：根文件系统异常导致挂载失败，系统停在 initramfs，画面因此是黑的。

---

## 二、根因

### 2.1 直接原因：根分区文件系统损坏

- 根分区：**`/dev/sda2`（ext4）**
- 重启时根分区挂载失败（文件系统处于不一致状态），内核把控制权交给 **initramfs 救援 shell**
- 典型诱因：**非正常关机 / 断电 / 强制重启**，ext4 日志未正常回放

### 2.2 为什么是黑屏

initramfs 阶段没有图形输出，Matrox 显卡此时也未被驱动接管，屏幕基本全黑；只有拿到 `(initramfs)` 提示符才能操作。

### 2.3 为什么 `nomodeset` 无效

`nomodeset` 只影响显卡驱动，与根分区挂载无关。**无效恰好说明病根不在图形层。**

---

## 三、处理过程（现场实际步骤，参数已确认）

### 3.1 进入 GRUB 编辑模式

开机在 GRUB 菜单上按 **`e`**，定位到以 `linux` 开头的那一行：

```
linux /boot/vmlinuz-... root=UUID=b1d62c72-... ro quiet splash vt.handoff=7
```

### 3.2 在 `linux` 行末尾追加参数

在行末追加：

```
systemd.unit=multi-user.target
```

完整行示例：

```
linux /boot/vmlinuz-... root=UUID=b1d62c72-... ro quiet splash vt.handoff=7 systemd.unit=multi-user.target
```

改完按 **`Ctrl+X`**（或 `F10`）启动。

> **这个参数的作用**：强制系统启动到 **多用户文本模式（multi-user.target）**，跳过图形界面（GDM）。
> 它本身不是“进 initramfs 的开关”——根分区挂不上时系统仍会先落到 `(initramfs)`；
> 它的价值在于：**根分区修好之后，能保证系统以文本模式正常起来**，从而进入 tty 命令行继续处理，而不是又卡在黑屏的图形阶段。

### 3.3 在 `(initramfs)` 提示符下修复根分区

系统因根分区挂载失败落到：

```
(initramfs) _
```

执行：

```bash
fsck -y /dev/sda2
```

- `-y`：所有修复询问自动回答 yes
- 回放 ext4 日志、修正不一致的 inode / 块位图 / 目录项
- 修复完成后回到 `(initramfs)` 提示符

### 3.4 `exit` 继续启动

```bash
(initramfs) exit
```

由于启动参数指定了 `systemd.unit=multi-user.target`，系统继续启动后**进入 tty 文本命令行**（而不是图形登录界面）——这与现场现象完全一致（“exit 后出现的是命令行界面”）。

### 3.5 重启，恢复正常图形界面

该参数只是**本次启动临时生效**，不会写入 `/boot/grub/grub.cfg`。直接重启：

```bash
sudo reboot
```

重启后按默认流程启动，**正常进入图形登录界面**，问题解决。

---

## 四、关键参数说明（避免混淆）

| 参数 | 作用 | 本次是否使用 |
|---|---|---|
| **`systemd.unit=multi-user.target`** | 启动到**多用户文本模式**，跳过图形界面，进 tty 命令行 | ✅ **本次使用** |
| `nomodeset` | 只禁用显卡高级驱动，治图形黑屏 | ❌ 试过，无效 |
| `init=/bin/bash` | 直接以 bash 作为 init（根分区需能挂载才能用） | ❌ 未使用 |
| `rw single` | 单用户模式、根分区可写 | ❌ 未使用 |
| `break=mount` | initramfs-tools 断点参数，在挂载阶段主动开 shell | ❌ 未使用 |

> 本次进入 `(initramfs)` 是**根分区挂载失败后系统自动落入**的；`systemd.unit=multi-user.target` 保证修好之后能以文本模式正常起来，避免再次卡在图形界面。

---

## 五、验证结果

| 检查项 | 命令 | 结果 |
|---|---|---|
| 根分区与类型 | `findmnt -no SOURCE,FSTYPE /` | `/dev/sda2 ext4` |
| 文件系统状态 | `sudo dumpe2fs -h /dev/sda2 \| grep "Filesystem state"` | **clean** |
| 最近挂载时间 | `sudo dumpe2fs -h /dev/sda2 \| grep "Last mount time"` | 2026-10-17 11:47:24（修复后成功挂载） |
| 显示管理器 | `systemctl status display-manager` | `gdm.service` **active (running)** |
| 系统运行 | `uptime` | 持续运行 3 天以上 |
| GRUB 是否残留参数 | `grep -c "systemd.unit" /boot/grub/grub.cfg` | 0（临时参数未落盘） |

---

## 六、经验总结

1. **GRUB 能进、`e`/`c` 能进，就别怀疑引导坏了**
   问题在内核之后——最常见是根文件系统挂载失败。

2. **加 `systemd.unit=multi-user.target` 能绕开图形界面**
   修完文件系统后，即使显示层有问题，也能以文本模式进入系统继续处理；这比一直盯着黑屏强。

3. **`(initramfs)` 里修盘只需要一条命令**
   ```bash
   fsck -y /dev/sda2
   ```
   设备名以实际根分区为准（可从 GRUB 的 `root=` 或 `blkid` 确认）。

4. **GRUB 编辑模式里的参数是临时的**
   只对本次启动生效，不会写入 `grub.cfg`；确认系统正常后直接重启即可恢复默认启动。

5. **`nomodeset` 无效是重要信号**
   说明不是显卡驱动问题，应转向根分区/文件系统方向排查。

6. **修复后必须验证文件系统状态**
   `dumpe2fs -h /dev/sda2 | grep "Filesystem state"` 应为 `clean`；若短期内反复需要 fsck，查硬盘 SMART 排除硬件。

7. **带外通道兜底**
   本地屏幕完全不可用时，Gen8 的 **iLO 4 远程控制台**可以接管画面；本次也通过 iLO 观察/控制启动过程。

---

## 七、可复用处置清单

```text
1. 开机能否看到 GRUB？
   ├─ 不能 → 引导层问题（grub 修复 / 分区 / 启动项）
   └─ 能 → 按 e 编辑 linux 行
2. 行末追加 systemd.unit=multi-user.target → Ctrl+X 启动
   ├─ 落到 (initramfs) → fsck -y /dev/sda2 → exit
   └─ 直接进 tty   → 说明根分区已能挂载，直接排查图形层
3. 修完重启（临时参数自动失效）→ 验证：
   findmnt -no SOURCE,FSTYPE /
   sudo dumpe2fs -h /dev/sda2 | grep "Filesystem state"    # 期望 clean
   systemctl status display-manager
4. 同一分区反复需要 fsck → 查 SMART，排除硬盘
```

---

## 八、与“纯显卡黑屏”的区分

| 现象 | 显卡/显示管理器问题 | 本次（根文件系统问题） |
|---|---|---|
| 能否进系统 | 能（SSH 可达、`gdm` 在跑） | **不能**（要先修根分区） |
| 选启动项 | 黑屏，但系统在后台启动 | 黑屏且系统没起来 |
| `nomodeset` | 通常有效 | **无效** |
| `systemd.unit=multi-user.target` | 能进文本模式 | 修完 fsck 后同样能进文本模式 |
| 根治方式 | 驱动参数 / 重装 gdm | `fsck -y <根分区>` |

---

## 九、备注

- 本文依据：① 现场操作链接记录（GRUB 编辑模式追加 `systemd.unit=multi-user.target` → `(initramfs)` 执行 `fsck -y /dev/sda2` → `exit` 进 tty → 重启恢复图形界面）；② 59 机器现场核实（根分区 `/dev/sda2 ext4`、当前 `Filesystem state: clean`、`gdm` 正常、系统持续运行）。
- **确定参数：`systemd.unit=multi-user.target`**，已与现场记录核对一致。
