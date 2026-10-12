# Codex 額度不足時自動降級為 Claude 審查 — 設計規格

## 背景與目標

目前所有 reviewer 都透過 `scripts/dispatch.sh` 交給 codex companion 執行。codex 的訂閱額度以「5 小時視窗」與「週視窗」計算，週額度一旦提前耗盡，後續整週的審查流程都會因 `ERROR` 卡住。

本設計新增 **Claude 審查後端**：`review-*.sh` 的呼叫方式與輸出格式維持不變，在派工前先查詢 codex 使用額度，若目前用量超過「依週重置時間均勻分配 + 5%」的節奏線（或任一視窗已逼近上限），則該批 reviewer 自動改以 `claude -p` 執行。

成功標準：

- agent 端呼叫 `review-brainstorm.sh` / `review-impl.sh` / `review-final.sh` 的方式、參數、`=== Summary ===` 的 reviewer 列格式完全不變。
- 額度充足時行為與現況完全相同（走 codex，Summary 無新增列）。
- 自動降級時 Summary 明確標示降級原因，且原因文字清楚指出是 **codex** 的額度。
- 額度查詢失敗不阻斷審查（回退 codex 並警告）。

另併入一項與降級功能無相依的流程約束（單元六）：審查迴圈中逐條向使用者揭露新 finding，以及任何需要使用者決策時先以文字詳述問題再發問。

## 已驗證的外部行為

- `codex app-server`（codex-cli 0.153.4）以 stdio JSON-RPC 提供 `account/rateLimits/read`；實測回應 `result.rateLimits` 含 `primary` / `secondary`（各自 `usedPercent`、`windowDurationMins`、`resetsAt`（Unix 秒））與 `rateLimitReachedType`。視窗位置不固定：曾觀察到 `primary` 為 300 分鐘、`secondary` 為 10080 分鐘，也曾觀察到僅有 `primary` 為 10080 分鐘、`secondary` 為 `null`。呼叫順序為 `initialize`（`params.clientInfo` 含 `name`、`version`）→ `initialized` notification → `account/rateLimits/read`。此請求每次都即時向 ChatGPT 後端查詢，而非回傳本機快取（openai/codex `codex-rs/app-server/src/request_processors/account_processor.rs` 的 `get_account_rate_limits_response` 呼叫 `BackendClient::get_rate_limits_with_reset_credits()`；讀取的是 main 分支原始碼），因此降級期間 codex 無請求也不會讀到過期快照。以 API key 登入 codex 時此請求回傳錯誤 `chatgpt authentication required to read rate limits`。
- `claude -p`（Claude Code 2.1.296）可由 stdin 讀入 prompt（已實測）。
- 唯讀保證的權限模式（皆已實測）：`--permission-mode dontAsk` 會放行符合使用者 `permissions.allow` 規則的指令——以 `--settings '{"permissions":{"allow":["Bash(touch:*)"]}}'` 測試時 `touch` 確實被執行，因此 `dontAsk` 下 reviewer 能否寫入取決於使用者設定，不採用。`--permission-mode plan` 在同一條 allow 規則下仍拒絕 `touch`，同時放行唯讀 Bash（`git diff --stat`、`git log`），且輸出為一般審查文字（不會改成產出計畫），故採用 `plan`。
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

**查詢**：啟動 `codex app-server`（執行檔路徑預設由 PATH 解析，可由環境變數 `CODEX_QUOTA_CODEX_BIN` 覆寫，作為測試接點），依序送出 `initialize`、`initialized`、`account/rateLimits/read`，讀到 `id` 為該請求的回應後終止子程序。整體逾時 15 秒，逾時即終止子程序並視為查詢失敗。子程序以獨立 process group 啟動（`detached: true`）；不論取得回應或逾時，皆以 `process.kill(-pid)` 終止整個 process group（含 app-server 可能衍生的孫程序），印出結果行後立即 `process.exit(0)`，**不等待** pipe 關閉或子程序退出事件，避免殘留的孫程序持有 pipe 使腳本無法結束。子程序的 stderr 一律丟棄，不轉發到 wrapper 的 stderr；失敗原因只以簡短文字寫入 reason。

**判斷規則**（依序，第一條成立者決定結果）：

