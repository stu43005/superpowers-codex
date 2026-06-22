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

本案**不修改** `dispatch.sh`。引擎對每個 job 的調用形式固定為（stdout/stderr 先導向
本次私有暫存檔，之後依 §4.3「先彙整後發佈」原子 `mv` 到最終中繼檔）：

```
dispatch.sh <subcommand> <args...>   > <私有 stdout 暫存>   2> <私有 stderr 暫存>
```

引擎不需要從 dispatch.sh 取得 prompt 文字（中繼檔不再保存 prompt，見 §6）。
spec-compliance 改傳 `--set TASK_HEAD=<sha>`（見 §5.3）只是多一個 `--set` 鍵值，
dispatch.sh 既有的 `--set` 機制已支援，**仍無需對 dispatch.sh 新增任何旗標**。
§4.6 的 HEAD 斷言、§9 的發佈互斥鎖皆在引擎層，與 dispatch.sh 無關。

## 4. 共用引擎 `review-batch-lib.sh`

### 4.1 公開 API

引擎以函式庫形式被 wrapper `source`，對外提供：

- `batch_init`：重置內部 job 佇列；設定 `ROUND`、`SPEC_NAME`、`STAGE`、`MAX_PARALLEL`、
  review 目錄等批次層級狀態。`STAGE` 是該 wrapper 的階段識別（`brainstorm` / `plan` /
  `impl`，各 wrapper 寫死），用於 manifest 的命名空間（見 §4.3）——因三個技能共用同一
  `<spec name>` 目錄、且各自的 `<round>` 是**各階段本地**的計數，需以 `STAGE` 區隔 manifest
  以免同主題的 round 1 互相覆寫。
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
`$PWD` 為技能執行所在的 repo 根目錄。三個技能在同一主題共用此目錄。

該目錄下的檔案命名（prompt 不再保存，見 §6）：

```
<spec name>/<label>.<round>.output.md        # 每個 reviewer 一個（label 各階段互異）
<spec name>/<stage>.<round>.manifest.md       # 每個 wrapper 每輪一個完整性 manifest
<spec name>/.batch.<run-id>/ ...              # 隱藏 staging（同檔案系統，讀者忽略）
<spec name>/.batch.lock                       # §9 互斥鎖（讀者忽略）
```

- **`<round>` 是各階段本地計數**（brainstorm round 1 與 plan round 1 是不同階段、彼此獨立）；
  output 檔以 stage-互異的 `<label>` 區隔、manifest 以 `<stage>` 區隔，故同主題各階段
  evidence 在同一目錄共存而不互相覆寫。
- **讀者探索規則**：消費者只認 `<label>.<round>.output.md` 與 `<stage>.<round>.manifest.md`
  （皆非 `.` 開頭）；一律**忽略 `.` 開頭的項目**（`.batch.<run-id>/`、`.batch.lock`），故
  staging 與鎖對讀者不可見、不會被當證據。

每個 job 落地**一個** output 中繼檔 `<label>.<round>.output.md`。

`<label>` 經檔名安全化：非英數字元壓成單一 `-`（例如 `Task 1` → `Task-1`）。
**安全化後必須單射（injective）**：`batch_run` 在**啟動任何 job 之前**檢查所有 job 的
安全化檔名是否互異；若兩個不同 label 安全化後撞名（例如 `Task 1` 與 `Task-1`、或
`Task.1`）→ **fail fast** 報錯退出，列出衝突的原始 label，要求 caller 改用互異的 label。
`<stage>.<round>.manifest.md` 內記錄 **原始 label → canonical 檔名** 的對映，確保 manifest 與檔案
一一對應、讀者不會把碰撞造成的不完整輪當成有效。

**stdout/stderr 分工**：canonical 中繼檔 `<label>.<round>.output.md` **只含該 job 的
stdout**（reviewer 結果本體）。stderr **不**落地成 canonical 檔——它只留在私有暫存，供
§4.4 組裝 ERROR 摘要用，隨私有暫存目錄一併清理。

**四種「失敗/結束」語義必須分清（避免術語混用）**：

| 情形 | 是否發佈 canonical | 說明 |
| ---- | ------------------ | ---- |
| **reviewer 回 findings**（Issues Found / needs-attention，codex 執行成功 → **退出 0**） | **發佈** + manifest | 有效批次的**正常結果**；verdict 在 stdout，由 SKILL round loop 處理（§4.4）。批次退出 0。 |
| **單一 job 工具失敗**（無 verdict 行、退出非零 → `ERROR`） | **發佈**（含該 job stdout，即使為空）+ manifest | 仍是**有效批次**：其餘 reviewer 結果照常給 agent；該 job 在 Summary 標 `ERROR`，批次以非零退出當注意訊號、caller 重跑該 job（§4.4 / §4.5）。 |
| **批次無效**（§4.6 HEAD 漂移） | **不發佈** | 混合快照結果不可落地；只在 stdout 出現 `BATCH INVALID`。 |
| **訊號中斷**（INT/TERM，發佈前） | **不發佈** | 走下述 shutdown 路徑：終止子行程、清暫存、釋鎖。 |
| **發佈步驟失敗**（某 `mv` 失敗） | **回滾到前一個有效輪** | 還原備份、不寫 manifest（見步驟 3）。 |

