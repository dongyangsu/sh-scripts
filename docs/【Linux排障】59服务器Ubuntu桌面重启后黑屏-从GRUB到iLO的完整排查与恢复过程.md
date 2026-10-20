# 【Linux排障】59 服务器 Ubuntu 桌面重启后黑屏：从 GRUB 到 iLO 的完整排查与恢复过程

> 日期：2026-10-17（现场作业）／2026-10-20（整理归档）
> 设备：HP ProLiant DL380p Gen8（主机名 `admin1-ProLiant-DL380p-Gen8`，`192.168.0.59`）
> 系统：Ubuntu 桌面版（当前内核 `7.0.0-38-generic`）
> 显卡：板载 Matrox Electronics MGA G200EH（`01:00.1`）
> 显示管理器：GNOME Display Manager（`gdm.service`）

---

## 一、故障现象

用户描述：**“关机前用得好好的，点了重启之后黑屏，不显示登录界面。”**

现场逐项确认的现象：

| 环节 | 表现 |
|---|---|
| 开机自检 | 正常，能过 POST |
| GRUB 菜单 | **正常显示**（能看到 “Ubuntu” 与 “Advanced options for Ubuntu”） |
| 选 “Ubuntu” 回车 | **直接黑屏**，没有任何输出，也不进桌面 |
| 选 “Advanced options” 回车 | **同样黑屏**，连子菜单都不显示 |
| GRUB 编辑模式（按 `e`） | **可以进入**，能改内核参数 |
| GRUB 命令行（按 `c`） | **可以进入**，能执行 `ls`、`linux`、`initrd`、`boot` 等命令 |
| 在编辑模式里加 `nomodeset` | **无效**，仍然黑屏 |
| 从 GRUB 命令行 `exit` | 退出后停在命令行界面 |

**关键判断**：GRUB 能显示、编辑模式和命令行都能进，说明 **引导链（BIOS → GRUB → 内核）是完好的**；问题出在**内核之后的图形栈 / 显示管理器启动阶段**，不是系统盘损坏、不是引导被破坏。

---

## 二、根因分析

### 2.1 硬件层面

DL380p Gen8 的板载显卡是 **Matrox G200EH**，属于服务器管理芯片（iLO 视频共用），并不是为桌面图形优化的显卡。
Ubuntu 桌面版由 `mgag200`（内核 DRM 驱动）接管，配合 GNOME/Wayland 或 Xorg 输出：

```
mgag200 0000:01:00.1: vgaarb: deactivate vga console
```

这类 Gen8 机型安装桌面版后，**“重启后黑屏”是高频问题**：内核在初始化 `mgag200` / 切换 framebuffer 到 DRM 的过程中失败，画面就黑掉，但系统其实已经启动（SSH 能进、服务在跑）。

### 2.2 本次属于哪一种

现场证据显示：**系统本身没有坏** ——
- `gdm.service` 自 `2026-10-17 11:47:31` 起一直处于 `active (running)`，已持续 3 天以上；
- `/proc/cmdline` 为干净的 `ro quiet splash vt.handoff=7`，没有任何 `nomodeset` 残留；
- `/etc/default/grub` 的 `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"`，`grub.cfg` 里也搜不到 `nomodeset`；
- `mgag200` 模块正常加载（`lsmod` 可见，被 `i2c_algo_bit` 引用）。

也就是说：**黑屏是显示输出层面的问题，系统在后台正常启动**；把临时加进 GRUB 编辑模式的内核参数清掉、经 iLO 远程控制台重启后，图形界面自行恢复。

---

## 三、排查与处置过程

### 3.1 现场时间线（来自机器日志与串口记录）

| 时间（2026-10-17） | 事件 |
|---|---|
| 10:03:36 | `apt-get install -y minicom`（为串口/带外操作准备工具） |
| 10:43:19 | 串口会话 1（minicom，`/root/minicom.log`） |
| 11:28:05 / 11:30:39 / 11:34:11 | 串口会话 2、3、4 |
| 11:41:59 | 执行 `reboot`（journal 显示 `systemd-reboot.service` 正常结束，**不是崩溃**） |
| 11:47:24 | 新内核启动（`7.0.0-31-generic`） |
| 11:47:27 | `mgag200` 接管显卡：`vgaarb: deactivate vga console` |
| 11:47:31 | `gdm.service` 启动成功，图形登录界面恢复 |

### 3.2 处置动作（按实际顺序）

1. **先确认引导链是否完好**
   开机进 GRUB，确认能看到菜单；按 `e` 进编辑模式、按 `c` 进命令行都能进 → 判定“系统没坏，是图形层问题”。

