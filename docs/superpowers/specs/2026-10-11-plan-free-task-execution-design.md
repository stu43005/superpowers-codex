# 免 plan 執行流程：以 Task 清單取代 implementation plan

- **日期**：2026-10-11
- **狀態**：設計已獲使用者口頭核准，待 spec 雙審查迴圈
- **提交類型**：`feat!:`（移除 `writing-plans` 階段，改變整條工作流的行為契約）

## 1. 問題

目前的強制流程是 `brainstorming → spec → writing-plans → plan → subagent-driven-development`。`writing-plans` 產出的 plan 為每個 Task 寫入**完整程式碼、完整測試與完整指令**，經 per-Task reviewer 與 coverage-verifier 審查後簽入 git。接著 `subagent-driven-development`（下稱 SDD）把 plan 的 Task 全文貼給 implementer，implementer 照抄 plan 的程式碼實作並 commit。

實務上 implementer 幾乎總是完全照著 plan 寫，於是同一份程式碼被產出兩次：一次寫在 plan（並簽入 git），一次寫成真正的檔案。plan 階段的審查迴圈也是在審一份「之後會被原樣複製的程式碼」，代價是兩倍的產出、兩輪審查，以及一份在分支完成後就被刪除的大型文件（見 `16d5f5b`）。

此外，plan 簽入 git 還帶來一個副作用：實作期間若需要修正 plan，修正 commit 會落入 `TASK_BASE..HEAD`，被 spec-compliance reviewer 判為超出範圍（`2026-08-10-requirement-doc-amendment-protocol-design.md` §1 的病理二）。

## 2. 目標與非目標

### 目標

- 移除 `writing-plans` 階段：brainstorming 完成並經使用者核准 spec 後，直接進入 SDD。
- SDD 在開始實作前，從 spec 拆出一份**不含程式碼**的 Task 清單（目標＋驗收條件），存成**不簽入 git** 的檔案，並在 harness 的 Task 工具中建立對應的進度條目。
- 每個 Task 依序由 implementer subagent 以 TDD 實作；實作完成後由四個 reviewer 並行審查：spec-compliance（改為對 spec 驗證）、code-quality、task-coverage、task-seam。
- final gate 新增 spec-coverage reviewer，補上「清單整個漏掉某項 spec 需求」的檢查。

### 非目標

- **不改 brainstorming 的設計與 spec 審查流程**，只改其終點（§6.1）。
- **不在動工前審查 Task 清單、也不設使用者確認關卡。** 使用者已核准 spec；清單產生後直接開始實作。清單品質由 per-Task 的四個 reviewer 與 final gate 的 spec-coverage 在事後把關。
- **不提供 plan 與免 plan 兩條路徑並存。** 本設計完全取代 `writing-plans`。
- **不處理實作期間修改 spec 的協定。** spec 仍簽入 git，其修正問題維持現狀。`2026-08-10-requirement-doc-amendment-protocol-design.md` 中針對 plan 的部分已被本設計取代（tasks 檔不在 git 內，修改它不會污染 diff）；其針對 spec 的部分仍未實作，不在本次範圍內。
- **不改 `dispatch.sh` 與 `review-batch-lib.sh`。** 只改兩個 wrapper（`review-impl.sh`、`review-final.sh`）的參數與註冊的 job。

## 3. 整體流程

```
brainstorming（不變，直到使用者明確核准 spec）
  └─> superpowers-codex:subagent-driven-development
        Phase 0：從 spec 拆出 Task 清單（§4）
          - 寫入 tasks 檔；每個 Task 在 Task 工具建一個條目
          - 不審查、不等使用者，直接進入 Phase 1
        Phase 1：逐個 Task 依序執行
          捕捉 TASK_BASE → implementer（TDD）→ review-impl.sh（四個 reviewer，§5.1）
          → 有 finding 就修正（§5.3）並重跑整個 review-impl.sh，直到通過
          → tasks 檔該 Task 標為 done、Task 工具條目標為 completed
        Phase 2：review-final.sh（final-adversarial + spec-coverage，§5.2）
  └─> superpowers-codex:finishing-a-development-branch（清理步驟改為刪除 tasks 檔，§6.4）
```

SDD 既有的 Base SHA 追蹤（`IMPL_BASE`、`TASK_BASE`）、invocation discipline、caller control-flow、HEAD 契約、continuous execution 原則全部沿用，只把其中「plan」的依據替換成 spec 與 tasks 檔。`IMPL_BASE` 在 Phase 0 寫完 tasks 檔之後、第一個 implementer 開始之前捕捉；tasks 檔不在 git 內，捕捉時機前後不影響 SHA。