**交易式生命週期**。為同時滿足「原子落地」「彙整只讀自己的輸出」「invalid/中斷/發佈
失敗不破壞既有有效證據」，`batch_run` 嚴格依下列交易進行：

1. **私有 staging（review 目錄下、同檔案系統、讀者忽略）+ shutdown trap**：`batch_run`
   以 `mktemp -d` 在 **review 目錄底下**建立隱藏的本次專屬 staging 目錄
   `<spec name>/.batch.<run-id>/`（`<run-id>` 由 `mktemp` 保證唯一）。**刻意置於 review 目錄
   內**，使 staging 與最終 canonical 檔**位於同一檔案系統** → 步驟 3 的 `mv` 是真正的
   same-filesystem 原子 rename（若改放 `$TMPDIR` 可能跨檔案系統，`mv` 會退化成 copy+unlink、
   失去原子性）；又因 staging 目錄以 `.` 開頭，依 §4.3 讀者探索規則**對消費者不可見**，
   不會被當證據。每個 job 的 stdout、stderr 各寫入此 staging 下的私有檔；各 job 的最終
   canonical 路徑於登記時即算好並存入內部陣列。**進場即裝 `trap <shutdown> EXIT INT TERM`**，
   shutdown 在**任一退出路徑**執行下列**順序**：
   - **停止再啟動新 job**（關閉 token bucket，不再從佇列取新工作）；
   - 對**已啟動仍在跑的子行程 PID** 送 `TERM`，逾時未退再送 `KILL`，並 `wait` **回收**
     （reap）之，確保不留孤兒 companion 行程對著已刪路徑空跑、也不會與隨後的 retry 並存；
   - 關閉/移除 FIFO 資源；
   - `rm -rf` 本次 staging 目錄 `<spec name>/.batch.<run-id>/`；
   - 釋放 §9 的 `.batch.lock`。
   （正常成功路徑由 EXIT 觸發同一 shutdown，此時子行程皆已 reap、暫存可清。）
2. **彙整（讀私有暫存）**：所有 job 結束後，`batch_run` **讀取私有暫存中的 stdout 檔**
   組裝 §4.4 的 stdout（全文 + Summary）；ERROR 摘要取自對應的私有 stderr 檔。彙整來源
   是私有暫存、不靠 glob 掃描 review 目錄，故別的批次對最終路徑的並行/事後覆寫**不會
   污染本次回傳結果**。
3. **發佈（全有全無、對同輪重跑可還原，僅在批次有效時）**：彙整完成**之後**、**且批次未被
   §4.6 判為無效**時才發佈。為使「同輪重跑」的發佈不會毀掉前一次已發佈的有效證據：
   - **先備份**：若該（stage, round）的 canonical 檔/`<stage>.<round>.manifest.md` 已存在
     （同輪重跑），先將**整組**既有檔搬到本次 staging 內的備份區（同檔案系統、不是刪除）。
   - **再發佈**：把每個 job 的 stdout staging 檔以 **same-filesystem 原子 `mv`** 改名到
     `<label>.<round>.output.md`（staging 與目標同在 review 目錄、同檔案系統，故為真正的原子
     rename）；全部成功後**最後**寫入本輪 **manifest** `<stage>.<round>.manifest.md`（列出本
     wrapper 本輪全部 label 及其 canonical 檔名）作為「本（stage, round）證據集完整」的權威
     信號。讀者僅在對應 manifest 存在且其列出的檔齊備時，才把該輪視為完整有效集。
   - **任一步失敗 → 整輪還原**：發佈過程中任何 `mv`/寫 manifest 失敗 → 把備份區的**整組
     舊檔與舊 manifest 原封還原**，使前一個已 commit 的輪次**完全保持原狀**，並以非零退出
     回報。**絕不**留下「新 manifest 指向缺檔」或「舊 manifest 配半套新檔」的混合態。
   - **成功**：發佈與 manifest 全部成功後，丟棄備份。
   - 批次無效（§4.6）時整個步驟 3 跳過：不動既有 canonical 檔、不寫 manifest。

如此：讀者永不會看到寫到一半的檔；invalid/中斷的執行**不留下讀者可見的證據**（staging
是 `.` 開頭、讀者忽略，且由 shutdown `rm -rf`、子行程被 reap）；同輪重跑發佈失敗時前一個
有效輪原樣保留；發佈用 same-filesystem 原子 rename。並行/重跑假設、互斥鎖與邊界見 §9。

### 4.4 stdout 彙整格式

依**登記順序**（非完成順序，確保輸出穩定可重現）串接每個 job 的全文，最後附一段
彙整：

```
## <label> (round <N>)
<該 job 的 stdout 全文（取自私有暫存，等同稍後發佈的 canonical 檔內容）>

## <label-2> (round <N>)
<...>

=== Summary (round <N>) ===
- <label>:   Status: OKAY
- <label-2>: Verdict: needs-attention
- <label-3>: ERROR (exit 1)
```

**退出碼 vs verdict 的語義（依 companion 原始碼，非推測）**：codex companion 的
`process.exitCode = execution.exitStatus = result.status`，即**codex 執行本身的狀態**——
reviewer 的審查結論（`Status: OKAY` / `Status: Issues Found`、`Verdict: approve` /
`Verdict: needs-attention`）一律寫在 **stdout 文字**裡。因此：

- reviewer **回報 findings**（Issues Found / needs-attention）時 codex 執行成功 →
  companion **退出 0**；findings 在 stdout，**不**靠退出碼表達。
