# 設計規格：並行 reviewer 批次派發層

## 1. 背景與目標

三個技能（brainstorming、writing-plans、subagent-driven-development）在 review
迴圈的每一輪都要派發多個 reviewer。現行做法要求 agent 為每個 reviewer 各發一個
`run_in_background: true` 的獨立 Bash call，逐一等待 completion notification、逐一把
stdout 讀進 context。reviewer 多、輪數多時，造成大量「啟動／等待／讀取」來回與
token 消耗。

**目標**：在現有 `scripts/dispatch.sh` 之上加一層「批次派發」，讓 agent **一次呼叫**
即可並行啟動一組 reviewer、等待全部完成、把結果彙整回傳。把原本 N 次 Bash 來回
壓縮成 1 次。

**核心約束**：

- `dispatch.sh` 三個子命令（`task` / `review` / `adversarial`）的既有行為**完全不變**，
  批次層只在其外圍包一層並行調度。
- 沿用 `dispatch.sh` 既有的 bash 3.2 / BSD 可攜性約束（不得依賴 `wait -n`、
  `sort -V` 等 bash 4+/GNU 專屬特性）。

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

- **共用引擎** `review-batch-lib.sh` 是一個被 source 的函式庫，提供批次調度的全部
  共通邏輯：job 註冊、並行節流、中繼檔落地、stdout 彙整、彙整退出碼。
- **三個 wrapper** 各自只負責「解析自己技能的 CLI 參數、定義自己有哪些 reviewer、
  把每個 reviewer 轉成一筆 dispatch.sh 呼叫的 job」，其餘全部委派給引擎。
- wrapper 與引擎都不重新實作 companion 解析／版本檢查／佔位符替換——那些仍由
  `dispatch.sh` 在每個 job 內部完成。

## 3. `dispatch.sh` 不變

本案**不修改** `dispatch.sh`。引擎對每個 job 的調用形式固定為：

```
dispatch.sh <subcommand> <args...>   > <output 中繼檔>   2> <stderr 暫存>
```

引擎不需要從 dispatch.sh 取得 prompt 文字（中繼檔不再保存 prompt，見 §6），因此
不需要對 dispatch.sh 新增任何旗標。

## 4. 共用引擎 `review-batch-lib.sh`

### 4.1 公開 API

引擎以函式庫形式被 wrapper `source`，對外提供：

- `batch_init`：重置內部 job 佇列；設定 `ROUND`、`SPEC_NAME`、`MAX_PARALLEL`、
  review 目錄等批次層級狀態。
- `batch_add <label> <subcommand> <dispatch-args...>`：登記一個 job。`label` 是該
  reviewer 在 stdout heading 與中繼檔名中的名稱；其餘參數是要原樣傳給
  `dispatch.sh` 的 argv。引擎以 `printf %q` 安全編碼 argv 後存入內部佇列（round-trip
  安全，避免含空白的參數如 `--set TASK_ID=Task 1` 被誤切）。
- `batch_run`：執行整個佇列（並行 + 節流），落地中繼檔，組裝並輸出 stdout，回傳
  彙整退出碼。

### 4.2 並行與節流

- 一次最多 `MAX_PARALLEL` 個 job 並行（預設 5，由 wrapper 的 `--max-parallel`
  覆寫）。
- 節流以 **FIFO token-bucket** 實作（`mkfifo` 預先寫入 N 顆 token，每個 job 啟動前
  讀一顆、結束後寫回一顆），在 bash 3.2 下可運作，且為真正的滑動式節流（非
  wave-barrier）。
- 每個 job 背景啟動後記錄其 PID 與對應 label；以 `wait <pid>` 逐一收集**各 job 的
  退出碼**。

### 4.3 中繼檔落地

review 目錄：`$PWD/.claude/superpowers/review/<spec name>/`（不存在時 `mkdir -p`）。
`$PWD` 為技能執行所在的 repo 根目錄。

每個 job 落地**一個**中繼檔（prompt 不再保存，見 §6）：

```
<spec name>/<label>.<round>.output.md
```

`<label>` 經檔名安全化：非英數字元壓成單一 `-`（例如 `Task 1` → `Task-1`）。
每個 job 的 stdout 直接重導向到該檔；stderr 另存暫存供 ERROR 摘要使用。

### 4.4 stdout 彙整格式

依**登記順序**（非完成順序，確保輸出穩定可重現）串接每個 job 的全文，最後附一段
彙整：

```
## <label> (round <N>)
<該 job output 中繼檔全文>

## <label-2> (round <N>)
<...>

=== Summary (round <N>) ===
- <label>:   Status: OKAY
- <label-2>: Verdict: needs-attention
- <label-3>: ERROR (exit 1)
```

彙整行的狀態以 best-effort 取得：