## 4. Task 清單（Phase 0）

### 4.1 位置與命名

- 路徑：`$(git rev-parse --git-dir)/superpowers/tasks/<topic>.md`。
- `<topic>`：spec 檔名去掉 `.md` 與結尾的 `-design`。例如 spec `docs/superpowers/specs/2026-10-11-plan-free-task-execution-design.md` 對應 `<topic>` = `2026-10-11-plan-free-task-execution`。
- 放在 git 目錄內的理由：永遠不會被簽入、不需修改 `.gitignore`、跨 session 仍存在、codex reviewer（外部 process，於 repo root 執行）可以讀取。
- wrapper 呼叫時以 `git rev-parse --git-dir` 的實際輸出組成路徑傳入（在一般 repo 為相對路徑 `.git/...`），不寫死 `.git`。

### 4.2 正本與 Task 工具的分工

- **tasks 檔是唯一正本**：codex reviewer 從它讀 Task 定義；controller 從它擷取 Task 全文貼給 implementer。
- **Task 工具只追蹤進度**：每個 Task 一個條目，標題對應 `Task N: <name>`，不存放 Task 內容。controller 更新 tasks 檔的 `Status` 時同步更新 Task 工具條目。
- 兩者狀態不一致時，以 tasks 檔為準。

### 4.3 檔案格式

格式定義寫在新的 sidecar `skills/subagent-driven-development/task-list-format.md`，內容如下：

````markdown
# <Feature Name> Tasks

Source spec: docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md

### Task 1: <Component Name>
Status: pending
Spec: §4.2, §4.3
Files: src/retry.ts (new), src/client.ts
Interface: export function withRetry(fn, opts)
Acceptance:
- retries up to opts.max on 5xx
- no retry on 4xx
- backoff doubles each attempt
Depends on: none
````

欄位規則：

- `Source spec:`：必填，恰好一個 spec 路徑。供 final gate 的 spec-adjudicated carve-out 以 fail-closed 方式辨識唯一來源 spec（取代原本 plan→spec 的參照）。
- 標題：`### Task N: <name>`，N 從 1 遞增；wrapper 的 `--task "Task N"` 以此比對。
- `Status:`：`pending` 或 `done`，只由 controller 更新。
- `Spec:`：此 Task 負責的 spec 章節，至少一個。
- `Files:`：預計建立或修改的檔案，標註 `(new)`。
- `Interface:`：此 Task 對其他 Task 暴露的介面（函式、型別、CLI 參數、檔案格式等）；沒有就寫 `none`。只寫簽名，不寫實作。
- `Acceptance:`：可用測試驗證的驗收條件，每條一行。
- `Depends on:`：依賴的 Task 與其使用的介面，例如 `Task 1 (HttpError type)`；沒有就寫 `none`。
- **不寫實作程式碼、測試程式碼或逐步指令。** implementer 在 TDD 中自行設計。

`task-list-format.md` 同時收納從 `writing-plans/SKILL.md` 移入的拆分原則：Scope Check（spec 涵蓋多個獨立子系統時應已在 brainstorming 拆開）與 File Structure（以職責劃分檔案、每個 Task 產出可獨立成立的變更、在既有 codebase 中遵循既有模式）。

### 4.4 Phase 0 的進入條件

- **tasks 檔不存在**：依 spec 產生清單，所有 Task 為 `pending`。
- **tasks 檔已存在且至少一個 Task 為 `done`**：視為接續執行，跳過已完成的 Task，從第一個 `pending` 開始；依 tasks 檔重建 Task 工具條目。
- **tasks 檔已存在且全部為 `pending`**：以 `AskUserQuestion` 詢問要接續還是重建。
- **tasks 檔已存在且全部為 `done`**：直接進入 Phase 2。

## 5. 審查

### 5.1 Per-Task 審查：`review-impl.sh`

新介面：

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-impl.sh" \
  --spec docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md \
  --tasks <git-dir>/superpowers/tasks/<topic>.md \
  --task "Task N" \
  --task-base <TASK_BASE>
