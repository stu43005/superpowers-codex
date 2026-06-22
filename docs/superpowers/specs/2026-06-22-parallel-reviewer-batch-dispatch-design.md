# 設計規格：並行 reviewer 批次派發層（精簡版）

## 1. 背景與目標

三個技能（brainstorming、writing-plans、subagent-driven-development）在 review
迴圈的每一輪都要派發多個 reviewer。現行做法要求 agent 為每個 reviewer 各發一個
`run_in_background: true` 的獨立 Bash call，逐一等待 completion notification、逐一把
stdout 讀進 context。reviewer 多、輪數多時造成大量「啟動／等待／讀取」來回與 token 消耗。

**目標**：在現有 `scripts/dispatch.sh` 之上加一層「批次派發」，讓 agent **一次呼叫**即可
並行啟動一組 reviewer、等待全部完成、把結果彙整回傳。把原本 N 次 Bash 來回壓成 1 次。

**與 agent 的對接面，只有兩個**：

1. **stdout 彙整格式**（§4.4）——依序串接每個 reviewer 的全文，最後加一段 Status 彙整；
2. **退出碼**（§4.5）——只反映工具層面是否有失敗。

**不持久化任何中繼檔**：批次層**不**在專案目錄寫任何 durable 證據檔（不建
`.claude/superpowers/review/` 之類目錄）。並行擷取各 job stdout 所需的暫存檔，一律放在
作業系統 temp 目錄（`mktemp -d`），並於退出時清除。因此本設計**不需要**原子寫入、交易式
發佈、manifest、內容雜湊、reader API、互斥鎖、備份/回滾等任何「為了安全寫共享目錄」而生的
機制。

**核心約束**：

- `dispatch.sh` 三個子命令（`task` / `review` / `adversarial`）的既有行為**完全不變**。
- 沿用 `dispatch.sh` 既有的 bash 3.2 / BSD 可攜性約束（不得依賴 `wait -n`、`sort -V` 等
  bash 4+/GNU 專屬特性）。

## 2. 整體架構：共用引擎 + 三個薄包裝

```
scripts/
  dispatch.sh              # 既有，本案不修改
  review-batch-lib.sh      # 新增：共用批次引擎（被三個 wrapper source）
  review-brainstorm.sh     # 新增：brainstorming 薄包裝
  review-plan.sh           # 新增：writing-plans 薄包裝
  review-impl.sh           # 新增：subagent-driven-development 薄包裝
  review-batch-lib.test.sh # 新增：引擎測試
```

- **共用引擎** `review-batch-lib.sh` 是一個被 source 的函式庫，提供批次調度的全部共通
  邏輯：job 註冊、並行節流、暫存擷取、stdout 彙整、退出碼。
- **三個 wrapper** 各自只負責「解析自己技能的 CLI 參數、定義自己有哪些 reviewer、把每個
  reviewer 轉成一筆 dispatch.sh 呼叫的 job」，其餘委派給引擎。
- wrapper 與引擎都不重新實作 companion 解析／版本檢查／佔位符替換——那些仍由 `dispatch.sh`
  在每個 job 內部完成。

## 3. `dispatch.sh` 不變

本案**不修改** `dispatch.sh`。引擎對每個 job 的調用形式固定為（stdout/stderr 各導向本次
temp 目錄下的一個暫存檔，供彙整時依序讀回）：

```
dispatch.sh <subcommand> <args...>   > <temp/job.out>   2> <temp/job.err>
```

引擎不需要從 dispatch.sh 取得 prompt 文字。impl 的 spec-compliance 多傳一個
`--set TASK_HEAD=<sha>`（其值由引擎把 sentinel `@HEAD_AT_START@` 替換為單一擷取的 HEAD，
見 §4.6）只是多一個 `--set` 鍵值，dispatch.sh 既有的 `--set` 機制已支援，**仍無需對
dispatch.sh 新增任何旗標**。

## 4. 共用引擎 `review-batch-lib.sh`

### 4.1 公開 API

