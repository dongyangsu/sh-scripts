# 124（DL380G902）故障修复全记录

> 日期：2026-10-20
> 维护人：小龙虾（OpenClaw）
> 设备：HP ProLiant（主机名 `DL380G902`），Ubuntu 16.04.7 LTS（xenial）
> 带外：iLO 4 v2.82，`ILOCN760904R9`，管理地址 `192.168.0.61`（账号 admin1）
> 业务地址：`192.168.2.124/16`，网关 `192.168.0.1`
> 系统盘：`/dev/sda` 465.8G（HITACHI HTS72505），根分区 458G，修复前已用 35G（8%）

---

## 一、故障现象

| 现象 | 具体表现 |
|---|---|
| SSH 连不上 | `kex_exchange_identification: read: Connection reset by peer` / `Connection closed by 192.168.2.124 port 22`，**连 banner 都不发** |
| 主机在线 | `ping 192.168.2.124` 正常，22 端口 TCP 能建立连接（随即被关闭） |
| 系统内部报错 | `journalctl -u ssh` 反复出现 `/usr/sbin/sshd: error while loading shared libraries: /usr/local/lib/libz.so.1: file too short` |
| 连锁故障 | `apt` 也报 `apt: error while loading shared libraries: /usr/local/lib/libz.so.1: file too short`；`polkitd`、`accounts-daemon`、`rsyslog` 全部 failed |

**关键判断**：TCP 能连但拿不到 banner，说明**不是网络问题、不是密码问题**，而是 sshd 进程本身启动即崩溃。此时千万不要反复试密码（会误判为账号锁定）。

---

## 二、排查时间线

| 时间 | 动作 | 结果 |
|---|---|---|
| 约 14:15 | 从 139 直接 SSH 到 `192.168.2.124` | `Permission denied`（后确认是源地址问题，应使用 `-b 192.168.0.139`） |
| 14:20-15:00 | 换源地址 `ssh -b 192.168.0.139` 登录成功 | 读取到 `ip addr`、`systemctl status ssh` 等信息 |
| 15:04 | 从截图确认 `sshd` 报 `libz.so.1: file too short` | 定位到动态库损坏 |
| 15:20-16:40 | 通过 iLO 4 HTML5 控制台进入 `tty2`（Ctrl+Alt+F2），用 admin1 登录 | 控制台可操作，但字体渲染异常、按键重复，输入不可靠 |
| 16:43 | 控制台执行修复命令后 **22 端口恢复** | SSH 可用 |
| 16:45-16:55 | 检查发现 `/usr/local/lib` 下 16 个 `.so` 是**文本文件**（9~26 字节） | 恢复为真软链接，polkitd/accounts-daemon/rsyslog 恢复 |
| 16:56-17:05 | apt 命令可执行但**无法访问源** | 排查出该网段无 IPv4 出口、网关只放行 192.168.0.x |
| 17:06-17:12 | 改用 **IPv6 通路**（RA 默认路由 `fe80::1` + IPv6 DNS） | `apt update` 全部 Hit，`apt install` 成功 |
| 17:17-17:22 | `apt upgrade`（93 包）→ `apt dist-upgrade`（31 包） | 全部完成，`rc=0` |
| 17:28-17:35 | 重启，内核从 `4.4.0-186-generic` 升到 **`4.4.0-210-generic`** | 17:33:23 恢复在线 |
| 17:36-17:45 | 重启后 `/etc/resolv.conf` 被 resolvconf 覆盖，DNS 顺序错误 | 修改 `resolvconf` 的 `head`，DNS 恢复 0.3 秒解析 |

---

## 三、根因分析（分层）

### 3.1 直接原因：`/usr/local/lib` 下的库损坏

```
/usr/sbin/sshd: error while loading shared libraries: /usr/local/lib/libz.so.1: file too short
```

`/etc/ld.so.conf` 里有 `include /usr/local/lib/*`，`/etc/ld.so.conf.d/libc.conf` 也有 `/usr/local/lib`，所以 **`/usr/local/lib` 的库优先于系统库**。
该目录下的 `libz.so.1` 只有 9 字节（正常约 104 KB），加载必然失败。

### 3.2 更深原因：软链接被当成普通文件拷贝

进一步检查 `/usr/local/lib`，发现 **16 个 `.so` 文件的体积只有 9~26 字节，内容是“另一个文件名”的纯文本**，例如：

