# Review wrapper 輸出重新導向防護 — 設計規格

## 背景與問題

`review-brainstorm.sh`、`review-impl.sh`、`review-final.sh` 是 agent 在 `brainstorming` 與
`subagent-driven-development` 中呼叫的 reviewer wrapper。wrapper 的 stdout 包含每位 reviewer
的完整 findings、`[stderr excerpt]` 與 `=== Summary ===`，caller 必須讀取完整輸出才能正確判讀
（特別是 Summary 為 `(prose — 見全文)` 的 reviewer，只能從全文判斷 blocking finding）。

兩份 SKILL.md 的 Invocation discipline 目前只有一句「Do NOT redirect, pipe, or `tee` the
output.」，措辭抽象，未列出 agent 實際會犯的寫法。agent 仍可能寫出 `>/dev/null`、
`2>/dev/null`、`| grep Status`、`| tail -50` 等指令，導致拿不到完整輸出，或在
`>/dev/null` 時白白跑完整輪 codex review 卻什麼都看不到。

## 目標

1. 文字規範：把禁令改寫為硬性、可檢查的規則——wrapper 指令列只能有 wrapper 本身與其參數，
   不得出現任何重新導向或 pipe，並列出具體反例與理由。
2. 腳本防護：wrapper 在 stdout 或 stderr 被導向 `/dev/null` 時，於派出任何 reviewer 之前
   拒絕執行，並以專屬 exit code 回報。

## 設計

### 1. 腳本防護（`scripts/review-batch-lib.sh`）

新增內部函式 `_batch_guard_output`，在 `batch_run` 的最開頭呼叫（早於
`_batch_validate_max_parallel`、早於建立 temp dir 與派出任何 dispatch job）。三支 wrapper
都以 `batch_run` 作為最後一行，因此只改這一處即涵蓋全部 wrapper，wrapper 本身不需修改。

偵測方式：使用 bash 內建 `test` 的 `-ef`（比對 device 與 inode）：

- `[ /dev/stdout -ef /dev/null ]` 成立 → stdout 被導向 `/dev/null`
- `[ /dev/stderr -ef /dev/null ]` 成立 → stderr 被導向 `/dev/null`

此行為已在 macOS（bash 3.2，BSD）實測：`>/dev/null` 時成立；`| cat` 與 `> 一般檔案` 時不成立；
`2>/dev/null` 時 stderr 判斷成立。

行為：

| stdout 是 /dev/null | stderr 是 /dev/null | 動作 |
|---|---|---|
| 否 | 否 | 正常繼續 |
| 是 | 否 | 錯誤訊息寫到 stderr，`batch_run` 回傳 3 |
| 否 | 是 | 錯誤訊息寫到 stdout，`batch_run` 回傳 3 |
| 是 | 是 | 無處可寫訊息；直接回傳 3 |

- 錯誤訊息為單行英文，前綴 `review-batch:`，內容說明 wrapper 的輸出被導向 `/dev/null`、
  必須移除所有重新導向與 pipe 後重跑。
- 回傳 3 時不建立 temp dir、不安裝 trap、不呼叫 `$BATCH_DISPATCH_SH`。
- wrapper 在 `set -euo pipefail` 下以 `batch_run` 作為最後一個指令，`batch_run` 回傳 3 即
  使 wrapper 以 exit 3 結束。exit 3 目前未被 wrapper 或 `batch_run` 使用（現有非零值為
  參數錯誤的 1、reviewer 工具失敗的 1、訊號中斷的 130），故可作為專屬代碼。

不偵測的情況：`| grep`、`| tail`、`> 檔案`、`tee` 等無法可靠偵測——Claude Code Bash tool
本身的 stdout 可能就是 pipe 或檔案，無法與 agent 自行加上的 pipe 區分。這些情況僅由文字
規範約束。

### 2. 文字規範（兩份 SKILL.md）

修改 `skills/brainstorming/SKILL.md` 與 `skills/subagent-driven-development/SKILL.md` 的
**Invocation discipline** 區塊，將現有「Do NOT redirect, pipe, or `tee` the output.」一條
替換為以下內容（兩份措辭一致，僅 wrapper 名稱依該 skill 而異）：

- **The command line is the wrapper and its arguments — nothing else.** 不得出現任何
  重新導向或 pipe 運算子：`>`、`>>`、`2>`、`2>&1`、`&>`、`|`、`tee`；不得以 `$(...)` 或
  反引號包裹；不得以 `&&`、`||`、`;` 串接其他指令。
- 明確列出禁止的反例：`>/dev/null`、`2>/dev/null`、`&>/dev/null`、`| grep Status`、
  `| grep -A`、`| tail -50`、`| head`、`> out.txt`、`| tee out.txt`。
- 理由：過濾或丟棄輸出會遺失 findings 全文與 `[stderr excerpt]`，`(prose — 見全文)` 的
  reviewer 也無從判讀；輸出過長或逾時時，Claude Code 會自動將完整輸出存檔，之後分段讀取
  該檔即可，不需要自行過濾。
- **Exit 3**：wrapper 以 exit 3 結束代表其 stdout 或 stderr 被導向 `/dev/null`，此時沒有
  任何 reviewer 被執行；移除所有重新導向後以相同參數重跑。

原有的 `run_in_background`、exit-code probe、逾時處理三條維持不變。

### 3. 測試（`scripts/review-batch-lib.test.sh`）

以既有的 stub dispatch（透過 `BATCH_DISPATCH_SH` 注入）新增案例，stub 被呼叫時寫入 marker
檔以判斷是否有派出 job：

1. stdout 導向 `/dev/null` → `batch_run` 回傳 3，marker 不存在，stderr 含 `review-batch:`
   錯誤訊息。
2. stderr 導向 `/dev/null` → 回傳 3，marker 不存在，stdout 含錯誤訊息。
3. stdout 與 stderr 皆導向 `/dev/null` → 回傳 3，marker 不存在。
4. stdout 為 pipe 或一般檔案（未導向 `/dev/null`）→ 正常執行，marker 存在，輸出含
   `=== Summary ===`。

測試須依 TDD 順序：先寫測試並在未修改的 `review-batch-lib.sh` 上看到案例 1–3 失敗，再實作。

## 非目標 / Non-goals / Accepted limitations

- 不偵測 pipe、一般檔案重新導向或 `tee`（原因見上）；這些僅靠文字規範。
- 不變更 wrapper 的輸出格式、Summary 格式或既有 exit code 語意。
- 不修改 `scripts/dispatch.sh`。

## 驗收標準

- 三支 wrapper 在 `>/dev/null`、`2>/dev/null`、`&>/dev/null` 下皆以 exit 3 結束且不派出
  reviewer。
- 正常呼叫（含 Claude Code 以 pipe 或檔案承接輸出）行為不變。
- `review-batch-lib.test.sh` 全數通過，`shellcheck` 對修改過的腳本無新增警告。
- 兩份 SKILL.md 的 Invocation discipline 含上述硬性規則、反例清單與 exit 3 說明。
