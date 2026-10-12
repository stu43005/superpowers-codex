# 合併 per-task reviewer 為 task-acceptance — 設計規格

## 背景與問題

`subagent-driven-development` 每個 task 完成後，`scripts/review-impl.sh` 會並行派出四個
reviewer：

| Reviewer | Prompt | 讀 spec | 回答的問題 |
|---|---|---|---|
| `spec-compliance` | `spec-reviewer-prompt.md` | 是 | 做對了沒（誤解、extra work、non-goals、證據） |
| `code-quality` | 原生 code review | 否 | 寫得好不好 |
| `task-coverage` | `task-coverage-prompt.md` | 是 | 做完了沒（逐條對照、證據） |
| `task-seam` | `task-seam-prompt.md` | 否 | 接得上既有程式嗎（介面一致、文件 reference 外洩、殘留 placeholder） |

實際執行一輪多 task 實作的觀察：

- `spec-compliance` 與 `task-coverage` 的輸入完全相同（spec、task summary line、
  `TASK_BASE..HEAD` diff），兩份 prompt 的 Evidence Rules 表格一字不差，等於每輪把 spec 與
  diff 各讀兩次。
- `task-seam` 抓到的 2 項問題中，一項與其他 reviewer 重複，另一項 final-adversarial 在 final
  gate 也抓到。
- 多輪循環的 task 每輪都重跑全部四個 reviewer，token 成本隨輪數線性放大。

## 目標

1. 把 `spec-compliance`、`task-coverage`、`task-seam` 合併為單一 reviewer `task-acceptance`；
   每個 task 的 reviewer 從 4 個減為 2 個（`task-acceptance` + `code-quality`）。
2. 合併後保留 `task-seam` 的「先不看 spec、只拿 diff 對照既有程式」視角，以分階段順序實現。
3. 合併後每一條 spec 要求同時檢查「有沒有做」與「內容是否符合 spec 原意」，避免「有實作但
   內容與 spec 不一致」被判為 met。

## 設計

### 1. 新 reviewer prompt：`skills/subagent-driven-development/task-acceptance-prompt.md`

名稱選 `task-acceptance`（驗收），以和負責程式品質的 `code-quality` 明確區隔：本 reviewer
不評程式寫得好不好，只驗收該 task 是否接得上既有程式、是否完整且正確地實現 spec、是否越界。

**Placeholder：** `[SPEC_FILE_PATH]`、`[TASK_SUMMARY]`、`[TASK_BASE]`，語意與現行
`spec-reviewer-prompt.md` 相同（task summary 只用來界定適用的 spec 章節，本身不是要求）。

**共通規則（沿用現行 prompt）：**

- 唯一的實作事實來源是 reviewer 自行執行的 `git diff [TASK_BASE]..HEAD`；不信任 commit
  message、程式註解或任何 prose 摘要。
- diff 中對 `[SPEC_FILE_PATH]` 本身的修改不是實作，不列為 extra work，也永遠不算證據；以 `HEAD`
  的 spec 為準。
- reviewer 看不到 task 的切分方式：Phase 2 列出所有未完成項目，不判斷是否由後續 task 負責。

**Phase 1 — Seam（不讀 spec）：**

- 執行 `git diff [TASK_BASE]..HEAD`，並以 `HEAD` 的 repo（例如 `git grep`）找出 caller 與
  callee。
- 依序完成三項檢查，檢查內容與判定標準沿用現行 `task-seam-prompt.md`：
  1. Interface Consistency
  2. Document Reference Leak（含現行的「不算外洩」例外：commit message 與 `Task:` trailer、
     主題本身是 task / spec 的產品內容）
  3. Residual Placeholders（含現行例外：以這些標記為主題的文字不算）
- 排除 `docs/superpowers/specs/` 底下的變更。
- **順序約束（prompt 中明文）：** 在 Phase 1 的結果寫出之前，不得開啟 spec 檔案；進入
  Phase 2 之後，不得以 spec 的敘述推翻 Phase 1 從程式碼查得的事實（例如 spec 說「輸出 JSON」，
  不能因此改判 consumer 的 parse 方式沒問題）。