1. `rateLimitReachedType` 非 `null` → `claude`，reason：`auto-downgraded: codex rate limit reached [<rateLimitReachedType>]`
2. `primary`、`secondary` 中任一非 `null` 視窗 `usedPercent >= 95` → `claude`，reason：`auto-downgraded: codex <label> usage <U>% reached 95% cap`，其中 `<label>` 為 `weekly`（`windowDurationMins == 10080`）、`5h-window`（`== 300`），其他長度寫 `<N>m-window`。
3. 取 `windowDurationMins == 10080` 的視窗為週視窗（依 `primary`、`secondary` 順序取第一個符合者），令 `W = 10080 × 60`：
   - `elapsed = clamp((now − (resetsAt − W)) / W, 0, 1)`
   - `pace = elapsed × 100 + 5`，`P = round(pace)`（四捨五入為整數）
   - `usedPercent > P` → `claude`，reason：`auto-downgraded: codex weekly usage <U>% exceeds even-pace limit <P>%`。判斷與顯示使用同一個整數 `P`，使 reason 中的「超過」永遠與顯示的數字一致（例如 pace 5.6 → `P = 6`，用量 6% 不降級）
4. 規則 1、2 不成立且回應中不存在週視窗 → `codex`，reason：`codex quota unavailable: no weekly (10080m) window in response`。以 `unavailable` 歸類，使 batch 層照常在 stderr 印出警告，避免 codex 改版改變視窗長度時節奏線規則無聲失效。
5. 以上皆不成立 → `codex`，reason：`codex quota ok`。

**欄位驗證（每條規則只驗證自己用到的欄位）**：

- 規則 1 只需 `rateLimitReachedType`：值為非空字串即成立；`null` 或缺失視為不成立；其他型別視為不成立並繼續後續規則。它不受任何視窗欄位是否合法影響。
- 規則 2 逐一檢查 `primary`、`secondary`：視窗為 `null` 或缺失則略過；`usedPercent` 不是有限數值的視窗略過；`windowDurationMins` 只用於產生 `<label>`，不是正整數時 label 寫 `unknown-window`。
- 規則 3 只有在找到 `windowDurationMins == 10080` 的視窗時套用，且該視窗的 `usedPercent` 與 `resetsAt` 皆須為有限數值；任一不合法則跳過規則 3，改以規則 4 的 reason 回報 `codex quota unavailable: weekly window has invalid usedPercent/resetsAt`。
- 規則 4「不存在週視窗」包含 `primary`、`secondary` 皆為 `null` 或缺失的情況。

**查詢失敗**（找不到 codex、子程序異常結束、逾時、回應含 `error`、`result` 或 `result.rateLimits` 不是物件）→ `codex`，reason：`codex quota unavailable: <簡短原因>`。個別欄位不合法不屬於整體查詢失敗，依上述逐條規則處理。

**輸出契約**：stdout 恰好一行 `<codex|claude>\t<reason>`；exit code 恆為 0（失敗已在內部回退為 `codex`）。

### 單元二：`scripts/dispatch-prompt-lib.sh`（共用函式）

由 `dispatch.sh` 抽出、行為不變的共用函式：`err`、`die`、暫存檔追蹤與清理（`_PRIVATE`、`cleanup`、`mk_private`）、`is_file_path_key`、`require_no_newline`、`subst_into`、`assert_no_residual`、`require_file`，以及 `task` 子命令的 prompt 組裝（參數解析、`--set` 驗證、`--report-file` 私有複本、placeholder 代入與殘留檢查）。`assert_no_residual` 新增選用的第二參數：以空白分隔的「允許保留的 placeholder 名稱」清單，預設為空；`dispatch.sh` 一律不傳此參數，行為與抽取前完全相同，只有 `dispatch-claude.sh` 的 `adversarial` 傳入 `USER_FOCUS`。`dispatch.sh` 改為 source 此檔，對外行為（含 `dispatch.test.sh` 全部案例）不變。此抽取為獨立 commit，在新功能之前完成。

### 單元三：`scripts/dispatch-claude.sh`（Claude 後端）

**介面**：與 `dispatch.sh` 完全相同的子命令與參數：`task --prompt <file> [--report-file <file>] [--set K=V]... [--dry-run]`、`review --base <ref> [--dry-run]`、`adversarial --base <ref> --focus <file> [--dry-run]`。

**prompt 來源**：

