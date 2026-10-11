# 免 plan 執行流程：以 Task 清單取代 implementation plan

- **日期**：2026-10-11
- **狀態**：使用者審閱中；最近一次修改為 final gate 職責重新分配（final-adversarial 只做程式碼層面審查，整體意圖偏離移交 spec-coverage）
- **提交類型**：`feat!:`（移除 `writing-plans` 階段，改變整條工作流的行為契約）

## 1. 問題

目前的強制流程是 `brainstorming → spec → writing-plans → plan → subagent-driven-development`。`writing-plans` 產出的 plan 為每個 Task 寫入**完整程式碼、完整測試與完整指令**，經 per-Task reviewer 與 coverage-verifier 審查後簽入 git。接著 `subagent-driven-development`（下稱 SDD）把 plan 的 Task 全文貼給 implementer，implementer 照抄 plan 的程式碼實作並 commit。

實務上 implementer 幾乎總是完全照著 plan 寫，於是同一份程式碼被產出兩次：一次寫在 plan（並簽入 git），一次寫成真正的檔案。plan 階段的審查迴圈也是在審一份「之後會被原樣複製的程式碼」，代價是兩倍的產出、兩輪審查，以及一份在分支完成後就被刪除的大型文件（見 `16d5f5b`）。

此外，plan 簽入 git 還帶來一個副作用：實作期間若需要修正 plan，修正 commit 會落入 `TASK_BASE..HEAD`，被 spec-compliance reviewer 判為超出範圍（`2026-08-10-requirement-doc-amendment-protocol-design.md` §1 的病理二）。

## 2. 目標與非目標

### 目標

- 移除 `writing-plans` 階段：brainstorming 完成並經使用者核准 spec 後，直接進入 SDD。
- SDD 在開始實作前，從 spec 拆出一份**不含程式碼**的 Task 清單（目標＋驗收條件），存放在 controller 的 session 狀態中，不寫成檔案。
- 使用者明確要求接續實作某份 spec 時，controller 從 git 歷史（以 commit trailer 標記）重建執行狀態（§4.4）。
- 每個 Task 依序由 implementer subagent 以 TDD 實作；實作完成後由四個 reviewer 並行審查：spec-compliance（改為對 spec 驗證）、code-quality、task-coverage、task-seam。reviewer 不讀 Task 清單，需要範圍資訊的 reviewer 只收到一行任務題目（§5.1）。
- final gate 新增 spec-coverage reviewer，補上「清單整個漏掉某項 spec 需求」與「各 Task 合起來偏離 spec 整體意圖」的檢查；final-adversarial 維持程式碼層面的對抗審查。

### 非目標

- **不改 brainstorming 的設計與 spec 審查流程**，只改其終點（§6.1）。
- **不在動工前審查 Task 清單、也不設使用者確認關卡。** 使用者已核准 spec；清單產生後直接開始實作。清單品質由 per-Task 的四個 reviewer、controller 的歸屬判斷（§5.3）與 final gate 的 spec-coverage 在事後把關。
- **不提供 plan 與免 plan 兩條路徑並存。** 本設計完全取代 `writing-plans`。
- **不持久化執行狀態。** Task 清單與 `IMPL_BASE` / `TASK_BASE` 只存在 session 內，不寫入任何檔案或外部儲存。跨 session 接續改由 §4.4 從 git 歷史重建，不另設狀態檔。
- **不定義完整的 spec 修正協定。** 實作期間遇到重大問題時可以回頭修改 spec，本設計只規定最低限度的處理（§4.6）：由 controller 在使用者同意後修改、獨立 commit、reviewer 不把 spec 檔本身的變更當成實作來審。更細的權限與順序規範屬於 `2026-08-10-requirement-doc-amendment-protocol-design.md` 的範圍（其針對 plan 的部分已被本設計取代；針對 spec 的部分仍未實作），不在本次範圍內。
- **不改 `dispatch.sh` 與 `review-batch-lib.sh`。** 只改兩個 wrapper（`review-impl.sh`、`review-final.sh`）的參數與註冊的 job。

## 3. 整體流程

```
brainstorming（不變，直到使用者明確核准 spec）
  └─> superpowers-codex:subagent-driven-development
        Phase 0：從 spec 拆出 Task 清單（§4）
          - 不審查、不等使用者，直接進入 Phase 1
          - 使用者要求接續實作時，改走接續模式重建狀態（§4.4）
        捕捉 IMPL_BASE
        Phase 1：逐個 Task 依序執行
          捕捉 TASK_BASE → implementer（TDD）→ review-impl.sh（四個 reviewer，§5.1）
          → controller 依歸屬規則分類 findings（§5.3）→ 修正後重跑整個 review-impl.sh，直到通過
          → 標記該 Task 完成
        Phase 2：review-final.sh（final-adversarial + spec-coverage，§5.2）
        若有需人工確認的項目：請使用者確認或豁免（§5.4）
  └─> superpowers-codex:finishing-a-development-branch
```