**Phase 2 — Spec 逐條對照：**

- 讀取 task summary 列出的章節、這些章節依賴的其他章節（定義、共用規則、設計決策），以及
  spec 中任何 Non-goals / Accepted limitations 章節。
- 列出這些章節中的每一條功能要求與描述的行為，以及每一條以「must / should / need / must not /
  avoid」或同義詞表述的條件。
- 每一條依 Evidence Rules 分類並尋找對應的充分證據；Evidence Rules 表格只保留一份，內容與現行
  兩份 prompt 相同（Executable behavior / Declarative / Preserve unchanged / Inherently manual
  四類）。證據來源：主要是 diff，輔助是 `HEAD` 已存在的程式與測試。
- **每一條另外判斷「Matches spec intent」：** 實作內容是否與 spec 的原意一致（包含是否違反
  spec 陳述的設計決策：架構、資料結構、API 形狀、錯誤處理策略、責任歸屬）。有實作但內容與
  spec 不一致，Result 判為 `not met`。

**Phase 3 — Scope：**

- Extra / unneeded work：做了列出章節沒要求的東西、過度工程、spec 沒有的 nice-to-have。
- Non-goals：實作了 spec 明列為不做的項目（Non-goals 清單或 Non-goals / Accepted
  limitations 章節）。spec 沒有這類章節時，此項無事可報。

**Calibration：** 只回報真實問題；spec 與實作之間的細微措辭差異不算問題，風格偏好不算問題。

**Issue 回報要求：** 每個 issue 必須附精確位置（`file:line`）與具體修正（patch 或可直接套用的
替換內容），沿用現行 `spec-reviewer-prompt.md` 的強制規定。Phase 2 表格中 `not met` 的列也
適用：「Incomplete items」清單的每一項須附位置（實作位置，或應新增實作／測試的位置）與修正。

**輸出格式（依序）：**

1. `### Seam Issues`：每項 `(check name): file:line — (問題) — (造成的破壞或誤導) — (修正)`；
   另可列 advisory recommendations（不影響 Status）。
2. `### Task Coverage`：表格欄位為 Condition、Source section、Implementation location、
   Test evidence、Matches spec intent、Result；`met` 的列也不得省略。表格後列
   `Incomplete items`。
3. `### Scope Issues`：Extra work 與 Non-goals 的問題。
4. `Needs manual confirmation:`：每項說明人工需確認的內容與相關 `file:line`。
5. 最後一行必須恰為 `Status: OKAY` 或 `Status: Issues Found`。只有當三個 Phase 都無 issue、
   且表格每列皆為 `met` 或 `needs manual confirmation` 時，才是 `Status: OKAY`。

### 2. 刪除舊 prompt

刪除 `spec-reviewer-prompt.md`、`task-coverage-prompt.md`、`task-seam-prompt.md`。三者只被
`review-impl.sh` 使用，不保留相容層。

### 3. `scripts/review-impl.sh`

- 改為註冊兩個 job，順序為 `task-acceptance`、`code-quality`：
  - `task-acceptance`：`task --prompt "$SDD_DIR/task-acceptance-prompt.md"`，帶
    `--set SPEC_FILE_PATH=...`、`--set TASK_SUMMARY=...`、`--set TASK_BASE=...`；
    `batch_claude_model sonnet`。
  - `code-quality`：維持 `review --base "$TASK_BASE"`；`batch_claude_model sonnet`。
- 檔頭說明註解改為描述這兩個 reviewer；移除 task-seam 專屬註解。
- 參數介面（`--spec`、`--task-summary`、`--task-base`、`--max-parallel`）不變。
- `review-batch-lib.sh` 不需修改：Summary 解析以 label 與 `Status:` / `Verdict:` 行為準，
  與 reviewer 數量無關。

### 4. `skills/subagent-driven-development/SKILL.md`

所有提到舊 reviewer 名稱或數量的地方改為新設計：

- **開頭說明與 Core principle：** 「four reviewers (spec-compliance, code-quality,
  task-coverage, task-seam)」→「two reviewers (task-acceptance, code-quality)」；
  「one batched four-reviewer review」照改。