| 子命令 | prompt |
|---|---|
| `task` | 與 `dispatch.sh` 相同的渲染結果（共用單元二） |
| `review` | `scripts/claude-prompts/code-review.md`，代入 `[BASE]`；指示審查 `git diff [BASE]...HEAD` 的程式品質問題（正確性、錯誤處理、可維護性、測試覆蓋），並採與 adversarial prompt 相同的 finding 門檻與 grounding 規則：只回報有證據的實質問題、每個 finding 附檔案與行號與嚴重度（blocking / non-blocking）、不得臆造檔案或行為、不回報純風格偏好；輸出散文，不輸出 `Status:` / `Verdict:` 行（與 codex 內建 review 一致，Summary 為 `(prose — 見全文)`） |
| `adversarial` | `scripts/claude-prompts/adversarial-review.md`：參照 codex companion 1.0.6 的 `prompts/adversarial-review.md`（位於 `~/.claude/plugins/cache/openai-codex/codex/1.0.6/`）**改寫**而非複製——原模板依賴 companion 組裝的 `{{REVIEW_INPUT}}` 與 JSON schema 輸出，無法直接沿用；保留其立場、攻擊面、finding 門檻與 grounding 規則，改為由 reviewer 自行執行 `git diff [BASE]...HEAD` 取得變更（三點、自 merge-base 起算，與 `review` 子命令及 codex companion 帶 `--base` 時的 `${baseRef}...HEAD` 一致；見 companion 1.0.6 `scripts/lib/git.mjs:74`），改為 Markdown 輸出，每個 finding 含檔案與行號、信心度、建議，最後一行恰為 `Verdict: approve` 或 `Verdict: needs-attention`。先代入 `[BASE]`，再執行殘留 placeholder 檢查——此檢查**將 `[USER_FOCUS]` 視為唯一允許的保留 placeholder**（其他任何 `[A-Z_][A-Z0-9_]*` 形式的殘留仍 `die`）；檢查通過**之後**才把 focus 檔內容代入 `[USER_FOCUS]`，代入後不再做殘留檢查，避免 focus 文字中的方括號被誤判為殘留 placeholder |

**執行**：渲染後的 prompt 以 stdin 餵入：

```
claude -p --permission-mode plan --strict-mcp-config \
  --tools "Read,Grep,Glob,Bash" --disallowedTools "mcp__*" \
  --disable-slash-commands --no-session-persistence --output-format text \
  --settings '{"disableAllHooks":true}' --max-turns 200 \
  --append-system-prompt "<REVIEWER_SYSTEM_NOTE>"
```

`<REVIEWER_SYSTEM_NOTE>` 為 `dispatch-claude.sh` 內的固定字串：

> You are a single-turn, read-only reviewer invoked non-interactively. Ignore any plan-mode workflow instructions (do not write plan files, do not call ExitPlanMode or AskUserQuestion, do not launch subagents). Perform the review requested in the user prompt and end your reply exactly as the prompt's output contract requires.

- `--permission-mode plan` 會在 reviewer 的 context 注入 plan-mode 工作流程指示（寫 plan 檔、以 ExitPlanMode 結束等），`<REVIEWER_SYSTEM_NOTE>` 用來覆蓋這些指示，使輸出遵守 prompt 的 `Status:` / `Verdict:` 契約（以此組 flags 實測，最後一行正確輸出 `Status: OKAY`）。
- `--strict-mcp-config` 且不帶 `--mcp-config`：實測 stream-json init 事件的 `mcp_servers` 由 12 個變為 0 個，reviewer 不啟動任何 MCP server，也不注入其 instructions。
- 唯讀保證由兩部分組成：
  - **工具呼叫**由 `--permission-mode plan` 擋下：即使使用者的 `permissions.allow` 放行了寫入類指令或 `review-*.sh`（可能造成遞迴審查），reviewer 也無法執行。不得改用 `dontAsk` 或 `bypassPermissions`。
  - **hooks** 由 `--settings '{"disableAllHooks":true}'` 關閉：hooks 不受 permission mode 管控，會在 reviewer 程序內執行使用者設定的任意指令。實測以 `--settings` 注入會寫檔的 SessionStart / Stop hook 時，未關閉則兩者皆執行，`disableAllHooks:true` 則兩者皆不執行。必須關閉的具體理由之一：codex plugin 帶有 Stop hook `stop-review-gate`（逾時 900 秒），使用者若以 `/codex:setup` 啟用，每個 claude reviewer 結束時都會觸發一次 codex review，與降級目的相反。plugin 自帶 hooks 是否同樣被關閉，列入端到端手動驗證。