- **退出碼非零代表「工具執行失敗」**（codex 執行錯誤、版本守門、companion 例外等），
  此時通常**沒有可解析的 verdict 行**。

故彙整行的狀態這樣判定（**verdict 以 stdout 為準，不以退出碼判審查結論**）：

1. 先在該 job 的 stdout 取**最後一行**符合 `^(Status|Verdict):` 的行 → 即該 reviewer 的
   審查結論（`OKAY` / `Issues Found` / `approve` / `needs-attention`），**無論退出碼為何**。
2. 若**無**此類 verdict 行**且退出碼非零** → `ERROR (tool failed, exit <rc>)`（工具失敗，
   在其 output 區段附 stderr 摘要）——這才是需要 caller **重跑該 job** 的情形。
3. 若退出碼為零但無 verdict 行（例如 code-quality reviewer 為 prose）→ `(prose — 見全文)`。
4. 邊界：退出碼非零但仍有可解析 verdict 行 → 以 verdict 為準（reviewer 已給結論），
   退出碼僅附註於該行尾。

### 4.5 退出碼與 partial-failure caller contract

`batch_run` 的退出碼**只反映工具層面是否有失敗**，**不**反映審查結論：

- **有任一 job 為 ERROR**（§4.4 第 2 點：無 verdict 行的工具失敗）或批次無效（§4.6）或
  發佈失敗（§4.3）→ `batch_run` **非零退出**（其餘 job 仍跑完）。
- **所有 job 都成功產生 verdict 行**（即使內容是 `Issues Found` / `needs-attention`）→
  **退出 0**。reviewer 找到問題是**正常結果**，由 SKILL 的 round loop 讀 verdict 行決定是否
  再迭代，**不**讓批次退出碼非零。

**caller contract（必須在 SKILL.md 呼叫端落實）**：

- wrapper 的 **stdout 在任何退出碼下都是完整且權威的**；非零退出**不會**截斷或丟棄 stdout。
- 三個技能的 SKILL.md 呼叫端**在任何退出碼下都讀取並解析 wrapper 的 stdout**（Summary 區段），
  據以判斷各 reviewer 是 OKAY / Issues Found / approve / needs-attention / prose / ERROR；
  **不得**因非零退出就略過 stdout。Claude Code 的 Bash 工具在指令非零退出時仍會完整回傳
  stdout 並附退出碼註記，故此契約在本 harness 可成立。
- **兩種「需要動作」要分清**：(a) **ERROR（工具失敗）** → caller **重跑該 job**（環境/版本/
  暫時性錯誤，非審查結果）；(b) **reviewer findings**（Issues Found / needs-attention）→
  caller 依 round loop **修正後 re-review**。批次非零退出只對應 (a)；(b) 由 stdout 的 verdict
  行驅動，與退出碼無關。

### 4.6 HEAD 快照一致性（diff 型 reviewer 的凍結保證）

diff 型 reviewer（code-quality 的 `review --base`、design-soundness 的
`adversarial --base`、spec-compliance 的 `git diff` 等）在 companion 內部各自對 `HEAD`
取 diff。若批次執行期間 `HEAD` 移動，兩個 reviewer 可能描述不同的 diff，卻被 caller
當成同一個原子閘——破壞 §5.3 的 invalidation 契約。引擎以下列方式凍結並偵測漂移：

1. **caller 契約**：`review-*.sh` 是**阻塞式單次呼叫**；caller（SKILL.md）在 wrapper
   執行期間**不得推進 `HEAD`**（不得提交/rebase/checkout）。
2. **引擎斷言 + 發佈前閘**：若在 git repo 內，`batch_run` 於**開始時**記錄
   `HEAD_AT_START=$(git rev-parse HEAD)`，於**所有 job 結束、彙整前**再讀一次 `HEAD`；
   若不一致 → 整個批次標為**無效**（非零退出，且 Summary 加一行
   `BATCH INVALID: HEAD moved during run (<a>→<b>) — rerun`），要求 caller 重跑。
   **無效批次不進入發佈**：跳過 §4.3 步驟 3 的 `mv`，**不寫任何 canonical
   `<label>.<round>.output.md`**——避免把混合快照的過時審查持久化成與有效證據同名的
   檔，讓事後的人或自動化誤當有效證據（漂移只會出現在 stdout 的 `BATCH INVALID` 行，
   不會落地）。這即使無法在 companion 內釘住 diff 終點，也能可靠偵測並阻止違反契約的
   結果落地。
3. **顯式釘住（可釘的部分）**：能以參數釘住 diff 終點的 reviewer 一律釘成不可變的
   commit pair，而非 `..HEAD`——見 §5.3 的 spec-compliance（透過 `--set TASK_HEAD`）。

**已知限制與為何如此（start/end 等值只偵測「最終漂移」）**：此斷言只在 job 全部結束後
比對一次 `HEAD`，因此**抓不到「執行中被改走又在結束前改回」的瞬態漂移**。要完全消除，
需把 diff 型 reviewer 釘到固定 ref：

- **detached worktree / 暫存 worktree** — 本專案規範**禁止任何 worktree 隔離**，排除。
- **改 companion/dispatch.sh 讓 `review` 接受顯式終點 SHA** — 違反「dispatch.sh 不變、
  不改 companion」核心約束，排除。

