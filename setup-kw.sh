#!/data/data/com.termux/files/usr/bin/sh

set -u

GUEST_ADB="127.0.0.1:6556"
LOCAL_PORT="28200"
GUEST_FRIDA_PORT="28100"
FRIDA_VER="16.5.9"
PKG_NAME="com.lptiyu.tanke"

ROOTFS="$PREFIX/var/lib/proot-distro/containers/debian/rootfs"
MARK="$ROOTFS/root/.kw_ready"

say()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*"; exit 1; }

# ---------------------------------------------------------------- 0. 前置
say "0/7 前置检查"
if [ -z "${PREFIX:-}" ]; then
    die "请在 Termux 里运行：sh ~/setup-kw.sh"
fi
info "PREFIX = $PREFIX"

if ! command -v adb >/dev/null 2>&1; then
    say "安装 android-tools"
    pkg install -y android-tools || die "装 android-tools 失败，先跑 pkg update"
fi

# ---------------------------------------------------------------- 1. libc++
say "1/7 修 adb（升级 libc++）"
apt-get update -y >/dev/null 2>&1 || true
if ! adb version >/dev/null 2>&1; then
    info "adb 跑不起来，升级 libc++ ..."
    apt-get install -y --only-upgrade libc++ >/dev/null 2>&1 || \
        apt-get install -y libc++ >/dev/null 2>&1 || true
fi
if ! adb version >/dev/null 2>&1; then
    warn "adb 仍然报符号错误，请在 Termux 里手动执行："
    warn "    pkg update && pkg install -y libc++"
    die  "修好后再重跑本脚本"
fi
info "$(adb version | head -1)"

# ---------------------------------------------------------------- 2. 连虚拟机
say "2/7 连接虚拟机 ($GUEST_ADB)"
adb start-server >/dev/null 2>&1 || true
adb connect "$GUEST_ADB" >/dev/null 2>&1 || true

state=""
i=0
while [ "$i" -lt 24 ]; do
    state=$(adb devices | awk -v d="$GUEST_ADB" '$1==d {print $2; exit}')
    case "$state" in
        device)
            break ;;
        unauthorized)
            warn "虚拟机里弹出了 adb 授权框 → 请在虚拟机屏幕上点「允许」"
            warn "（勾选「一律允许」更好）" ;;
        offline)
            adb disconnect "$GUEST_ADB" >/dev/null 2>&1 || true
            adb connect "$GUEST_ADB" >/dev/null 2>&1 || true ;;
        *)
            adb connect "$GUEST_ADB" >/dev/null 2>&1 || true ;;
    esac
    i=$((i + 1))
    sleep 5
done

if [ "$state" != "device" ]; then
    warn "当前状态: ${state:-未连接}"
    die "连不上虚拟机。请检查：虚拟机是否在运行？「ADB 无线调试」是否开启？端口是否还是 6556？"
fi
info "Android $(adb shell getprop ro.build.version.release | tr -d '\r')"

# ---------------------------------------------------------- 3. frida-server
say "3/7 检查虚拟机里的 frida-server"
if adb shell "ls /data/local/tmp/svc" >/dev/null 2>&1; then
    info "已有 /data/local/tmp/svc"
else
    warn "虚拟机里没有 frida-server，尝试从 GitHub 下载 $FRIDA_VER ..."
    command -v xz >/dev/null 2>&1 || pkg install -y xz-utils || true
    URL="https://github.com/frida/frida/releases/download/$FRIDA_VER/frida-server-$FRIDA_VER-android-arm64.xz"
    if curl -fL --max-time 300 -o "$HOME/fs.xz" "$URL"; then
        xz -d -f "$HOME/fs.xz" || die "解压失败"
        adb push "$HOME/fs" /data/local/tmp/svc || die "push 失败"
        adb shell chmod 755 /data/local/tmp/svc
        rm -f "$HOME/fs"
        info "已部署 frida-server"
    else
        die "下载失败。可以手动把 frida-server-$FRIDA_VER-android-arm64 推到虚拟机的 /data/local/tmp/svc（chmod 755）"
    fi