- `--max-turns 200`：限制單一 reviewer 的 agentic 輪數，避免 reviewer 無限探索而使 batch 無限期阻塞、持續消耗與主 session 共用的 Claude 額度。實測達到上限時 `claude -p` 以 exit 1 結束，並在 **stdout** 輸出 `Error: Reached max turns (<N>)`；因此 Summary 呈現 `ERROR (tool failed, exit 1)`，且該行原因出現在該 reviewer 的 `## <label>` 段落中，agent 可據此判斷這不是偶發失敗。取 200 而非較小值，是因為 `spec-coverage` / `task-coverage` 要求讀完每個變更檔，大型實作的 final review 在 50 輪內可能完成不了。
- `--tools "Read,Grep,Glob,Bash"` 已限制內建工具，`--disallowedTools "mcp__*"` 與 `--strict-mcp-config` 再排除 MCP 工具與 server：三者刻意重疊作為多層防護，任何一層失效時其餘仍有效。
- **模型**：三個子命令皆接受選用參數 `--model <alias>`，有給時原樣轉傳給 `claude -p --model <alias>`；未給時不傳 `--model`（沿用使用者的 Claude Code 預設模型，僅供手動直接呼叫 `dispatch-claude.sh` 時使用）。經 batch 派工時一律由單元四依 reviewer 帶入模型。`claude -p --model` 接受 `sonnet`、`opus`、`haiku` 等別名（CLI reference 已確認）。
- `claude` 執行檔預設由 PATH 解析，可由 `DISPATCH_CLAUDE_BIN` 覆寫（測試接點）。找不到時 `die`（exit ≠ 0），不回頭改走 codex。
- 環境存在非空 `ANTHROPIC_API_KEY` 時，於 stderr 印出警告 `dispatch-claude: ANTHROPIC_API_KEY is set; claude -p will bill the API key`，不主動 unset。
- 於前景執行，stdout 原樣串流，exit code 傳遞 `claude` 本身的結果。
- `--dry-run`：印出將執行的指令與渲染後的 prompt，不執行 `claude`。

**reviewer prompt 措辭**：`skills/brainstorming/spec-document-reviewer-prompt.md`、`skills/subagent-driven-development/{spec-reviewer,task-coverage,task-seam,spec-coverage}-prompt.md` 開頭的 "executed by the codex companion" 改為 "executed as an independent read-only reviewer"，使兩個後端皆適用。

### 單元四：`review-batch-lib.sh` 整合

新增 `_batch_select_backend`，於 `batch_run` 的 output guard 與 `--max-parallel` 驗證之後、建立暫存目錄之前呼叫：

| `SUPERPOWERS_REVIEW_BACKEND` | 行為 |
|---|---|
| 未設定、空值或 `auto` | 執行 `node "<scripts>/codex-quota.mjs"` 並解析 `<backend>\t<reason>`；node 不存在、腳本 exit ≠ 0 或輸出不符契約 → `codex`，reason `codex quota unavailable: quota probe failed` |
| `codex` | 走 codex，不查詢額度 |
| `claude` | 走 claude，不查詢額度 |
| 其他值 | stderr 印 `review-batch: SUPERPOWERS_REVIEW_BACKEND must be auto|codex|claude, got: <值>`，`batch_run` 回傳 1，不派工 |