SDD 既有的 Base SHA 追蹤（`IMPL_BASE`、`TASK_BASE`，存在 controller 的 session 狀態）、invocation discipline、caller control-flow、HEAD 契約、continuous execution 原則全部沿用，只把其中「plan」的依據替換成 spec 與 session 內的 Task 清單。

## 4. Task 清單（Phase 0）

### 4.1 存放位置

- Task 清單存放在 controller 的 session 狀態中：Phase 0 拆完後，controller 在回覆中列出完整清單（每個 Task 依 §4.2 格式），並在每個 Task 開始時重新列出該 Task 的定義，降低 context 壓縮造成的遺失風險。
- Task 清單**不寫成檔案、不簽入 git**。controller 派發 implementer 時把該 Task 的完整定義貼進 implementer prompt；reviewer 不讀清單。
- harness 有可用的 task-tracking 工具時，controller 為每個 Task 建一個條目（標題 `Task N: <name>`）並同步狀態，作為給使用者看的進度顯示。**正確性不依賴這些工具**：它們在新版模型上預設停用，跨 session 恢復也不可靠（§8）。SKILL.md 以「the harness's task-tracking tool, if available」稱呼，不綁定特定工具名稱。

### 4.2 Task 定義格式

格式定義寫在新的 sidecar `skills/subagent-driven-development/task-list-format.md`：

```
Task 3: Retry policy
Spec: §4.2, §4.3
Files: src/retry.ts (new), src/client.ts
Interface: export function withRetry(fn, opts)
Acceptance:
- retries up to opts.max on 5xx
- no retry on 4xx
- backoff doubles each attempt
Depends on: Task 1 (HttpError type)
```

欄位規則：

- `Spec:`：此 Task 涉及的 spec 章節，至少一個。同一章節可以拆給多個 Task；此 Task 在該章節中實際負責哪些需求，由 `Acceptance:` 界定。
- `Files:`：預計建立或修改的檔案，標註 `(new)`。
- `Interface:`：此 Task 對其他 Task 暴露的介面（函式、型別、CLI 參數、檔案格式等）；沒有就寫 `none`。只寫簽名，不寫實作。
- `Acceptance:`：可用測試驗證的驗收條件，每條一行。
- `Depends on:`：依賴的 Task 與其使用的介面；沒有就寫 `none`。**只能引用編號較小的 Task**：Phase 0 依依賴關係排定 Task 順序，使每個 Task 開始時其依賴都已完成；若依賴關係無法排出這樣的順序（循環依賴），就把循環中的 Task 合併成一個。追加的 Task（§5.2、§5.3）同樣遵守此規則。
- **不寫實作程式碼、測試程式碼或逐步指令。** implementer 在 TDD 中自行設計。

`task-list-format.md` 同時收納從 `writing-plans/SKILL.md` 移入的拆分原則：Scope Check（spec 涵蓋多個獨立子系統時應已在 brainstorming 拆開）與 File Structure（以職責劃分檔案、每個 Task 產出可獨立成立的變更、在既有 codebase 中遵循既有模式）。

### 4.3 任務題目（task summary）

每個 Task 由 controller 產生一行任務題目，格式為 `Task N: <name> (spec §X, §Y)`，章節與該 Task 的 `Spec:` 一致。例如 `Task 3: Retry policy (spec §4.2, §4.3)`。

- 這是傳給 reviewer 的**唯一**範圍資訊，透過 `--task-summary` 傳入（§5.1）。
- 必須是單行：`dispatch.sh` 既有的 `require_no_newline` 會拒絕含換行的 `--set` 值，wrapper 直接失敗。

### 4.4 接續模式（從 git 歷史重建）

**觸發條件**：只有使用者明確要求「接續實作某份 spec」時才進入。一般流程（brainstorming 交接後直接實作）不做任何偵測，狀態完全在 session 內。

**重建步驟**：

