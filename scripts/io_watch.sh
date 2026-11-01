#!/system/bin/sh
# io_watch.sh v8 — Android TV 盒子 I/O 監視器
#
# 每 5 秒（I/O 風暴期 2 秒）記錄：
#   - 這一輪讀/寫最多的前 5 個程序
#   - 處於 D state（不可中斷等待）的程序，以及它卡在哪個核心函式
#   - PSI I/O 壓力（/proc/pressure/io）
#   - adbd 看門狗：遠端 adb 掛掉會自動拉回
#   - tmpfs 保險：升級/下載目錄若被 app 刪掉重建，會自動重掛
#   - 日誌輪替：copytruncate（保留 inode，append fd 不會斷）
#
# 用法：
#   adb push io_watch.sh /data/local/tmp/
#   adb shell su 0 sh /data/local/tmp/io_watch.sh &
#   adb shell su 0 tail -f /data/local/tmp/io_watch.log
#
# 建議搭配開機自動化（見 install-recovery.sh），重開機後自動常駐。

# ======== 設定區：依你的盒子修改 ========
LOG=/data/local/tmp/io_watch.log
# 要監看/自動重掛的 tmpfs 目錄（空白分隔）。留空 = 不啟用。
TMPFS_DIRS="/storage/emulated/0/Android/data/<PACKAGE>/files/Download"
# =======================================

PREV=/dev/io_prev
CUR=/dev/io_cur
DELTA=/dev/io_delta
TOPR=/dev/io_top_r
TOPW=/dev/io_top_w
DL=/dev/io_dlist

# 單一實例鎖
[ -f /dev/io_watch.lock ] && kill -0 $(cat /dev/io_watch.lock) 2>/dev/null && exit 0
echo $$ > /dev/io_watch.lock

echo "=== io_watch v8 start $(date +%F_%T) ===" >> $LOG

# 抓每個程序的 read_bytes / write_bytes
snap() { awk '/^read_bytes/{sub(/[^0-9]*/,"");r=$0} /^write_bytes/{sub(/[^0-9]*/,"");print FILENAME,r,$0}' /proc/[0-9]*/io 2>/dev/null | sed 's|/proc/||;s|/io||' | sort -k1; }

snap > $PREV
c=0

while true; do
  # --- adbd 看門狗 ---
  if [ "$(getprop init.svc.adbd)" != "running" ]; then
    echo "  ADBD: down → ctl.start adbd ($(date +%H:%M:%S))"
    setprop ctl.start adbd
  fi
  if [ "$(getprop service.adb.tcp.port)" != "5555" ]; then
    echo "  ADBD: port=$(getprop service.adb.tcp.port) → 設回 5555"
    setprop service.adb.tcp.port 5555
    stop adbd; start adbd
  fi

  # --- tmpfs 保險：app 可能把目錄刪掉重建，掛載會掉 ---
  for d in $TMPFS_DIRS; do
    [ -n "$d" ] || continue
    mkdir -p "$d" 2>/dev/null
    mount | grep -q " $d " || { mount -t tmpfs tmpfs "$d" 2>/dev/null && chmod 0777 "$d"; }
  done

  # --- 日誌輪替（v8）：每 60 圈（約 5 分鐘）檢查，超過 1.5MB 就留最後 1500 行 ---
  # 注意：不能用 mv！跨檔案系統會失敗，且 rename 會讓常駐 >> $LOG 的 fd 指向舊 inode。
  # copytruncate 才能讓 O_APPEND 的 fd 繼續寫同一個 inode。
  c=$((c+1))
  if [ $c -ge 60 ]; then
    c=0
    if [ -f $LOG ] && [ $(wc -c < $LOG 2>/dev/null) -gt 1536000 ]; then
      tail -n 1500 $LOG > /dev/io_log.tmp && cat /dev/io_log.tmp > $LOG && rm -f /dev/io_log.tmp
    fi
  fi

  # --- 取樣 ---
  snap > $CUR
  f10=$(sed -n 2p /proc/pressure/io 2>/dev/null | sed 's/.*avg10=\([0-9.]*\).*/\1/')
  awk 'NR==FNR { a[$1]=$2; b[$1]=$3; next } ($1 in a) { print $1, $2-a[$1], $3-b[$1] }' $PREV $CUR > $DELTA
  awk '$2>0 {print $1, int($2/1024)"K"}' $DELTA | sort -k2nr | head -5 > $TOPR
  awk '$3>0 {print $1, int($3/1024)"K"}' $DELTA | sort -k2nr | head -5 > $TOPW

  # D state 程序（排除已知的良性等待執行緒）
  awk '$3=="D" {gsub(/[()]/,"",$2); print $2, FILENAME}' /proc/[0-9]*/stat 2>/dev/null | sed 's|/proc/||;s|/stat||' > $DL

  rline=""; wline=""; dline=""
  while read p kb; do n=$(cat /proc/$p/comm 2>/dev/null); rline="$rline $n($p)=${kb}"; done < $TOPR
  while read p kb; do n=$(cat /proc/$p/comm 2>/dev/null); wline="$wline $n($p)=${kb}"; done < $TOPW
  # 注意：變數名稱不要用 c（會蓋掉輪替計數器，導致輪替永遠不觸發）
  while read dc dp; do dline="$dline $dc($dp)=$(cat /proc/$dp/wchan 2>/dev/null)"; done < $DL

  echo "$(date +%H:%M:%S) $(sed -n 1p /proc/pressure/io 2>/dev/null) $(sed -n 2p /proc/pressure/io 2>/dev/null)"
  [ -n "$rline" ] && echo "  READ:$rline"
  [ -n "$wline" ] && echo "  WRITE:$wline"
  [ -n "$dline" ] && echo "  D-STATE:$dline"

  mv $CUR $PREV

  # 風暴期（PSI > 3）加密取樣
  hi=$(awk -v v="$f10" 'BEGIN{print (v>3)?1:0}')
  [ "$hi" = 1 ] && sleep 2 || sleep 5
done >> $LOG