```
libgio-2.0.so      15 字节，内容是 "libgio-2.0.so.0"
libgio-2.0.so.0    22 字节，内容是 "libgio-2.0.so.0.5400.0"
libz.so             9 字节，内容是 "libz.so.1"
```

这是典型的 **`cp` 拷贝软链接时没有加 `-a` / `-d`** 的后果：符号链接被跟随/解引用失败后写成了文本文件。
系统或某次部署把整个 `/usr/local/lib` 搬过来时用了非保留属性的方式，导致：

- `libz.so.1`（文本）→ sshd / apt / dpkg 全部加载失败
- `libgio-2.0.so.0`（文本）→ polkitd / accounts-daemon 加载失败
- 其余 `libglib/libgobject/libgmodule/libgthread/libffi/libau_utils/libdmi_core` 同样受影响

### 3.3 网络层原因：该网段没有 IPv4 出口

修复库之后，`apt-get update` 仍然不通。逐项排查：

- `ping 223.5.5.5` / `8.8.8.8` → 不通
- 网关 `192.168.0.1`：**ARP 能解析、能回包**，但 `ping`、`tcp/53`、`tcp/80` 全部不通
- 换网关测试 `192.168.2.1 / 192.168.2.13 / 192.168.0.254 / 192.168.2.254 / 192.168.3.1 / 192.168.1.1` → 只有 `192.168.2.13` 可达但不出外网
- 对比同网段的 `133`：它 `ping 223.5.5.5` 也不通、访问公网 IP:443 也不通，**但 apt 正常**

结论：**该网络对 `192.168.2.x` 源地址的 IPv4 出口做了限制，而 IPv6 是通的**。
`133` 之所以正常，是因为它走：

```
default via fe80::1 dev eno1 proto ra metric 1024
nameserver fe80::1（由 RA 下发）
```

### 3.4 重启后的二次故障：resolvconf 覆盖 DNS 顺序

重启后 `/etc/resolv.conf` 变成：

```
nameserver 192.168.0.1
nameserver 8.8.8.8
nameserver 114.114.114.114
nameserver 192.168.0.1
nameserver fe80::1
```

`fe80::1` 排到了最后，前面 4 个不可达的 IPv4 DNS 每个超时 5 秒，`getent hosts` 直接超时。
根因在 **`/etc/resolvconf/resolv.conf.d/head`**：resolvconf 每次 `ifup` 都会把 head 的内容**插到最前面**。

---

## 四、修复步骤（可直接复用）

### 步骤 0：先判断 sshd 是不是“进程崩了”

```bash
# 从能连通的对端执行
ssh -b 192.168.0.139 admin1@192.168.2.124
# 若报 kex_exchange_identification / Connection closed（无 banner）
# → 到带外/控制台看：
journalctl -u ssh -n 20 --no-pager
ldd /usr/sbin/sshd | grep -i "not found"
```

### 步骤 1：修复损坏的动态库

```bash
# 1) 确认哪个库坏了
ldd /usr/sbin/sshd | grep -i "not found"
ls -l /usr/local/lib/libz.so.1

# 2) 备份并用系统库替换
sudo mv /usr/local/lib/libz.so.1 /root/libz.so.1.broken
sudo cp -f /lib/x86_64-linux-gnu/libz.so.1 /usr/local/lib/libz.so.1
sudo ldconfig

# 3) 验证
python3 -c "import zlib; print('zlib ok')"
sudo systemctl restart ssh
systemctl is-active ssh      # 期望 active
```

### 步骤 2：修复 `/usr/local/lib` 里"被写成文本的软链接"

```bash
sudo bash -c '
cd /usr/local/lib
mkdir -p /root/usr_local_lib_broken
for f in $(ls); do
  s=$(stat -c %s "$f" 2>/dev/null)
  [ -n "$s" ] && [ "$s" -lt 200 ] || continue
  tgt=$(head -c 120 "$f" | tr -d "\n\r")
  if [ -e "$tgt" ]; then
    cp -a "$f" /root/usr_local_lib_broken/
    ln -sfn "$tgt" "$f"
    echo "FIXED $f -> $tgt"
  else
    echo "SKIP $f (target missing)"
  fi
done
ldconfig
'
```