1. **定位起點**：`S` = 新增 spec 檔的 commit（`git log --diff-filter=A --format=%H -- <spec>` 的結果）。
2. **重建 `IMPL_BASE`**：在 `S..HEAD` 中找出第一個帶 `Task:` trailer（§4.5）的 commit，`IMPL_BASE` = 它的 parent。實作期間的 spec 修正 commit（§4.6）不帶 trailer，不影響判定。
3. **分組**：依 trailer 把 `IMPL_BASE..HEAD` 中帶 trailer 的 commit 分到各個 Task。
4. **重建 Task 清單**：依**目前的** spec 重新拆出 Task 清單（§4.2），再對照第 3 步的分組與程式碼現況，判定哪些 Task 已完成。重建出的清單與原本的編號或切分不一致時，以 trailer 中的 Task 名稱與 commit 內容對應，不以編號硬套。
5. **處理最後一個 Task**：trailer 中最後出現的 Task 一律視為**尚未通過審查**（無法得知上個 session 是否在審查途中中斷）。它的 `TASK_BASE` = 該 Task 第一個 commit 的 parent；先以此跑 `review-impl.sh`，之後照一般流程處理 findings。若這個 Task 之後的 commit 混有其他 Task 的 commit（交錯），視為無法判定，走下方 fail closed。
6. 之後照一般流程從下一個未完成的 Task 繼續。final gate 使用重建的 `IMPL_BASE`，因此涵蓋整段實作，包括上個 session 的部分。
7. 重建完成後，controller 在回覆中列出重建結果（`IMPL_BASE`、各 Task 狀態與對應 commit），然後直接繼續，不等使用者確認。

**Fail closed**：以下任一情況成立，controller 把目前的重建結果與疑點列給使用者，以 `AskUserQuestion` 確認後才繼續，不自行猜測：

- 工作目錄不乾淨（`git status --porcelain` 有輸出：staged、unstaged 或 untracked 的變更）。這通常是上個 session 在 commit 前中斷留下的實作。controller 不得忽略或自行歸屬它們，必須請使用者決定 commit 到哪個 Task、stash 或捨棄；工作目錄乾淨後才開始重建，確保審查與測試看到的是同一個已 commit 的狀態。此檢查在第 1 步之前執行。
- 找不到 spec 的新增 commit，或 `S..HEAD` 中沒有任何帶 `Task:` trailer 的 commit。
- **整段 `S..HEAD`**（包括第一個帶 trailer 的 commit 之前的部分）中，有不帶 trailer、且不是只修改 spec 檔的 commit：可能無法判斷它屬於哪個 Task、根本與此 spec 無關，或是以舊流程（沒有 trailer）做到一半的實作。最後一種情況下，使用者需要明確指定 `IMPL_BASE` 與這些 commit 的 Task 歸屬，這也是從舊流程遷移的分支的接續方式。
- 同一個 Task 的 commit 與其他 Task 的 commit 交錯。
- 依目前 spec 重建的清單無法與 trailer 中的 Task 對應。

### 4.5 Commit trailer

implementer 的每一個 commit（含審查後的修正 commit）的 message 結尾必須加上 trailer：

```
Task: <N> <name>
```

例如 `Task: 3 Retry policy`，`<N>` 與 `<name>` 與該 Task 的定義一致。它與其他 trailer（例如 `Co-Authored-By:`）並列於 message 最後一段。

- 用途只有一個：讓 §4.4 能從 `git log` 把 commit 分組。一般流程中 controller 不讀它。
- trailer 是 commit message，不是程式碼，不受 task-seam 「程式碼與註解不得引用 Task 編號」的限制。
- controller 派發 implementer 時把要用的 trailer 字串一併給出；implementer 不得自行編造。

### 4.6 實作期間修改 spec

實作期間遇到重大問題、需要修改 spec 時：

- 只有 controller 可以修改 spec，且必須先以 `AskUserQuestion` 取得使用者同意；implementer 不得修改 spec 檔。
- spec 修改以**獨立 commit** 提交：只包含 spec 檔、不帶 `Task:` trailer、message 使用 `docs(spec): ...`。
- 修改 spec 後，controller 依新的 spec 調整尚未完成的 Task 定義（遵守 §5.3 的範圍同步通則）。已完成的 Task 若受影響，依 §5.3 追加或併入修正。
- 所有 reviewer prompt 都明訂：diff 中對來源 spec 檔（`[SPEC_FILE_PATH]`）本身的變更不是實作，不納入 Extra/unneeded work 或其他實作審查。task-seam 不讀 spec，但同樣排除 `docs/superpowers/specs/` 下的變更。code-quality 為 codex 原生 review，無法排除，controller 忽略它對 spec 文字的意見。

## 5. 審查

### 5.1 Per-Task 審查：`review-impl.sh`

新介面：

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-impl.sh" \
  --spec docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md \
  --task-summary "Task N: <name> (spec §X, §Y)" \
  --task-base <TASK_BASE>
