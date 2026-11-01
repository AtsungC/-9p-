# 讓 eMMC 有問題的 Android TV 盒子不再隨機凍結

> **實戰紀錄：小雲盒子 9P（Amlogic S905X4 / Android 11 / 白牌 eMMC）**
> 從「35 小時內凍結 31 次」降到「一天約 3 次」，並且每一次重開機都自動恢復防護。
>
> *A practical survival guide for Android TV boxes with a failing eMMC: diagnose the silent I/O hang, find the write-storm culprits, and keep the box usable with tmpfs overlays, I/O tuning, boot-time automation and remote self-healing.*

**最後更新：2026-11-01**

---

## 目錄

0. [前置：ADB 開啟與 adbd 恢復（本機實測）](#0-前置adb-開啟與-adbd-恢復本機實測)
1. [症狀：你的盒子是不是同一種病](#1-症狀你的盒子是不是同一種病)
2. [診斷：確認是不是 eMMC](#2-診斷確認是不是-emmc)
3. [找出寫入風暴的兇手](#3-找出寫入風暴的兇手)
4. [八大優化手段（依效果排序）](#4-八大優化手段依效果排序)
5. [讓設定活過重開機：開機自動化](#5-讓設定活過重開機開機自動化)
6. [遠端監控與自癒](#6-遠端監控與自癒)
7. [實測成效](#7-實測成效)
8. [快速檢查清單](#8-快速檢查清單)
9. [適用範圍與限制](#9-適用範圍與限制)

---

## 0. 前置：ADB 開啟與 adbd 恢復（本機實測）

> 這份指南的所有指令都需要 ADB。以下每一步都在小雲盒子 9P 上實際跑過。

### 0.1 開啟 adbd（出廠時是關的）

這台出廠時 adb 是關閉的。實際做法：**在盒子上安裝終端機 app（本案例用 Termux）**，開啟後：

1. 輸入 `su`，提示符變成 `:/#`（root shell），再輸入 `id` 確認：

   ```
   uid=0(root) gid=0(root)
   ```

2. 啟動 adbd：

   ```sh
   setprop ctl.start adbd
   ```

3. 確認狀態：

   ```sh
   getprop init.svc.adbd          # 應為 running
   getprop service.adb.tcp.port   # 本案例本來就是 5555
   ```

> **adbd 不會跨重開機存活。** 每次重開機都要再 `setprop ctl.start adbd` 一次 —— 這就是第 5 節開機自動化的由來：開機 25 秒後自動執行，不用再進 Termux。

之後電腦端就能連上：

```sh
adb connect <盒子IP>:5555
adb devices
```

看到 `device` 就能用。IP 會變（本案例從 .238 變成 .114），連不上先確認 IP 沒變。

### 0.2 確認與恢復

adbd 掛掉時，同一個指令就能拉回來：

```sh
setprop ctl.start adbd
```

實測：`stop adbd` 之後看門狗執行這行，5 秒內復活（PID 3728 → 12747）。

### 0.3 自動恢復（本案例已部署）

兩層保險，重開機或 adbd 掛掉都會自己回來：

- **開機腳本**（第 5 節）：開機 25 秒後執行 `setprop ctl.start adbd`。
- **io_watch 看門狗**（第 3 節）：每 5 秒檢查 `init.svc.adbd` 是否為 `running`，不是就 `setprop ctl.start adbd`。

### 0.4 連線卡住（實測）

adbd 重啟後，電腦端常卡在 stale 的 `offline` transport，這樣解：

```sh
adb disconnect <盒子IP>:5555
adb connect <盒子IP>:5555
```

---

## 1. 症狀：你的盒子是不是同一種病

符合以下多數症狀，這份指南就適用：

- 看影片看到一半**畫面凍結**，遙控器完全沒反應，只能拔電源
- 有時放著不動也會凍，**不是高負載才會**
- 凍結**偶爾會自己恢復**（幾十秒到幾分鐘後），但多數要拔電
- 開機後**前幾分鐘特別容易**凍
- 重開機後一切正常，過幾小時又來
- 換 app、清快取、恢復原廠設定都**沒有用**
- 系統日誌裡找不到明確的軟體錯誤

> ⚠️ 這不是「記憶體不足」或「某個 app 寫得爛」。這是 **eMMC（內建儲存）在硬體層級沒有回應**，整個系統的讀寫都卡在它身上。

---

## 2. 診斷：確認是不是 eMMC

### 2.1 看核心日誌有沒有 mmc 錯誤

```sh
su 0 dmesg | grep -iE "mmc.*timeout|blk_update_request: I/O error|mmc0.*error"
```

- **有錯誤** → 驅動層看得到問題，eMMC 已經在報錯
- **完全沒有錯誤，但系統照樣凍結** → **更嚴重**：控制器層無聲掛點（silent hang）。驅動連「我出事了」都喊不出來

### 2.2 看 I/O 壓力（Linux PSI）

Android 11 / kernel 5.4 有 `/proc/pressure/io`：

```sh
cat /proc/pressure/io
```

```
some avg10=83.42 avg60=61.10 avg300=24.33 total=3058510
full avg10=62.10 avg60=44.02 avg300=18.77 total=911476
```

- `avg10` 平常應該是個位數
- **凍結瞬間會看到 50～90%**，而且 `full` 也很高（代表所有任務都在等 I/O）
- 這是最可靠的「即時體感」指標，比 load average 準得多

### 2.3 eMMC 健康指標

```sh
for f in name manfid oemid serial pre_eol_info life_time; do
  printf "%s: " "$f"; cat /sys/block/mmcblk0/device/$f 2>/dev/null
done
```

- `pre_eol_info`：
  - `0x01` = 正常
  - `0x02` = 警告（接近壽命終點）
  - `0x03` = 壽命將盡
- `life_time`：兩個十六進位值（A/B 型估計壽命），`0x01 0x01` 代表還很新
- `manfid: 0x0000df` 之類的白牌 ID = 雜牌顆粒，品質不一

> 注意：**健康指標正常不代表沒事**。本案例 `pre_eol_info=0x01`、`life_time=0x01 0x01`，看起來完全健康，但一樣會凍結 —— 問題在控制器/供電，不在抹寫壽命。

### 2.4 唯讀全碟掃描（⚠️ 會誘發凍結）

`scripts/emmc_scan.sh` 會分段讀完整顆 eMMC 並記錄每一段的耗時：

```sh
su 0 sh /data/local/tmp/emmc_scan.sh
# 進度：/data/local/tmp/emmc_scan.log
# 中止：touch /dev/stop_scan
```

**判讀方式**：正常一段 64MB 約 0.3 秒；如果某一段花 **5～13 秒**，那就是壞區/卡頓區。

> ⚠️ **警告**：這個掃描本身就是壓力測試。本案例掃到 128MB 處直接讓整台盒子凍結、需要拔電。**不要在你還要看電視的時候跑**，也不要對重要設備跑。

### 2.5 「無聲掛點」的完整特徵

本案例凍結當下的證據組合：

| 觀察點 | 凍結時的樣子 |
|---|---|
| 核心 mmc 錯誤 | **0 筆**（完全沉默） |
| PSI io some avg10 | 83% |
| PSI io full avg10 | 62% |
| `kworker` / `kblockd` 狀態 | D state，卡在 `mmc_wait_for_req_done` |
| `jbd2`（檔案系統日誌） | D state，卡在 `__wait_on_buffer` |
| 系統程序 | init、system_server 陸續卡死 |
| HDMI / 畫面中斷 | 還在流動（代表 **CPU 活著，是儲存掛了**） |

只要看到「核心零錯誤 + PSI 飆高 + kblockd 卡 D state」，就可以確定是 eMMC 硬體層。

---

## 3. 找出寫入風暴的兇手

eMMC 快壞的時候，**任何大量讀寫都是扳機**。要延長壽命、避免凍結，第一步是找出「誰在瘋狂寫」。

### 3.1 用 io_watch.sh 監視

`scripts/io_watch.sh` 每 5 秒記錄：

- 每個程序這 5 秒的讀/寫位元組數（前 5 名）
- 處於 D state（不可中斷等待）的程序與它卡在哪個核心函式
- PSI 壓力值
- 附帶 adbd 看門狗（遠端救援不會失聯）

部署：

```sh
adb push scripts/io_watch.sh /data/local/tmp/
adb shell su 0 sh /data/local/tmp/io_watch.sh &
adb shell su 0 tail -f /data/local/tmp/io_watch.log
```

### 3.2 看懂日誌

```
21:48:52 some avg10=27.10 ... full avg10=19.42 ...
  WRITE: live.home.ytv9x(1993)=40192K vold(312)=512K
  D-STATE: kworker/u9:0(1734)=mmc_wait_for_req_done jbd2/dm-9-8(285)=__wait_on_buffer
```

解讀：

- `WRITE: 某app=40192K` → **40MB/5秒** 的寫入，這就是風暴源
- `D-STATE: ... mmc_wait_for_req_done` → 核心正在等 eMMC 回應
- `jbd2 ... __wait_on_buffer` → 檔案系統日誌也被卡住
- PSI `avg10` > 20 → 已經進入危險區

### 3.3 本案例抓到的三個兇手

1. **VLive 自升級引擎**：反覆下載 32.5MB 升級包，30 秒內寫 40MB
2. **廠商 App 市場**：自動更新 APK（背景突發）
3. **Google Play 商店**：billing 迴圈 + 自動更新

三者都是「使用者沒操作時發生」的背景 I/O —— 這正是為什麼「明明沒在用也會凍」。

---

## 4. 八大優化手段（依效果排序）

### 4.1 把高頻寫入目錄掛上 tmpfs（效果最大）

讓 app 的暫存/下載/升級包**寫進 RAM**，完全不碰 eMMC：

```sh
# 目錄必須先存在（很多 app 的升級流程會自己刪掉重建）
mkdir -p /storage/emulated/0/Android/data/<PACKAGE>/files/Download
mount -t tmpfs tmpfs /storage/emulated/0/Android/data/<PACKAGE>/files/Download
chmod 0777 /storage/emulated/0/Android/data/<PACKAGE>/files/Download
```

要點：

- **先 `mkdir -p` 再掛載** —— app 可能已經把目錄刪了，掛載會失敗
- tmpfs 大小預設是 RAM 的一半，可用 `-o size=512M` 限制
- **重開機就消失** —— 對暫存/下載是優點（本來就是垃圾）
- **不要掛在需要保留資料的目錄**（例如 app 的資料庫）
- 常見目標：`Download/`、`cache/`、`download_tmp/`、`.self_upgrade/`

本案例：VLive 的升級下載 40MB/30s → 掛 tmpfs 後，同樣的下載行為不再產生 eMMC 寫入，凍結訊號消失。

### 4.2 停用自動更新（治本）

背景自動更新是白牌盒子最常見的突發 I/O 來源。

```sh
# Play 商店（若不需要）
su 0 pm disable-user --user 0 com.android.vending

# 找出廠商的自動更新服務（常見線索）
su 0 dumpsys package | grep -iE "update|upgrade"
su 0 pm list packages | grep -iE "market|store|update"
```

本案例停用 Play 商店後，billing 服務造成的喚醒/寫入迴圈消失。

> 代價：app 不會自動更新。對一台隨時會凍的盒子，這通常值得。

### 4.3 清除安裝暫存（vmdl）

`/data/app/vmdl*.tmp` 是 PackageInstaller 的安裝暫存區。失敗/中斷的更新會在這裡留下完整的 APK。

```sh
su 0 ls -la /data/app/ | grep vmdl
```

本案例堆了 **17 個 × 32.5MB ≈ 550MB** 的廢棄升級包。

**安全清掃時機：開機時。** Android 的安裝 session 不跨重開機存活，開機後這些目錄保證是垃圾：

```sh
# 放在開機腳本裡
rm -rf /data/app/vmdl*.tmp
```

> 用 `rm` 而不是 `mv`：刪除不需要讀取檔案內容，而**讀取正是壞 eMMC 的雷區**。

### 4.4 核心 I/O 調校（降低寫入爆發）

```sh
# 佇列深度減半：避免一次塞太多請求給壞掉的控制器
echo 64 > /sys/block/mmcblk0/queue/nr_requests

# 髒頁更早、更緩慢地回寫，避免「一次噴幾十 MB」
echo 2  > /proc/sys/vm/dirty_background_ratio   # 原本 5
echo 10 > /proc/sys/vm/dirty_ratio              # 原本 20
echo 2000 > /proc/sys/vm/dirty_expire_centisecs # 原本 200（20 秒）
```

說明：

- `dirty_background_ratio` 調低 → 背景回寫更早開始，單次量更小
- `dirty_ratio` 調低 → 程序不會累積大量髒頁後一次爆寫
- `dirty_expire_centisecs` 調高 → 讓資料在記憶體多待一會，平滑寫入
- 部分核心沒有 `wbt_lat_usec`（writeback throttling），可用 `ls /sys/block/mmcblk0/queue/wbt_lat_usec` 確認

### 4.5 降低整體背景負載

- **換輕量桌面**：本案例換成 [Projectivy Launcher](https://github.com/spocky/miproja1)，HOME 導向 Projectivy，原廠桌面停用。
  ```sh
  # 原廠桌面若曾被移除，先還原
  su 0 pm install-existing <原廠桌面 package>
  # 再停用（實測：重開機後 HOME 仍是 Projectivy）
  su 0 pm disable-user --user 0 <原廠桌面 package>
  ```
  ⚠️ **不要用 `pm uninstall --user 0` 移除原廠桌面。** 本案例試過：它會觸發 AMS force-stop 風暴，把 IR／composer／thermal 等 uid 1000 的 HAL 一起殺掉，整機凍結（遙控器沒反應、畫面卡死）。`pm install-existing` 是安全的還原方式。
- **關閉動畫**（減少 GPU/CPU 與寫入）：
  ```sh
  su 0 settings put global window_animation_scale 0
  su 0 settings put global transition_animation_scale 0
  su 0 settings put global animator_duration_scale 0
  ```
- **停用不用的內建 app**（尤其是會背景連網、寫日誌的）

### 4.6 日誌輪替：小心 copytruncate 陷阱

如果你的監視器一直往同一個檔案 append，日誌會無限長大，變成新的 eMMC 負擔。

**錯誤做法**（本案例踩過的坑）：

```sh
tail -n 1500 "$LOG" > /tmp/new && mv /tmp/new "$LOG"
```

問題有兩個：
1. `/tmp` 是 tmpfs，`mv` 到 `/data` 是**跨檔案系統**，某些 toybox `mv` 會直接失敗
2. 就算成功，`mv` 是 rename，**常駐的 `>> $LOG` fd 會繼續指向舊 inode** —— 日誌看起來被清空，其實還在寫一個已刪除的檔案

**正確做法：copytruncate（原地覆寫，保留 inode）**

```sh
tail -n 1500 "$LOG" > /dev/log.tmp && cat /dev/log.tmp > "$LOG" && rm -f /dev/log.tmp
```

搭配 appending 的 `>>`（O_APPEND），寫入 fd 會自動接在檔案尾端，不會斷。

**另一個隱形坑：變數命名衝突。** 本案例的監視器在解析 D-state 時寫了：

```sh
while read c p; do dline="$dline $c($p)=..." ; done < $DL
```

`c` 同時是輪替計數器 —— 每輪都被蓋成程序名稱（如 `kworker/u9:0`），`c=$((c+1))` 永遠到不了 60，**輪替碼寫得再對也永遠不會執行**。修法：換一個變數名（`dc`/`dp`）。

> 除錯心法：如果「輪替沒生效」，先確認那段程式**到底有沒有被執行**（在裡面加一行 `echo rotate-check` 到日誌），再檢查指令本身。

### 4.7 避免大量 I/O 操作

壞 eMMC 最怕「一次搬很多東西」：

- ❌ 全碟 `dd` 掃描 / 基準測試
- ❌ `fstrim`（部分廠商韌體甚至把 binary 拔掉了）
- ❌ 一次複製幾 GB 的檔案
- ❌ 在盒子上看 4K 時同時下載/更新
- ✅ 需要大量 I/O 時，**分次、分批、中間留緩衝**（例如一次搬一個目錄，中間 sleep 3 秒）

### 4.8 封鎖廠商後台與後門

本案例的盒子會在背景連向裝置後門與事件回報端點（`8989c.net`、`collectapi.google.com`、偽裝的 YouTube 域名、MQTT／Umeng／yunos 等），伴隨喚醒與寫入。實際做法是兩層：

1. **iptables**：在廠商的 `oem_out` chain 上 REJECT 具體 IP（14 條）與網域字串（20 條），共 34 條。字串規則加 `! --sport 5555`，避免擋到 adb。
2. **hosts bind-mount**：把網域指到 `127.0.0.1`。`/system/etc/hosts` 是唯讀，用 `mount -o bind /data/local/tmp/hosts /system/etc/hosts` 覆蓋；廠商 daemon 會把 hosts 重置，所以每次開機都要重建再掛。

兩者都寫進開機腳本（第 5 節）與主機端自癒（第 6 節），重開機自動補回。

⚠️ 限制：

- 字串比對只看得到明文 TCP/UDP；走 TLS／DoH 的流量未必擋得到
- 白名單要留給 VLive 直播 CDN、app store、系統 OTA，否則會把正常功能一起擋掉
- IP 與網域因機器而異，範例見 [`scripts/block_vendor.example.sh`](scripts/block_vendor.example.sh)

---

## 5. 讓設定活過重開機：開機自動化

盒子會凍結 → 一定會被拔電 → 所有 `iptables`、`mount`、sysctl 設定**全部消失**。所以必須做開機自動重套。

**adbd 也一樣** —— 重開機後就關閉，沒有自動開啟就再也連不進去。開機腳本的其中一項工作就是 `setprop ctl.start adbd`。

### 5.1 Android init service（不用 root app、不用 Magisk）

在 `/vendor/etc/init/` 建立服務（需 remount）：

```
# /vendor/etc/init/emmc-fix.rc
service emmc-fix /vendor/bin/install-recovery.sh
    class main
    user root
    group root
    oneshot
```

> 服務名稱可以自訂；`install-recovery.sh` 是本指南的腳本。

### 5.2 三個必踩的坑

1. **SELinux 標籤**
   放在 `/vendor/bin/` 的腳本必須改成可執行 domain：
   ```sh
   chcon u:object_r:preinstall_exec:s0 /vendor/bin/install-recovery.sh
   ```
   否則 init 會拒絕執行（log 出現 `avc: denied`）。
   **每次覆蓋檔案後都要重新 chcon。**

2. **oneshot 服務會殺 process group**
   不能在腳本裡用 `&` 丟背景工作 —— init 在服務主程序結束後會清掉整個 process group。
   解法：**同步跑完，最後 `exec` 成常駐程序**：
   ```sh
   exec /system/bin/sh /data/local/tmp/io_watch.sh
   ```

3. **/vendor 是唯讀的**
   寫入前先：
   ```sh
   su 0 remount
   ```

### 5.3 開機腳本範本

見 [`scripts/install-recovery.sh`](scripts/install-recovery.sh)。核心流程：

```
開機 → sleep 25（等系統服務起來）
     → 修復 adb over Wi-Fi 設定
     → 重套 iptables + hosts
     → 重掛 tmpfs
     → 清 vmdl 暫存
     → 重套核心 I/O 調校
     → exec io_watch.sh（常駐監視）
```

實測：開機約 13 秒後自動執行，34 條封鎖規則補回、監視器常駐、全程無人介入。

---

## 6. 遠端監控與自癒

### 6.1 主機端自癒腳本

`scripts/heal_box.sh` 每 5 分鐘檢查：

- 封鎖規則是否少於 N 條 → 重新套用
- 監視器 PID 是否還活著 → 重啟

即使開機自動化失敗，也能在 5 分鐘內補回來。

---

## 7. 實測成效

同一台機器、同一套使用情境：

| 日期 | 當日開機次數（≈凍結次數） |
|---|---|
| 10/17–10/19 | **31 次 / 約 35 小時** |
| 10/20 | 3 次 |
| 10/21 | 4 次 |
| 10/22 | 3 次 |
| 10/23 | **1 次**（09:32 開機後穩定 9 小時） |

其他指標：

| 指標 | 優化前 | 優化後 |
|---|---|---|
| PSI io `some avg10` 峰值 | 83% | 12.6% |
| 核心 mmc 錯誤 | 0（無聲掛點） | 0 |
| `/data/app` 廢棄暫存 | 550MB（17 個） | 0（開機自動清） |
| 重開機後防護 | 全部消失，需手動重套 | 13 秒內自動恢復 |

> **誠實聲明**：這是單一設備的觀察，不是對照實驗。改善可能同時來自多項措施疊加，也無法排除硬體狀態自身的波動。但它至少證明：**在 eMMC 已經會無聲掛點的情況下，軟體層的減壓確實能把「幾乎不能用」拉回「大致可用」。**

---

## 8. 快速檢查清單

### 診斷

- [ ] ADB 可在 5555 連上（`adb connect <IP>:5555` → `device`）
- [ ] `dmesg | grep -i mmc` 有沒有 timeout/error
- [ ] `/proc/pressure/io` 的 avg10 平常是多少、凍結時是多少
- [ ] `pre_eol_info` / `life_time` 是否正常
- [ ] 凍結時 `kworker`/`jbd2` 是否卡在 D state

### 止血

- [ ] 找出寫入最多的程序（io_watch）
- [ ] 把它的下載/暫存目錄掛 tmpfs
- [ ] 停用 Play 商店與廠商自動更新
- [ ] 封鎖廠商後台／後門（iptables + hosts）
- [ ] 清掉 `/data/app/vmdl*.tmp`
- [ ] 套用 I/O 調校（nr_requests / dirty_*）
- [ ] 換輕量桌面、關動畫

### 固化

- [ ] 開機腳本自動重套所有設定（含 SELinux 標籤）
- [ ] 主機端自癒腳本每 5 分鐘檢查
- [ ] 監視器日誌有 copytruncate 輪替

---

## 9. 適用範圍與限制

**適用：**

- Amlogic / Rockchip 等白牌 Android TV 盒子
- 有 root（`su 0`）的 userdebug 韌體
- eMMC 尚未完全死亡（還能開機、能讀寫大部分資料）

**限制：**

- 軟體優化**不能修復硬體**。eMMC 進入 `pre_eol_info=0x02/0x03`、或無聲掛點頻率持續升高時，最終仍要換硬體
- 不同廠商的 init/掛載結構不同，腳本需要按實際情況調整
- 停用自動更新會讓 app 停留在舊版
- tmpfs 會佔用 RAM，盒子 RAM 小時要限制大小

**安全提醒：**

- 修改 `/vendor`、`iptables`、`init` 服務都有把系統弄壞的風險，**先備份**
- 所有指令請先在可犧牲的設備上驗證
- 不要對別人的設備做這些操作，除非你得到明確授權
- 不要把 adb 的 5555 埠直接開到公網（等於無密碼的 root shell）

---

## 附錄：腳本

| 檔案 | 用途 |
|---|---|
| [`scripts/io_watch.sh`](scripts/io_watch.sh) | I/O 監視器（讀寫排行、D state、PSI、adbd 看門狗、日誌輪替） |
| [`scripts/emmc_scan.sh`](scripts/emmc_scan.sh) | eMMC 分段唯讀掃描（⚠️ 會誘發凍結） |
| [`scripts/emmc_tune.sh`](scripts/emmc_tune.sh) | 核心 I/O 調校 + 暫存清掃（可獨立執行） |
| [`scripts/block_vendor.example.sh`](scripts/block_vendor.example.sh) | 封鎖廠商後台/升級端點的範例（IP 需自行替換） |
| [`scripts/install-recovery.sh`](scripts/install-recovery.sh) | 開機自動化腳本範本 |
| [`scripts/heal_box.sh`](scripts/heal_box.sh) | 主機端自癒監視器範本 |

所有腳本都假設：

- 盒子已開啟 `adb over Wi-Fi`（`setprop service.adb.tcp.port 5555`）
- root 可用（`su 0`）
- 路徑為 `/data/local/tmp/`

使用前請先閱讀每個腳本開頭的註解，把 `<PACKAGE>`、IP、路徑換成你自己的。

---

## 授權

MIT（可自由使用、修改、再散布；風險自負）