引擎以函式庫形式被 wrapper `source`，對外提供：

- `batch_init`：重置內部 job 佇列；設定 `MAX_PARALLEL`（預設 5）等批次層級狀態。
- `batch_add <label> <subcommand> <dispatch-args...>`：登記一個 job。`label` 是該 reviewer
  在 stdout heading 與 Summary 中的名稱；其餘參數是要原樣傳給 `dispatch.sh` 的 argv。引擎以
  `printf %q` 安全編碼 argv 後存入內部佇列（round-trip 安全，避免含空白的參數如
  `--set TASK_ID=Task 1` 被誤切）。argv 中的 sentinel `@HEAD_AT_START@` 由 `batch_run` 在
  擷取 HEAD 後替換（見 §4.6）。
- `batch_run`：執行整個佇列（並行 + 節流），把各 job 的 stdout/stderr 擷取到 temp 目錄，
  組裝並輸出 §4.4 的 stdout，回傳 §4.5 的退出碼，最後清除 temp 目錄。

### 4.2 並行與節流

- 一次最多 `MAX_PARALLEL` 個 job 並行（預設 5，由 wrapper 的 `--max-parallel` 覆寫）。
  **建立 FIFO token bucket 前嚴格驗證** `MAX_PARALLEL`：只接受正十進位整數
  （`^[1-9][0-9]*$`）；`0`、空值、非數字一律 fail fast 報錯退出（避免 token 數為 0 時 job
  永遠等不到 token 而死鎖）；並設一個有文件記載的安全上限（預設 16），超過則夾到上限並提示。
- 節流以 **FIFO token-bucket** 實作（`mkfifo` 預先寫入 N 顆 token，每個 job 啟動前讀一顆、
  結束後寫回一顆），在 bash 3.2 下可運作，且為真正的滑動式節流（非 wave-barrier）。
- 每個 job 背景啟動後記錄其 PID 與對應 label；以 `wait <pid>` 逐一收集各 job 的退出碼。

### 4.3 暫存與清理（只用 OS temp 目錄，退出即清）

- `batch_run` 以 `mktemp -d`（置於 `$TMPDIR`）建立本次專屬 temp 目錄；每個 job 的 stdout、
  stderr 各寫入該目錄下的暫存檔。**不在專案目錄寫任何檔**；temp 目錄可在任意檔案系統，因為
  本設計**不做任何原子 rename / 跨檔案系統發佈**——暫存檔只是讀回彙整用的工作檔。
- 需要暫存的唯一理由：並行 job 的 stdout 不能直接交錯寫到同一個輸出串流，故各寫各的暫存檔，
  再由引擎**依登記順序**讀回串接（§4.4），確保輸出穩定可重現。
- **進場即裝 `trap <shutdown> EXIT INT TERM`**，shutdown 在**任一退出路徑**執行：
  1. 停止再啟動新 job（關閉 token bucket，不再從佇列取新工作）；
  2. 對**已啟動仍在跑的子行程 PID** 送 `TERM`，逾時未退再送 `KILL`，並 `wait` **回收**
     （reap）之——確保不留孤兒 companion 行程、也不會與隨後的 retry 並存；
  3. 關閉/移除 FIFO 資源；
  4. `rm -rf` 本次 temp 目錄。
  （正常成功路徑由 EXIT 觸發同一 shutdown，此時子行程皆已 reap、temp 可清。）

### 4.4 stdout 彙整格式

依**登記順序**（非完成順序，確保輸出穩定可重現）串接每個 job 的全文，最後附一段彙整：

```
## <label>
<該 job 的 stdout 全文（取自 temp 暫存）>

## <label-2>
<...>

=== Summary ===
- <label>:   Status: OKAY
- <label-2>: Verdict: needs-attention
- <label-3>: ERROR (tool failed, exit 1)
```