```

`--spec`、`--tasks`、`--task`、`--task-base` 皆為必填；保留 `--max-parallel`；移除 `--plan`。wrapper 一次並行註冊四個 job。重疊的處理原則是**每個 reviewer 只回答一個問題**：

| Label | 回答的問題 | 機制與依據 | 輸出 |
|---|---|---|---|
| `spec-compliance` | 做出來的東西**對不對**：對 spec 的理解是否偏差、做法是否違背 spec 的設計決策、是否有超出此 Task 範圍的額外工作、是否碰到 spec 的 Non-goals | `task`，prompt `spec-reviewer-prompt.md`；`git diff <TASK_BASE>..HEAD` 對照此 Task `Spec:` 引用的 spec 章節。spec 是需求的唯一真相，Task 定義只用來界定範圍 | `Status: OKAY \| Issues Found` |
| `code-quality` | 做得**好不好** | `review --base <TASK_BASE>`（codex 原生 review，不變） | prose |
| `task-coverage` | **做完了沒** | `task`，prompt `task-coverage-prompt.md`；diff + tasks 檔 + spec | 逐條對照表 + `Status:` |
| `task-seam` | 跟其他 Task **接不接得起來** | `task`，prompt `task-seam-prompt.md`；diff + tasks 檔所有 sibling Task | `Status:` |

各 prompt 的 placeholder（皆由 wrapper 以 `--set` 注入）：

- `spec-reviewer-prompt.md`：`[SPEC_FILE_PATH]`、`[TASKS_FILE_PATH]`、`[TASK_ID]`、`[TASK_BASE]`
- `task-coverage-prompt.md`：同上四個
- `task-seam-prompt.md`：同上四個

`*_FILE_PATH` 的值由 `dispatch.sh` 既有的存在性檢查把關，tasks 檔不存在時 wrapper 直接失敗。

**`spec-reviewer-prompt.md`（改寫）**

- 依據從「plan 中的 Task」改為「spec 中此 Task `Spec:` 所列章節」；Task 定義只用來界定本次 diff 的範圍。
- 保留：Misunderstandings、Extra/unneeded work、Evidence Verifiability、Issue Reporting Requirements、Output Contract。
- 新增：檢查 diff 是否實作了 spec **Non-goals / Accepted limitations** 中明列不做的事。
- 移除：Missing requirements 整節（移交 `task-coverage`）。

**`task-coverage-prompt.md`（新增，由 `writing-plans/coverage-verifier-prompt.md` 改寫）**

- 逐條列出：(a) 此 Task 的每一條 `Acceptance`；(b) 此 Task `Spec:` 所列章節中所有以 must / should / need / must not / avoid 或同義語表述的條件。
- 每一條要給出 diff 中的實作位置**與**測試證據；缺任一者即為缺漏。無法以 diff 或測試驗證的項目，沿用 spec-compliance 的 Evidence Verifiability 規則：標註並移交 final gate，不判失敗。
- (b) 中有條件未被 (a) 涵蓋時，回報為「Task 定義缺漏」，與「實作缺漏」分開列出。
- 輸出格式：對照表（條目 / 來源 / 實作位置 / 測試證據 / 結果），最後一行 `Status: OKAY` 或 `Status: Issues Found`。

**`task-seam-prompt.md`（新增，由 `writing-plans/plan-document-reviewer-prompt.md` 改寫）**

保留並改寫三項準則，對象從 plan 文字改為實際 diff：

1. **介面一致性**：diff 實際對外暴露的介面是否符合此 Task 的 `Interface:`；是否符合所有在 `Depends on:` 中引用此 Task 的 sibling Task 的預期（名稱、參數、型別、回傳值）。不一致時指明是此 Task 的實作要改，還是某個 `pending` sibling 的定義要改。
2. **文件引用洩漏**：程式碼與註解不得引用 spec、tasks 檔或 Task 編號（例如「per spec §4」、「see Task 2」）。
3. **殘留 placeholder**：交付的程式碼不得含 TODO、TBD、未實作的 stub。

刪除原 plan reviewer 的 Spec Coverage（移交 `spec-compliance` 與 `task-coverage`）、Code Completeness、Command Accuracy、Pre-Implementation Research Task Leak（Task 不再含程式碼與指令，這三項不再適用）。最後一行 `Status: OKAY` 或 `Status: Issues Found`。

**通過條件**：同一輪、沒有中途修改的情況下，三個 `Status:` reviewer 全部 `Status: OKAY`，且 code-quality 沒有 blocking finding。任一 reviewer `ERROR` 即重跑整個 wrapper（沿用既有 caller control-flow）。

### 5.2 Final gate：`review-final.sh`

新介面：

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-final.sh" \
  --base <IMPL_BASE> \
  --spec docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md \
  --tasks <git-dir>/superpowers/tasks/<topic>.md
```

`--base`、`--spec`、`--tasks` 皆為必填。wrapper 並行註冊兩個 job：

