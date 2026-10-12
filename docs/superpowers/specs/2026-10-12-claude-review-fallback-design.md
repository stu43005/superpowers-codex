# Codex 額度不足時自動降級為 Claude 審查 — 設計規格

## 背景與目標

目前所有 reviewer 都透過 `scripts/dispatch.sh` 交給 codex companion 執行。codex 的訂閱額度以「5 小時視窗」與「週視窗」計算，週額度一旦提前耗盡，後續整週的審查流程都會因 `ERROR` 卡住。

本設計新增 **Claude 審查後端**：`review-*.sh` 的呼叫方式與輸出格式維持不變，在派工前先查詢 codex 使用額度，若目前用量超過「依週重置時間均勻分配 + 5%」的節奏線（或任一視窗已逼近上限），則該批 reviewer 自動改以 `claude -p` 執行。

成功標準：

- agent 端呼叫 `review-brainstorm.sh` / `review-impl.sh` / `review-final.sh` 的方式、參數、`=== Summary ===` 的 reviewer 列格式完全不變。
- 額度充足時行為與現況完全相同（走 codex，Summary 無新增列）。
- 自動降級時 Summary 明確標示降級原因，且原因文字清楚指出是 **codex** 的額度。
- 額度查詢失敗不阻斷審查（回退 codex 並警告）。

## 已驗證的外部行為

- `codex app-server`（codex-cli 0.153.4）以 stdio JSON-RPC 提供 `account/rateLimits/read`；實測回應 `result.rateLimits` 含 `primary` / `secondary`（各自 `usedPercent`、`windowDurationMins`、`resetsAt`（Unix 秒））與 `rateLimitReachedType`。視窗位置不固定：曾觀察到 `primary` 為 300 分鐘、`secondary` 為 10080 分鐘，也曾觀察到僅有 `primary` 為 10080 分鐘、`secondary` 為 `null`。呼叫順序為 `initialize`（`params.clientInfo` 含 `name`、`version`）→ `initialized` notification → `account/rateLimits/read`。
- `claude -p`（Claude Code 2.1.296）可由 stdin 讀入 prompt；搭配 `--permission-mode dontAsk --tools "Read,Grep,Glob,Bash"` 時，唯讀 Bash（`git rev-parse`）被放行、寫入操作（`touch`）被拒絕（皆已實測）。
- `claude -p` 在訂閱登入下扣用與互動 session 相同的訂閱額度；環境中存在 `ANTHROPIC_API_KEY` 時 `-p` 模式一律改用 API key 計費。

## 架構

```
review-*.sh ──> review-batch-lib.sh: batch_run
                   │ _batch_select_backend
                   │   ├─ SUPERPOWERS_REVIEW_BACKEND=codex|claude → 直接採用
                   │   └─ auto → node scripts/codex-quota.mjs → "<backend>\t<reason>"
                   ├─ backend=codex  → scripts/dispatch.sh        (現有，不變)
                   └─ backend=claude → scripts/dispatch-claude.sh (新)
                                         └─ scripts/dispatch-prompt-lib.sh (由 dispatch.sh 抽出的共用函式)
```

一個 batch 只查詢一次額度，整批 reviewer 走同一個後端。

### 單元一：`scripts/codex-quota.mjs`（額度查詢與判斷）

**職責**：查詢 codex 額度並輸出建議後端。不讀 `SUPERPOWERS_REVIEW_BACKEND`（該開關由 batch 層處理）。

**查詢**：啟動 `codex app-server`（執行檔路徑預設由 PATH 解析，可由環境變數 `CODEX_QUOTA_CODEX_BIN` 覆寫，作為測試接點），依序送出 `initialize`、`initialized`、`account/rateLimits/read`，讀到 `id` 為該請求的回應後終止子程序。整體逾時 15 秒，逾時即終止子程序並視為查詢失敗。

**判斷規則**（依序，第一條成立者決定結果）：

1. `rateLimitReachedType` 非 `null` → `claude`，reason：`auto-downgraded: codex rate limit reached [<rateLimitReachedType>]`
2. `primary`、`secondary` 中任一非 `null` 視窗 `usedPercent >= 95` → `claude`，reason：`auto-downgraded: codex <label> usage <U>% reached 95% cap`，其中 `<label>` 為 `weekly`（`windowDurationMins == 10080`）、`5h-window`（`== 300`），其他長度寫 `<N>m-window`。
3. 取 `windowDurationMins == 10080` 的視窗為週視窗，令 `W = 10080 × 60`：
   - `elapsed = clamp((now − (resetsAt − W)) / W, 0, 1)`
   - `pace = elapsed × 100 + 5`
   - `usedPercent > pace` → `claude`，reason：`auto-downgraded: codex weekly usage <U>% exceeds even-pace limit <P>%`（`<P>` 取整數，四捨五入）
