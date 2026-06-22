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
"$BATCH_DISPATCH_SH" <subcommand> <args...>   > <temp/job.out>   2> <temp/job.err>
```

（`BATCH_DISPATCH_SH` 由 wrapper 設為 `$SCRIPT_DIR/dispatch.sh`，測試可覆寫為 stub；見 §4.1 / §5。）

引擎不需要從 dispatch.sh 取得 prompt 文字，也不對 dispatch.sh 傳任何新旗標或特殊 `--set`。

## 4. 共用引擎 `review-batch-lib.sh`

### 4.1 公開 API

引擎以函式庫形式被 wrapper `source`，對外提供：

- `batch_init`：重置內部 job 佇列；設定 `MAX_PARALLEL`（預設 5）等批次層級狀態。
- **`BATCH_DISPATCH_SH`（引擎用以呼叫 dispatch.sh 的路徑）**：engine 不假設相對路徑，而是讀此
  變數決定要執行哪個 `dispatch.sh`。各 wrapper 在 `source` 引擎後、`batch_run` 前設定
  `BATCH_DISPATCH_SH="$SCRIPT_DIR/dispatch.sh"`（見 §5）；**測試可覆寫**為 stub `dispatch.sh`
  以驗證 argv 組裝（§9）。
- `batch_add <label> <subcommand> <dispatch-args...>`：登記一個 job。`label` 是該 reviewer
  在 stdout heading 與 Summary 中的名稱；其餘參數是要原樣傳給 `dispatch.sh` 的 argv。引擎以
  `printf %q` 安全編碼 argv 後存入內部佇列（round-trip 安全，避免含空白的參數如
  `--set TASK_ID=Task 1` 被誤切）。
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

**並行安全基礎（為何同時跑多個 `dispatch.sh` 是安全的，依查證事實）**：

- **既有行為已是並行**：現行三個技能的 SKILL.md 本來就以多個 `run_in_background: true` 的獨立
  Bash call **並行**派發這些 reviewer 命令（`dispatch.sh task/review/adversarial`）。並行呼叫
  companion 是**既有且運作中的行為**；本引擎只是把「agent 端 N 個背景呼叫」收斂成「一個腳本背景
  N 個 `dispatch.sh`」，**並未提高並行度**，反而**新增 `MAX_PARALLEL` 上限**（舊流程在 agent 端
  無上限）。故本設計不引入比現況更高的並行風險。
- **per-invocation 隔離（已查證）**：`dispatch.sh` 每次呼叫都用**自己的 `mktemp`** 建立私有
  prompt 工作檔（`task` 子命令）與 report 私有副本，故並行呼叫之間**無 prompt/輸入檔碰撞**。
- **per-job 輸出隔離**：引擎把每個 job 的 stdout/stderr 各導向**獨立的 temp 檔**（§4.3），故並行
  job 的輸出不交錯、彙整穩定。
- **companion 狀態以 session 為「目錄」、以唯一 job.id 為「鍵」（已查證）**：companion 的
  tracked-jobs/log/job-file 雖落在以 `CODEX_COMPANION_SESSION_ID` 為命名的 session 目錄下，但
  **每個 job 的狀態檔以該次呼叫的唯一 `job.id` 為鍵**（已查證：`generateJobId` =
  `${prefix}-${Date.now()}-${Math.random()}`，每次呼叫互異）。因此並行（或前後 stale）呼叫各寫
  各的 job-id 檔，**不會互相覆寫或污染彼此的狀態**；session 目錄只是一堆 per-job-id 記錄的集合。
  這正是現行並行 skill 用法已在運作的同一前提；本引擎不改變 companion 的調用契約。
- **明確界線**：本設計**不**為每個 job 另建獨立 HOME/cache/config——既非現行行為、也會過度
  工程化（per-job-id 命名空間已足以避免狀態碰撞）。若 companion 未來需要序列化才能正確，那會先
  讓現行並行 skill 失效（現況未失效）。

### 4.3 暫存與清理（只用 OS temp 目錄，退出即清）

- `batch_run` 以 `mktemp -d`（置於 `$TMPDIR`）建立本次專屬 temp 目錄；每個 job 的 stdout、
  stderr 各寫入該目錄下的暫存檔。**不在專案目錄寫任何檔**；temp 目錄可在任意檔案系統，因為
  本設計**不做任何原子 rename / 跨檔案系統發佈**——暫存檔只是讀回彙整用的工作檔。
- 需要暫存的唯一理由：並行 job 的 stdout 不能直接交錯寫到同一個輸出串流，故各寫各的暫存檔，
  再由引擎**依登記順序**讀回串接（§4.4），確保輸出穩定可重現。
- **進場即裝 `trap <shutdown> EXIT INT TERM`**，shutdown 在**任一退出路徑**執行：
  1. 停止再啟動新 job（關閉 token bucket，不再從佇列取新工作）；
  2. **終止整個 job 行程樹（best-effort）**：每個 job 是 `dispatch.sh`（其下再 spawn
     `node companion`）。為能連同 companion 子孫一起收掉，**盡量讓每個 job 自成一個 process
     group**（bash job-control：在子 shell 內 `set -m` 背景啟動，job 取得獨立 pgid），shutdown
     時對**整個 group** 送 `TERM`、逾時未退再送 `KILL`（`kill -- -<pgid>`），再 `wait` **回收**
     （reap）；
  3. 關閉/移除 FIFO 資源；
  4. `rm -rf` 本次 temp 目錄。
  （正常成功路徑由 EXIT 觸發同一 shutdown，此時子行程皆已 reap、temp 可清。）
- **可攜性後備與弱保證（誠實聲明）**：在 bash 3.2 / BSD 上若無法可攜地為每個 job 建立 process
  group（無 `setsid`、job-control 在非互動 script 行為受限），則退化為**只對直接子 PID
  （`dispatch.sh` shell）送訊號 + reap**，companion 子孫可能短暫存活。**此弱保證下不假設「retry
  與舊行程零重疊」**，但 stale 子孫的影響有界：
  - 它的 stdout/stderr 寫到**本次（已被 `rm -rf`）的 temp 目錄**，retry 用全新 temp 目錄與全新
    job 暫存，故**無法污染 retry 的輸出或彙整**；
  - 它對 companion 狀態的寫入落在**它自己唯一 `job.id` 的檔**（§4.2 已查證），retry 是新 job.id，
    故**不會覆寫 retry 的狀態**；至多在 session 目錄留下一筆它自己的孤兒 job 記錄（如同被遺棄的
    暫存，review 批次不讀它）。
  因此 stale 子孫的唯一實質代價是**浪費算力**，非正確性問題。引擎測試須涵蓋「stub dispatch.sh
  留下 grandchild」情境，驗證 group 終止能收掉它、或在弱保證下確認上述隔離成立（§9）。

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

- **有任一 job 為 ERROR**（§4.4 第 2 點：無 verdict 行的工具失敗）→ `batch_run` **非零退出**
  （其餘 job 結果仍照原樣出現在 stdout）。
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

## 5. 三個 wrapper 的 CLI

所有 wrapper 共通：

- `--max-parallel N`（選填，預設 5；驗證見 §4.2）。

wrapper 從自身所在路徑推導路徑（不依賴 `CLAUDE_PLUGIN_ROOT` 是否設定），並把結果以**可覆寫的
變數**傳給引擎與用於組 argv，使測試能注入 stub：

- `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)`；
- `BATCH_DISPATCH_SH="${BATCH_DISPATCH_SH:-$SCRIPT_DIR/dispatch.sh}"`（引擎呼叫的 dispatch.sh，
  見 §4.1；測試覆寫為 stub）；
- `PLUGIN_ROOT="${PLUGIN_ROOT:-$SCRIPT_DIR/..}"`，各 prompt sidecar 以 `$PLUGIN_ROOT/skills/...`
  組路徑（測試覆寫 `PLUGIN_ROOT` 即可驗證精確 argv，不依賴已安裝的 plugin 佈局）。

兩個變數都用 `${VAR:-default}` 形式：未設時取 wrapper 推導的預設、已設時尊重覆寫值。

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

兩個 reviewer 都自然看 `..HEAD`，不釘住 diff 範圍、引擎也不偵測 HEAD 變更（見下方 snapshot 契約
的**已知取捨**）。

| label             | dispatch 呼叫 |
| ----------------- | ------------- |
| `spec-compliance` | `task --prompt <root>/skills/subagent-driven-development/spec-reviewer-prompt.md --set PLAN_FILE_PATH=<plan> --set TASK_ID="Task N" --set TASK_BASE=<TASK_BASE>` |
| `code-quality`    | `review --base <TASK_BASE>` |

subagent-driven-development 的**最終 adversarial 合併閘**仍維持單一 `dispatch.sh adversarial`
直呼，不納入批次（單一 reviewer 無並行需求）。

**並行化的 snapshot / invalidation / rerun 契約（取代原本的循序閘）**：

1. **同一 snapshot（靠 caller 契約，不做偵測——已知取捨）**：spec-compliance 跑
   `git diff <TASK_BASE>..HEAD`、code-quality 取 `..HEAD`；兩者看同一 HEAD 的前提，由 **caller
   契約**保證：`review-impl.sh` 是阻塞式單次呼叫，caller（SKILL.md）在其執行期間**不得推進
   `HEAD`**（不得提交/rebase/checkout）。**引擎不額外偵測 HEAD 變更**——這是刻意的**已知取捨**：
   偵測（reflog 比對）或釘住（worktree/改 companion）都被判定不值得其複雜度；若 caller 違反契約
   在批次窗內動了 HEAD，兩個 reviewer 可能看到不同 diff，此風險由 caller 契約承擔（見 §11）。
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
`git diff <TASK_BASE>..HEAD` 對照 plan 中該 Task 的需求；`spec-reviewer-prompt.md` 中本就
明示「不信任 report」，唯一獨有價值僅「宣稱做了但其實沒做」，而只要該需求本在 plan Task 內，
比對 plan↔diff 一樣會抓到缺失。移除 report 可省去 agent 管理暫存 report 檔與完成後清理的複雜度。

**證據完整性要求**：移除 report 後，spec-compliance 的可審證據一律以
`git diff <TASK_BASE>..HEAD` 為事實來源。對 diff 不能直接呈現的產物（生成檔、runtime
行為、外部副作用），plan 的該 Task 必須以「會落進 diff 的可驗證形式」表達預期結果——主要手段是
**提交測試**（該 skill 既有 TDD 政策下，測試本身就在 diff 內，reviewer 可直接讀）。report 是
prose 自述、本就不可信，保留它並不會把非 diff 可見產物變得可驗證。

**`spec-reviewer-prompt.md` 變更**（僅移除 report，diff 範圍維持 `..HEAD` 不變）：
- 移除 `[REPORT_FILE_PATH]` 佔位符與「讀取 implementer report 看其 CLAIM」段落；保留並強化
  「以 plan Task 需求 ↔ git diff 獨立驗證」的核心。
- diff 範圍維持既有的 `git diff [TASK_BASE]..HEAD`（不釘住、不新增 `[TASK_HEAD]` 佔位符）。
- **新增「證據可驗證性」規則（取代 report 後的證據要求；經校準，避免合法 task 永遠過不了）**：
  reviewer 檢查每個驗收項是否**可由 diff（含提交的測試）驗證**，並分兩類處置：
  - **「本應可測卻沒測」→ fail-closed**：若某需求**可以**用測試/diff 表達卻未提供（例如可寫單元
    測試的行為卻沒寫），reviewer 回 `Status: Issues Found`、要求補測試——不以較弱證據放行。
  - **「本質上無法由 diff/測試驗證」→ 標注交下游，不硬擋**：若驗收項**本質上**無法以 diff/測試
    證明（純外部副作用、需真人操作驗證者），reviewer **不因此判 fail**，而是在輸出中**明確標注**
    「此驗收項無法由 diff/測試驗證，已交由最終 adversarial 合併閘 + user-review gate 人工確認」。
  如此既不讓「該測而沒測」蒙混過關，也**不會把本質上不可由 diff 驗證的合法 task 變成永遠不可過**。
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
- 三個 SKILL.md 呼叫端**只消費 stdout**（無任何中繼檔可讀），且須寫成下列**明確控制流**
  （不得沿用「非零退出＝直接當失敗中止」的舊處理）：

  1. **無論退出碼為何，先讀並解析 wrapper 的整段 stdout**，定位 `=== Summary ===` 區段
     （此區段即**機器可讀狀態**，且因 stdout 在非零退出下仍完整保留而恆可取得）；
  2. 逐個 reviewer 依 Summary 行分類為 OKAY / Issues Found / approve / needs-attention / prose /
     ERROR；
  3. **若有 ERROR** → **重跑整個 wrapper**（同一完整 job set），不要把它當一般審查失敗、也不要
     忽略 stdout；
  4. **否則**依各 verdict 走 round loop：有 blocking finding → 修正後 re-review；全部通過 → 收斂。

  非零退出是「需要動作」的注意訊號（對應步驟 3），**不是**「丟棄輸出」訊號。§9 須加 caller 層
  acceptance 測試/transcript fixture，證明每個 SKILL.md 呼叫端在**退出碼 0 與非零**兩種情況下都
  正確讀取並分類 stdout。

## 8. 失敗、並行與邊界

- 單一 reviewer 的 companion 失敗（無 verdict 行、退出非零）→ 標 `ERROR`；其餘 job 照常跑完並
  出現在 stdout；批次非零退出；caller 重跑整個 wrapper（§4.5）。
- companion 未安裝／版本過低：`dispatch.sh` 既有硬停使該 job 非零退出 → 走 ERROR 路徑（引擎不
  重複做版本檢查）。
- HEAD 在批次期間移動：引擎**不偵測**（已知取捨，見 §5.3 / §11）；由 caller 契約「執行期間不動
  HEAD」承擔。
- `--max-parallel` 為 0/空/非數字 → fail fast（§4.2）。
- 訊號中斷（INT/TERM）：shutdown 終止並回收子行程、`rm -rf` temp 目錄（§4.3）。因不寫專案目錄，
  中斷不留任何殘骸。
- temp 目錄置於 `$TMPDIR`，可跨檔案系統——因無原子 rename 需求。

## 9. 驗證策略

仿 `dispatch.test.sh`，新增 `review-batch-lib.test.sh`，以 **`BATCH_DISPATCH_SH` 覆寫為 stub
`dispatch.sh`、`PLUGIN_ROOT` 覆寫為測試夾具目錄**（見 §4.1 / §5）來驗證（不依賴已安裝 plugin
佈局）：

- **注入機制可用**：覆寫 `BATCH_DISPATCH_SH` 後引擎確實呼叫 stub、覆寫 `PLUGIN_ROOT` 後 prompt
  路徑指向夾具；未覆寫時取 wrapper 推導的預設。
- **job 組裝**：每個 wrapper 把 CLI 參數正確轉為預期的 dispatch.sh argv（含含空白的
  `--set TASK_ID=Task 1` 不被切斷；prompt 路徑用 `$PLUGIN_ROOT`）。
- **stdout 彙整格式**：heading 順序 = 登記順序；Summary 區段狀態行擷取（Status / Verdict /
  prose / ERROR 四種情形）。
- **退出碼 vs verdict 分類**：stub companion「成功且 stdout 含 `Status: Issues Found`」→ 該 job
  退出 0、Summary 標 `Issues Found`、**批次退出 0**；「無 verdict 行且退出非零」→ Summary 標
  `ERROR`、批次非零退出。
- **ERROR 不影響其他**：一個 job ERROR 時其餘仍完成並出現在 stdout、批次非零退出。
- **不讀 HEAD**：批次執行期間即使 repo git 狀態變動（HEAD 移動），引擎**不讀 HEAD、不標注、
  不因此失敗**（已移除 HEAD 偵測；§5.3 / §11 已知取捨）。
- **並行節流**：同時並行數不超過 `MAX_PARALLEL`；`--max-parallel` 0/空/非數字 fail fast、超上限
  夾到上限。
- **process-tree 清理 / 弱保證隔離**：以 stub `dispatch.sh` **留下一個 grandchild**，驗證 shutdown 的
  group 終止能收掉它；在無法建 process group 的弱保證平台上，改驗「stale 子孫只寫自己的（已刪）
  temp、不污染 retry 的全新 temp 與彙整」（§4.3）。
- **temp 清理**：正常結束與 INT/TERM 中斷後，temp 目錄都被清除；專案目錄不被寫入。
- **caller 層 stdout-on-nonzero（acceptance / transcript fixture）**：對每個 SKILL.md 呼叫端，
  以 fixture 模擬 wrapper 的兩種輸出——(i) 退出 0 + 全 OKAY、(ii) 非零 + 含 `ERROR`——驗證呼叫端
  **在兩種退出碼下都讀取並正確分類 stdout 的 Summary**，且 ERROR → 走「重跑整個 wrapper」、
  findings → 走「修正後 re-review」（§7 控制流）。
- **spec-reviewer-prompt 證據可驗證性規則**：屬 prompt 內容變更，由該 prompt 自身的審查涵蓋
  （驗證 prompt 含 §6 校準後的兩類處置——「本應可測卻沒測 → Issues Found」「本質不可測 → 標注
  交下游、不硬擋」）。

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
- **完全不處理 HEAD（不偵測、不釘住）＝已知取捨**（vs 偵測 reflog / 釘住 diff 範圍）：偵測與
  釘住都被判定不值得其複雜度（reflog 偵測雖可行、釘住需 worktree 或改 companion）；改由
  **caller 契約**「review-impl/brainstorm 執行期間不得動 HEAD」承擔，違反契約導致兩 reviewer
  看不同 diff 的風險列為已知取捨。引擎因此完全不讀 HEAD，wrapper 更精簡。
- **並行安全靠「保留現有已並行的調用契約」而非新建隔離**（依查證）：現行 skill 早已並行呼叫
  companion；引擎不提高並行度、加 max-parallel 上限、per-job 輸出隔離、依賴 dispatch.sh 既有的
  per-call mktemp 與 companion 的 **per-invocation 唯一 job.id 命名空間**（已查證 `generateJobId`
  = timestamp+random）——不過度工程化建立 per-job HOME/cache。
- **shutdown 盡量收 process-tree、無法時誠實降為弱保證**：弱保證下靠 per-job temp 隔離 +
  per-job-id 狀態命名空間界定「stale 子孫只浪費算力、不污染 retry 的輸出或狀態」（§4.2 / §4.3）。
- **ERROR 復原＝整批重跑**（vs per-job 局部重跑）：wrapper 本就跑固定/指定的 job set，語義單純。
- **移除 report file，並以 prompt 內「證據可驗證性」規則取代「證據強制」**（vs 保留 report 通道）：
  report 本就不被信任，git diff（含提交的測試）是事實來源；證據要求改由 spec-reviewer-prompt 的
  校準規則落實（**該測而沒測 → Issues Found；本質不可測 → 標注交下游、不硬擋**），不需重新引入
  不可信的 prose report，且不會把合法 task 變成永遠不可過（§6）。
- **caller 在非零退出下仍以 stdout 的 Summary 為機器可讀狀態**：§7 明定 SKILL.md 控制流、§9 加
  caller acceptance 測試，避免「非零＝直接當失敗」而丟失 ERROR 的可用資訊。
- **FIFO token-bucket 節流 + 嚴格驗證**：bash 3.2 可攜、真正滑動節流；0/空/非數字轉為 fail fast。

## 11. 非目標

- 不修改 `dispatch.sh` 既有三個子命令的行為。
- **不在專案目錄持久化任何 reviewer prompt/output 中繼檔**（只用 OS temp、退出清理）。
- 不改變各 reviewer prompt sidecar 的審查準則（除 §6 移除 report 段落外；diff 範圍維持 `..HEAD`）。
- 不改變各技能 review 迴圈的收斂條件與 zero-tolerance 政策。
- 不把 subagent 的最終 adversarial 合併閘納入批次。
- 不引入跨技能共用的單一「萬用」CLI——三個 wrapper 各自獨立面向自己的技能。
- 不為 spec-compliance 重建 implementer report / evidence 檔通道（刻意決定；證據要求改由 §6 的
  prompt「證據可驗證性」校準規則落實——該測而沒測 → Issues Found，本質不可測 → 標注交下游、
  不硬擋；非 diff 可見的純外部副作用由最終 adversarial 合併閘 + user-review gate 人工審查涵蓋）。
- **完全不處理 HEAD 一致性（不偵測、不釘住）＝刻意的已知取捨**：review-impl/brainstorm 的 diff 型
  reviewer 都看 `..HEAD`，引擎**不讀 HEAD、不偵測變更、不釘住範圍**。兩個 reviewer 看同一 HEAD 的
  前提，僅由 **caller 契約**「`review-*.sh` 執行期間不得動 HEAD（提交/rebase/checkout）」保證
  （§5.3）。若 caller 違反契約而在批次窗內動了 HEAD，兩個 reviewer 可能看到不同 diff——此風險
  **不由本層偵測或防護**，作為已知取捨承擔（偵測/釘住的複雜度被判定不值得；agent 每輪重審亦能
  自然修正多數情形）。