1. 若該 job 退出碼非零 → `ERROR (exit <rc>)`（並在其 output 區段附帶 stderr 摘要）。
2. 否則取該 output 中繼檔中**最後一行**符合 `^(Status|Verdict):` 的行作為狀態。
3. 若退出碼為零但無此類狀態行（例如 code-quality reviewer 是 prose）→
   `(prose — 見全文)`。

### 4.5 退出碼

任一 job 退出碼非零 → `batch_run` 以非零退出（其餘 job 仍全部跑完並落地）。全部
成功 → 退出 0。

## 5. 三個 wrapper 的 CLI

所有 wrapper 共通：

- `--round N`（必填）：由 agent 顯式傳入，作為中繼檔的 `<round>`。
- `--name <spec>`（選填）：覆寫 `<spec name>`；預設由主要文件檔名推導——去掉前綴
  `YYYY-MM-DD-`、去掉副檔名與 `-design`/`-plan` 後綴。例：
  `2026-06-22-parallel-reviewer-batch-dispatch-design.md` → `parallel-reviewer-batch-dispatch`。
- `--max-parallel N`（選填，預設 5）。

wrapper 從自身所在路徑推導 plugin root（`dispatch.sh` 與各 prompt sidecar 的位置），
不依賴 `CLAUDE_PLUGIN_ROOT` 環境變數是否設定：`SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)`，
`dispatch.sh` 在 `$SCRIPT_DIR/dispatch.sh`，prompt 在 `$SCRIPT_DIR/../skills/...`。

### 5.1 `review-brainstorm.sh`

固定兩個 reviewer。

```
review-brainstorm.sh --spec <design.md> --base <SPEC_BASE> --round N [--name X] [--max-parallel 5]
```

| label                     | dispatch 呼叫 |
| ------------------------- | ------------- |
| `structural-completeness` | `task --prompt <root>/skills/brainstorming/spec-document-reviewer-prompt.md --set SPEC_FILE_PATH=<spec>` |
| `design-soundness`        | `adversarial --base <SPEC_BASE> --focus <root>/skills/brainstorming/adversarial-spec-review-focus.md` |

### 5.2 `review-plan.sh`

Per-Task 數量可變 + Coverage 可選。

```
review-plan.sh --plan <plan.md> --spec <design.md> --round N \
  --task "Task 1" [--task "Task 3" ...] [--coverage] [--name X] [--max-parallel 5]
```

- 每個 `--task "Task N"` → 一個 label `per-task-Task-N` 的 job：
  `task --prompt <root>/skills/writing-plans/plan-document-reviewer-prompt.md
  --set PLAN_FILE_PATH=<plan> --set SPEC_FILE_PATH=<spec> --set TASK_ID="Task N"`
- 帶 `--coverage` → 額外一個 label `coverage-verifier` 的 job：
  `task --prompt <root>/skills/writing-plans/coverage-verifier-prompt.md
  --set PLAN_FILE_PATH=<plan> --set SPEC_FILE_PATH=<spec>`
- 至少要有一個 `--task` 或 `--coverage`，否則報錯退出。

### 5.3 `review-impl.sh`

每個 task 的 spec-compliance 與 code-quality **並行**（取代原本兩段循序）。不傳
report file（見 §7）。

```
review-impl.sh --plan <plan.md> --task "Task N" --task-base <TASK_BASE> \
  --round N [--name X] [--max-parallel 5]
```

| label             | dispatch 呼叫 |
| ----------------- | ------------- |
| `spec-compliance` | `task --prompt <root>/skills/subagent-driven-development/spec-reviewer-prompt.md --set PLAN_FILE_PATH=<plan> --set TASK_ID="Task N" --set TASK_BASE=<TASK_BASE>` |
| `code-quality`    | `review --base <TASK_BASE>` |

subagent-driven-development 的**最終 adversarial 合併閘**仍維持單一
`dispatch.sh adversarial` 直呼，不納入批次（單一 reviewer 無並行需求）。

## 6. 不保存 prompt 中繼檔的決定

中繼檔僅保存 `output`，**不保存** prompt。prompt 對 `task` 子命令只是
spec-document-reviewer 等 sidecar 經佔位符替換後的結果，對 review/adversarial 更只是
base/focus 的轉述，事後幾乎用不到，且保存它會迫使引擎重現 dispatch.sh 的替換邏輯或
對 dispatch.sh 加旗標。捨棄後 dispatch.sh 維持零改動，中繼檔路徑簡化為單一
`<label>.<round>.output.md`。

## 7. 連帶變更：移除 spec-compliance reviewer 的 report file

review-impl 不再傳 `--report-file`。spec-compliance 的真正驗證是
`git diff <TASK_BASE>..HEAD` 對照 plan 中該 Task 的需求；implementer report 在
`spec-reviewer-prompt.md` 中本就被明示「不信任」，唯一獨有價值僅「宣稱做了但其實沒做」，
而只要該需求本在 plan Task 內，比對 plan↔diff 一樣會抓到缺失。移除 report 可省去 agent
管理暫存 report 檔與完成後清理的複雜度。