```

`--spec`、`--task-summary`、`--task-base` 皆為必填；保留 `--max-parallel`；移除 `--plan` 與 `--task`。wrapper 一次並行註冊四個 job。分工原則是**每個 reviewer 只回答一個問題**，並且只拿到回答該問題所需的輸入：

| Label | 回答的問題 | 機制與輸入 | 輸出 |
|---|---|---|---|
| `spec-compliance` | 做出來的東西**對不對**：對 spec 的理解是否偏差、做法是否違背 spec 的設計決策、是否有超出任務題目範圍的額外工作、是否碰到 spec 的 Non-goals | `task`，prompt `spec-reviewer-prompt.md`；`[SPEC_FILE_PATH]`、`[TASK_SUMMARY]`、`[TASK_BASE]` | `Status: OKAY \| Issues Found` |
| `code-quality` | 做得**好不好** | `review --base <TASK_BASE>`（codex 原生 review，不變） | prose |
| `task-coverage` | **做完了沒** | `task`，prompt `task-coverage-prompt.md`；`[SPEC_FILE_PATH]`、`[TASK_SUMMARY]`、`[TASK_BASE]` | 對照表 + `Status:` |
| `task-seam` | 跟既有程式碼**接不接得起來** | `task`，prompt `task-seam-prompt.md`；只有 `[TASK_BASE]`，不讀 spec | `Status:` |

`SPEC_FILE_PATH` 由 `dispatch.sh` 既有的 `*_FILE_PATH` 存在性檢查把關。

**共用證據規則**（spec-compliance、task-coverage、spec-coverage 三份 prompt 寫入同一段文字）。每個需求依性質歸入一類，各有對應的充分證據：

| 類別 | 範例 | 充分證據 |
|---|---|---|
| 可執行行為 | 函式回傳值、CLI 行為、錯誤處理 | 實作位置**且**測試證據；有機會寫測試卻沒寫，判為缺漏 |
| 宣告式 / 文件變更 | skill 指令文字、README、設定值、prompt 內容 | 對應位置即可，不要求可執行測試。位置可以在 diff 中，也可以是 `HEAD` 上已存在的內容（例如同一章節的文件需求已由先前的 Task 完成） |
| 保留不變 | spec 明列「保留」「不改」的檔案或內容 | `HEAD` 上該內容仍存在，且 diff 沒有改動它；不要求 diff 位置 |
| 本質上需人工確認 | 外部系統的副作用、需要人操作才能觀察的行為 | 標註為需人工確認，不判缺漏，交由 §5.4 收尾 |

**`spec-reviewer-prompt.md`（改寫）**

- 依據從「plan 中的 Task」改為「spec 中任務題目所列章節」；任務題目只用來界定本次 diff 的範圍，需求的唯一真相是 spec。
- 保留：Misunderstandings、Extra/unneeded work、Issue Reporting Requirements、Output Contract。
- Evidence Verifiability 段落改為共用證據規則的文字。
- 新增：檢查 diff 是否實作了 spec **Non-goals / Accepted limitations** 中明列不做的事。
- 移除：Missing requirements 整節（移交 `task-coverage`）。

**`task-coverage-prompt.md`（新增，由 `writing-plans/coverage-verifier-prompt.md` 改寫）**

- 列出任務題目所列 spec 章節中的功能需求，以及以 must / should / need / must not / avoid 或同義語表述的條件。
- 每一條依共用證據規則給出該類別的充分證據；不足者列為未完成。證據以 `git diff [TASK_BASE]..HEAD` 為主；先前已存在於 `HEAD` 的程式碼與測試可以作為輔助證據。
- prompt 明確告知：同一章節可能拆給多個 Task，reviewer 看不到 Task 清單，因此**列出所有未完成的條目即可，不需要判斷它是否屬於後面的 Task**；歸屬由 controller 判斷（§5.3）。
- 輸出格式：對照表（條件 / 來源章節 / 實作位置 / 測試證據 / 結果），最後一行 `Status: OKAY` 或 `Status: Issues Found`。

**`task-seam-prompt.md`（新增，由 `writing-plans/plan-document-reviewer-prompt.md` 改寫）**

只看 `git diff [TASK_BASE]..HEAD` 與 repo 現有程式碼，不讀 spec，檢查三項：

1. **介面一致性**：diff 新增或修改的介面（函式、型別、CLI 參數、檔案格式）與 repo 中既有的呼叫端、被呼叫端是否一致（名稱、參數、型別、回傳值）。
2. **文件引用洩漏**：程式碼與註解不得引用 spec、plan、Task 編號（例如「per spec §4」、「see Task 2」）。
3. **殘留 placeholder**：交付的程式碼不得含 TODO、TBD、未實作的 stub。

刪除原 plan reviewer 的 Spec Coverage（移交 `spec-compliance` 與 `task-coverage`）、Type Consistency 中針對 plan 文字的 sibling 比對（改為上面第 1 項對實際程式碼的比對）、Code Completeness、Command Accuracy、Pre-Implementation Research Task Leak（Task 不再含程式碼與指令，這三項不再適用）。最後一行 `Status: OKAY` 或 `Status: Issues Found`。

**通過條件**：同一輪、沒有中途修改的情況下，每個 `Status:` reviewer 要嘛是 `Status: OKAY`，要嘛其所有 findings 都已依 §5.3 被 controller 判定為「屬於後面的 Task」；且 code-quality 沒有 blocking finding。任一 reviewer `ERROR` 即重跑整個 wrapper（沿用既有 caller control-flow）。

### 5.2 Final gate：`review-final.sh`

新介面：

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-final.sh" \
  --base <IMPL_BASE> \
  --spec docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md
```