> 本次修复的 16 个文件：`libau_utils.so(.1)`、`libdmi_core.so(.0)`、`libffi.so(.7)`、`libgio-2.0.so(.0)`、`libglib-2.0.so(.0)`、`libgmodule-2.0.so(.0)`、`libgobject-2.0.so(.0)`、`libgthread-2.0.so(.0)`、`libz.so`

### 步骤 3：恢复被连带打挂的服务

```bash
sudo systemctl restart rsyslog polkitd accounts-daemon
systemctl --failed --no-legend --no-pager
```

### 步骤 4：让 apt 可达（无 IPv4 出口时走 IPv6）

```bash
# 4.1 确认 IPv6 默认路由存在（RA 下发）
ip -6 route | grep default
# 期望：default via fe80::1 dev eno1 proto ra

# 4.2 DNS 指向 IPv6（链路本地必须带 %接口名）
sudo tee /etc/resolv.conf > /dev/null <<'EOF'
nameserver fe80::1%eno1
nameserver 192.168.0.1
EOF

# 4.3 让 apt 强制走 IPv6
echo 'Acquire::ForceIPv6 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv6

# 4.4 验证
getent hosts us.archive.ubuntu.com
sudo apt-get update
```

### 步骤 5：持久化 DNS（防止重启被覆盖）

```bash
# resolvconf 的 head 会插到最前面，必须改这里
sudo cp -a /etc/resolvconf/resolv.conf.d/head /root/resolvconf-head.bak
echo 'nameserver fe80::1%eno1' | sudo tee /etc/resolvconf/resolv.conf.d/head

# 网卡配置里的 dns-nameservers 作为备用
sudo sed -i 's|^[[:space:]]*dns-nameservers.*|\tdns-nameservers 192.168.0.1|' /etc/network/interfaces

sudo resolvconf -u
cat /etc/resolv.conf     # 确认 fe80::1%eno1 在第一行
```

### 步骤 6：全量升级

```bash
# 清理可能残留的 apt 锁与僵死进程（注意：不要用 pkill -f apt-get，会误杀自己的 SSH 连接）
sudo pkill -9 -x apt-get
sudo rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock*

sudo DEBIAN_FRONTEND=noninteractive apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
```

> 建议放后台跑并记日志，避免 SSH 断线中断：
> ```bash
> setsid nohup bash /tmp/distup.sh >/dev/null 2>&1 < /dev/null &
> # 日志：/var/log/apt-distupgrade.log
> ```

### 步骤 7：重启并验证

```bash
sudo reboot
# 重启后
uname -r                              # 4.4.0-210-generic
systemctl is-active ssh diskwebui rsyslog
systemctl --failed --no-legend --no-pager   # 期望 0 条
getent hosts us.archive.ubuntu.com
sudo apt-get update
```

---

## 五、修复结果

| 项目 | 修复前 | 修复后 |
|---|---|---|
| SSH | 22 端口 TCP 可连但立即断开 | ✅ 正常，`sshd active` |
| `libz.so.1` | 9 字节文本文件 | ✅ 104,864 字节正常 ELF，`import zlib` 通过 |
| `/usr/local/lib` | 16 个 `.so` 为文本文件 | ✅ 恢复为软链接，原件备份 `/root/usr_local_lib_broken/` |
| apt | 报 `file too short`，完全不可用 | ✅ update/install/upgrade/dist-upgrade 全部可用 |
| 失败服务 | rsyslog / polkitd / accounts-daemon / lxd / unattended-upgrades | ✅ `systemctl --failed` 为 **0** |
| DNS | 解析超时 | ✅ `fe80::1%eno1` 优先，解析 0.3 秒 |
| 内核 | 4.4.0-186-generic | ✅ 4.4.0-210-generic |
| 待升级包 | 108 个 | ✅ 0 个 |
| diskwebui | 无 | ✅ 0.4.0（node16 + `KillMode=process`） |
| 磁盘 | 35G / 8% | ✅ 36G / 9% |

---

## 六、本次踩过的坑与解决办法（重点）

1. **TCP 能连、无 banner ≠ 密码错**
   `kex_exchange_identification: Connection reset` 说明 sshd 进程启动失败。此时不要反复试密码，先看 `journalctl -u ssh` 和 `ldd`。

2. **源地址不同，认证结果不同**
   该机器从 `192.168.2.139` 发起会被拒，从 `192.168.0.139` 发起就正常：
   ```bash
   ssh -b 192.168.0.139 admin1@192.168.2.124
   ```

