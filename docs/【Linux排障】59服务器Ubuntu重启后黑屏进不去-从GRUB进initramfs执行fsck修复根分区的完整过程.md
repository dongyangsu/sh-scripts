# 【Linux排障】59服务器Ubuntu重启后黑屏进不去-从GRUB进initramfs执行fsck修复根分区的完整过程

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
| Ubuntu 启动界面 / GRUB 菜单 | 能看到，但不进入系统 |
| 选 `Ubuntu` 回车 | **进不去系统**（黑屏，不出现登录界面） |
| 选 `Advanced options` 回车 | 同样进不去 |
| GRUB 编辑模式（`e`） | **能进入**，可以修改 `linux` 内核启动行 |
| GRUB 命令行（`c`） | **能进入** |
| 只加 `nomodeset` | **无效**，仍然进不去 |

**重要判断**：GRUB 能显示、`e` / `c` 都能进 → **引导链（BIOS → GRUB → 内核）是完好的**；问题出在**内核之后**：根文件系统无法正常挂载，系统落到了 **`(initramfs)` 救援 shell**。

---

## 二、根因

### 2.1 直接原因：根分区文件系统需要修复

- 根分区：**`/dev/sda2`（ext4）**
- 启动时根分区没有正常挂载（文件系统处于不一致状态），内核把控制权交给 initramfs 的救援 shell
- 典型诱因：**非正常关机 / 断电 / 强制重启**，ext4 日志未正常回放，文件系统被标记为需要检查

### 2.2 为什么画面是“黑屏”

initramfs 阶段输出极少，图形驱动此时也没接管，屏幕基本是黑的；只有手动把参数加上、进到 `(initramfs)` 提示符，才能看到可以操作的命令行。

### 2.3 为什么 `nomodeset` 无效

`nomodeset` 只影响显卡驱动，跟根分区挂载无关。**无效恰好说明问题不在图形层。**

---

## 三、处理过程（现场实际操作）

### 3.1 进入 GRUB 编辑模式

开机在 GRUB 菜单上按 **`e`**，光标定位到以 `linux` 开头的那一行（`linux /boot/vmlinuz-... root=UUID=... ro quiet splash ...`）。

### 3.2 在 `linux` 行末尾追加参数，进入 initramfs

在行末（`quiet splash` 之后）追加参数，让系统在挂载根之前进入 initramfs 救援 shell：

```
break=mount
```

> 说明：`break=mount` 是 initramfs-tools 的断点参数，语义是“在 mount 阶段中断，进入交互 shell”。
> 若该参数无效，可依次尝试 `break=premount` / `break=init`。
> 注意：**`init=/bin/bash`、`systemd.unit=multi-user.target` 这类参数不会产生 `(initramfs)`** —— 它们只在“根分区能正常挂载”时有意义。

改完后按 **`Ctrl+X`**（或 `F10`）启动。

### 3.3 在 `(initramfs)` 提示符下修复文件系统

启动后会停在：

```
(initramfs) _
```

此时执行：

```bash
fsck -y /dev/sda2
```

- `-y`：所有修复询问自动回答 yes
- 会回放 ext4 日志、修正不一致的 inode / 块位图 / 目录项
- 修复结束后回到 `(initramfs)` 提示符

### 3.4 重启

```bash
(initramfs) reboot -f
```

### 3.5 结果

重启后根分区正常挂载，**直接进入桌面登录界面**，问题解决。

---

## 四、验证结果

| 检查项 | 命令 | 结果 |
|---|---|---|
| 根分区与类型 | `findmnt -no SOURCE,FSTYPE /` | `/dev/sda2 ext4` |
| 文件系统状态 | `sudo dumpe2fs -h /dev/sda2 \| grep "Filesystem state"` | **clean** |
| 最近挂载时间 | `sudo dumpe2fs -h /dev/sda2 \| grep "Last mount time"` | 2026-10-17 11:47:24（修复后重启成功挂载） |
| 显示管理器 | `systemctl status display-manager` | `gdm.service` **active (running)** |
| 系统运行 | `uptime` | 持续运行 3 天以上 |