`--base`、`--spec` 皆為必填。wrapper 並行註冊兩個 job：

- `final-adversarial`：呼叫方式不變（`adversarial --base <IMPL_BASE> --focus final-code-reviewer-focus.md`），不接收 spec。它的職責是對整體變更做程式碼層面的對抗審查（跨 Task 的介面縫隙、權限與隔離、資料遺失、rollback 與部分失敗、race condition、observability、ship/no-ship 判斷），不負責檢查實作是否符合 spec。`final-code-reviewer-focus.md` 移除「drift from the plan's overall intent (requirements that fell through the cracks between tasks, …)」一項：需求是否遺漏與整體意圖是否偏離，都改由 spec-coverage 負責（見下方 `spec-coverage-prompt.md` 的「逐條覆蓋」與「整體意圖偏離」）。同一句中「scaffolding or TODOs left behind, dead code from the task-by-task process」屬於程式碼層面，保留為獨立一項。
- `spec-coverage`：`task`，prompt `spec-coverage-prompt.md`，placeholder `[SPEC_FILE_PATH]`、`[IMPL_BASE]`。

**`spec-coverage-prompt.md`（新增）**

- 讀完整份 spec，並執行 `git diff [IMPL_BASE]..HEAD`。
- **逐條覆蓋**：列出 spec 的功能需求、設計決策、must / should 類條件，各自依共用證據規則（§5.1）給出該類別的充分證據；不足者為缺漏。
- **整體意圖偏離**：在逐條覆蓋之外，以整個 `IMPL_BASE..HEAD` 為對象，檢查各 Task 的實作合起來是否仍符合 spec 描述的架構、元件分工、資料流與設計方向。逐條覆蓋通過但整體仍可能偏離，例如各部分以 spec 未描述的方式組合、職責落在與 spec 不同的元件、多個 Task 各自做了局部合理但彼此矛盾的取捨。每項偏離要指出對應的 spec 段落與實作位置。per-Task 的 spec-compliance 只看單一 Task 的 diff，無法發現這類跨 Task 的偏離，所以由這裡負責。
- spec 的 **Non-goals / Accepted limitations** 所列項目不算缺漏，也不算偏離。
- 輸出分兩段：Coverage Gaps 與 Intent Drift。任一段有項目即為 `Status: Issues Found`。
- 最後一行 `Status: OKAY` 或 `Status: Issues Found`。

**Final gate 通過條件**：同一輪中，`spec-coverage` 為 `Status: OKAY`，且 `final-adversarial` 為 `Verdict: approve`（或其剩餘 findings 全部符合既有的 spec-adjudicated carve-out）。此時所有 Task 都已完成，§5.3 的「屬於後面的 Task」不再適用：spec-coverage 的每一項缺漏都是 blocking。

**缺漏與 blocking findings 的處理**：spec-coverage 的缺漏與 final-adversarial 的 blocking findings 採同一條路徑：controller 在 Task 清單末尾追加新 Task（新的編號與名稱、依 §4.2 寫出 `Spec:` 與 `Acceptance:`，修正 final-adversarial finding 的 Task 其 `Spec:` 為該 finding 涉及的章節），新 Task 走完整 Phase 1 流程（捕捉 `TASK_BASE`、帶自己的 `Task:` trailer、四個 reviewer），全部完成後以同一個 `IMPL_BASE` 重跑整個 `review-final.sh`。這取代既有「直接派 implementer 修正 final-adversarial findings」的做法，確保每個 commit 都屬於唯一一個 Task，接續模式不需要任何特例（不會出現「已完成的 Task 之後又出現它的 commit」這種交錯）。

**既有 carve-out 的來源 spec 辨識**：改為「傳給 `review-final.sh --spec` 的那份 spec」。這是 SDD 從 brainstorming 交接時收到的唯一 spec，不再需要從 plan 反查。找不到 **Non-goals / Accepted limitations** 章節時，不壓制任何 finding（沿用既有 fail-closed 規則）。

### 5.3 Controller 的歸屬判斷與修正路徑

reviewer 看不到 Task 清單，task-coverage（以及 spec-compliance）可能把屬於後面 Task 的需求回報為未完成。controller 持有完整清單，負責分類每一項 finding：