- backend 為 `codex` 時 job 以 `BATCH_DISPATCH_SH` 執行（現況）；為 `claude` 時改以 `BATCH_DISPATCH_CLAUDE_SH` 執行。`BATCH_DISPATCH_CLAUDE_SH` 與 `BATCH_DISPATCH_SH` 同為測試接點，三支 wrapper 以 `${BATCH_DISPATCH_CLAUDE_SH:-$SCRIPT_DIR/dispatch-claude.sh}` 設定預設值並匯出。
- **依 reviewer 指定 claude 模型**：claude reviewer 與主 session 共用同一份 Claude 訂閱額度，為降低消耗，每個 reviewer 依其特性指定模型——需要對抗式深度推理者用 `opus`，清單式比對或程式品質檢查者用 `sonnet`；不使用 `haiku`（所有 reviewer 都須讀檔並判斷符合與否，漏判風險過高）。
  - 機制：新增 `batch_claude_model <alias>`，作用於**最近一次** `batch_add` 註冊的 job，記錄於 engine 內部的 per-job 陣列；未呼叫者視為未指定。`batch_run` 僅在後端為 `claude` 時，把 `--model <alias>` 附加到該 job 的 `dispatch-claude.sh` argv；後端為 `codex` 時完全忽略，`dispatch.sh` 的 argv 與現況相同。
  - 三支 wrapper 的分配：

    | wrapper | reviewer | 特性 | 模型 |
    |---|---|---|---|
    | `review-brainstorm.sh` | structural-completeness | 照清單檢查 spec 缺漏與一致性 | `sonnet` |
    | `review-brainstorm.sh` | design-soundness | 對抗式挑戰設計 | `opus` |
    | `review-impl.sh` | spec-compliance | 逐條比對 spec 與實作 | `sonnet` |
    | `review-impl.sh` | code-quality | diff 程式品質 | `sonnet` |
    | `review-impl.sh` | task-coverage | task 每一項是否做到 | `sonnet` |
    | `review-impl.sh` | task-seam | 新舊程式碼銜接 | `sonnet` |
    | `review-final.sh` | final-adversarial | 對整份實作做對抗式審查 | `opus` |
    | `review-final.sh` | spec-coverage | 讀完所有變更檔比對 spec | `sonnet` |
- **claude 後端的並行數**：claude reviewer 與執行中的 agent session 共用同一份 Claude 訂閱額度，為避免並行過多拖垮主 session，後端為 `claude`（不論自動降級或手動指定）且呼叫端**未明確指定** `--max-parallel` 時，`MAX_PARALLEL` 改為 `2`。「是否明確指定」由 `batch_init` 在套用預設值 5 **之前**記錄（`MAX_PARALLEL` 原本是否已設定，含 `--max-parallel` 與從呼叫端環境繼承的值；後者同樣視為明確指定，此為預期行為）；明確指定時一律尊重呼叫端的值。改為 `2` 的動作在 `_batch_validate_max_parallel` 的驗證與上限截斷**之後**執行。後端為 `codex` 時預設維持 5。
- 額度腳本路徑同樣可由 `BATCH_QUOTA_PROBE`（預設 `<scripts>/codex-quota.mjs`）覆寫，作為測試接點。
- **API key 計費警告**：後端為 `claude`（自動降級或手動指定）且環境中 `ANTHROPIC_API_KEY` 非空時，batch 層在派工前於自身 stderr 印出 `review-batch: ANTHROPIC_API_KEY is set; claude reviewers will bill the API key`。此警告必須由 batch 層印出：job 的 stderr 只在 rc≠0 時才以 `[stderr excerpt]` 呈現，`dispatch-claude.sh` 自身的同一警告在 reviewer 成功時不會被看到（該警告仍保留，供手動直接呼叫 `dispatch-claude.sh` 時使用）。
- **stderr 訊息**：自動降級時印 `review-batch: <reason>`；查詢失敗（reason 以 `codex quota unavailable:` 開頭）時印 `review-batch: <reason>; using codex`；額度正常（`codex quota ok`）或手動指定 `codex` / `claude` 時不印任何訊息。
- **Summary**：僅在 `auto` 判斷結果為降級成 claude 時，於 `=== Summary ===` 下方第一行加入 `- backend: claude (<reason>)`，例如 `- backend: claude (auto-downgraded: codex weekly usage 62% exceeds even-pace limit 45%)`。走 codex 或手動指定 `claude` 時不輸出此列。

### 單元五：SKILL.md 與 README