**退出碼 vs verdict 的語義（依 companion 原始碼，非推測）**：codex companion 的
`process.exitCode = execution.exitStatus = result.status`，即**codex 執行本身的狀態**——
reviewer 的審查結論（`Status: OKAY` / `Status: Issues Found`、`Verdict: approve` /
`Verdict: needs-attention`）一律寫在 **stdout 文字**裡。因此 reviewer 回報 findings 時 codex
執行成功 → companion 退出 0；退出碼非零代表「工具執行失敗」（codex 執行錯誤、版本守門、
companion 例外等），此時通常沒有可解析的 verdict 行。

故 Summary 行的狀態這樣判定（**verdict 以 stdout 為準，不以退出碼判審查結論**）：

1. 先在該 job 的 stdout 取**最後一行**符合 `^(Status|Verdict):` 的行 → 即該 reviewer 的審查
   結論（`OKAY` / `Issues Found` / `approve` / `needs-attention`），**無論退出碼為何**。
2. 若**無**此類 verdict 行**且退出碼非零** → `ERROR (tool failed, exit <rc>)`（工具失敗，在其
   區段附 stderr 摘要）——這才是需要 caller **重跑整個 wrapper** 的情形。
3. 若退出碼為零但無 verdict 行（例如 code-quality reviewer 為 prose）→ `(prose — 見全文)`。
4. 邊界：退出碼非零但仍有可解析 verdict 行 → 以 verdict 為準，退出碼僅附註於行尾。

### 4.5 退出碼與 caller contract

`batch_run` 的退出碼**只反映工具層面是否有失敗**，**不**反映審查結論：

- **有任一 job 為 ERROR**（§4.4 第 2 點：無 verdict 行的工具失敗）或批次被 §4.6 標為 HEAD
  無效 → `batch_run` **非零退出**（其餘 job 仍跑完、其結果照常出現在 stdout）。
- **所有 job 都成功產生 verdict 行**（即使內容是 `Issues Found` / `needs-attention`）→
  **退出 0**。reviewer 找到問題是**正常結果**，由 SKILL 的 round loop 讀 verdict 行決定是否
  再迭代，不讓批次退出碼非零。

**caller contract（在 SKILL.md 呼叫端落實）**：

- wrapper 的 **stdout 在任何退出碼下都是完整且權威的**；非零退出不會截斷或丟棄 stdout。
  Claude Code 的 Bash 工具在指令非零退出時仍會完整回傳 stdout 並附退出碼註記。
- 呼叫端**在任何退出碼下都讀取並解析 wrapper 的 stdout**（§4.4 全文 + Summary），據以判斷
  各 reviewer 是 OKAY / Issues Found / approve / needs-attention / prose / ERROR。
- **兩種「需要動作」要分清**：(a) **ERROR（工具失敗）** → caller **重跑整個 wrapper**（同一
  完整 job set；環境/版本/暫時性錯誤，非審查結果）；(b) **reviewer findings** → caller 依
  round loop **修正後 re-review**。批次非零退出只對應 (a)；(b) 由 stdout 的 verdict 行驅動，
  與退出碼無關。

### 4.6 HEAD 快照一致性（impl 並行 diff reviewer 的凍結保證）

review-impl 的兩個 reviewer 都針對 diff：spec-compliance 跑 `git diff <TASK_BASE>..HEAD`，
code-quality 跑 `review --base <TASK_BASE>`（companion 內部對 `HEAD` 取 diff）。若批次執行期間
`HEAD` 移動，兩者可能描述不同 diff，破壞「同一 snapshot」契約。引擎以下列方式凍結並偵測：

1. **caller 契約**：`review-*.sh` 是阻塞式單次呼叫；caller（SKILL.md）在 wrapper 執行期間
   **不得推進 `HEAD`**（不得提交/rebase/checkout）。
2. **引擎為 HEAD 的唯一擷取點**：若在 git repo 內，`batch_run` 在啟動任何 job 之前**只擷取
   一次** `HEAD_AT_START=$(git rev-parse HEAD)`，作為本批次唯一基準。**wrapper 不得自行
   `git rev-parse HEAD`**——避免「wrapper 抓一次、引擎再抓一次，兩次之間 HEAD 變動」的競態。