- `final-adversarial`：不變（`adversarial --focus final-code-reviewer-focus.md`）。focus 中「drift from the plan's overall intent」改為「drift from the spec's overall intent」。
- `spec-coverage`：`task`，prompt `spec-coverage-prompt.md`，placeholder `[SPEC_FILE_PATH]`、`[TASKS_FILE_PATH]`、`[IMPL_BASE]`。

**`spec-coverage-prompt.md`（新增）**

- 讀完整份 spec 與 tasks 檔，並執行 `git diff [IMPL_BASE]..HEAD`。
- 逐條列出 spec 的功能需求、設計決策、must / should 類條件，各自指出實作位置；找不到者為缺漏。
- spec 的 **Non-goals / Accepted limitations** 所列項目不算缺漏。
- 另外列出：沒有任何 Task 在 `Spec:` 引用的 spec 章節（清單拆分漏洞的直接證據）。
- 最後一行 `Status: OKAY` 或 `Status: Issues Found`。

**Final gate 通過條件**：同一輪中，`spec-coverage` 為 `Status: OKAY`，且 `final-adversarial` 為 `Verdict: approve`（或其剩餘 findings 全部符合既有的 spec-adjudicated carve-out）。

**缺漏的處理**：controller 在 tasks 檔末尾追加新 Task（`pending`）涵蓋缺漏，並建立 Task 工具條目；新 Task 走完整 Phase 1 流程後，以同一個 `IMPL_BASE` 重跑整個 `review-final.sh`。final-adversarial 的 blocking findings 沿用既有做法（派 implementer 修正後重跑）。

**既有 carve-out 的來源 spec 辨識**：改為讀 tasks 檔的 `Source spec:`。欄位缺失、指向不存在的檔案、或找不到 **Non-goals / Accepted limitations** 章節時，不壓制任何 finding（沿用既有 fail-closed 規則）。

### 5.3 Finding 的修正路徑

| Finding 性質 | 處理 |
|---|---|
| 實作錯誤（任一 reviewer） | implementer 修正並 commit；重跑整個 `review-impl.sh`（同一個 `TASK_BASE`） |
| 此 Task 的定義缺漏（`task-coverage` 回報 Task 定義缺漏） | controller 先修改 tasks 檔中此 Task 的定義，再派 implementer 補實作；重跑 `review-impl.sh` |
| 某個 `pending` sibling 的定義需要調整（`task-seam` 回報） | controller 直接修改該 sibling 的定義；若此 Task 本身沒有問題，不需要重跑 |
| 某個 `done` sibling 需要調整 | 在 tasks 檔末尾追加修正 Task，不重開已完成的 Task |

tasks 檔不在 git 內，上述修改都不會出現在任何 reviewer 看到的 diff 中。controller **不得**為了讓 reviewer 通過而刪減 Task 的 `Acceptance` 或 `Spec:`：定義只能因為更貼近 spec 而修改，不能因為遷就實作而放寬。

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
- 「Read plan, extract all tasks」改為「Read tasks file」；Red Flags 中「Make subagent read plan file」改為「Make subagent read the tasks file (provide full text instead)」。
- 新增 Red Flags：寫入或簽入 tasks 檔到 repo 工作目錄；為了讓 reviewer 通過而放寬 Task 定義；在 Task 工具而非 tasks 檔中存放 Task 內容。
- Example Workflow 改寫為新流程。
- Integration 移除 writing-plans。
- Sidecar files 列出：`implementer-prompt.md`、`task-list-format.md`、`spec-reviewer-prompt.md`、`task-coverage-prompt.md`、`task-seam-prompt.md`、`spec-coverage-prompt.md`、`final-code-reviewer-focus.md`。

### 6.3 `skills/subagent-driven-development/implementer-prompt.md`

- Task Description 改為「FULL TEXT of the task from the tasks file」。
- Your Job 明訂：Task 不含程式碼，implementer 依 `Interface:` 與 `Acceptance:` 自行設計，並遵守 TDD 順序（先寫測試、看到失敗、再實作）。
- 新增：若實作需要的第三方 API 行為在 spec 中沒有記載研究結論，回報 `NEEDS_CONTEXT` 並列出需要確認的 API，不得自行猜測。controller 收到後依使用者的 research subagent 規範取得結論，再重新派發。
- Subagent model 說明從「sonnet — follows code already specified in the plan」改為依 SDD 的 Model Selection 依複雜度選擇（implementer 現在需要做程式設計，不再只是照抄）。
- 「Follow the file structure defined in the plan」改為「defined in the task's `Files:`」。

### 6.4 `skills/finishing-a-development-branch/SKILL.md`

Step 4 改為「Clean Up Completed Tasks File」：

