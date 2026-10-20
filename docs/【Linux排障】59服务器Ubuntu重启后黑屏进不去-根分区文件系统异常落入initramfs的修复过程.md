# 【Linux排障】59服务器Ubuntu重启后黑屏进不去-根分区文件系统异常落入initramfs的修复过程

> 日期：2026-10-17（现场处理）／2026-10-20（整理归档）
> 设备：HP ProLiant DL380p Gen8（主机名 `admin1-ProLiant-DL380p-Gen8`，`192.168.0.59`）
> 系统：Ubuntu 桌面版（ext4 根分区 `/dev/sda2`）
> 板卡显卡：Matrox MGA G200EH（板载，iLO 共用）

---

## 一、故障现象

用户描述：**“关机前用得好好的，点了重启之后黑屏，不显示登录界面。”**

现场逐项确认：

| 环节 | 表现 |
|---|---|
| 开机自检 | 正常 |
| GRUB 菜单 | **正常显示**（能看到 `Ubuntu` 与 `Advanced options for Ubuntu`） |
| 选 `Ubuntu` 回车 | **直接黑屏**，无输出、不进桌面 |
| 选 `Advanced options` 回车 | **同样黑屏**，连子菜单都不显示 |
| GRUB 编辑模式（`e`） | **能进入**，可改内核参数 |
| GRUB 命令行（`c`） | **能进入**，可执行 `ls` / `linux` / `initrd` / `boot` |
| 编辑模式加 `nomodeset` | **无效**，仍然黑屏 |
| GRUB 命令行 `exit` | 退出后出现命令行界面 |

**表面看像“显卡黑屏”，实际不是。** 真正的落点是 **`(initramfs)` 提示符** —— 系统没能挂载根文件系统，内核把控制权交给了 initramfs 的救援 shell，屏幕因此停在黑屏/极简命令行状态。

---

## 二、根因

### 2.1 直接原因：根分区文件系统不一致

- 根分区：**`/dev/sda2`（ext4）**
- 系统在启动时无法以可写方式挂载根分区（文件系统需要检查/修复），于是走 **initramfs 救援模式**，停在 `(initramfs)` 提示符
- 触发原因通常是：**非正常关机/断电/强制重启**，导致 ext4 日志未正常回放，文件系统被标记为需要 fsck

### 2.2 为什么看起来像“显卡黑屏”

- initramfs 阶段的输出很少，桌面显卡（Matrox G200EH）此时也没被完整驱动接管，屏幕就是一片黑；
- 只有在 GRUB 里按 `e`/`c` 能进、选正常启动就黑 —— 这是“内核起来了但根文件系统挂不上”的典型表现；
- 因此 **`nomodeset` 无效**：问题不在显卡驱动，而在**根分区挂载失败**。

### 2.3 为什么 `Advanced options` 也黑屏

advanced 里同样是启动同一个内核，只是参数不同；根分区挂不上时，无论选哪个内核都会落到 initramfs。

---

## 三、处理过程（实际有效步骤）

### 3.1 进入 initramfs

在 GRUB 里正常选择启动项（或 `Advanced options` 里的内核），系统在挂载根分区失败后会落到：

```
(initramfs) _
```

如果屏幕全黑但有输出被吞掉，可尝试在 GRUB 编辑模式里去掉 `quiet splash` 再看内核输出，能直接看到 `Failed to mount /dev/sda2` 一类的报错。

### 3.2 在 initramfs 里修复文件系统

```bash
(initramfs) fsck -y /dev/sda2
```

- `-y`：对所有修复询问自动回答 yes（无人值守修复）
- 修复过程中会回放 ext4 日志、修正不一致的块/目录项
- 修复完成后提示符会回到 `(initramfs)`

### 3.3 重启

```bash
(initramfs) reboot -f
```

### 3.4 结果

重启后系统正常挂载根分区，**直接进入图形登录界面**，问题解决。

---

## 四、验证结果

在系统正常启动后逐项确认：

| 检查项 | 命令 | 结果 |
|---|---|---|
| 根分区与类型 | `findmnt -no SOURCE,FSTYPE /` | `/dev/sda2 ext4` |
| 文件系统状态 | `sudo dumpe2fs -h /dev/sda2 \| grep "Filesystem state"` | **clean** |
| 上次检查时间 | `sudo dumpe2fs -h /dev/sda2 \| grep "Last checked"` | 已记录检查时间 |
| 挂载计数 | `sudo dumpe2fs -h /dev/sda2 \| grep "Mount count"` | 正常递增 |
| 显示管理器 | `systemctl status display-manager` | `gdm.service` **active (running)** |
| 系统运行 | `uptime` | 持续运行 3 天以上 |

---

## 五、经验总结（同类问题直接照做）

1. **“黑屏进不去”先判断是不是 initramfs**
   只要 GRUB 能进、`e`/`c` 都能进，就不是引导层损坏；再看是否停在 `(initramfs)`。

2. **`(initramfs)` = 根文件系统挂载失败**
   绝大多数是非正常关机/断电导致 ext4 需要 fsck，而不是系统坏了、更不是显卡坏了。

3. **修复只需一条命令**
   ```bash
   (initramfs) fsck -y /dev/sda2
   (initramfs) reboot -f
   ```
   注意 `/dev/sda2` 要换成**实际的根分区**（可用 `blkid` 或 GRUB 里的 `linux ... root=/dev/sdX` 确认）。

4. **`nomodeset` 无效就是重要信号**
   如果是显卡驱动问题，`nomodeset` 通常能让画面出来；无效说明问题不在图形层，应往根分区挂载方向查。

5. **去掉 `quiet splash` 能看到真实报错**
   在 GRUB 编辑模式里删掉这两个参数，启动时就能看到 `Failed to mount` / `fsck` 相关提示，比盯黑屏猜快得多。

6. **修完要确认状态**
   `dumpe2fs -h /dev/sda2 | grep "Filesystem state"` 应为 `clean`；如果反复出现不一致，要怀疑硬盘健康（看 SMART）。

7. **带外通道仍然是兜底**
   当本地屏幕完全不可用时，Gen8 自带的 **iLO 4 远程控制台**能接管画面继续操作；本次处理期间也使用了 iLO 观察启动过程。

---

## 六、可复用处置清单

```text
1. 开机能否进 GRUB？
   ├─ 不能 → 引导层问题（grub 修复 / 分区 / 启动项）
   └─ 能 → 按 e 进编辑模式，去掉 quiet splash，看内核报错
2. 是否出现 (initramfs) 提示符 或 "Failed to mount /dev/sdX"？
   ├─ 是 → 根文件系统问题：fsck -y /dev/sda2 → reboot -f
   └─ 否 → 再考虑显卡/显示管理器（nomodeset、gdm 重装）
3. 修复后验证：
   findmnt -no SOURCE,FSTYPE /
   sudo dumpe2fs -h /dev/sda2 | grep "Filesystem state"   # 期望 clean
   systemctl status display-manager
4. 若同一分区反复需要 fsck → 查硬盘 SMART，排除硬件
```

---

## 七、备注

- 本文依据：① 处理人现场操作记录（进入 `(initramfs)` → `fsck -y /dev/sda2` → 重启）；② 59 机器现场核实（根分区 `/dev/sda2 ext4`、当前 `Filesystem state: clean`、`gdm` 正常、系统持续运行）。
- 与“显卡黑屏”的区别：显卡问题的典型特征是能进系统（SSH 可达、`gdm` 在跑）只是本地无显示；本次是**根本进不了系统**，必须在 initramfs 里修文件系统。