3. **以 sentinel 把同一個 HEAD 注入需釘住的 job**：spec-compliance 在 `batch_add` 時以 sentinel
   `--set TASK_HEAD=@HEAD_AT_START@` 登記；引擎擷取 `HEAD_AT_START` 後、啟動 job 前，把所有
   job argv 中的 `@HEAD_AT_START@` 替換為該 SHA，使 spec-compliance 釘住
   `git diff <TASK_BASE>..<HEAD_AT_START>`。code-quality 的 `..HEAD` 由下述 end 斷言保證等於
   同一基準。
4. **end 斷言**：於**所有 job 結束、彙整前**再讀一次 `HEAD`；若 ≠ `HEAD_AT_START` → 在 stdout
   彙整加一行 `BATCH INVALID: HEAD moved during run (<a>→<b>) — rerun` 並**強制非零退出**，
   要求 caller 重跑。如此 spec-compliance 的釘住終點、code-quality 的 `..HEAD`、與基準三者
   只有在同一 commit 時批次才算有效。

非 impl 的 wrapper（brainstorm 的 design-soundness 用 `adversarial --base`、plan 的
reviewer 用 `task` 讀檔）：brainstorm 的 design-soundness 也是 diff 型，沿用同一 end 斷言；
plan 的 reviewer 讀 plan/spec 檔內容、非 diff，不受 HEAD 影響。

**已知限制（約束所迫）**：end 斷言只在 job 結束後比對一次，抓不到「執行中改走又改回」的瞬態
漂移；要完全消除需把 code-quality 釘到固定 ref，而其兩條路徑——worktree 隔離、改
companion/dispatch.sh 收顯式 end SHA——都被本專案硬性約束排除。HEAD 是 repo 全域狀態，會推進它
的是 implementer 提交或外部 git 操作（非 read-only 的 review 批次），故 repo 級 review 鎖無效。
此瞬態漂移列為約束所迫的已知限制，靠 caller 契約 + 最終漂移斷言把風險限縮到「外部行為者在數秒
批次窗內改走又改回 HEAD」的窄邊界。要消除須由專案層級放寬其中一個約束。

## 5. 三個 wrapper 的 CLI

所有 wrapper 共通：

- `--max-parallel N`（選填，預設 5；驗證見 §4.2）。

wrapper 從自身所在路徑推導 plugin root（`dispatch.sh` 與各 prompt sidecar 的位置），不依賴
`CLAUDE_PLUGIN_ROOT` 是否設定：`SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)`，`dispatch.sh` 在
`$SCRIPT_DIR/dispatch.sh`，prompt 在 `$SCRIPT_DIR/../skills/...`。

### 5.1 `review-brainstorm.sh`

固定兩個 reviewer。

```
review-brainstorm.sh --spec <design.md> --base <SPEC_BASE> [--max-parallel 5]
```

| label                     | dispatch 呼叫 |
| ------------------------- | ------------- |
| `structural-completeness` | `task --prompt <root>/skills/brainstorming/spec-document-reviewer-prompt.md --set SPEC_FILE_PATH=<spec>` |
| `design-soundness`        | `adversarial --base <SPEC_BASE> --focus <root>/skills/brainstorming/adversarial-spec-review-focus.md` |

### 5.2 `review-plan.sh`

Per-Task 數量可變 + Coverage 可選。

```
review-plan.sh --plan <plan.md> --spec <design.md> \
  --task "Task 1" [--task "Task 3" ...] [--coverage] [--max-parallel 5]
```

- 每個 `--task "Task N"` → 一個 label `per-task Task N` 的 job：
  `task --prompt <root>/skills/writing-plans/plan-document-reviewer-prompt.md
  --set PLAN_FILE_PATH=<plan> --set SPEC_FILE_PATH=<spec> --set TASK_ID="Task N"`
- 帶 `--coverage` → 額外一個 label `coverage-verifier` 的 job：
  `task --prompt <root>/skills/writing-plans/coverage-verifier-prompt.md
  --set PLAN_FILE_PATH=<plan> --set SPEC_FILE_PATH=<spec>`