- **屬於後面的 Task**：只有在 Task 清單中**確實存在**一個尚未完成的 Task，其 `Acceptance:` **明確涵蓋**該項，**且**其 `Spec:`（因而其任務題目）包含該項所在的 spec 章節時，才能如此判定。第二個條件確保接收方的 task-coverage 一定會檢查該項的實作與測試證據。另有第三個條件：該項**不是本 Task 的前置條件**（本 Task 的實作或測試不需要用到它）。前置條件即使已經分配給後面的 Task，也一律 blocking，改走下表「併入本 Task」的路徑，並從原本負責的 Task 移除該條目。controller 必須在回報中寫出對應的 Task 編號與 Acceptance 條目。此類 finding 不阻擋本 Task 通過，也不修改。
- **其他一律 blocking**：找不到明確涵蓋的未完成 Task、涵蓋只是部分重疊、或判斷有疑義時，一律視為本 Task 的 finding。這條規則刻意保守，避免歸屬判斷變成放行漏洞。

blocking finding 的處理：

| Finding 性質 | 處理 |
|---|---|
| 實作錯誤（任一 reviewer） | implementer 修正並 commit |
| 本 Task 少做了某項需求，且沒有任何 Task 涵蓋 | controller 在本 Task 的 `Acceptance:` 補上條目，派 implementer 補實作 |
| 該需求較適合由後面的 Task 負責，但目前沒有 Task 涵蓋 | controller 把條目加到某個尚未完成 Task 的 `Acceptance:`，並在其 `Spec:` 補上該需求所在章節（任務題目隨之更新）；或追加新 Task。本 Task 不補實作。**限制**：若本 Task 的實作或測試需要用到該需求（即它是本 Task 的前置條件），不得轉給後面的 Task，必須走上一列併入本 Task。這確保執行順序永遠不會出現「目前的 Task 依賴尚未執行的 Task」 |
| 需要修改已完成 Task 的程式碼才能讓本 Task 成立 | controller 把該修正併入本 Task 的 `Acceptance:`，由本 Task 的 implementer 一起完成；不追加獨立的修正 Task，避免本 Task 卡在等待後面的 Task |

**範圍同步通則**：任何 Task 的 `Acceptance:` 被新增或修改時（上表任一路徑，包括把需求或已完成 Task 的修正併入本 Task），controller 必須同時把新條目所在的 spec 章節補進該 Task 的 `Spec:`，並依 §4.3 重新產生任務題目，之後的 `review-impl.sh` 一律使用更新後的題目。新條目若改變了該 Task 對外暴露的介面或它依賴的介面，也一併更新 `Interface:` 與 `Depends on:`。reviewer 看不到 `Acceptance:`，只有這樣，spec-compliance 才不會把併入的工作判為超出範圍，task-coverage 也才會檢查它。

**任何修正之後都重跑整個 `review-impl.sh`**（同一個 `TASK_BASE`），包括只改了 Task 定義、沒有新 commit 的情況。

controller **不得**為了讓 reviewer 通過而刪減 Task 的 `Acceptance:`：定義只能因為更貼近 spec 而修改，不能因為遷就實作而放寬。

### 5.4 需人工確認的項目

spec-compliance、task-coverage、spec-coverage 依共用證據規則（§5.1）標註為「本質上需人工確認」的項目，不阻擋 reviewer 通過，但必須有明確的收尾：

- controller 在整個執行過程中收集這些項目（項目內容、來源 reviewer、所屬 Task），存在 session 狀態中。
- final gate 通過後、呼叫 `finishing-a-development-branch` 之前，若清單不為空，controller 把清單列給使用者，以 `AskUserQuestion` 請使用者逐項確認已驗證，或明確豁免。使用者回報某項未通過時，視同 final gate 的缺漏：追加 Task 修正後重跑 `review-final.sh`。
- 清單為空時不打斷，直接進入 finishing。這是 continuous execution 原則的唯一新增停點。

## 6. 其他檔案變更

### 6.1 `skills/brainstorming/SKILL.md`

- Checklist 第 8 項、流程圖終點、「The terminal state is…」、User Review Gate 的離開條件、Implementation 段落：`superpowers-codex:writing-plans` 全部改為 `superpowers-codex:subagent-driven-development`。
- 強制順序改為 `brainstorming → spec document → subagent-driven-development`。
- User Review Gate 的提示語從「before we start writing out the implementation plan」改為「before we start implementation」。
- fail-closed 規則保留，對象改為 SDD。

### 6.2 `skills/subagent-driven-development/SKILL.md`

