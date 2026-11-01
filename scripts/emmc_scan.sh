#!/system/bin/sh
# emmc_scan.sh — eMMC 分段唯讀掃描
#
# 用途：找出 eMMC 上「讀取特別慢」的區段（壞區/控制器卡頓區）
# 原理：每次讀 64MB，記錄耗時；正常約 0.3 秒，超過 2 秒就記一筆慢段
#
# 用法：
#   adb push emmc_scan.sh /data/local/tmp/
#   adb shell su 0 sh /data/local/tmp/emmc_scan.sh &
#   adb shell su 0 tail -f /data/local/tmp/emmc_scan.log
#
# 中止：
#   adb shell su 0 touch /dev/stop_scan
#
# ⚠️ 警告：本腳本本身就是 I/O 壓力測試。
#    對已經會凍結的 eMMC，掃描可能直接讓整台機器死當（本案例掃到 128MB 就凍結）。
#    請不要在重要的時候執行，也不要對別人的設備執行。

DEV=/dev/block/mmcblk0
LOG=/data/local/tmp/emmc_scan.log
CHUNK=64   # MB

SECTORS=$(cat /sys/block/mmcblk0/size 2>/dev/null)   # 512B 單位
MB=$((SECTORS/2048))
B0=$(dmesg | grep -ciE "mmc.*timeout|blk_update_request: I/O error")
t0=$(cat /proc/uptime | cut -d. -f1)
echo "=== scan start $(date +%F_%T) size=${MB}MB chunk=${CHUNK}MB mmc錯誤基線=$B0 ===" > $LOG

i=0; slow=0; worst=0
while [ $((i*CHUNK)) -lt $MB ] && [ ! -f /dev/stop_scan ]; do
  s=$(cat /proc/uptime | cut -d. -f1)
  dd if=$DEV of=/dev/null bs=1M count=$CHUNK skip=$((i*CHUNK)) 2>/dev/null
  e=$(cat /proc/uptime | cut -d. -f1)
  dt=$((e-s))
  [ $dt -gt $worst ] && worst=$dt
  if [ $dt -ge 2 ]; then
    echo "慢段: offset=$((i*CHUNK))MB 花${dt}秒 ($(date +%H:%M:%S))" >> $LOG
    slow=$((slow+1))
  fi
  i=$((i+1))
  [ $((i%16)) -eq 0 ] && echo "進度: $((i*CHUNK))/${MB}MB ($(date +%H:%M:%S))" >> $LOG
done

t1=$(cat /proc/uptime | cut -d. -f1)
B1=$(dmesg | grep -ciE "mmc.*timeout|blk_update_request: I/O error")
echo "=== scan done $(date +%F_%T) 總花$((t1-t0))秒 慢段$slow 最慢單段${worst}秒 mmc錯誤基線$B0→$B1 ===" >> $LOG