fi

# ------------------------------------------------------------- 4. 装 Debian
say "4/7 准备 proot Debian 12"
if [ -d "$ROOTFS/etc" ]; then
    info "已有 Debian 容器，直接复用（不会重装）"
else
    command -v proot-distro >/dev/null 2>&1 || pkg install -y proot-distro || die "装 proot-distro 失败"

    if [ -d "$ROOTFS" ]; then
        info "清理上次未完成的空容器"
        proot-distro remove debian >/dev/null 2>&1 || true
    fi

    BASE="https://mirrors.tuna.tsinghua.edu.cn/lxc-images/images/debian/bookworm/arm64/default/"
    info "查找最新 rootfs ..."
    LATEST=$(curl -sL --max-time 30 "$BASE" | grep -oE '2[0-9]{7}_[0-9]{2}:[0-9]{2}/' | sort | tail -1)
    [ -n "$LATEST" ] || LATEST="20261112_05:24/"
    URL="${BASE}${LATEST}rootfs.tar.xz"
    info "下载 $URL"
    cd "$HOME" || die "无法进入 HOME"
    rm -f deb.tar.xz
    curl -fL --max-time 900 -o deb.tar.xz "$URL" || die "下载 rootfs 失败"
    info "已下载 $(du -h deb.tar.xz | cut -f1)，开始安装 ..."
    proot-distro install -n debian "$HOME/deb.tar.xz" || die "proot-distro 安装失败"
    rm -f deb.tar.xz
fi

# ------------------------------------------------ 5. 配置 Debian 里的客户端
say "5/7 配置 Debian（python + adb + frida $FRIDA_VER）"
[ -d "$ROOTFS" ] || die "找不到 Debian rootfs：$ROOTFS"

cat > "$ROOTFS/root/deb_bootstrap.sh" <<'BOOTSTRAP'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "[1/4] 换清华源"
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    sed -i 's|http://deb.debian.org|https://mirrors.tuna.tsinghua.edu.cn|g' "$f" || true
    sed -i 's|http://security.debian.org|https://mirrors.tuna.tsinghua.edu.cn|g' "$f" || true
    sed -i 's|http://ftp.debian.org|https://mirrors.tuna.tsinghua.edu.cn|g' "$f" || true
done

echo "[2/4] 更新索引"
apt-get update -y >/dev/null 2>&1 || apt-get update -y

echo "[3/4] 装 python3 + adb"
apt-get install -y --no-install-recommends \
    python3 python3-pip android-tools-adb ca-certificates >/dev/null

echo "[4/4] 装 frida"
python3 -m pip install --break-system-packages --no-cache-dir \
    -i https://pypi.tuna.tsinghua.edu.cn/simple "frida==@FRIDA_VER@" 2>&1 | tail -3

python3 -c "import frida; print('frida', frida.__version__)"
adb version | head -1
touch /root/.kw_ready
BOOTSTRAP
sed -i "s|@FRIDA_VER@|$FRIDA_VER|g" "$ROOTFS/root/deb_bootstrap.sh"
chmod 755 "$ROOTFS/root/deb_bootstrap.sh"

if [ -f "$MARK" ]; then
    info "Debian 已装好 frida，跳过"
else
    proot-distro login debian -- bash /root/deb_bootstrap.sh || die "Debian 内配置失败"
fi

# ------------------------------------------------ 6. 写入连接 / 注入脚本
say "6/7 生成连接与注入脚本"