- 新增 Phase 0（§4），並在流程圖加入對應節點。
- When to Use 的判斷從「Have implementation plan?」改為「Have an approved spec?」。
- `review-impl.sh`、`review-final.sh` 的呼叫範例與 caller control-flow 改為 §5 的新介面與四個 / 兩個 reviewer。
- 新增 §5.3 的歸屬判斷規則、修正路徑與範圍同步通則，以及 §5.4 的人工確認收尾；Continuous execution 段落的停止理由加上「§5.4 的人工確認清單不為空」。
- 「Read plan, extract all tasks」改為「Derive the task list from the spec and list it in full in your reply (mirror into the task-tracking tool if available)」；Red Flags 中「Make subagent read plan file」改為「Make subagent derive its own task from the spec (provide the full task definition instead)」。
- 新增接續模式（§4.4）、commit trailer（§4.5）、實作期間修改 spec（§4.6）三段。
- 新增 Red Flags：把 finding 判定為「屬於後面的 Task」卻無法指出明確涵蓋它的 Task 與 Acceptance 條目；為了讓 reviewer 通過而放寬 Task 定義；把 Task 清單寫成檔案或簽入 git；implementer commit 缺少 `Task:` trailer；未經使用者同意修改 spec，或把 spec 修改與實作混在同一個 commit；接續模式遇到 fail closed 條件仍自行猜測繼續。
- Example Workflow 改寫為新流程。
- Integration 移除 writing-plans。
- Sidecar files 列出：`implementer-prompt.md`、`task-list-format.md`、`spec-reviewer-prompt.md`、`task-coverage-prompt.md`、`task-seam-prompt.md`、`spec-coverage-prompt.md`、`final-code-reviewer-focus.md`。

### 6.3 `skills/subagent-driven-development/implementer-prompt.md`

- Task Description 改為「FULL TEXT of the task definition (provided by the controller)」，並另外提供 spec 路徑，讓 implementer 能查閱 `Spec:` 所列章節。
- 新增：每個 commit 的 message 結尾都要加上 controller 提供的 `Task:` trailer（§4.5）；不得修改 spec 檔，認為 spec 有問題時回報 `DONE_WITH_CONCERNS` 或 `BLOCKED` 交給 controller（§4.6）。
- Your Job 明訂：Task 不含程式碼，implementer 依 `Interface:` 與 `Acceptance:` 自行設計，並遵守 TDD 順序（先寫測試、看到失敗、再實作）。
- 新增：若實作需要的第三方 API 行為在 spec 中沒有記載研究結論，回報 `NEEDS_CONTEXT` 並列出需要確認的 API，不得自行猜測。controller 收到後依使用者的 research subagent 規範取得結論，再重新派發。
- Subagent model 說明從「sonnet — follows code already specified in the plan」改為依 SDD 的 Model Selection 依複雜度選擇（implementer 現在需要做程式設計，不再只是照抄）。
- 「Follow the file structure defined in the plan」改為「defined in the task's `Files:`」。

### 6.4 `skills/finishing-a-development-branch/SKILL.md`

- 移除 Step 4「Clean Up Completed Plan Files」，因為不再產生 plan 檔。後續步驟編號遞補。
- 開頭的 Core principle 改為「Verify tests → Present options → Execute choice」。
- Quick Reference 表格移除「Remove Completed Plan」欄。
- Common Mistakes 移除「Leaving completed plans in `docs/superpowers/plans/`」與「Deleting specs along with plans」兩項。
- Red Flags 的 Never 清單移除「Delete anything under `docs/superpowers/specs/`」與「Remove a plan whose implementation is only partially complete」；Always 清單移除「Remove the completed plan file before merging…」。這些條目都只為 Step 4 的清理動作而存在；Step 4 移除後此 skill 不再觸及 `docs/superpowers/` 下的任何檔案。

### 6.5 刪除

- `skills/writing-plans/`（整個目錄，含 `SKILL.md`、`coverage-verifier-prompt.md`、`plan-document-reviewer-prompt.md`；後兩者改寫後的內容移到 SDD 目錄，見 §5.1）。
- `scripts/review-plan.sh`。
- `scripts/review-batch-lib.test.sh` 中 review-plan 相關的測試與 plan caller shape 測試。
- `vendored-skills.txt` 中的 `writing-plans`，避免 `sync-upstream.sh` 把它帶回 `vendor` 分支。

### 6.6 保留不改

- `scripts/preflight-plugin-install.sh` 的 `SKILLS` 清單**保留** `writing-plans`：使用者環境中殘留的 legacy `writing-plans` 副本仍可能被誤觸發，preflight 應繼續把它當成需要移除的殘留。`scripts/preflight.test.sh` 隨之不變。

### 6.7 README 與 plugin metadata

- `.claude-plugin/plugin.json` 的 `description` 移除 `writing-plans`。
- `README.md`：skill 清單移除 `writing-plans`；遷移指令中的 `rm -rf` 與 legacy 殘留檢查迴圈**保留** `writing-plans`（理由同 §6.6）；說明流程時改為 brainstorming → SDD。
- `README.md` 遷移步驟 3 的**正向安裝檢查**目前以 `~/.claude/plugins/cache/*/superpowers-codex/*/skills/writing-plans` 判斷 plugin 已安裝，必須改為檢查保留下來的 `skills/subagent-driven-development`。否則新安裝會永遠回報 FAIL，而殘留舊版快取的環境則會用過時的證據誤判為 OK。

## 7. 錯誤處理