- 每一處解讀 `=== Summary ===` 的 caller control-flow 段落各加一句——`skills/brainstorming/SKILL.md` 的 spec review 段落，以及 `skills/subagent-driven-development/SKILL.md` 的 per-task review（`review-impl.sh`）與 final review（`review-final.sh`）兩處段落：`- backend:` 列為資訊列，不是 reviewer，不參與迴圈的 ERROR / verdict 判斷。agent 呼叫方式不變。
- **ERROR 重跑的例外（重跑必定失敗時改為詢問）**：兩份 SKILL.md 中「任一 reviewer 為 ERROR → 重跑整個 wrapper」的規則加上例外——若該 reviewer 的 `## <label>` 段落或 `[stderr excerpt]` 顯示重跑也必定無法成功的失敗（例如找不到 `claude` / `codex` 執行檔、`Error: Reached max turns`、未登入或認證失敗、額度用盡如 `You've hit your usage limit`），agent 不重跑，改依單元六規則二先以文字詳述失敗原因（並提示使用者可設定 `SUPERPOWERS_REVIEW_BACKEND` 改用另一個後端），再以 `AskUserQuestion` 詢問使用者。判斷由 agent 依輸出內容進行，不設連續次數門檻。`skills/subagent-driven-development/SKILL.md` 的 Continuous execution 停止條件清單同步加入此情況。
- `README.md` 新增一節說明自動降級規則、`SUPERPOWERS_REVIEW_BACKEND` 開關、`ANTHROPIC_API_KEY` 計費注意事項。開關的設定方式須寫明：agent 依 SKILL 呼叫規範不得在 wrapper 指令前加環境變數前綴，因此此開關由**使用者**設定——於啟動 Claude Code 前在 shell 匯出，或寫入 Claude Code `settings.json` 的 `env`（實測：以 `--settings '{"env":{...}}'` 啟動的 session，其 Bash 指令可讀到該變數；新啟動的 session 會套用）。並說明典型使用時機：降級後 claude reviewer 持續失敗而 agent 停下來詢問時，使用者可設為 `codex` 強制改回。

### 單元六：審查結果揭露與決策前詳述規則（SKILL.md）

此單元與降級功能無相依，為使用者於本 spec 審查期間提出、併入本 spec 一併實作的獨立流程約束；實作時為獨立 commit（類型 `feat:`，因其新增 skill 的行為約束）。

**規則一：逐條揭露新 finding。** 每一輪拿到審查結果、完成 finding 驗證後，在修正、跳過或升級任何 finding 之前，agent 必須在回覆中為**每一條新的** finding 各給使用者**至少一句**問題描述（每條 finding 獨立成句，說明它指出什麼問題；「一句」是最低要求而非上限）。不得把多條 finding 合併成一句簡短帶過。「新的」指本輪首次出現、或雖屬既有 ledger topic 但提出了新論點或新證據的 finding；與既有 topic 完全相同且無新證據的重複 finding 可只在 ledger 中呈現。直接修正、判定 `refuted`、或因 `adjudicated-reject` 而跳過的 finding 同樣要揭露。

**規則二：決策前先以文字詳述。** 任何需要使用者決策的 `AskUserQuestion` 呼叫之前，agent 必須先在回覆文字中詳細描述該問題：發生的情境、影響、各選項的做法與代價（以及 agent 的建議，若有）。`AskUserQuestion` 的選項說明不得是使用者第一次看到該問題的地方。

**套用位置**（描述目標狀態，措辭由實作決定）：

- `skills/brainstorming/SKILL.md`：
  - 規則一加入 spec review 迴圈——**Verify findings before acting** 段落與 **Round loop** 中「讀取並驗證每條 finding、更新 ledger」的步驟之後、修正 finding 之前。
  - 規則二加入 escape valve 的 escalation 說明（**At escalation, present …** 段落），並以一句通則涵蓋本 skill 內所有 `AskUserQuestion` 使用處。
- `skills/subagent-driven-development/SKILL.md`：
  - 規則一加入 **Verify Findings Before Acting** 段落，使其同時涵蓋 per-task review（`review-impl.sh`）與 final review（`review-final.sh`）兩處迴圈。
  - 規則二以一句通則涵蓋本 skill 內所有 `AskUserQuestion` 使用處（含 refuted 升級、Manual-Check Disposition、Mid-Implementation Spec Edits、Resume Mode 等）。
- Checklist / Process Flow 中與審查迴圈相關的摘要句，若列出迴圈步驟，同步補上「逐條揭露新 finding」一項，使摘要與正文一致。

## 錯誤處理

| 情況 | 結果 |
|---|---|
| 額度查詢失敗 | 走 codex，stderr 警告 |
| 降級為 claude 但 `claude` 不存在或執行失敗 | 該 reviewer Summary 為 `ERROR (tool failed, exit N)`，agent 依現有規則重跑整個 wrapper；重跑時重新查詢額度 |
| `SUPERPOWERS_REVIEW_BACKEND` 值不合法 | wrapper exit 1，不派工 |
| output guard 觸發（輸出被導向 /dev/null） | 維持 exit 3，且在查詢額度之前返回 |

## 測試

所有自動化測試皆不需網路，不呼叫真實的 codex 或 claude。