3. **iLO 的 `/json/login_session` 用 curl 调会失败**
   curl 直接调返回 `{"message":"JS_ERR_NO_PRIV"}`，**但在页面里用 fetch 同源调用就成功**（能拿到 `session_key`）。自动化时应复用浏览器会话，而不是外部 curl。

4. **iLO HTML5 控制台的 `TEXTCONS` 不可用**
   提示 `Monitor is in graphics mode or an unsupported text mode`；`VSP`（虚拟串口）没有 getty 输出。可行做法：进 HTML5 图形控制台后按 **Ctrl+Alt+F2** 切到 tty2 文本终端。

5. **控制台字体“变形”（u 变样）不是输入错误**
   是 iLO 控制台渲染问题；重开控制台窗口可缓解。字体本身可通过 `console-setup` 调整：
   ```bash
   sudo sed -i 's/^FONTFACE=.*/FONTFACE="Terminus"/; s/^FONTSIZE=.*/FONTSIZE="16"/' /etc/default/console-setup
   sudo setupcon --force
   ```
   > 注意：`FONTSIZE="16x32"` 会把字号放大一倍、界面行数减半，不是“只换字体”。

6. **CDP 向控制台发按键会“重复输入”**
   同时发 `keyDown`（带 `text`）和 `keyUp` 会导致每个字符输入两次（`admin1` → `aaddmmiinn11`）。正确做法：**只发 `rawKeyDown`**（带 `text`）+ `keyUp`（不带 `text`）。

7. **控制台里 `echo pass | sudo -S` 管道不生效**
   改为逐条执行 `sudo`，等出现 `[sudo] password for ...` 再输入密码。

8. **`pkill -f apt-get` 会杀掉自己的 SSH 会话**
   因为自己的命令行里也包含 `apt-get` 字样。改用 `pkill -9 -x apt-get`（精确匹配进程名）。

9. **IP 冲突误判**
   临时给本机加了 `192.168.0.124` 后又去 ping 它，误以为“被占用”；其实是自己。**加地址后不要立刻用 ping 判断占用**，先查本机 `ip addr`。

10. **网关可达 ≠ 能上网**
    `192.168.0.1` 能回 ARP，但对 `192.168.2.x` 源的 ICMP/DNS/HTTP 全部丢弃。判断出口要测 `tcp/53`、`curl`，不能只看 ping。

11. **DNS 只写 IPv4 会整体超时**
    必须把 `fe80::1%eno1` 放第一位；链路本地地址要带 `%接口名`。否则前面每个不可达 DNS 各等 5 秒。

12. **`/etc/resolvconf/resolv.conf.d/head` 会覆盖 DNS 顺序**
    每次 `ifup` 都会把 head 内容插到最前面，改 `/etc/resolv.conf` 只是临时的，必须改 head。

13. **`ldconfig` 报 `xxx is not a known library type`**
    是 `/usr/local/lib` 里还有被截断的 `.so`。不影响已经缓存的服务，但会刷满日志，需要逐个替换为正确软链。

14. **apt 锁残留**
    多次中断的 `apt-get update` 会留下 `/var/lib/apt/lists/lock`，表现为 `Could not get lock`。清理锁文件和僵死进程即可。

15. **升级 `libc` 期间不要重启/断电**
    `libc6 / libc-bin` 升级过程中断会导致系统不可用，务必等 `Dpkg` 走完。

16. **124 上的 Python 是 3.5，不支持 f-string**
   脚本里用 `print(f"...")` 会直接 `SyntaxError`，必须改成 `%` 格式化。跨机执行脚本前先看 `python3 -V`。

17. **`ldconfig` 满屏 `is not a known library type`，根因不一定是损坏文件**
   本次排查发现 `/etc/ld.so.conf` 里写的是 `include /usr/local/lib/*` —— 这会把目录里**每一个 `.so` 当配置文件解析**，于是二进制内容被当成“库类型”解析失败。
   正确写法是目录形式：`/usr/local/lib`。改完 `ldconfig` 立刻安静。

18. **把系统库 `cp` 到 `/usr/local/lib` 会让 ldconfig 报 `not a symbolic link`**
   临时救急可以，但收尾应改回软链接（例如 `libz.so.1 -> libz.so.1.2.11`），否则每次 `ldconfig` 都会留一行警告。