4. 以上皆不成立（含不存在週視窗的情況）→ `codex`，reason：`codex quota ok`。

**查詢失敗**（找不到 codex、子程序異常結束、逾時、回應含 `error`、`result.rateLimits` 缺失或欄位型別不符）→ `codex`，reason：`codex quota unavailable: <簡短原因>`。

**輸出契約**：stdout 恰好一行 `<codex|claude>\t<reason>`；exit code 恆為 0（失敗已在內部回退為 `codex`）。

### 單元二：`scripts/dispatch-prompt-lib.sh`（共用函式）

由 `dispatch.sh` 抽出、行為不變的共用函式：`err`、`die`、暫存檔追蹤與清理（`_PRIVATE`、`cleanup`、`mk_private`）、`is_file_path_key`、`require_no_newline`、`subst_into`、`assert_no_residual`、`require_file`，以及 `task` 子命令的 prompt 組裝（參數解析、`--set` 驗證、`--report-file` 私有複本、placeholder 代入與殘留檢查）。`dispatch.sh` 改為 source 此檔，對外行為（含 `dispatch.test.sh` 全部案例）不變。此抽取為獨立 commit，在新功能之前完成。

### 單元三：`scripts/dispatch-claude.sh`（Claude 後端）

**介面**：與 `dispatch.sh` 完全相同的子命令與參數：`task --prompt <file> [--report-file <file>] [--set K=V]... [--dry-run]`、`review --base <ref> [--dry-run]`、`adversarial --base <ref> --focus <file> [--dry-run]`。

**prompt 來源**：

| 子命令 | prompt |
|---|---|
| `task` | 與 `dispatch.sh` 相同的渲染結果（共用單元二） |
| `review` | `scripts/claude-prompts/code-review.md`，代入 `[BASE]`；指示審查 `git diff [BASE]...HEAD` 的程式品質問題，輸出散文，不輸出 `Status:` / `Verdict:` 行（與 codex 內建 review 一致，Summary 為 `(prose — 見全文)`） |
| `adversarial` | `scripts/claude-prompts/adversarial-review.md`：沿用 codex companion `adversarial-review` 模板的立場、攻擊面、finding 門檻與 grounding 規則，改為 Markdown 輸出，每個 finding 含檔案與行號、信心度、建議，最後一行恰為 `Verdict: approve` 或 `Verdict: needs-attention`。先代入 `[BASE]` 並執行殘留 placeholder 檢查，**之後**才把 focus 檔內容代入 `[USER_FOCUS]`，避免 focus 文字中的方括號被誤判為殘留 placeholder |

**執行**：渲染後的 prompt 以 stdin 餵入：

```
claude -p --permission-mode dontAsk --tools "Read,Grep,Glob,Bash" \
  --disallowedTools "mcp__*" --disable-slash-commands \
  --no-session-persistence --output-format text
```

- 不傳 `--model`，沿用使用者的 Claude Code 預設模型。
- `claude` 執行檔預設由 PATH 解析，可由 `DISPATCH_CLAUDE_BIN` 覆寫（測試接點）。找不到時 `die`（exit ≠ 0），不回頭改走 codex。
- 環境存在非空 `ANTHROPIC_API_KEY` 時，於 stderr 印出警告 `dispatch-claude: ANTHROPIC_API_KEY is set; claude -p will bill the API key`，不主動 unset。
- 於前景執行，stdout 原樣串流，exit code 傳遞 `claude` 本身的結果。
- `--dry-run`：印出將執行的指令與渲染後的 prompt，不執行 `claude`。

**reviewer prompt 措辭**：`skills/brainstorming/spec-document-reviewer-prompt.md`、`skills/subagent-driven-development/{spec-reviewer,task-coverage,task-seam,spec-coverage}-prompt.md` 開頭的 "executed by the codex companion" 改為 "executed as an independent read-only reviewer"，使兩個後端皆適用。

### 單元四：`review-batch-lib.sh` 整合

新增 `_batch_select_backend`，於 `batch_run` 的 output guard 與 `--max-parallel` 驗證之後、建立暫存目錄之前呼叫：

| `SUPERPOWERS_REVIEW_BACKEND` | 行為 |
|---|---|
| 未設定或 `auto` | 執行 `node "<scripts>/codex-quota.mjs"` 並解析 `<backend>\t<reason>`；node 不存在、腳本 exit ≠ 0 或輸出不符契約 → `codex`，reason `codex quota unavailable: quota probe failed` |
| `codex` | 走 codex，不查詢額度 |
| `claude` | 走 claude，不查詢額度 |
| 其他值 | stderr 印 `review-batch: SUPERPOWERS_REVIEW_BACKEND must be auto|codex|claude, got: <值>`，`batch_run` 回傳 1，不派工 |

