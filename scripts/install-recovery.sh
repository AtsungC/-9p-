#!/system/bin/sh
# install-recovery.sh — 開機自動化範本（Android init oneshot 服務用）
#
# 部署方式：
#   1) 放到 /vendor/bin/install-recovery.sh（/vendor 唯讀，先 su 0 remount）
#   2) chcon u:object_r:preinstall_exec:s0 /vendor/bin/install-recovery.sh
#   3) 建立 /vendor/etc/init/emmc-fix.rc：
#
#        service emmc-fix /vendor/bin/install-recovery.sh
#            class main
#            user root
#            group root
#            oneshot
#
#   4) 重開機驗證：cat /data/local/tmp/boot_script.log
#
# 三個坑（血淚教訓）：
#   ① SELinux 標籤一定要 preinstall_exec，否則 init 拒絕執行
#      → 每次覆蓋檔案後都要重新 chcon
#   ② oneshot 服務主程序結束後，init 會殺掉整個 process group
#      → 不能用 & 丟背景工作；要同步跑完，最後 exec 成常駐程序
#   ③ /vendor 是唯讀 → 寫入前先 su 0 remount

LOG=/data/local/tmp/boot_script.log
echo "=== boot auto $(date +%F_%T) ===" >> $LOG

# 等系統服務起來（太早執行會失敗）
sleep 25

# --- adb over Wi-Fi 保險 ---
if [ "$(getprop service.adb.tcp.port)" != "5555" ]; then
  setprop service.adb.tcp.port 5555
  stop adbd; start adbd
fi
setprop ctl.start adbd

# --- 重套封鎖規則（重試 3 次，直到規則數達標）---
for i in 1 2 3; do
  out=$(sh /data/local/tmp/block_vendor.example.sh 2>&1)
  n=$(iptables -L oem_out -n 2>/dev/null | grep -c REJECT)
  echo "try$i: $out ($n rejects)" >> $LOG
  [ "$n" -ge 30 ] && break
  sleep 20
done

# --- eMMC 調校 + 暫存清掃 ---
sh /data/local/tmp/emmc_tune.sh >> $LOG 2>&1

echo "=== boot auto done $(date +%F_%T) ===" >> $LOG

# --- 常駐監視器（主程序不結束 = init 不清場）---
exec /system/bin/sh /data/local/tmp/io_watch.sh