- **Per-Task Batched Review：** 開頭「The four per-task reviewers」改為兩個；reviewer 表格改為
  兩列：
  - `task-acceptance`：Does it fit the existing code (checked from the diff before reading the
    spec)? Is it done? Is it right? Does it stay in scope and respect the Non-goals? —
    `Status: OKAY | Issues Found`
  - `code-quality`：維持現行內容。
- **Caller control-flow 第 2 步：** 改為「task-acceptance 為 `Status: OKAY` /
  `Status: Issues Found`；code-quality 為 `(prose — 見全文)`」。
- **Pass condition：** 文字維持「every `Status:` reviewer …」，語意不變（現在只有
  task-acceptance）。
- **Finding Attribution：** 「task-coverage (and spec-compliance) may report requirements」與
  條件 2「so that task's task-coverage reviewer will check it」改為 task-acceptance；
  Scope-sync rule 中「keeps spec-compliance from flagging the folded work as out of scope and
  makes task-coverage check it」改為 task-acceptance 的對應敘述。
- **Manual-Check Items：** 來源改為「task-acceptance and spec-coverage」。
- **Final Gate：** appended task「own `Task:` trailer, four reviewers」改為「both per-task
  reviewers」。
- **Commit Trailer：** 「task-seam's "no task references in code or comments" rule」改為
  task-acceptance 的 Document Reference Leak 檢查。
- **Sidecar files：** 三個舊 prompt 的條目改為一條 `./task-acceptance-prompt.md`。
- **Example Workflow：** Summary 範例改為兩行（`task-acceptance`、`code-quality`），
  「Read the full ## task-coverage …」等改為 `## task-acceptance`，範例中的 finding 歸屬照改。
- **Advantages / Red Flags：** 「One batched four-reviewer review」「implementer + 4 reviewers
  per task + 2 at the final gate」「any of the four per-task reviewers」改為兩個 reviewer 的對應
  敘述。

### 5. 其他檔案

- `scripts/claude-prompts/`（`code-review.md`、`adversarial-review.md`）不受影響。
- `README.md` 目前未提及三個舊 reviewer 名稱或 per-task reviewer 數量；若實作時發現有提及，
  一併更新。
- `docs/superpowers/specs/` 底下既有的 spec 為歷史紀錄，不修改。

## 測試

- `scripts/review-batch-lib.test.sh` 中 `review-impl` 區段：
  - 斷言 label 順序改為 `## task-acceptance|## code-quality|`，且恰為兩個 job。
  - 斷言 `task-acceptance` 的 argv 為
    `task --prompt <SDD_DIR>/task-acceptance-prompt.md --set SPEC_FILE_PATH=... --set
    TASK_SUMMARY=... --set TASK_BASE=...`。
  - `code-quality` 的 argv 斷言維持不變；移除 `spec-compliance`、`task-coverage`、`task-seam`
    的斷言與測試 fixture 中對應的空 prompt 檔。
  - 參數驗證（缺 `--spec` 等）測試維持不變。
- 依 TDD 順序：先改測試並在未修改的 `review-impl.sh` 上看到失敗，再改 wrapper。
- `shellcheck scripts/review-impl.sh` 通過。
- 以下搜尋在 `skills`、`scripts`、`README.md` 中須為零筆：
  `spec-compliance`、`task-coverage`、`task-seam`、`spec-reviewer-prompt`。

## Non-goals / Accepted limitations

- **Selective rerun 不在本次範圍：** 修正後仍重跑整個 `review-impl.sh`；pass condition（同一輪、
  中間無修改、全部通過）不變。「只重跑上一輪有問題的 reviewer」會放寬這層保護，另案評估。
- **分階段順序無法強制保證：** Phase 1 不讀 spec 的約束只靠 prompt 指示，模型仍可能不完全遵守；
  跨 task 的介面接縫由 final gate 的 `final-adversarial` 兜底。此為使用者選擇三合一時已接受的
  取捨。
- **Final gate 不變：** `review-final.sh`、`final-adversarial`、`spec-coverage` 不修改。