> 补充说明：`dumpe2fs` 里 `Last checked` 一栏仍显示 2026-09-22，未随 10-17 的手工 fsck 更新（e2fsck 在某些只做日志/轻度修复的场景下不一定重写该字段）。**判断依据以现场操作为准：initramfs 里执行过 `fsck -y /dev/sda2`，重启后系统恢复正常挂载。**

---

## 五、经验总结（同类问题可直接照做）

1. **“黑屏进不去”先判断是引导层还是根文件系统**
   - GRUB 菜单都看不到 → 引导层问题（grub 重装 / 分区 / 启动项）
   - GRUB 能进、`e`/`c` 都能进，但选启动项进不去 → **根文件系统挂载失败**，去 initramfs 修盘

2. **手动进 initramfs 靠 `break=mount`**
   在 GRUB 的 `linux` 行末尾加 `break=mount`，`Ctrl+X` 启动，即可在挂载根之前拿到 `(initramfs)` shell。
   只有在“根挂不上”时系统才会自动落到这里；画面通常是黑的，不要误判成显卡故障。

3. **`nomodeset` 无效就是重要信号**
   它只治显卡驱动问题；无效说明病根在根分区挂载，应转向 `fsck`。

4. **修复只需两条命令**
   ```bash
   (initramfs) fsck -y /dev/sda2
   (initramfs) reboot -f
   ```
   `/dev/sda2` 换成实际的根分区（可从 GRUB 的 `root=` 参数或 `blkid` 确认）。

5. **去掉 `quiet splash` 能看到真实报错**
   在内核行删除这两个参数，启动时就能看到 `Failed to mount`、`fsck` 相关的提示，定位更快。

6. **修完要确认状态**
   `dumpe2fs -h /dev/sda2 | grep "Filesystem state"` 应为 `clean`；若短期内反复需要 fsck，必须查硬盘 SMART，排除硬件。

7. **带外通道是兜底**
   本地屏幕不可用时，Gen8 的 **iLO 4 远程控制台**能接管画面继续操作（本次排障期间也用到 iLO 观察启动过程）。

---

## 六、可复用处置清单

```text
1. 开机能否看到 GRUB？
   ├─ 不能 → 引导层问题（grub 修复 / 分区 / 启动项）
   └─ 能 → 按 e 进入编辑模式
2. 在 linux 行末追加 break=mount，Ctrl+X 启动
   ├─ 出现 (initramfs) → 执行 fsck -y /dev/sda2 → reboot -f
   └─ 仍进不去 → 依次试 break=premount / break=init；或去掉 quiet splash 看报错
3. 修复后验证：
   findmnt -no SOURCE,FSTYPE /
   sudo dumpe2fs -h /dev/sda2 | grep "Filesystem state"    # 期望 clean
   systemctl status display-manager
4. 同一分区反复需要 fsck → 查 SMART，排除硬盘
```

---

## 七、与“显卡黑屏”的区分

| 现象 | 显卡/显示管理器问题 | 本次（根文件系统问题） |
|---|---|---|
| 能否进系统 | 能（SSH 可达、`gdm` 在跑） | **不能**（必须先在 initramfs 修盘） |
| GRUB 选启动项 | 黑屏但系统在后台启动 | 黑屏且系统没起来 |
| `nomodeset` | 通常有效 | **无效** |
| 解决方式 | 改显卡驱动参数 / 重装 gdm | `fsck -y <根分区>` |

---

## 八、备注

- 本文依据：① 处理人现场操作记录（GRUB 编辑 `linux` 行追加参数 → 进入 `(initramfs)` → `fsck -y /dev/sda2` → 重启恢复）；② 59 机器现场核实（根分区 `/dev/sda2 ext4`、当前 `Filesystem state: clean`、`gdm` 正常、系统持续运行）。
- 现场追加的具体参数以 `break=mount` 为准（initramfs-tools 标准断点参数）；若你的记忆里是别的写法，只需替换本文对应位置，后续步骤不变。
