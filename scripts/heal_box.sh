#!/bin/zsh
# heal_box.sh — 主機端自癒監視器範本
#
# 每 5 分鐘檢查盒子：
#   1) 封鎖規則是否 < 30 條 → 重套
#   2) io_watch 監視器是否還活著 → 重啟
#
# 用途：開機自動化若失敗（或盒子凍結後自行恢復但設定掉了），
#       最多 5 分鐘內會補回來。
#
# 用法：zsh heal_box.sh &   （建議搭配 nohup / 背景執行）
# 修改：DEV 改成你的盒子 IP

DEV="192.168.1.50:5555"
IP="192.168.1.50"
DIR="$HOME/tvbox"          # 放腳本/watchdog 的目錄
LOG="$DIR/heal_box.log"

while true; do
  adb connect $IP >/dev/null 2>&1
  sleep 2
  if adb -s $DEV get-state 2>/dev/null | grep -q device; then
    rejects=$(adb -s $DEV shell "su 0 sh -c 'iptables -L oem_out -n 2>/dev/null | grep -c REJECT'" 2>/dev/null | tr -d '\r' | tail -1)
    watch=$(adb -s $DEV shell "su 0 sh -c 'kill -0 \$(cat /dev/io_watch.lock 2>/dev/null) 2>/dev/null && echo alive || echo dead'" 2>/dev/null | tr -d '\r' | tail -1)
    now=$(date '+%F %T')

    if [[ "$rejects" =~ ^[0-9]+$ ]] && [[ "$rejects" -lt 30 ]]; then
      out=$(adb -s $DEV shell "su 0 sh /data/local/tmp/block_vendor.example.sh" 2>&1 | tr -d '\r')
      echo "$now rejects=$rejects → 補套: $out" >> $LOG
    fi

    if [[ "$watch" != "alive" ]]; then
      adb -s $DEV shell "su 0 sh -c 'rm -f /dev/io_watch.lock; nohup sh /data/local/tmp/io_watch.sh >/dev/null 2>&1 &'" >/dev/null 2>&1
      echo "$now io_watch 沒在跑 → 已重啟" >> $LOG
    fi
  else
    echo "$(date '+%F %T') 盒子連不上" >> $LOG
  fi
  sleep 300
done