- backend 為 `codex` 時 job 以 `BATCH_DISPATCH_SH` 執行（現況）；為 `claude` 時改以 `BATCH_DISPATCH_CLAUDE_SH` 執行。`BATCH_DISPATCH_CLAUDE_SH` 與 `BATCH_DISPATCH_SH` 同為測試接點，三支 wrapper 以 `${BATCH_DISPATCH_CLAUDE_SH:-$SCRIPT_DIR/dispatch-claude.sh}` 設定預設值並匯出。
- 額度腳本路徑同樣可由 `BATCH_QUOTA_PROBE`（預設 `<scripts>/codex-quota.mjs`）覆寫，作為測試接點。
- **stderr 訊息**：自動降級時印 `review-batch: <reason>`；查詢失敗時印 `review-batch: <reason>; using codex`。
- **Summary**：僅在 `auto` 判斷結果為降級成 claude 時，於 `=== Summary ===` 下方第一行加入 `- backend: claude (<reason>)`，例如 `- backend: claude (auto-downgraded: codex weekly usage 62% exceeds even-pace limit 45%)`。走 codex 或手動指定 `claude` 時不輸出此列。

### 單元五：SKILL.md 與 README

- `skills/brainstorming/SKILL.md` 與 `skills/subagent-driven-development/SKILL.md` 解讀 `=== Summary ===` 的段落各加一句：`- backend:` 列為資訊列，不是 reviewer，不參與迴圈的 ERROR / verdict 判斷。agent 呼叫方式不變。
- `README.md` 新增一節說明自動降級規則、`SUPERPOWERS_REVIEW_BACKEND` 開關、`ANTHROPIC_API_KEY` 計費注意事項。

## 錯誤處理

| 情況 | 結果 |
|---|---|
| 額度查詢失敗 | 走 codex，stderr 警告 |
| 降級為 claude 但 `claude` 不存在或執行失敗 | 該 reviewer Summary 為 `ERROR (tool failed, exit N)`，agent 依現有規則重跑整個 wrapper；重跑時重新查詢額度 |
| `SUPERPOWERS_REVIEW_BACKEND` 值不合法 | wrapper exit 1，不派工 |
| output guard 觸發（輸出被導向 /dev/null） | 維持 exit 3，且在查詢額度之前返回 |

## 測試

所有自動化測試皆不需網路，不呼叫真實的 codex 或 claude。

- **`scripts/codex-quota.test.sh`**：以 `CODEX_QUOTA_CODEX_BIN` 注入假 `codex`，依情境輸出預先準備的 JSON-RPC 回應；`resetsAt` 依當下時間計算以控制 `elapsed`。案例：低於節奏線 → `codex`；高於節奏線 → `claude`（reason 全字串比對）；5h 視窗 95% → `claude`；週視窗 95% → `claude`；`rateLimitReachedType` 非 null → `claude`；僅有非週視窗且未達上限 → `codex`；回應含 `error`、欄位缺失、假 codex 不回應（逾時）、執行檔不存在 → `codex` 且 reason 以 `codex quota unavailable:` 開頭；exit code 恆為 0。
- **`scripts/dispatch-claude.test.sh`**：以 `DISPATCH_CLAUDE_BIN` 注入假 `claude`，記錄 argv 與 stdin。驗證三個子命令渲染的 prompt、唯讀 flags 齊全、未傳 `--model`、`ANTHROPIC_API_KEY` 警告、`claude` 不存在時 exit ≠ 0、`--dry-run` 不執行 `claude`、focus 文字含方括號時不觸發殘留檢查。
- **`scripts/review-batch-lib.test.sh` 擴充**：`SUPERPOWERS_REVIEW_BACKEND` 為 `codex` / `claude` / 不合法值；`auto` 降級時以 `BATCH_DISPATCH_CLAUDE_SH` 派工且出現 `backend:` 列、未降級時以 `BATCH_DISPATCH_SH` 派工且沒有該列（以 `BATCH_QUOTA_PROBE` 注入假額度腳本）；額度腳本失敗或輸出不符契約時回退 codex 並警告。既有案例的共用 setup 設定 `SUPERPOWERS_REVIEW_BACKEND=codex`，使其不查詢真實額度。
- **`scripts/dispatch.test.sh`**：抽出共用 lib 後維持全綠。
- **端到端手動驗證**：以 `SUPERPOWERS_REVIEW_BACKEND=claude` 實際執行一次 `review-brainstorm.sh`，確認兩個 reviewer 均產出可解析的 Summary 列。

## Non-goals / Accepted limitations

- 不做 per-job 後端選擇；同一批 reviewer 一律走同一後端。
- 不追蹤或限制 Claude 端的使用額度。
- 不快取額度查詢結果；每次 `batch_run` 查詢一次（約數秒）。
- 不支援以 API key 登入 codex 的額度查詢（查不到即回退 codex）。