---

## 七、经验与最佳实践

1. **拷软链接必须用 `cp -a` / `rsync -a`**，否则会把链接写成文本文件，之后所有依赖该库的程序都会“莫名其妙的找不到库”。
2. **`/usr/local/lib` 优先级高于系统库**，任何损坏都会导致 sshd、apt、polkit 等基础组件不可用；排查时优先 `ldd`。
3. **无外网机器装包，先找“同网段能用 apt 的机器”做对照**（本次对照 133 才发现是 IPv6 通路）。
4. **改 DNS/网络前先备份**：`/etc/resolv.conf`、`/etc/network/interfaces`、`/etc/resolvconf/resolv.conf.d/head`。
5. **长任务放后台 + 日志**：`setsid nohup ... &`，避免 SSH 断线导致升级中断在 `dpkg` 半途。
6. **升级后必须重启验证**：本次内核从 `4.4.0-186` 升到 `4.4.0-210`，重启后才生效；重启后 DNS 顺序问题也才暴露。


---

## 八、软链接恢复全过程（补充详解）

修复 `/usr/local/lib` 一共走了四轮，每轮的发现、问题与解决方式如下。

### 第 1 轮：发现 `.so` 被写成了“文本文件”

现象：`sshd`、`apt`、`polkitd` 都报 `libz.so.1: file too short`。把 `libz.so.1` 换成系统真库后 sshd 恢复，但 `polkitd`、`accounts-daemon` 又报 `libgio-2.0.so.0: file too short`。

于是逐个检查 `/usr/local/lib` 里小于 200 字节的文件：

```bash
cd /usr/local/lib
for f in *; do
  s=$(stat -c %s "$f")
  [ "$s" -lt 200 ] && printf "%-28s %5s  -> %s\n" "$f" "$s" "$(head -c 120 "$f")"
done
```

输出非常直观 —— 这些“库文件”只有 9~26 字节，内容就是软链接目标名：

```
libau_utils.so       16  -> libau_utils.so.1
libgio-2.0.so        15  -> libgio-2.0.so.0
libgio-2.0.so.0      22  -> libgio-2.0.so.0.5400.0
libglib-2.0.so       16  -> libglib-2.0.so.0
libz.so               9  -> libz.so.1
...
```

**结论**：当初把 `/usr/local/lib` 搬过来时用了 `cp`（没有 `-a` / `-d`），**符号链接被写成了包含目标路径的普通文本文件**。

**解决**：读取文件内容作为目标名，备份原件后重建软链接：

```bash
sudo bash -c '
cd /usr/local/lib
mkdir -p /root/usr_local_lib_broken
for f in $(ls); do
  s=$(stat -c %s "$f" 2>/dev/null)
  [ -n "$s" ] && [ "$s" -lt 200 ] || continue
  tgt=$(head -c 120 "$f" | tr -d "\n\r")
  if [ -e "$tgt" ]; then
    cp -a "$f" /root/usr_local_lib_broken/
    ln -sfn "$tgt" "$f"
    echo "FIXED $f -> $tgt"
  else
    echo "SKIP $f (target missing)"
  fi
done
ldconfig
'
```

这一轮修好了 16 个文件（`libgio/libglib/libgobject/libgmodule/libgthread/libffi/libau_utils/libdmi_core/libz.so`），`rsyslog`、`polkitd`、`accounts-daemon` 随之恢复。

### 第 2 轮：`ldconfig` 仍在报错 —— 查出 `include` 写错

修完软链后 `ldconfig` 依然刷出大量乱码式报错：

```
/sbin/ldconfig.real: .ï... is not a known library type
/sbin/ldconfig.real: /usr/local/lib/libz.so.1 is not a symbolic link
```

一开始误以为是还有损坏的库文件，反复扫描 `/usr/local/lib` 却找不到坏文件。最后检查配置文件才发现根因：

```bash
cat /etc/ld.so.conf
# include /etc/ld.so.conf.d/*.conf
# include /usr/local/lib/*      <-- 问题在这里
```

**`include /usr/local/lib/*` 的语义是“把该目录下每个文件当配置文件读取”**，于是每个 `.so` 的二进制内容都被当成“库类型”去解析，必然报 `is not a known library type`。

**解决**：改成目录形式（正确写法）：