- 至少要有一個 `--task` 或 `--coverage`，否則報錯退出。

### 5.3 `review-impl.sh`

每個 task 的 spec-compliance 與 code-quality **並行**（取代原本兩段循序）。不傳 report file
（見 §6）。

```
review-impl.sh --plan <plan.md> --task "Task N" --task-base <TASK_BASE> \
  [--max-parallel 5]
```

HEAD 由引擎唯一擷取（§4.6）：review-impl.sh **不自行 `git rev-parse HEAD`**；spec-compliance
以 sentinel `--set TASK_HEAD=@HEAD_AT_START@` 登記。

| label             | dispatch 呼叫 |
| ----------------- | ------------- |
| `spec-compliance` | `task --prompt <root>/skills/subagent-driven-development/spec-reviewer-prompt.md --set PLAN_FILE_PATH=<plan> --set TASK_ID="Task N" --set TASK_BASE=<TASK_BASE> --set TASK_HEAD=@HEAD_AT_START@` |
| `code-quality`    | `review --base <TASK_BASE>` |

subagent-driven-development 的**最終 adversarial 合併閘**仍維持單一 `dispatch.sh adversarial`
直呼，不納入批次（單一 reviewer 無並行需求）。

**並行化的 snapshot / invalidation / rerun 契約（取代原本的循序閘）**：

1. **同一 snapshot**：spec-compliance 經 sentinel 釘住 `git diff <TASK_BASE>..<HEAD_AT_START>`、
   code-quality 取 `..HEAD`，由 §4.6 end 斷言保證批次期間 `HEAD == HEAD_AT_START`，故兩者針對
   同一不可變 commit pair。
2. **任一修改使雙方結果一起失效**：該 task 本輪後有任何修正提交（HEAD 前進）→ spec-compliance
   與 code-quality 的先前結果全部作廢。
3. **修完整批重跑**：implementer 一次修完兩個 reviewer 本輪的全部 blocking findings，再以同一個
   `<TASK_BASE>`、新的 HEAD 重跑整個 `review-impl.sh`（兩個 reviewer 都重跑）。
4. **收斂條件**：該 task 只有在單一次批次呼叫內、其後無任何修改的情況下，spec-compliance 回
   `Status: OKAY` 且 code-quality 無 blocking finding，才算通過。
5. **ERROR 復原＝整批重跑**：任一 reviewer ERROR（工具失敗）→ 以相同完整 job set 重跑整個
   wrapper（review-plan 須帶相同 `--task`/`--coverage`）；引擎不提供 per-job 局部重跑。

## 6. 連帶變更：移除 spec-compliance reviewer 的 report file

review-impl 不再傳 `--report-file`。spec-compliance 的真正驗證是
`git diff <TASK_BASE>..<TASK_HEAD>` 對照 plan 中該 Task 的需求；`spec-reviewer-prompt.md` 中本就
明示「不信任 report」，唯一獨有價值僅「宣稱做了但其實沒做」，而只要該需求本在 plan Task 內，
比對 plan↔diff 一樣會抓到缺失。移除 report 可省去 agent 管理暫存 report 檔與完成後清理的複雜度。

**證據完整性要求**：移除 report 後，spec-compliance 的可審證據一律以
`git diff <TASK_BASE>..<TASK_HEAD>` 為事實來源。對 diff 不能直接呈現的產物（生成檔、runtime
行為、外部副作用），plan 的該 Task 必須以「會落進 diff 的可驗證形式」表達預期結果——主要手段是
**提交測試**（該 skill 既有 TDD 政策下，測試本身就在 diff 內，reviewer 可直接讀）。report 是
prose 自述、本就不可信，保留它並不會把非 diff 可見產物變得可驗證。

**`spec-reviewer-prompt.md` 變更**：
- 移除 `[REPORT_FILE_PATH]` 佔位符與「讀取 implementer report 看其 CLAIM」段落；保留並強化
  「以 plan Task 需求 ↔ git diff 獨立驗證」的核心。