- **`scripts/codex-quota.test.sh`**：以 `CODEX_QUOTA_CODEX_BIN` 注入假 `codex`，依情境輸出預先準備的 JSON-RPC 回應；`resetsAt` 依當下時間計算以控制 `elapsed`。案例：低於節奏線 → `codex`；高於節奏線 → `claude`（reason 全字串比對）；5h 視窗 95% → `claude`；週視窗 95% → `claude`；`rateLimitReachedType` 非 null → `claude`；僅有非週視窗（含未知長度視窗）且未達上限 → `codex` 且 reason 為 `codex quota unavailable: no weekly (10080m) window in response`；兩個視窗皆為 10080 分鐘時取 `primary`；回應含 `error`、欄位缺失、`rateLimitReachedType` 非 null 但視窗欄位不合法（例如 `resetsAt` 為 null）→ 仍為 `claude`；週視窗 `resetsAt` 為 null 且未達上限 → `codex` 且 reason 為 `codex quota unavailable: weekly window has invalid usedPercent/resetsAt`；假 codex 不回應（逾時）、假 codex 回應後衍生一個持有 stdout pipe 的長時間孫程序（腳本仍須在逾時內印出結果並結束，且孫程序被終止）、執行檔不存在 → `codex` 且 reason 以 `codex quota unavailable:` 開頭；exit code 恆為 0。
- **`scripts/dispatch-claude.test.sh`**：以 `DISPATCH_CLAUDE_BIN` 注入假 `claude`，記錄 argv 與 stdin。驗證三個子命令渲染的 prompt、唯讀與隔離 flags 齊全（含 `--permission-mode plan`、`--strict-mcp-config`、`--settings '{"disableAllHooks":true}'`、`--max-turns 200`、`--append-system-prompt` 帶 `<REVIEWER_SYSTEM_NOTE>` 全文）、給 `--model <alias>` 時原樣轉傳而未給時不傳 `--model`、`ANTHROPIC_API_KEY` 警告、`claude` 不存在時 exit ≠ 0、`--dry-run` 不執行 `claude`、focus 文字含方括號時不觸發殘留檢查。
- **`scripts/review-batch-lib.test.sh` 擴充**：`SUPERPOWERS_REVIEW_BACKEND` 為 `codex` / `claude` / 不合法值；`auto` 降級時以 `BATCH_DISPATCH_CLAUDE_SH` 派工且出現 `backend:` 列、未降級時以 `BATCH_DISPATCH_SH` 派工且沒有該列（以 `BATCH_QUOTA_PROBE` 注入假額度腳本）；額度腳本失敗或輸出不符契約時回退 codex 並警告；後端為 `claude` 且 `ANTHROPIC_API_KEY` 非空時 batch stderr 含計費警告（job 成功時仍可見）、為空或後端為 `codex` 時不含；後端為 `claude` 時各 job 的 argv 帶有該 reviewer 以 `batch_claude_model` 指定的 `--model`、後端為 `codex` 時 argv 不含 `--model`；三支 wrapper 的每個 reviewer 皆依分配表指定模型；後端為 `claude` 且未指定 `--max-parallel` 時同時執行的 job 不超過 2 個、明確指定時依指定值、後端為 `codex` 時預設仍為 5；stderr 訊息依情境比對：降級時印 reason、查詢失敗時印 `…; using codex`、額度正常與手動指定時 stderr 不含 `review-batch:` 訊息。既有案例的共用 setup 設定 `SUPERPOWERS_REVIEW_BACKEND=codex`，使其不查詢真實額度。
- **`scripts/dispatch.test.sh`**：抽出共用 lib 後維持全綠。
- **端到端手動驗證**：以 `SUPERPOWERS_REVIEW_BACKEND=claude` 實際執行一次 `review-brainstorm.sh`，確認兩個 reviewer 均產出可解析的 Summary 列；並在此執行期間確認 plugin 自帶 hooks 未被觸發（例如 codex plugin 的 SessionStart / Stop hook 未產生其 job 狀態紀錄）。另以 `SUPERPOWERS_REVIEW_BACKEND=codex` 實際執行一次 `review-brainstorm.sh`（codex 額度可用時），確認 reviewer prompt 開頭措辭變更後，codex 後端仍產出可解析的 Summary 列。

## Non-goals / Accepted limitations