故採務實組合並明確承認殘餘風險：(a) spec-compliance 已用 `--set TASK_HEAD` **完全釘住**；
(b) code-quality 的 `review --base` 終點仍是 `HEAD`，由 caller 契約「阻塞呼叫期間不得推進
HEAD」+ §9 per-`<spec name>` 鎖（擋同主題並行批次）+ 本斷言（擋最終漂移）三者覆蓋常見情形；
(c) **瞬態改走又改回**屬高度對抗性的窄邊界，列為**已記載的可接受殘餘風險**，非設計疏漏。
若未來放寬 worktree 或 companion 約束，應改為把 code-quality 也釘到固定 ref。

## 5. 三個 wrapper 的 CLI

所有 wrapper 共通：

- `--round N`（必填）：由 agent 顯式傳入，作為中繼檔的 `<round>`。
- `--name <spec>`（選填）：覆寫 `<spec name>`；未給時由各 wrapper 的**主要文件檔名**
  推導——去掉前綴 `YYYY-MM-DD-`、去掉副檔名與 `-design`/`-plan` 後綴。例：
  `2026-06-22-parallel-reviewer-batch-dispatch-design.md` → `parallel-reviewer-batch-dispatch`。
  **`<spec name>` 嚴格驗證（對推導值與 `--name` 覆寫值都套用，於建立目錄/鎖之前）**：
  規則為 `^[A-Za-z0-9_-][A-Za-z0-9._-]*$`——**首字元不得為 `.`**（避免產生隱藏目錄、或與
  讀者忽略的 `.` 開頭 staging/鎖混淆），其餘字元限英數與 `._-`；**拒絕**空值、`.`、`..`、
  前導 `.`（含 `.foo`）、含路徑分隔符（`/`、`\`）、或絕對路徑樣式的值——避免把
  lock/manifest/輸出寫到 review 命名空間外、或讓兩個邏輯 spec 別名到同一目錄互相覆寫
  （這也保護 §9 的 per-`<spec name>` 鎖）。不合法 → fail fast。
- `--max-parallel N`（選填，預設 5）。**在建立 FIFO token bucket 前嚴格驗證**：只接受
  正十進位整數（`^[1-9][0-9]*$`）；`0`、空值、非數字一律 **fail fast** 報錯退出（避免
  token 數為 0 時 job 永遠等不到 token 而死鎖）。並設一個有文件記載的安全上限（預設
  上限 16），超過則夾到上限並提示。

**各 wrapper 的 `<spec name>` 預設來源（明確指定，避免歧義）**：

| wrapper                | 推導來源       | 去除的後綴 | 固定 `STAGE` |
| ---------------------- | -------------- | ---------- | ------------ |
| `review-brainstorm.sh` | `--spec`       | `-design`  | `brainstorm` |
| `review-plan.sh`       | `--plan`       | `-plan`    | `plan`       |
| `review-impl.sh`       | `--plan`       | `-plan`    | `impl`       |

各 wrapper 對 `batch_init` 傳入上表的固定 `STAGE`，用於 manifest 命名空間
`<stage>.<round>.manifest.md`（見 §4.3）；`<round>` 為各 stage 本地計數。

設計意圖：同一主題的 design 與 plan 檔共用相同 topic stem（`2026-06-22-<topic>-design.md`
與 `2026-06-22-<topic>-plan.md` 去後綴後皆為 `<topic>`），因此三個技能在**同一主題**的
所有審查輪次都落在**同一個 `<spec name>` 目錄**下，便於彙整該主題的全部 reviewer 證據。
三階段以 stage-互異的 reviewer `<label>` 與 stage-namespaced manifest 區隔，彼此不覆寫。
review-impl 雖只收 `--plan`，仍能由 plan 檔名得到與 brainstorming/writing-plans 一致的
`<spec name>`，無需額外傳 spec 路徑；任何技能要覆寫時用 `--name`。

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

review-impl.sh 於**開始時**擷取 `TASK_HEAD=$(git rev-parse HEAD)`，把這個不可變 SHA
釘給 spec-compliance（讓其 `git diff` 用固定的 `[TASK_BASE]..[TASK_HEAD]` commit pair，
而非 `..HEAD`）。code-quality 的 `review --base` 在 companion 內部取 `..HEAD`，無參數可
釘終點，但由 §4.6 的引擎 HEAD 斷言保證「批次期間 HEAD 未移動」，故其 `HEAD` 等同
`TASK_HEAD`。

| label             | dispatch 呼叫 |
| ----------------- | ------------- |
| `spec-compliance` | `task --prompt <root>/skills/subagent-driven-development/spec-reviewer-prompt.md --set PLAN_FILE_PATH=<plan> --set TASK_ID="Task N" --set TASK_BASE=<TASK_BASE> --set TASK_HEAD=<TASK_HEAD>` |
| `code-quality`    | `review --base <TASK_BASE>` |

subagent-driven-development 的**最終 adversarial 合併閘**仍維持單一
`dispatch.sh adversarial` 直呼，不納入批次（單一 reviewer 無並行需求）。

**並行化的 snapshot / invalidation / rerun 契約（取代原本的循序閘）**：

原本「先 spec OKAY，再跑 code-quality」是**循序閘**——code-quality 只在 spec 通過後才
解讀。改為並行後，必須明定以下契約，否則會出現「一個過、一個敗，修完又使先前的過
失效」的競態：

1. **同一 snapshot**：同一次 `review-impl.sh` 呼叫中，spec-compliance 用釘住的
   `git diff <TASK_BASE>..<TASK_HEAD>`、code-quality 的 `review --base <TASK_BASE>` 在
   companion 內取 `..HEAD`；由 §4.6 保證批次期間 `HEAD == TASK_HEAD`（漂移即整批無效），
   故兩者實際針對**同一個不可變 commit pair**。
2. **任一修改使雙方結果一起失效**：只要該 task 在本輪後有任何修正提交（HEAD 前進），
   spec-compliance 與 code-quality 的**先前結果全部作廢**——不得保留「上一輪某一方已
   通過」的狀態。
3. **修完整批重跑**：implementer 必須**一次修完兩個 reviewer 本輪的全部 blocking
   findings**，再以同一個 `<TASK_BASE>`、新的 HEAD **重跑整個 `review-impl.sh` 批次**
   （兩個 reviewer 都重跑）。
4. **收斂條件**：該 task 只有在**單一次批次呼叫內、且其後無任何修改**的情況下，
   spec-compliance 回 `Status: OKAY` **且** code-quality 無 blocking finding，才算通過、
   進入下一個 task。
5. **「一過一敗」的處理**：一方過、另一方有 blocking → 仍須修，修改觸發第 2 點使
   先前「過」的一方作廢，第 4 點要求兩者在無修改的同一批次都過才收斂，故不會接受
   過時的通過。

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

**證據完整性要求（取代 report 作為證據來源）**：移除 report 後，spec-compliance 的可審
證據**一律以 `git diff <TASK_BASE>..[TASK_HEAD]` 為事實來源**。對於 diff 不能直接呈現的
產物（生成檔、移動/改名、被 gitignore 的檔、runtime 行為、git 外部副作用），**plan 的該
Task 必須以「會落進 diff 的可驗證形式」表達預期結果**——主要手段是**提交測試**：在該
skill 既有的 TDD 政策下，runtime 行為與生成輸出皆由 implementer 提交的測試斷言，而**測試
本身就在 git diff 內**，reviewer 能直接讀到並據以驗證。

**為何 report 即使對非 diff 產物也補不上這個洞**：implementer report 是 **prose 自述**，
`spec-reviewer-prompt.md` 本就明示「**不信任** report」。一句「我已更新外部 DB / 已生成
資產 Z」是**不可驗證的主張**，不構成證據；真正能驗證的仍是「提交一個讀取/檢查該外部
狀態或生成檔的測試」——而那同樣落在 diff 裡。因此保留 report 並不會把「非 diff 可見
產物」變得可驗證，只會把不可信的 prose 重新引入。結論：以「測試入 diff」為證據通道，
嚴格強於以 report 為通道。

**`spec-reviewer-prompt.md` 變更**：
- 移除 `[REPORT_FILE_PATH]` 佔位符（第 7 行）與「讀取 implementer report 看其 CLAIM」
  段落（第 11 行）及「不信任 report」框架中對 report 的引用；保留並強化「以 plan Task
  需求 ↔ git diff 獨立驗證」的核心。
- **把 diff 範圍由 `git diff [TASK_BASE]..HEAD` 改為釘住的 `git diff [TASK_BASE]..[TASK_HEAD]`**
  （新增 `[TASK_HEAD]` 佔位符，由 review-impl.sh 以 `--set TASK_HEAD` 注入；見 §4.6 / §5.3
  的 HEAD 凍結）。
- Output Contract（`Status: OKAY` / `Status: Issues Found`）不變。

**相容性／遷移盤點（已查證現有 footprint）**：

| 位置 | 現況 | 處置 |
| ---- | ---- | ---- |
| `spec-reviewer-prompt.md` | 含 `[REPORT_FILE_PATH]` 佔位符 | 移除（如上） |
| `subagent-driven-development/SKILL.md` | 建立 report mktemp → `--report-file` 傳入 → 完成後 `rm`，並有對應流程圖/範例/檔案清單描述 | 全部移除這套接線，改為 §8 的 `review-impl.sh` 單一呼叫 |
| `implementer-prompt.md` | 要求 implementer 回報 Status/實作/測試/自審（§"Report Format"） | **不改**——該 report 是 subagent **回傳給父 agent 的訊息**、非磁碟檔；移除後它仍是給父 agent 的有用上下文，不是 dead path |
| `dispatch.sh` | `cmd_task` 仍支援 `--report-file` 通用選項 | **不改**——僅「review-impl 不再使用」，非死碼；保留供未來其他用途 |
| `dispatch.test.sh` | 測試 `--report-file` 行為 | **不改**——dispatch.sh 該選項仍在，測試仍有效 |

要點：除了 prompt 佔位符與 subagent SKILL.md 的接線，沒有其他 caller 依賴 report 檔
（已 grep 全 repo 確認）；implementer 的 report 改回單純的 subagent 回傳訊息，不產生
孤兒檔或失效路徑。

## 8. 連帶變更：三個 SKILL.md 的 dispatch 段落改寫

把每個技能 review 迴圈中「N 個 `run_in_background` Bash call + 逐一等通知 + 逐一讀
stdout」改寫為「**單一** wrapper 呼叫」。round loop 的控制邏輯（哪些 reviewer 在哪一輪
跑、zero-tolerance、收斂條件）維持不變，只是每一輪改為呼叫一次對應 wrapper 並從其
stdout 一次取得全部結果。

- **brainstorming/SKILL.md**：spec review loop 改呼 `review-brainstorm.sh`。
- **writing-plans/SKILL.md**：Per-Task + Coverage 改呼 `review-plan.sh`（以多個
  `--task` 指定本輪 active tasks、以 `--coverage` 控制 Coverage Verifier 是否參與）。
- **subagent-driven-development/SKILL.md**：每個 task 的兩階段審查改呼
  `review-impl.sh`（spec 與 code-quality 並行，遵循 §5.3 的 snapshot/invalidation/rerun
  契約）；流程語義由「先 spec OKAY 再 code-quality」改為「兩者每輪並跑、任一有
  blocking finding 就由 implementer 一次修完兩者再整批重跑」。同時**移除 §7 盤點的
  report 接線**（report mktemp 建立、`--report-file` 傳入、完成後 `rm`，及對應流程圖
  節點、範例 log、檔案清單描述）。最終 adversarial 合併閘段落維持原樣。
- 三個 SKILL.md 的呼叫端說明都須落實 §4.5 的 partial-failure caller contract（任何
  退出碼都讀並解析 wrapper stdout 的 Summary）。

## 9. 失敗、並行與邊界

- 單一 reviewer 的 companion 失敗：其他 job 繼續跑完；失敗者的 output 區段標
  `ERROR`（附 stderr 摘要），彙整行標 `ERROR (exit <rc>)`；引擎最終非零退出。
- companion 未安裝／版本過低：`dispatch.sh` 既有硬停使該 job 非零退出 → 走上述
  ERROR 路徑（引擎不重複做版本檢查）。
- 並行度上限預設 5，可由 `--max-parallel` 調整；FIFO token-bucket 真正節流。
- review 目錄不存在時自動 `mkdir -p`。
- **staging 為 review 目錄下隱藏同檔案系統子目錄** `.batch.<run-id>/`（`mktemp -d`），與
  canonical 同檔案系統以確保發佈是原子 rename，且 `.` 開頭被讀者忽略；由 shutdown trap 在所有
  退出路徑 `rm -rf`，故 invalid/中斷不會在 review 目錄留下**讀者可見**的審查殘骸（§4.3）。
- **訊號中斷＝完整 shutdown**：INT/TERM 時 trap 先停止啟動新 job、對在跑子行程送
  TERM→（逾時）KILL 並 `wait` 回收、關閉 FIFO，**最後**才清暫存與釋鎖；確保不留孤兒
  companion 行程，也不會與隨後的 retry 並存（§4.3 步驟 1）。
- **發佈全有全無 + 同輪重跑可還原**：成功批次最後寫 `<stage>.<round>.manifest.md` 作為
  完整性信號；發佈前先備份既有同（stage, round）檔組，任一 `mv`/manifest 失敗 → **整組還原
  舊檔與舊 manifest**、前一個有效輪原樣保留、不寫新 manifest（§4.3 步驟 3）。
- **同一 `<label>.<round>.output.md` 已存在（同輪重跑）**：以「先備份既有整組 → 原子 `mv`
  → 寫新 manifest；失敗則整組還原」處理，最終檔永遠是某一次完整輸出，且重跑失敗不毀掉
  前一次有效證據。
- **互斥鎖在啟動任何 job 前取得（fail fast，避免輸家白跑全程）**：`batch_run`
  **在登記後、啟動任何 reviewer job 之前**，先以**原子 `mkdir`** 取得
  `<review 目錄>/.batch.lock` 作為 per-`<spec name>` 互斥鎖（lock 目錄內記錄持有者 PID
  與 round），持有至發佈完成，於 trap 中移除。
  - `mkdir` 在 POSIX 上是原子操作，bash 3.2 / BSD 可攜（不依賴 `flock`，後者 macOS
    預設無）。
  - 取鎖失敗（另一批次正持有）→ **立刻 fail fast**，印出可行動訊息（「`<spec name>`
    已有審查批次在跑；請改傳不同 `--name`，或移除殘留的 `.batch.lock`」）。**在花費
    任何 reviewer 成本之前**就退出——輸家不會白跑完整輪審查、也不會在發佈時才失敗
    而丟失持久證據。如此兩個 agent 同名同 round 並行時，只有先取鎖者會實際執行。
  - 殘留鎖（持有者已死）：訊息明確指引手動移除；引擎不自動猜測 PID 存活以免誤判。
  - 鎖涵蓋整個 `batch_run`（啟動 job → 彙整 → 發佈），確保同一 `<spec name>` 的批次
    完全序列化，與「同一主題同時只有一個審查迴圈」的模型一致。
- **並行/重跑隔離假設**：預設模型仍是「同一 `<spec name>` 同時只有一個審查迴圈」
  （單一 agent 循序推進輪次，`--round` 對每個邏輯輪次唯一）。上面的互斥鎖把「違反此
  假設」從「靜默毀證據」變成「fail fast 報錯」。要真正並行同一主題，由 caller 傳不同
  `--name` 分流到不同目錄。

## 10. 驗證策略

仿 `dispatch.test.sh`，新增 `review-batch-lib.test.sh`，以 stub 的 `dispatch.sh`
（或 `--dry-run` 路徑 / 假 companion）驗證：

- job 組裝：每個 wrapper 把 CLI 參數正確轉為預期的 dispatch.sh argv（含含空白的
  `--set TASK_ID=Task 1` 不被切斷）。
- 中繼檔路徑命名：`<spec name>/<label>.<round>.output.md`，label 檔名安全化正確。
- stdout 彙整格式：heading 順序 = 登記順序；Summary 區段狀態行擷取（Status/Verdict/
  prose/ERROR 四種情形）。
- 失敗語義：一個 job 失敗時其他仍完成、失敗者標 ERROR、整體非零退出。
- **partial-failure stdout 完整性**：模擬一個 reviewer 失敗，驗證**非零退出下 stdout 仍
  含完整全文 + Summary**（含失敗者的 ERROR 行與成功者的狀態行），對應 §4.5 caller
  contract。
- **原子寫入與本次擁有權**：驗證最終檔由原子 `mv` 落地（無半寫狀態）；且預先在 review
  目錄塞入一個別人的舊 `<label>.<round>.output.md`，確認本次 `batch_run` 的 Summary
  只反映自己這次的輸出、不被既有檔污染（§4.3）。
- **先彙整後發佈順序**：驗證彙整在 `mv` 之前完成（私有暫存於彙整時仍存在），最終檔在
  彙整後才出現（§4.3 步驟順序）。
- **HEAD 漂移偵測 + 不發佈 + staging 清理**：在批次執行中讓 `HEAD` 變動，驗證引擎標
  `BATCH INVALID`、非零退出，**且不產生任何 canonical 檔或 manifest**，**且 staging 目錄
  `.batch.<run-id>/` 被 trap 清掉**（review 目錄無讀者可見殘骸）（§4.3 / §4.6）；HEAD 不動時正常發佈。
- **canonical 僅含 stdout**：job 同時有 stdout 與 stderr 時，驗證 `<label>.<round>.output.md`
  只含 stdout，stderr 僅出現在彙整的 ERROR 摘要、且不落地成 canonical 檔（§4.3 stdout/stderr
  分工）。
- **訊號中斷＝無孤兒行程**：對 `batch_run` 送 INT/TERM，驗證在跑子行程被 TERM/KILL 並
  reap（無存活 child）、私有暫存被清、鎖被釋；且**緊接的 retry 不會與舊 job 重疊**（能取到鎖）。
- **同輪重跑發佈失敗保前一輪**：先成功發佈一輪（有 canonical + manifest），再對同輪重跑注入
  某個 `mv` 失敗，驗證**前一個有效輪的檔與 manifest 原封還原**、不出現「新 manifest 配半套
  新檔」或「舊 manifest 配缺檔」的混合態、非零退出（§4.3 步驟 3 備份/還原）。
- **canonical/job 失敗仍發佈**：reviewer job 非零退出（有效批次）時，驗證**仍發佈**所有
  canonical 檔 + manifest、Summary 標 ERROR、整體非零退出（§4.3 術語表、§4.5）。
- **瞬態 HEAD 漂移為已記載限制**：start==end 但中途改走又改回 → 斷言不報（記載限制，非
  bug）；最終仍不同 → 報 `BATCH INVALID`（§4.6）。
- **manifest 完整性信號 + stage 命名空間**：成功批次最後寫出 `<stage>.<round>.manifest.md`
  且列出全部 label；無 manifest 的輪次不被視為完整有效集。並驗證**同主題不同 stage 的
  round 1**（`brainstorm.1.manifest.md` / `plan.1.manifest.md` / `impl.1.manifest.md`）
  共存於同一 `<spec name>` 目錄、**互不覆寫**（§4.3）。
- **same-filesystem 原子發佈**：驗證 staging 目錄 `.batch.<run-id>/` 建在 review 目錄底下
  （與 canonical 同檔案系統），發佈 `mv` 為原子 rename；以 mock 模擬跨裝置 rename/copy 失敗時
  走步驟 3 還原、不留半寫檔（§4.3 步驟 1/3）。
- **讀者忽略 `.` 開頭項**：驗證探索 canonical 證據時略過 `.batch.<run-id>/`、`.batch.lock`，
  只認 `<label>.<round>.output.md` 與 `<stage>.<round>.manifest.md`（§4.3 讀者探索規則）。
- **互斥鎖在 job 啟動前 fail fast**：預先建立 `.batch.lock` 模擬另一批次持鎖，驗證本次
  **在啟動任何 reviewer job 之前**就 fail fast、報出可行動訊息、且**不覆寫**既有最終檔、
  也不花費 reviewer 成本（§9）。
- **`--max-parallel` 驗證**：`0`/空/非數字 → fail fast；超過上限 → 夾到上限；正整數 →
  通過（§5 共通參數）。
- **各 wrapper 名稱推導**：`review-brainstorm.sh` 由 `--spec` 去 `-design`、
  `review-plan.sh` 與 `review-impl.sh` 由 `--plan` 去 `-plan`，同主題三者得到一致
  `<spec name>`；`--name` 覆寫生效。
- **label 安全化單射**：兩個不同 label 安全化後撞名（如 `Task 1` 與 `Task-1`）→ **fail
  fast**、列出衝突、不啟動任何 job（§4.3）；互異 label 正常。
- **`<spec name>` 驗證**：`--name` 或推導值含 `..`、`/`、`\`、**前導 `.`（含 `.foo`）**、空值、
  絕對路徑樣式 → fail fast；合法值（`^[A-Za-z0-9_-][A-Za-z0-9._-]*$`）通過，且輸出/鎖/manifest
  不逸出 review 命名空間（§5；含 `.foo` 一律拒絕，與本規則一致）。
- **退出碼 vs verdict 分類**：以 stub companion 模擬「成功且 stdout 含 `Status: Issues Found`」
  → 該 job 退出 0、Summary 標 `Issues Found`、**批次退出 0**；模擬「無 verdict 行且退出非零」
  → Summary 標 `ERROR`、批次退出非零（§4.4 / §4.5）。
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
- **移除 report file**：report 本就不被信任，git diff 已是事實來源；implementer 的
  report 改回單純的 subagent 回傳訊息（非磁碟檔），無孤兒路徑。
- **FIFO token-bucket 節流**：bash 3.2 可攜，且為真正滑動節流。
- **原子 `mv` + 彙整只讀本次私有暫存**（vs 直接寫最終路徑 + glob 目錄）：避免並行/同輪
  重跑時的半寫檔與交錯污染；持久證據的跨 agent 互斥另由 §9 的 `mkdir` 鎖在 job 啟動前
  把競態轉為 fail fast（兩者互補：原子 `mv` 防半寫，鎖防同名覆寫毀證據）。
- **非零退出但 stdout 權威**（保留使用者「非零退出」決策，並補 caller contract）：以
  「stdout 任何退出碼都完整」的 harness 行為為前提，非零碼僅作注意訊號。
- **並行 impl reviewer 的 invalidation 契約**（vs 保留循序閘）：以「任一修改使雙方失效、
  同一無修改批次雙方皆過才收斂」消除「一過一敗後修改使過時通過」的競態。
- **HEAD 凍結＝顯式釘住 + 引擎斷言**（vs 只傳 base 任 reviewer 各自取 HEAD）：能釘的
  reviewer 釘成 commit pair，不能釘的（`review --base`）由引擎偵測 HEAD 漂移補強，兩者
  皆不需改 dispatch.sh/companion。
- **發佈期 `mkdir` 互斥鎖**（vs 在檔名加 run-id / 不防護）：保留使用者指定的
  `<reviewer>.<round>.output.md` 檔名格式，同時把「並行靜默覆寫毀證據」轉為 fail fast；
  用 `mkdir` 原子性而非 `flock`（macOS 無）以維持 bash 3.2/BSD 可攜。
- **交易式發佈**（staging 為 review 目錄下隱藏同檔案系統子目錄 `.batch.<run-id>/`、shutdown
  終止並回收子行程、stage-namespaced manifest 完整性信號、同輪重跑備份/還原；vs 直接寫最終
  路徑、失敗不清理、trap 只刪暫存）：staging 同檔案系統確保發佈是真正的原子 rename（放
  `$TMPDIR` 會跨檔案系統失去原子性），又因 `.` 開頭被讀者忽略而不污染證據；invalid/中斷不留
  讀者可見殘骸、不留孤兒 companion；同輪重跑發佈失敗時前一個有效輪原樣保留，不會「新 manifest
  配缺檔」。canonical 僅含 stdout、stderr 留私有。三技能共用 `<spec name>` 目錄、以 stage-互異
  label 與 stage-namespaced manifest 並存不覆寫。
- **HEAD 凍結的殘餘風險明確化**：spec-compliance 完全釘住；code-quality 終點因「禁用
  worktree + 不改 companion」無法釘住，故 start/end 斷言只擋最終漂移，瞬態改走又改回列為
  **已記載可接受殘餘風險**，靠 caller 契約 + 鎖 + 斷言覆蓋常見情形。
- **verdict 以 stdout 為準、退出碼只表工具成敗**（依 companion 原始碼，非推測）：reviewer
  findings 走 stdout 不觸發批次非零；ERROR 專指「無 verdict 行的工具失敗」才需重跑——
  把「修 findings」與「重跑工具」兩種動作分清。
- **輸入驗證 fail fast**（label 安全化單射、`<spec name>` 字元白名單）：在啟動 job/建立
  目錄前擋掉碰撞與路徑跳脫，避免不完整/逸出命名空間的證據集。
- **`--max-parallel` 嚴格驗證 + 安全上限**：把 0/空/非數字導致的 FIFO 死鎖轉為 fail
  fast 的可行動錯誤。

## 12. 非目標

- 不修改 `dispatch.sh` 既有三個子命令的行為。
- 不改變各 reviewer prompt sidecar 的審查準則（除 §7 移除 report 段落外）。
- 不改變各技能 review 迴圈的收斂條件與 zero-tolerance 政策。
- 不把 subagent 的最終 adversarial 合併閘納入批次。
- 不引入跨技能共用的單一「萬用」CLI——三個 wrapper 各自獨立面向自己的技能。
- **不為 spec-compliance 重建 implementer report / evidence 檔通道（明確可接受限制）**：
  真正落入 git diff 的變更（含提交的測試）是事實證據；無法以「會進 diff 的測試」表達的
  純外部副作用，本就無法被 prose report 可信地驗證（reviewer prompt 既定不信任 report），
  故不在 spec-compliance 自動審查範圍，改由「implementer 提交的測試 + 最終 adversarial
  合併閘 + user-review gate 的人工審查」涵蓋。此為刻意取捨，非疏漏。