- 把 diff 範圍由 `git diff [TASK_BASE]..HEAD` 改為釘住的 `git diff [TASK_BASE]..[TASK_HEAD]`
  （新增 `[TASK_HEAD]` 佔位符，由 review-impl.sh 以 `--set TASK_HEAD` 注入；值來自 §4.6 sentinel）。
- Output Contract（`Status: OKAY` / `Status: Issues Found`）不變。

**相容性盤點（已查證）**：`spec-reviewer-prompt.md` 含 `[REPORT_FILE_PATH]`（移除如上）；
`subagent-driven-development/SKILL.md` 有 report mktemp 建立→`--report-file`→完成後 `rm` 的接線
（全部移除，改為 §7 的 `review-impl.sh` 單一呼叫）；`implementer-prompt.md` 的 report 是 subagent
**回傳給父 agent 的訊息**、非磁碟檔，**不改**（移除後仍是有用上下文，非 dead path）；`dispatch.sh`
的 `--report-file` 通用選項**不改**（僅 review-impl 不再使用，非死碼）。

## 7. 連帶變更：三個 SKILL.md 的 dispatch 段落改寫

把每個技能 review 迴圈中「N 個 `run_in_background` Bash call + 逐一等通知 + 逐一讀 stdout」改寫為
「**單一** wrapper 呼叫」。round loop 的控制邏輯（哪些 reviewer 在哪一輪跑、zero-tolerance、收斂
條件）維持不變，只是每一輪改為呼叫一次對應 wrapper 並從其 stdout 一次取得全部結果。

- **brainstorming/SKILL.md**：spec review loop 改呼 `review-brainstorm.sh`。
- **writing-plans/SKILL.md**：Per-Task + Coverage 改呼 `review-plan.sh`（以多個 `--task` 指定本輪
  active tasks、以 `--coverage` 控制 Coverage Verifier 是否參與）。
- **subagent-driven-development/SKILL.md**：每個 task 的兩階段審查改呼 `review-impl.sh`（spec 與
  code-quality 並行，遵循 §5.3 契約）；流程語義由「先 spec OKAY 再 code-quality」改為「兩者每輪
  並跑、任一有 blocking finding 就由 implementer 一次修完兩者再整批重跑」。同時移除 §6 盤點的
  report 接線。最終 adversarial 合併閘段落維持原樣。
- 三個 SKILL.md 呼叫端都須落實 §4.5 caller contract（任何退出碼都讀並解析 wrapper stdout 的
  Summary；ERROR→重跑整個 wrapper）。呼叫端**只消費 stdout**，無任何中繼檔可讀。

## 8. 失敗、並行與邊界

- 單一 reviewer 的 companion 失敗（無 verdict 行、退出非零）→ 標 `ERROR`；其餘 job 照常跑完並
  出現在 stdout；批次非零退出；caller 重跑整個 wrapper（§4.5）。
- companion 未安裝／版本過低：`dispatch.sh` 既有硬停使該 job 非零退出 → 走 ERROR 路徑（引擎不
  重複做版本檢查）。
- HEAD 在批次期間移動：end 斷言 → `BATCH INVALID` 行 + 非零退出（§4.6）。
- `--max-parallel` 為 0/空/非數字 → fail fast（§4.2）。
- 訊號中斷（INT/TERM）：shutdown 終止並回收子行程、`rm -rf` temp 目錄（§4.3）。因不寫專案目錄，
  中斷不留任何殘骸。
- temp 目錄置於 `$TMPDIR`，可跨檔案系統——因無原子 rename 需求。

## 9. 驗證策略

仿 `dispatch.test.sh`，新增 `review-batch-lib.test.sh`，以 stub 的 `dispatch.sh`（或 `--dry-run`
路徑 / 假 companion）驗證：

- **job 組裝**：每個 wrapper 把 CLI 參數正確轉為預期的 dispatch.sh argv（含含空白的
  `--set TASK_ID=Task 1` 不被切斷）。