cat > "$ROOTFS/root/kw_hook.py" <<'HOOKPY'
import io, os, sys, time
ADDR = "127.0.0.1:28200"
ZYGOTE = "zygote64"
JS = r"""
'use strict';
try {
    var STUB = Memory.alloc(Process.pageSize);
    Memory.protect(STUB, Process.pageSize, 'rwx');
    Memory.writeByteArray(STUB, [0x00,0x00,0x80,0x52,0xC0,0x03,0x5F,0xD6]);
    var pc = Module.findExportByName('libc.so', 'pthread_create');
    Interceptor.attach(pc, {
        onEnter: function (a) {
            try {
                var m = Process.findModuleByAddress(a[2]);
                var n = m ? m.name : '';
                if (/KwProtect|kwsdataenc|ijiami/i.test(n)) {
                    a[2] = STUB;
                    console.log('[zygote] BLOCKED ' + n);
                }
            } catch (e) {}
        }
    });
    console.log('[zygote] HOOK-INSTALLED');
} catch (e) { console.log('[zygote] FAIL ' + e); }
"""
check_only = "--check" in sys.argv
import frida
dev = frida.get_device_manager().add_remote_device(ADDR)
zyg = None
for p in dev.enumerate_processes():
    if p.name == ZYGOTE:
        zyg = p.pid
        break
if zyg is None:
    print("[x] 没找到 zygote64"); sys.exit(2)
print("[*] zygote64 pid =", zyg)
if check_only:
    print("[+] 连通性 OK"); sys.exit(0)
s = dev.attach(zyg)
sc = s.create_script(JS)
sc.on("message", lambda m, d: print("   ", m.get("payload", m)))
sc.load()
time.sleep(1.0)
try:
    sc.eternalize()
    print("[*] eternalized")
except Exception as e:
    print("[!] eternalize 失败:", e)
try:
    s.detach()
except Exception:
    pass
print("[+] 完成")
HOOKPY

cat > "$ROOTFS/root/connect.sh" <<'CONNECT'
#!/bin/bash
set -e
TH=/data/data/com.termux/files/home/.android
mkdir -p /root/.android
if [ -f "$TH/adbkey" ]; then
    cp -f "$TH/adbkey" /root/.android/adbkey
    cp -f "$TH/adbkey.pub" /root/.android/adbkey.pub
    chmod 600 /root/.android/adbkey
fi
export HOME=/root
adb kill-server >/dev/null 2>&1 || true
adb start-server >/dev/null 2>&1
adb connect 127.0.0.1:6556 >/dev/null 2>&1 || true
sleep 1
adb devices
if ! adb shell pidof svc >/dev/null 2>&1; then
    echo "[*] 启动虚拟机里的 frida-server"
    adb shell "/system/xbin/su -c 'nohup /data/local/tmp/svc -l 127.0.0.1:28100 >/dev/null 2>&1 &'" || true
    sleep 3
fi
adb forward tcp:28200 tcp:28100
python3 /root/kw_hook.py
CONNECT

chmod 755 "$ROOTFS/root/connect.sh"
info "已写入 /root/kw_hook.py 和 /root/connect.sh"

# Termux 侧一键入口
cat > "$HOME/kw.sh" <<'KWSH'
#!/data/data/com.termux/files/usr/bin/sh
export HOME=/data/data/com.termux/files/home
export TMPDIR=/data/data/com.termux/files/usr/tmp
export PATH=/data/data/com.termux/files/usr/bin:$PATH
proot-distro login debian -- bash /root/connect.sh
KWSH
# 注意：上面是单引号 heredoc，$PATH 会原样保留
chmod 755 "$HOME/kw.sh"
mkdir -p "$HOME/.termux/boot"
cp -f "$HOME/kw.sh" "$HOME/.termux/boot/kw.sh"
chmod 700 "$HOME/.termux/boot/kw.sh"
info "已生成 ~/kw.sh 和 ~/.termux/boot/kw.sh"

# ---------------------------------------------------------------- 7. 跑一次
say "7/7 立即注入 hook"
sh "$HOME/kw.sh" || warn "注入失败，见上面的报错"

say "全部完成"
cat <<TIP

  以后怎么用：
    · 平时         → 在「光速虚拟机」里点步道乐跑图标
    · 虚拟机重启后 → 打开 Termux，敲：sh ~/kw.sh

  注意事项：
    · 虚拟机「ADB 无线调试」要保持开启
    · 别 kill 虚拟机里的 /data/local/tmp/svc
    · Debian 里的 frida 必须和虚拟机里的 frida-server 主版本一致（现在都是 $FRIDA_VER）

TIP