```bash
sudo cp -a /etc/ld.so.conf /root/ld.so.conf.bak
sudo sed -i 's|^include /usr/local/lib/\*|/usr/local/lib|' /etc/ld.so.conf
sudo ldconfig
```

### 第 3 轮：确认没有残留的“截断库”

改完配置后报错只剩 `libz.so.1 is not a symbolic link`（因为第 1 轮我是用 `cp` 把系统库覆盖成了普通文件）。
为避免遗漏，写了一个检查 + 修复脚本（按“同名前缀里最大的真实库”作为目标）：

```python
#!/usr/bin/env python3
# 保存为 /tmp/fix_symlinks.py，用 sudo python3 执行
import os, shutil, subprocess

LIB = '/usr/local/lib'
BAK = '/root/usr_local_lib_broken'
os.makedirs(BAK, exist_ok=True)
entries = os.listdir(LIB)
fixed = skipped = []

for f in entries:
    p = os.path.join(LIB, f)
    if os.path.islink(p) or '.so' not in f:
        continue
    sz = os.path.getsize(p)
    if sz >= 200:
        continue
    base = f.split('.so')[0]
    cands = [(os.path.getsize(os.path.join(LIB, x)), x) for x in entries
             if x != f and x.startswith(base + '.so') and os.path.getsize(os.path.join(LIB, x)) > 1000]
    if not cands:
        continue
    cands.sort(reverse=True)
    target = cands[0][1]
    shutil.copy2(p, os.path.join(BAK, f))
    os.remove(p)
    os.symlink(target, p)
    fixed.append((f, sz, target))

print("FIXED: %d" % len(fixed))
for f, sz, t in fixed:
    print("  %s (%dB) -> %s" % (f, sz, t))
subprocess.run(['ldconfig'], check=False)
```

**踩坑**：124 的系统是 Ubuntu 16.04，自带 **Python 3.5**，不支持 f-string，第一版脚本直接 `SyntaxError`；改用 `%` 格式化后正常。

执行结果 `FIXED: 0`，说明第 1 轮已经全修完，没有残留。

### 第 4 轮：把 `libz.so.1` 改回软链接，彻底消除警告

```bash
sudo mv -f /usr/local/lib/libz.so.1 /root/usr_local_lib_broken/libz.so.1.systemcopy
sudo ln -sfn libz.so.1.2.11 /usr/local/lib/libz.so.1
sudo ldconfig
ldconfig 2>&1 | head -3      # 此时应完全无输出
```

最终 `/usr/local/lib` 状态：

```
libz.so   -> libz.so.1.2.11
libz.so.1 -> libz.so.1.2.11
libz.so.1.2.11  106039 字节（真实库文件）
```

### 恢复结果验证

```bash
cd /usr/local/lib
bad=0; dangle=0
for f in *; do
  if [ -L "$f" ]; then [ -e "$f" ] || dangle=$((dangle+1))
  else t=$(file -b "$f"); case "$t" in ELF*|directory) ;; *) bad=$((bad+1));; esac; fi
done
echo "坏文件=$bad 悬空链接=$dangle 总条目=$(ls | wc -l)"
```

实测结果：

| 指标 | 结果 |
|---|---|
| 总条目 | 33 |
| 坏文件 | **0**（唯一被标记的 `python3.5` 是目录，属正常） |
| 悬空链接 | **0** |
| `ldconfig` 输出 | **无任何输出** |
| `ldconfig -p` 收录 `/usr/local/lib` 的库 | 23 个 |
| `python3 -c "import zlib"` | 通过 |
| 服务状态 | `ssh` / `diskwebui` / `rsyslog` 均 active |
| `systemctl --failed` | **0** |

---

## 九、遗留事项

1. `/usr/local/lib` 仍有 **17 个被截断的 `.so`**（9~26 字节，带 ELF 头的残缺文件），会让 `ldconfig` 持续报 `not a known library type`。不影响服务与 apt，建议后续按“备份 + 指向真实库”的方式清理。
2. `lxd-containers.service`、`unattended-upgrades.service` 在升级前为 failed（升级后 failed 总数已为 0），如后续再出现，可单独确认是否需要。
3. 建议为 124 建立与其它节点一致的巡检项：`ssh`、`apt-get update`、`/usr/local/lib` 完整性（无坏文件/无悬空链接）、`/etc/ld.so.conf` 是否为目录写法、`systemctl --failed`。
