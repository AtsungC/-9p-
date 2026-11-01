#!/system/bin/sh
# block_vendor.example.sh — 封鎖廠商後台/自動升級端點（範例）
#
# ⚠️ 這是「範例」，IP 與網域是從本案例的機器抓出來的，換一台機器就不一樣。
#    請先用 io_watch.sh 觀察你的盒子在跟誰通訊，再自行替換。
#
# 原理：
#   1) iptables 在廠商的 oem_out chain 上 REJECT 指定 IP 與網域字串
#   2) 用 bind-mount 蓋掉 /system/etc/hosts，把網域指到 127.0.0.1
#   3) 每次重開機都要重套（寫進開機腳本）
#
# 為什麼要封：
#   廠商的「自動升級」引擎會反覆下載完整 APK（本案例一次 32.5MB），
#   在背景造成突發寫入 → 觸發壞 eMMC 凍結。封掉後訊號明顯減少。

IPS="203.0.113.10 203.0.113.11"          # ← 改成你抓到的 IP
STRINGS="example-vendor.com example-cdn.net"  # ← 改成你抓到的網域

# 找到正確的 chain（不同廠商可能是 oem_out / oem / fw_OUTPUT）
CHAIN=oem_out
iptables -L $CHAIN -n >/dev/null 2>&1 || { echo "找不到 $CHAIN chain，請先確認"; exit 1; }

for ip in $IPS; do
  iptables -C $CHAIN -d $ip -j REJECT 2>/dev/null || iptables -I $CHAIN -d $ip -j REJECT
done

for s in $STRINGS; do
  # TCP/UDP 都封；! --sport 5555 避免擋掉 adb
  iptables -C $CHAIN -m string --string "$s" --algo bm -p tcp ! --sport 5555 -j REJECT 2>/dev/null \
    || iptables -I $CHAIN -m string --string "$s" --algo bm -p tcp ! --sport 5555 -j REJECT
  iptables -C $CHAIN -m string --string "$s" --algo bm -p udp -j REJECT 2>/dev/null \
    || iptables -I $CHAIN -m string --string "$s" --algo bm -p udp -j REJECT
done

# hosts（注意：有些韌體的 /system 是唯讀，mount -o bind 需要 root）
if ! grep -q "example-vendor" /data/local/tmp/hosts 2>/dev/null; then
  printf '127.0.0.1 localhost\n::1 ip6-localhost\n127.0.0.1 example-vendor.com example-cdn.net\n' > /data/local/tmp/hosts
  chmod 644 /data/local/tmp/hosts
fi
mount | grep -q "/system/etc/hosts" && umount /system/etc/hosts 2>/dev/null
mount -o bind /data/local/tmp/hosts /system/etc/hosts

# ------------------------------------------------------------------
# tmpfs：把高頻寫入目錄搬到 RAM（最重要的防凍手段之一）
# 目錄要先 mkdir —— 很多 app 的升級流程會把目錄刪掉重建，掛載會失敗
# ------------------------------------------------------------------
TMPFS_DIRS="/storage/emulated/0/Android/data/<PACKAGE>/files/Download \
            /storage/emulated/0/Android/data/<PACKAGE>/files/download_tmp \
            /storage/emulated/0/Android/data/<PACKAGE>/files/.self_upgrade"

for d in $TMPFS_DIRS; do
  [ "$d" = "<PACKAGE>" ] && continue
  mkdir -p "$d" 2>/dev/null
  mount | grep -q " $d " || { mount -t tmpfs tmpfs "$d" 2>/dev/null && chmod 0777 "$d"; }
done

echo "done: $(iptables -L $CHAIN -n | grep -c REJECT) rejects, hosts mounted, tmpfs ok"