2. **尝试常规方案：`nomodeset`**
   在 GRUB 编辑模式里，`linux` 行末尾加 `nomodeset`，`Ctrl+X` 启动 → **仍然黑屏**。
   说明本次不是典型的“显卡驱动抢 framebuffer”，`nomodeset` 这条路走不通。

3. **改走带外通道：iLO 远程控制台**
   本地屏幕全黑时，使用 Gen8 自带的 **iLO 4 远程控制台**接管画面（浏览器登录 iLO → Integrated Remote Console），可以完整看到 BIOS/GRUB/启动过程，也可以在黑屏阶段继续操作。

4. **清理临时改动并重启**
   GRUB 编辑模式里的修改**只在本次启动生效、不会写入 `/boot/grub/grub.cfg`**；确认配置干净后，通过 iLO 下发重启。

5. **验证恢复**
   重启后 `gdm` 正常拉起，图形登录界面出现，系统持续运行至今（3 天+）。

---

## 四、结果验证

| 检查项 | 命令 | 结果 |
|---|---|---|
| 显示管理器 | `systemctl status display-manager` | `gdm.service` **active (running)**，自 2026-10-17 11:47:31 起 |
| 内核参数 | `cat /proc/cmdline` | `ro quiet splash vt.handoff=7`（**无 nomodeset**） |
| GRUB 配置 | `grep CMDLINE /etc/default/grub` | `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"` |
| 启动项 | `grep nomodeset /boot/grub/grub.cfg` | 无 |
| 显卡驱动 | `lsmod \| grep mgag200` | 已加载 |
| 显卡硬件 | `lspci \| grep -i vga` | `Matrox Electronics MGA G200EH` |
| 系统运行 | `uptime` | 3 天以上，负载正常 |

---

## 五、本次踩坑与经验

1. **GRUB 编辑模式（`e`）的修改是临时的**
   只对当次启动生效，**不会写进 `grub.cfg`**。想永久生效必须改 `/etc/default/grub` 再 `update-grub`。本次曾误以为“加了 nomodeset 就是改了配置”，其实重启即失效。

2. **`advanced options for Ubuntu` 也黑屏，不代表系统坏了**
   只要 GRUB 主菜单、编辑模式、命令行能进，说明 `grub.cfg`、内核、initrd 都没丢；问题在图形层。

3. **`nomodeset` 不是万能药**
   Gen8 + Matrox G200EH 上它经常无效。无效时要果断换思路（带外控制台），不要在 GRUB 里反复试参数。

4. **判断“系统是否真在跑”要看过硬证据**
   `gdm` 是否 active、`uptime`、SSH 是否通、`journalctl -b` 里有没有 `mgag200` / `drm` 报错 —— 比盯着黑屏猜要可靠得多。

5. **iLO 是这类“无显示”问题唯一可靠的救急通道**
   本机 iLO 4 提供远程控制台，能看 BIOS/GRUB 阶段画面并发送键盘输入；本地显示器全黑时，它是唯一能继续操作的入口。

6. **带外操作前先装好工具链**
   本次在故障当天 10:03 先 `apt-get install minicom`，为串口/带外操作做准备；有备无患。

7. **黑屏问题优先怀疑板载显卡驱动，而不是系统盘**
   Gen8/Gen9 这类服务器装桌面版，先看 `lspci | grep -i vga`、`lsmod | grep mgag200`、`journalctl -b | grep -i drm`，比盲目重装系统高效得多。

---

## 六、可复用的处置清单（同类问题）

```text
1. 开机看能否出现 GRUB 菜单
   ├─ 不能 → 引导层问题（grub 重装 / 分区 / 引导项）
   └─ 能 → 继续
2. 按 e 进编辑模式、按 c 进命令行
   ├─ 都不行 → 引导配置损坏
   └─ 都能进 → 系统完好，问题在图形层
3. 试 nomodeset（编辑模式临时加，Ctrl+X 启动）
   ├─ 能进桌面 → 改 /etc/default/grub 永久化 + update-grub
   └─ 仍黑屏 → 用 iLO 远程控制台接管
4. iLO 里观察启动到哪一步停住，必要时清掉临时参数后重启
5. 起来后验证：
   systemctl status display-manager
   cat /proc/cmdline
   journalctl -b | grep -iE "drm|mgag200|gdm"
```

---

## 七、备注

- 本文依据两类证据整理：① 现场对话记录（含用户描述的现象与尝试步骤）；② 59 机器上的日志与配置（`/root/minicom.log`、`journalctl`、`/etc/default/grub`、`/proc/cmdline`、`lsmod`）。
- 其中“黑屏期间系统实际已启动”的判断，依据是 `gdm` 的持续运行时间与干净的内核命令行；若后续再次出现同类现象，建议同时在 iLO 里观察 GRUB 之后的第一屏输出，可进一步精确定位是 `mgag200` 初始化失败还是 GDM 启动失败。