**`spec-reviewer-prompt.md` 變更**：移除 `[REPORT_FILE_PATH]` 佔位符與所有「讀取／引用
implementer report」的段落（保留並強化「以 plan Task 需求 ↔ `git diff(TASK_BASE..HEAD)`
獨立驗證」的核心）。其餘 prompt 的 Output Contract（`Status: OKAY` / `Status: Issues Found`）
不變。

## 8. 連帶變更：三個 SKILL.md 的 dispatch 段落改寫

把每個技能 review 迴圈中「N 個 `run_in_background` Bash call + 逐一等通知 + 逐一讀
stdout」改寫為「**單一** wrapper 呼叫」。round loop 的控制邏輯（哪些 reviewer 在哪一輪
跑、zero-tolerance、收斂條件）維持不變，只是每一輪改為呼叫一次對應 wrapper 並從其
stdout 一次取得全部結果。

- **brainstorming/SKILL.md**：spec review loop 改呼 `review-brainstorm.sh`。
- **writing-plans/SKILL.md**：Per-Task + Coverage 改呼 `review-plan.sh`（以多個
  `--task` 指定本輪 active tasks、以 `--coverage` 控制 Coverage Verifier 是否參與）。
- **subagent-driven-development/SKILL.md**：每個 task 的兩階段審查改呼
  `review-impl.sh`（spec 與 code-quality 並行）；流程語義由「先 spec OKAY 再
  code-quality」改為「兩者每輪並跑、任一有 blocking finding 就由 implementer 修完
  兩者後整批重跑」。最終 adversarial 合併閘段落維持原樣。

## 9. 失敗、並行與邊界

- 單一 reviewer 的 companion 失敗：其他 job 繼續跑完；失敗者的 output 區段標
  `ERROR`（附 stderr 摘要），彙整行標 `ERROR (exit <rc>)`；引擎最終非零退出。
- companion 未安裝／版本過低：`dispatch.sh` 既有硬停使該 job 非零退出 → 走上述
  ERROR 路徑（引擎不重複做版本檢查）。
- 並行度上限預設 5，可由 `--max-parallel` 調整；FIFO token-bucket 真正節流。
- review 目錄不存在時自動 `mkdir -p`。
- 同一 `<label>.<round>.output.md` 已存在（同輪重跑）→ 覆寫。

## 10. 驗證策略

仿 `dispatch.test.sh`，新增 `review-batch-lib.test.sh`，以 stub 的 `dispatch.sh`
（或 `--dry-run` 路徑 / 假 companion）驗證：

- job 組裝：每個 wrapper 把 CLI 參數正確轉為預期的 dispatch.sh argv（含含空白的
  `--set TASK_ID=Task 1` 不被切斷）。
- 中繼檔路徑命名：`<spec name>/<label>.<round>.output.md`，label 檔名安全化正確。
- stdout 彙整格式：heading 順序 = 登記順序；Summary 區段狀態行擷取（Status/Verdict/
  prose/ERROR 四種情形）。
- 失敗語義：一個 job 失敗時其他仍完成、失敗者標 ERROR、整體非零退出。
- 並行節流：同時並行數不超過 `MAX_PARALLEL`。

## 11. 設計取捨記錄

- **共用引擎 + 三薄包裝**（vs 三個完全獨立腳本 / dispatch.sh 加 batch 子命令）：
  零邏輯重複，且 dispatch.sh 職責不膨脹。
- **stdout 回傳全部 reviewer 全文 + 末尾 Status 彙整**（vs 只回摘要+路徑）：省 token
  的來源是「把多次來回壓成一次」，agent 一次拿到全部全文，不需為失敗 reviewer 再發
  讀檔呼叫。
- **round 由 agent 顯式傳、name 由檔名推**：腳本無狀態、跨技能語義一致，不靠掃描
  目錄猜輪數。
- **prompt 不落地**：保 dispatch.sh 零改動，並避免重現替換邏輯。
- **移除 report file**：report 本就不被信任，git diff 已是事實來源。
- **FIFO token-bucket 節流**：bash 3.2 可攜，且為真正滑動節流。

## 12. 非目標

- 不修改 `dispatch.sh` 既有三個子命令的行為。
- 不改變各 reviewer prompt sidecar 的審查準則（除 §7 移除 report 段落外）。
- 不改變各技能 review 迴圈的收斂條件與 zero-tolerance 政策。
- 不把 subagent 的最終 adversarial 合併閘納入批次。
- 不引入跨技能共用的單一「萬用」CLI——三個 wrapper 各自獨立面向自己的技能。
