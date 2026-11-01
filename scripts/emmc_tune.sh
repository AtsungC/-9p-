#!/system/bin/sh
# emmc_tune.sh — eMMC 減壓調校 + 暫存清掃
#
# 用途：降低寫入爆發、清理廢棄安裝暫存。可獨立執行，也可放進開機腳本。
# 用法：adb push emmc_tune.sh /data/local/tmp/ && adb shell su 0 sh /data/local/tmp/emmc_tune.sh
#
# 所有設定在重開機後會消失 —— 請放進開機自動化（見 install-recovery.sh）。

echo "=== emmc_tune $(date +%F_%T) ==="

# 1) 佇列深度減半：避免一次塞太多請求給不穩定的控制器
#    （先確認節點存在，不同核心/裝置名稱可能是 mmcblk0/mmcblk1）
Q=/sys/block/mmcblk0/queue
if [ -e $Q/nr_requests ]; then
  echo 64 > $Q/nr_requests 2>/dev/null && echo "nr_requests = $(cat $Q/nr_requests)"
fi

# 2) 髒頁回寫調溫和：更早開始、單次更小、不要一次噴幾十 MB
echo 2    > /proc/sys/vm/dirty_background_ratio   2>/dev/null
echo 10   > /proc/sys/vm/dirty_ratio              2>/dev/null
echo 2000 > /proc/sys/vm/dirty_expire_centisecs   2>/dev/null
echo "dirty: bg=$(cat /proc/sys/vm/dirty_background_ratio) ratio=$(cat /proc/sys/vm/dirty_ratio) expire=$(cat /proc/sys/vm/dirty_expire_centisecs)"

# 3) 清理廢棄的 PackageInstaller 暫存
#    安裝 session 不跨重開機存活 → 開機後 vmdl*.tmp 一定是垃圾
#    用 rm（不讀內容）：讀取是壞 eMMC 的雷區
if [ -d /data/app ]; then
  n=$(ls -d /data/app/vmdl*.tmp 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] && { rm -rf /data/app/vmdl*.tmp; echo "清掉 $n 個 vmdl*.tmp"; }
fi

echo "=== done ==="