- 不做 per-job 後端選擇；同一批 reviewer 一律走同一後端。
- 不追蹤或限制 Claude 端的使用額度。
- 不快取額度查詢結果；每次 `batch_run` 查詢一次（約數秒）。
- 不支援以 API key 登入 codex 的額度查詢（查不到即回退 codex）。
- **Concern**：降級為 claude 後，若 `claude -p` 持續失敗（例如 Claude 訂閱被限流），每輪 reviewer 皆為 `ERROR`，SKILL 的「ERROR 即重跑」規則可能無限重跑；在節奏線（規則 3）降級時 codex 其實仍有額度。**Decision**：不實作 batch 內自動回退 codex 重跑。**Rationale**（使用者裁定）：ERROR 訊息與 stderr 摘錄本來就會輸出，agent 一定會讀取輸出，本身就有能力判斷要直接重跑或詢問使用者；必要時可設 `SUPERPOWERS_REVIEW_BACKEND=codex` 手動改回。此判斷能力由單元五的「ERROR 重跑的例外」規則落實於 SKILL.md（重跑必定失敗時改為詢問使用者）。
- **Concern**：每輪各自判斷後端且無遲滯，用量貼近門檻時同一審查迴圈內可能在 codex 與 claude 之間交替，不同模型的 finding 集合不同，可能影響 brainstorming ledger 的連續輪數計數與迴圈收斂。**Decision**：不實作 sticky 後端或遲滯。**Rationale**（使用者裁定）：節奏線每小時僅上升約 0.6%，只有用量剛好貼著門檻時才會切換，實際影響有限，不值得引入跨輪次狀態。
- **Concern**：額度查詢失敗（例如 codex 升版後 schema 漂移）時會回退 codex，訊號只寫在 stderr，Summary 無對應列；週額度耗盡時可能每輪 ERROR 而看不出是降級機制失效。**Decision**：不在 Summary 加列，維持僅自動降級時輸出 `backend:` 列。**Rationale**（使用者裁定）：查詢失敗時 wrapper 已在 stderr 印出 `review-batch: codex quota unavailable: …; using codex`，agent 讀取輸出時一樣看得到，Summary 再加一列是重複。
- **Concern**：節奏線 `elapsed × 100 + 5` 在週期剛重置時僅約 5%，且對集中於工作日使用的使用者，正常節奏必然快於 7 天均分，可能使降級成為常態，週末剩餘的 codex 額度在重置時浪費。**Decision**：不調整節奏線公式。**Rationale**（使用者裁定）：「依週重置時間均勻分配、允許超用 5%」即為需求本身——用量超前進度時讓出 codex 正是預期行為。
- **Concern**：batch 層同步執行 `codex-quota.mjs` 時沒有外層逾時；若 node 程序本身卡死（連腳本內的計時器都不觸發），wrapper 會在派工前無限期阻塞。**Decision**：不在 batch 層加外層 watchdog。**Rationale**（使用者裁定）：腳本內已有 15 秒逾時、process group 終止與立即 `process.exit`，孫程序持有 pipe 的情境已排除；node 本身卡死屬極低機率，而 bash 3.2 無 `timeout` 指令，自寫 watchdog 的成本不成比例。
- **Concern**：`design-soundness` 與 `final-adversarial` 固定使用 `--model opus`，無覆寫開關也無替代路徑；若使用者的 Claude 方案無法使用 Opus 或 Opus 用量耗盡，這兩個 reviewer 每次皆 `ERROR`，而規則 1、2 觸發的降級下改回 codex 也無法恢復。**Decision**：不新增模型覆寫開關或自動改用預設模型重試。**Rationale**（使用者裁定）：使用者環境中 `--model opus` 已實測可用；模型不可用時錯誤訊息會出現在 reviewer 段落中，agent 可據此停下來詢問使用者。
- Claude 後端未使用 `--bare`（訂閱登入下無法使用），因此 reviewer 仍會載入使用者的 CLAUDE.md 等設定（hooks 已由 `disableAllHooks` 關閉），可能影響其回覆語言或風格；MCP 由 `--strict-mcp-config` 排除，`Status:` / `Verdict:` 行由各 prompt 的輸出契約與 `<REVIEWER_SYSTEM_NOTE>` 約束。模型是否每次都遵守輸出契約無法以封閉測試保證，由端到端手動驗證確認；若某輪輸出缺少 verdict 行，Summary 會呈現 `(prose — 見全文)`，由 agent 依現有規則讀全文判斷。