- **stdout 彙整格式**：heading 順序 = 登記順序；Summary 區段狀態行擷取（Status / Verdict /
  prose / ERROR 四種情形）。
- **退出碼 vs verdict 分類**：stub companion「成功且 stdout 含 `Status: Issues Found`」→ 該 job
  退出 0、Summary 標 `Issues Found`、**批次退出 0**；「無 verdict 行且退出非零」→ Summary 標
  `ERROR`、批次非零退出。
- **ERROR 不影響其他**：一個 job ERROR 時其餘仍完成並出現在 stdout、批次非零退出。
- **HEAD 凍結**：wrapper 不呼叫 `git rev-parse`；`batch_run` 擷取單一 `HEAD_AT_START` 並替換
  argv 的 `@HEAD_AT_START@`；spec-compliance 收到的 `TASK_HEAD` 恆等於 `HEAD_AT_START`；批次內
  HEAD 變動 → `BATCH INVALID` + 非零退出。
- **並行節流**：同時並行數不超過 `MAX_PARALLEL`；`--max-parallel` 0/空/非數字 fail fast、超上限
  夾到上限。
- **temp 清理**：正常結束與 INT/TERM 中斷後，temp 目錄都被清除、無孤兒子行程；專案目錄不被寫入。

## 10. 設計取捨記錄

- **不持久化中繼檔，只用 OS temp + 退出清理**：agent 介面僅 stdout + 退出碼，durable 證據檔非
  需求；移除後即不需要原子寫入、交易式發佈、manifest、雜湊、reader API、互斥鎖、備份/回滾等
  全部複雜度，大幅縮減實作面與失敗模式。
- **共用引擎 + 三薄包裝**（vs 三個獨立腳本 / dispatch.sh 加子命令）：零邏輯重複，dispatch.sh
  職責不膨脹。
- **stdout 回傳全部 reviewer 全文 + 末尾 Status 彙整**：省 token 的來源是「把多次來回壓成一次」，
  agent 一次拿到全部全文。
- **verdict 以 stdout 為準、退出碼只表工具成敗**（依 companion 原始碼，非推測）：findings 走
  stdout 不觸發批次非零；ERROR 專指工具失敗才需重跑——把「修 findings」與「重跑工具」分清。
- **HEAD 凍結＝引擎單一擷取 + sentinel 注入 + end 斷言**：消除 wrapper/引擎雙擷取 TOCTOU，且不需
  改 dispatch.sh/companion；瞬態外部漂移為約束所迫已知限制。
- **ERROR 復原＝整批重跑**（vs per-job 局部重跑）：wrapper 本就跑固定/指定的 job set，語義單純。
- **移除 report file**：report 本就不被信任，git diff（含提交的測試）是事實來源。
- **FIFO token-bucket 節流 + 嚴格驗證**：bash 3.2 可攜、真正滑動節流；0/空/非數字轉為 fail fast。

## 11. 非目標

- 不修改 `dispatch.sh` 既有三個子命令的行為。
- **不在專案目錄持久化任何 reviewer prompt/output 中繼檔**（只用 OS temp、退出清理）。
- 不改變各 reviewer prompt sidecar 的審查準則（除 §6 移除 report 段落、釘住 diff 範圍外）。
- 不改變各技能 review 迴圈的收斂條件與 zero-tolerance 政策。
- 不把 subagent 的最終 adversarial 合併閘納入批次。
- 不引入跨技能共用的單一「萬用」CLI——三個 wrapper 各自獨立面向自己的技能。
- 不為 spec-compliance 重建 implementer report / evidence 檔通道（明確可接受限制；非 diff 可見的
  純外部副作用由 implementer 提交的測試 + 最終 adversarial 合併閘 + user-review gate 人工審查涵蓋）。
- **不消除瞬態 HEAD 漂移**（§4.6 已知限制；消除需專案層級放寬「禁用 worktree」或「dispatch.sh
  不變」其中一個約束）。