- 只適用 Option 1、2（不變）。
- 刪除 `$(git rev-parse --git-dir)/superpowers/tasks/<topic>.md`（`rm`，不是 `git rm`，不需要 commit）。
- 若 tasks 檔中仍有 `pending` 的 Task，保留檔案並明確告知使用者。
- 「Never delete `docs/superpowers/specs/`」保留。
- Common Mistakes 中「Leaving completed plans in `docs/superpowers/plans/`」改為對應 tasks 檔的版本。

### 6.5 刪除

- `skills/writing-plans/`（整個目錄，含 `SKILL.md`、`coverage-verifier-prompt.md`、`plan-document-reviewer-prompt.md`；後兩者改寫後的內容移到 SDD 目錄，見 §5.1）。
- `scripts/review-plan.sh`。
- `scripts/review-batch-lib.test.sh` 中 review-plan 相關的測試與 plan caller shape 測試。
- `vendored-skills.txt` 中的 `writing-plans`，避免 `sync-upstream.sh` 把它帶回 `vendor` 分支。

### 6.6 保留不改

- `scripts/preflight-plugin-install.sh` 的 `SKILLS` 清單**保留** `writing-plans`：使用者環境中殘留的 legacy `writing-plans` 副本仍可能被誤觸發，preflight 應繼續把它當成需要移除的殘留。`scripts/preflight.test.sh` 隨之不變。

### 6.7 README 與 plugin metadata

- `.claude-plugin/plugin.json` 的 `description` 移除 `writing-plans`。
- `README.md`：skill 清單移除 `writing-plans`；遷移指令中的 `rm -rf` 與 legacy 檢查**保留** `writing-plans`（理由同 §6.6）；說明流程時改為 brainstorming → SDD。

## 7. 錯誤處理

- **執行途中 tasks 檔消失**（換 session 後被清除、手動刪除）：fail closed，停下來以 `AskUserQuestion` 詢問使用者，不憑記憶或 Task 工具重建。
- **tasks 檔格式不符**（缺 `Source spec:`、Task 缺必填欄位、Task 編號重複）：Phase 0 寫完後由 controller 自檢；執行途中發現時先修正 tasks 檔再繼續。wrapper 不解析 tasks 檔內容，格式錯誤只會反映在 reviewer 的 findings 中。
- **implementer 回報 `NEEDS_CONTEXT`（第三方 API）**：見 §6.3。
- **wrapper `ERROR`、`(tool exit N)`**：沿用既有 caller control-flow。

## 8. 假設

- codex companion 的 read-only 任務可以讀取 git 目錄內的一般檔案。依據：既有 reviewer 已在同一 sandbox 中執行 `git diff`，需要讀取 git 目錄。若實作時發現不可讀，改用 repo 工作目錄內、由 `.git/info/exclude` 排除的路徑，其餘設計不變。
- harness 提供 Task 工具（或等效的 TodoWrite）。SKILL.md 以「the harness's task-tracking tool」稱呼，不綁定特定工具名稱；正本在 tasks 檔，Task 工具不可用時不影響正確性。

## 9. 測試

更新 `scripts/review-batch-lib.test.sh`（以既有的 `BATCH_DISPATCH_SH` echo stub 驗證 argv 契約）：

- `review-impl.sh`：註冊四個 job，label 依序為 `spec-compliance`、`code-quality`、`task-coverage`、`task-seam`；三個 `task` job 的 prompt 路徑與 `SPEC_FILE_PATH`、`TASKS_FILE_PATH`、`TASK_ID`、`TASK_BASE` 的 `--set` 值正確；code-quality 為 `review --base <TASK_BASE>`；缺少 `--spec`、`--tasks`、`--task`、`--task-base` 任一者時 fail fast 並輸出清楚的錯誤；傳入已移除的 `--plan` 時以 unknown arg 失敗。
- `review-final.sh`：註冊兩個 job（`final-adversarial`、`spec-coverage`），`spec-coverage` 的 prompt 路徑與三個 `--set` 值正確；缺少 `--base`、`--spec`、`--tasks` 任一者時 fail fast。
- 刪除 review-plan 的所有測試與 plan caller shape 測試。
- `bash scripts/review-batch-lib.test.sh`、`bash scripts/dispatch.test.sh`、`bash scripts/preflight.test.sh` 全部通過；所有修改過的 `.sh` 通過 `shellcheck` 與 `bash -n`。

skill 文字（SKILL.md、prompt）沒有自動化測試，正確性由 spec 審查與實作階段的四個 reviewer 把關。

## Non-goals / Accepted limitations

（目前沒有。審查過程中使用者裁決不實作的顧慮將記錄於此。）