- **`--task-summary` 含換行**：`dispatch.sh` 拒絕，wrapper 失敗。controller 改成單行後重跑。
- **implementer 回報 `NEEDS_CONTEXT`（第三方 API）**：見 §6.3。
- **歸屬判斷有疑義**：一律 blocking（§5.3）。
- **接續模式重建有疑義**：fail closed，詢問使用者（§4.4）。
- **wrapper `ERROR`、`(tool exit N)`**：沿用既有 caller control-flow。

## 8. 假設

- **不假設 harness 的 task-tracking 工具可用或可靠。** 已查證（Claude Code 2.1.296）：`TaskCreate` / `TaskGet` / `TaskUpdate` / `TaskList` / `TodoWrite` 自 2.1.233 起在 Opus 4.8 以後、Sonnet 5、Fable 5、Opus 5.x 等新模型上預設停用，需 `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` 才會開啟；條目存在 `~/.claude/tasks/<list-id>/`，可撐過 context 壓縮，但 `--resume` / `--continue` 的恢復有尚未修復的回報（anthropics/claude-code#76844）。因此 Task 清單以 controller 回覆中的完整列表為準（§4.1），跨 session 以 git 歷史重建（§4.4）。
- 清單放在回覆中會受 context 壓縮影響。這不影響 reviewer（reviewer 本來就不讀清單）；歸屬判斷仍以「指不出明確涵蓋的 Task 就 blocking」的保守規則把關；清單在同一個 session 內遺失時，controller 可以用 §4.4 的同一套步驟從 git 歷史重建。

## 9. 測試

更新 `scripts/review-batch-lib.test.sh`（以既有的 `BATCH_DISPATCH_SH` echo stub 驗證 argv 契約）：

- `review-impl.sh`：註冊四個 job，label 依序為 `spec-compliance`、`code-quality`、`task-coverage`、`task-seam`；`spec-compliance` 與 `task-coverage` 的 prompt 路徑與 `SPEC_FILE_PATH`、`TASK_SUMMARY`、`TASK_BASE` 的 `--set` 值正確；`task-seam` 的 prompt 路徑正確且只帶 `TASK_BASE`（不帶 `SPEC_FILE_PATH`）；code-quality 為 `review --base <TASK_BASE>`；缺少 `--spec`、`--task-summary`、`--task-base` 任一者時 fail fast 並輸出清楚的錯誤；傳入已移除的 `--plan` 或 `--task` 時以 unknown arg 失敗。
- `review-final.sh`：註冊兩個 job（`final-adversarial`、`spec-coverage`），`spec-coverage` 的 prompt 路徑與 `SPEC_FILE_PATH`、`IMPL_BASE` 的 `--set` 值正確；`final-adversarial` 的 argv 與舊版相同（`adversarial --base <IMPL_BASE> --focus <root>/skills/subagent-driven-development/final-code-reviewer-focus.md`）；缺少 `--base`、`--spec` 任一者時 fail fast。
- 刪除 review-plan 的所有測試與 plan caller shape 測試。
- `bash scripts/review-batch-lib.test.sh`、`bash scripts/dispatch.test.sh`、`bash scripts/preflight.test.sh` 全部通過；所有修改過的 `.sh` 通過 `shellcheck` 與 `bash -n`。

skill 文字（SKILL.md、prompt）沒有自動化測試，正確性由 spec 審查與實作階段的四個 reviewer 把關。

## Non-goals / Accepted limitations

（本節記錄審查過程中使用者裁決不實作的顧慮，格式為 Concern / Decision / Rationale。供下游 `subagent-driven-development` 的 carve-out 依此 canonical 標題定位並尊重。）

### 把來源 spec 路徑傳給 final-adversarial reviewer

- **Concern**：spec 通常早於 `IMPL_BASE`、不在 final gate 的 diff 中，而 final-adversarial 只收到 base 與靜態 focus 文字。在有多份 spec 的 repo 裡，它無法得知哪份設計主導這次變更，因而無法可靠地偵測設計偏離。reviewer 建議由 wrapper 產生含 spec 路徑的暫存 focus 檔，並加測試證明 spec 有送達。
- **Decision**：不實作。final-adversarial 不接收 spec；其 focus 移除「drift from the overall intent」一項（§5.2）。
- **Rationale**：final-adversarial 的職責是程式碼層面的對抗審查，不是用來檢查實作是否偏離 spec 的整體意圖（使用者裁決）。實作是否符合 spec 已由 per-Task 的 spec-compliance（理解與設計決策）、task-coverage，以及 final gate 的 spec-coverage（整份 spec 的需求覆蓋與跨 Task 的整體意圖偏離）負責。**前提**：以「spec-compliance 與 spec-coverage 都維持讀取來源 spec」為裁決前提；若其中任一被移除或改為不讀 spec，此前提即改變，須依 stale-waiver 規則重新評估。
