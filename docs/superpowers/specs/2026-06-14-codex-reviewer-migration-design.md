# 設計規格：將 review subagent 改用 codex plugin 執行

- 日期：2026-06-14
- 狀態：設計（待 user 審核 → writing-plans）
- 影響範圍：`skills/brainstorming`、`skills/writing-plans`、`skills/subagent-driven-development`

## 1. 背景與目標

目前 superpowers-codex 的三個 skill 在各自的審查階段，會「啟動獨立 opus subagent（Claude Agent）」來執行 review，並以 `OKAY | Issues Found` verdict 驅動 until-OKAY 迴圈。本設計把這些 review subagent 改為透過 **codex plugin**（`codex-companion.mjs`）執行，借助 Codex 的原生 review / 對抗式 review / 通用委派能力。

目標：

1. 將既有 6 個 review 角色（brainstorming 拆為 2 個後共 7 個 reviewer 實例）改由 codex companion 執行。
2. 維持既有的零容忍 until-OKAY/approve 自動迴圈語意。
3. 修正 writing-plans Round Loop 現存的「散文 vs 虛擬碼」重跑策略矛盾，並把統一後的重跑策略套到所有 skill。
4. 不更動全域 `~/.claude/CLAUDE.md`；僅在本規格列出與之衝突、待 user 後續處理的區段。

## 2. codex plugin 機制（已查證）

companion 進入點：`node <companion> <subcommand> [args]`，與 `${CLAUDE_PLUGIN_ROOT}` 無關，可在 codex plugin command 以外的情境直接執行（已實測）。

可用於 review 的三個 subcommand：

| subcommand | 審查對象 | 自訂 prompt | 定位 | 輸出 |
|---|---|---|---|---|
| `review [--base <ref>] [--wait\|--background] [--scope auto\|working-tree\|branch]` | git diff（working-tree；`--base` 時見下方 diff 語意） | 無 | 原生 code review | **Codex reviewer 自由格式 prose；無結構化 verdict、無 `Verdict:` 行** |
| `adversarial-review [--base <ref>] [--wait\|--background] [focus text]` | git diff（`--base` 時見下方 diff 語意） | 接受 focus 文字注入 `USER_FOCUS` | 對抗式：挑戰設計/取捨/假設，**不需逐行** | 結構化 `review-output.schema.json` |
| `task [--write] [--model <m>] [--effort <e>] [prompt]` | 任意（非 diff 綁定，可讀檔、可在 repo 跑 git） | 全自訂 prompt | 通用委派；不加 `--write` 即 read-only | Codex 自由格式（由 prompt 決定） |

**`--base <ref>` 的 diff 語意（已查證 source）**：companion 並非做字面 `git diff <ref>..HEAD` 或三點 `<ref>...HEAD`，而是先算 `mergeBase = git merge-base HEAD <ref>`，再 diff `git diff <mergeBase>..HEAD`。因此凡作為 base 傳入者，**必須是 dispatch 當下 HEAD 的直系祖先**（如此 `merge-base == base`，審到的 diff 才等於預期範圍）。§5 對每個 base 都要求在正確時點以「當下 HEAD」捕捉，即滿足此前提。

**結構化輸出只有 `adversarial-review` 走**（native `review` 不走此 schema，見下）。`review-output.schema.json`：

- `verdict`：列舉值僅 `approve` | `needs-attention`。
- `findings[]`：`severity`(critical/high/medium/low)、`title`、`body`、`file`、`line_start`、`line_end`、`confidence`(0–1)、`recommendation`。
- `summary`、`next_steps[]`。

companion 把 `adversarial-review` 的 JSON 渲染成文字輸出，含 `Verdict: <verdict>` 行。**native `review` 不同**：它走 `runAppServerReview` → `renderNativeReviewResult`，把 Codex reviewer 的**自由格式 prose 原樣輸出**，沒有結構化 verdict、沒有 `Verdict:` 行；其通過/不通過一律由父 agent 解讀該 prose（見 §6 機制 C）。

`adversarial-review` 的固定 prompt 立場：「打破對變更的信心」，優先攻擊 auth/權限/隔離、資料遺失/損毀、rollback/部分失敗/idempotency、race/順序假設、空狀態/timeout/降級、版本 skew/schema drift/遷移、可觀測性缺口；只報 material findings，明文略過 style/naming；`approve` 僅在「找不到任何可支持的對抗 finding」時給出。

## 3. Reviewer → codex 對應

brainstorming 的 spec 審查由 1 個拆成 2 個互補 reviewer（結構完整性檢查 + 設計層級對抗）。全表如下：

| 編號 | 階段 | Reviewer | 審查對象 | codex 機制 | verdict 來源 |
|---|---|---|---|---|---|
| 1 | brainstorming | Spec Document Reviewer（**保留**：placeholder/一致性/scope/歧義/YAGNI） | spec 文件 | `task`（read-only）+ 既有準則 prompt | prompt 內契約 `OKAY \| Issues Found` |
| 2 | brainstorming | Adversarial Spec Review（設計層級對抗，不逐行） | spec 文件 diff | `adversarial-review --base <SPEC_BASE>` + focus | `approve` / `needs-attention` |
| 3 | writing-plans | Per-Task Reviewer | plan 文件逐 Task | `task`（read-only）+ 7 準則 prompt | prompt 內契約 `OKAY \| Issues Found` |
| 4 | writing-plans | Coverage Verifier | 整份 plan vs 整份 spec | `task`（read-only）+ 覆蓋準則 prompt | prompt 內契約 `OKAY \| Issues Found` |
| 5 | sdd | Spec-Compliance Reviewer（不信 report/逐行比對/強制附 fix code） | 實作 diff vs 需求 | `task`（read-only）+ 既有準則 prompt + git range | prompt 內契約 `OKAY \| Issues Found` |
| 6 | sdd | Code-Quality Reviewer | 單 task 的 git diff | `review --base <TASK_BASE>`（原生，無自訂 prompt） | **native 自由格式 prose；父 agent 解讀（§6 機制 C）** |
| 7 | sdd | Final Code Reviewer | 整體實作 diff | `adversarial-review --base <IMPL_BASE>` + focus | `approve` / `needs-attention` |

### 3.1 各機制選擇理由

- **1 用 `task` 而非 adversarial-review**：1 的工作是結構性完整度檢查（缺漏段落、TBD、scope、歧義），需要逐項固定準則與 `OKAY|Issues Found` 契約；adversarial-review 明文「不逐行、只挑設計」，與此互補但不可取代，故 1 保留並改用 `task`。
- **2 用 adversarial-review**：設計尚未實作，需以對抗視角挑戰設計健全性與完整性（失敗路徑/部分失敗/回滾、並發與順序假設、邊界與空狀態、相容性/遷移風險、未言明卻關鍵的假設）。
- **3/4/5 用 `task`**：皆需高度自訂、固定的逐項準則，且 3/4 審查的是 Markdown 文件（非 diff）、5 需要「不信任 report + 逐行需求比對 + 強制附 file:line 與修正 code」——這些都不是 `review`/`adversarial-review` 能表達的，`task` 可完整保留既有 prompt 與輸出契約。
- **6 用原生 `review`**：純 code 品質/bug 掃描，交給 Codex 原生 reviewer，依嚴重度回 findings。**注意**：native `review` 不回結構化 `approve|needs-attention`，只回自由格式 prose，故 6 的迴圈判定靠父 agent 解讀 prose（§6 機制 C）——這與 user 選定的「父 agent 解讀 codex findings → 維持自動 loop」整合方式一致。
- **7 用 adversarial-review**：merge 前最終 gate，adversarial 的 ship/no-ship 立場與「跨切面昂貴失敗（整合、遷移、rollback、版本 skew）」攻擊面正是整體審查所需；focus 注入「跨 task 整合縫隙 + 偏離 plan 整體意圖」。

## 4. companion 呼叫與路徑解析

skill 並非 codex plugin command，`${CLAUDE_PLUGIN_ROOT}` 不會被注入。所有改用 codex 的 dispatch 步驟一律以下列方式解析 companion 路徑（cache 取最新版本，marketplace 為 fallback）：

```bash
CODEX_COMPANION="$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)"
[ -z "$CODEX_COMPANION" ] && CODEX_COMPANION="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
node "$CODEX_COMPANION" <subcommand> [--base <sha>] [--wait] ["focus or prompt"]
```

若兩個路徑皆不存在（codex plugin 未安裝），dispatch 步驟必須中止並提示 user 安裝 / 執行 `/codex:setup`，不得退回 inline self-review 或自行偽裝審查。

## 5. base SHA 取得（diff 型 reviewer：2 / 6 / 7）

reviewer 2/6/7 透過 companion `--base` 取 diff，皆依 §2 的 `--base` 語意計算（`git diff $(git merge-base HEAD <base>)..HEAD`）。下列三個 base 取法皆「在正確時點捕捉當下 HEAD」，使該 base 為 dispatch 當下 HEAD 的直系祖先（`merge-base == base`），審到的 diff 才等於預期範圍。dispatch 步驟必須在該時點以 `git rev-parse HEAD` 實際捕捉並保存，不可事後回推。

- **2（SPEC_BASE）**：brainstorming 既有流程會把 spec 單獨 commit。`SPEC_BASE` = 寫 spec 檔前捕捉的 `git rev-parse HEAD`（即 spec commit 的父 commit）。`adversarial-review --base <SPEC_BASE>` 審到的 diff 即新加入的 spec 文件。
- **6（TASK_BASE）**：該 task 的 implementer 動工前的 HEAD（sdd 既有就需記錄每個 task 的起始 commit）。
- **7（IMPL_BASE）**：整個實作開始前的 HEAD。
- **3/4（無 base）**：read-only `task`，直接於 prompt 指明 plan / spec 檔路徑，由 Codex 讀檔。
- **5（無 --base，注意 diff 語意不同）**：read-only `task`，於 prompt 指明 `git diff <TASK_BASE>..HEAD` 範圍，由 Codex **自行跑 git** 讀實作 diff。這是字面 two-dot `<TASK_BASE>..HEAD`，**與 2/6/7 經 `--base` 走的 merge-base 語意不同**；因 reviewer 5 走 `task`（Codex 自己跑 git，不經 `--base`），在線性 task 歷史下字面 two-dot 即正確範圍。實作時**不要**把 reviewer 5「統一」成 `--base`，否則會悄悄改變 diff 語意。

文件型審查（1/3/4）若對應文件被 gitignore：1/3/4 走 `task` 讀檔不受影響；但 reviewer 2 需要 diff，若 spec 被 gitignore 則無法 commit/取 diff——此情況下 reviewer 2 跳過並在輸出說明（與既有 commit discipline「gitignored 則跳過 commit、嚴禁 `git add -f`」一致）。

## 6. verdict → 迴圈銜接

父 agent（執行 skill 的主控）負責把 codex 輸出對應回既有迴圈判定。三個機制依輸出形態區分：

- **機制 A — `task`（reviewer 1 / 3 / 4 / 5）**：沿用既有 prompt 的輸出契約。prompt 明確要求 Codex 以 `Status:`/`Verdict:` 行回 `OKAY` 或 `Issues Found` 並逐項列出問題；父 agent 解析該行。
- **機制 B — 結構化 `adversarial-review`（reviewer 2 / 7）**：讀 companion stdout 的 `Verdict:` 行。
  - `approve` → 視為通過（等同 OKAY）。
  - `needs-attention` → 視為 Issues Found：把 findings（含 file:line_start–line_end、recommendation）交給負責修正者修完，再重跑該 reviewer。
- **機制 C — native `review`（reviewer 6）**：native review **不回結構化 verdict、無 `Verdict:` 行**，只回 Codex reviewer 的自由格式 prose。父 agent 解讀該 prose：
  - prose 報出任何 blocking 等級的瑕疵（bug、明確品質/正確性問題）→ 視為 Issues Found：把對應 file:line 與建議交給負責修正者修完，再重跑 native review。
  - prose 表示無顯著問題（無 blocking finding）→ 視為通過（等同 OKAY）。
  - 此「父 agent 解讀 prose」即 user 選定的「父 agent 解讀 codex findings → 維持自動 loop」整合方式；不依賴結構化欄位。

父 agent 維持零容忍自動迴圈：發現任何 blocking finding/Issue 即修正後重跑，直到通過；此自動修正—重跑迴圈為 user 既有授權（CLAUDE.md 既有要求），不另外詢問 user（覆寫 codex result-handling 預設「review 後須問 user 才可修」的保守行為，因為 user 已給定常態授權）。

## 7. Round Loop 與重跑策略（統一）

本設計修正 writing-plans 現存矛盾（散文：只重跑未過的 Task；虛擬碼：每輪重跑全部 Task），統一為下列策略並套到所有 skill。

### 7.1 統一原則

1. **變動內容必重審**：本輪內容被編輯過的審查單位，下一輪一定重派 reviewer 重審；新建立的 Task 視為新內容，首次納入審查。
2. **改動單位的 reviewer 守接縫**：重審一個被改動的 Task A 時，其 reviewer 必須同時檢查 A 與**所有 sibling Task 及 spec** 的一致性與整合。因此「A 的變更可能弄壞未被編輯的 B」這種情況，由 A 的 reviewer 負責抓出（不需為此重跑 B）。為使此歸責成立，重審 A 時必須把 sibling Task 的脈絡一併餵給該 reviewer。
3. **未動到且已通過者退出**：回報通過（OKAY/approve）且本輪內容未被編輯的 reviewer 退出迴圈、不再重跑。

「修 A 弄壞已過 B」的兩種情況因此都被覆蓋：

- **情況 1：B 內容確實被改動** → B 以「變動內容」身分重派重審（原則 1）。
- **情況 2：B 內容未變，但 A 的變更可能弄壞 B** → A 的 reviewer 負責檢出（原則 2）。

### 7.2 套用到各 skill

- **writing-plans（Per-Task + Coverage，並行）**：
  - Per-Task reviewer：本輪被編輯（有 issue、或被修正/覆蓋缺口連帶改寫/新增）的 Task 重跑；未動且已過的 Task 退出。每個 Per-Task reviewer 一律帶 sibling Task 脈絡，扛跨 Task 一致性與整合（原則 2）。
  - Coverage Verifier：僅在「它自己查到的覆蓋缺口被修正」後才重跑；回報 OKAY 即退出。跨 Task 一致性由 Per-Task reviewer 承擔，故 Coverage **不因任何 Task 改動而被動重跑**。
  - 每輪把 Per-Task + Coverage 並行 dispatch、收齊、一次修完所有 issue/gap，再進下一輪；全部退出（同一輪內無待修內容且全通過）才結束。
- **brainstorming（reviewer 1 + 2，並行）**：reviewer 1 與 2 審查的是**同一份 spec 文件（共用 artifact）**。任何一方的 finding 被修正都會編輯該 spec，依原則 1「變動內容必重審」，**兩者每輪一起重跑**，直到同一輪內 reviewer 1 回 OKAY 且 reviewer 2 回 approve，才進 User Review Gate。
- **subagent-driven-development（reviewer 5 → 6 序列，7 末次一次）**：維持「每 task 先 spec-compliance（5）通過、再 code-quality（6）」的序列；任一發現問題 → implementer 修 → 重跑該 reviewer，直到通過；全 task 完成後跑一次 final（7）。此處每個 reviewer 對應單一 task 的實作，重跑語意即「同一 task 反覆修—審到過」，無跨單位 drop-out 問題。

## 8. 並行執行

writing-plans 同一輪的 Per-Task reviewers 與 Coverage Verifier、brainstorming 的 reviewer 1 與 2，皆以 **Claude Bash `run_in_background: true` 各自啟動一個 `node <companion> <sub> --wait ...`** 的方式並行：companion 以前景模式（`--wait`）跑到完成，由 Claude 端 detach，多個同時送出即平行執行。

**結果收集方式**：採 Claude 端背景任務輸出（對各背景 Bash 以 `BashOutput` 輪詢直到該任務結束、取得其 stdout），**不**使用 companion 自身的 `--background` + `status`/`result` 輪詢（避免兩層背景語意疊加）。父 agent 收齊整輪所有 reviewer 的 stdout 後，依 §6 機制判定、一次修正所有 issue/finding，再進下一輪。不要求 user 在 wait/background 之間選擇（既有 codex 命令的 AskUserQuestion 互動不適用於 skill 自動化情境）。

## 9. 受影響檔案與改寫形態

### 9.1 brainstorming

- `SKILL.md`：將「Spec Review Loop（單一 opus subagent）」改寫為「**雙 reviewer 並行 Round Loop**」：每輪並行 reviewer 1（`task`）+ reviewer 2（`adversarial-review`），兩者每輪一起重跑直到 reviewer 1 OKAY 且 reviewer 2 approve；更新流程圖與步驟文字（subagent → codex companion）。保留既有 git commit discipline 與 User Review Gate（Gate 內 user 要求修改後，重跑同一雙 reviewer 迴圈）。
- `spec-document-reviewer-prompt.md`（reviewer 1）：保留全部準則內容，把「Task tool (general-purpose, opus)」外殼換成 §4 的 companion `task`（read-only）呼叫；明確要求 Codex 以 `Status: OKAY | Issues Found` 契約輸出。
- **新增** `adversarial-spec-review-prompt.md`（reviewer 2）：定義 `adversarial-review --base <SPEC_BASE>` 的呼叫、focus 文字（挑戰設計健全性/完整性：失敗路徑/部分失敗/回滾、並發與順序假設、邊界與空狀態、相容性/遷移風險、未言明假設；不逐行）、SPEC_BASE 取得、`approve|needs-attention` → 迴圈對應。

### 9.2 writing-plans

- `SKILL.md`：更新「Plan Review Loop」與「The Round Loop」，把 dispatch 改為 codex companion；以 §7 統一重跑策略改寫（修掉散文/虛擬碼矛盾）；明定 Per-Task reviewer 須帶 sibling Task 脈絡並扛跨 Task 一致性、Coverage 僅在自身缺口被修後重跑。
- `plan-document-reviewer-prompt.md`（reviewer 3）：保留 7 準則；外殼換成 companion `task`（read-only）；**強化**準則使其明確承擔「被改動 Task 對所有 sibling Task 的型別/命名一致性與整合接縫」之檢查，並要求呼叫時附上 sibling Task 脈絡；要求 `OKAY | Issues Found` 契約輸出。
- `coverage-verifier-prompt.md`（reviewer 4）：保留覆蓋準則；外殼換成 companion `task`（read-only）；要求 `OKAY | Issues Found` 契約輸出。

### 9.3 subagent-driven-development

- `SKILL.md`：流程圖與步驟文字把三個 reviewer 的 dispatch 改為 codex companion（reviewer 5=`task`、6=`review`、7=`adversarial-review`）；保留「先 spec-compliance 再 code-quality」序列與「全 task 後 final 一次」。
- `spec-reviewer-prompt.md`（reviewer 5）：保留全部準則（不信 report、逐行比對、強制 file:line + 具體修正 code）；外殼換成 companion `task`（read-only），於 prompt 指明 `git diff <TASK_BASE>..HEAD` 範圍；要求 `OKAY | Issues Found` 契約輸出。
- `code-quality-reviewer-prompt.md`（reviewer 6）：改為原生 `review --base <TASK_BASE>`，移除自訂品質 checklist（交由 Codex 原生 reviewer），模板瘦身為：base 取得 + companion 呼叫 + **§6 機制 C 的 prose 解讀規則（native review 無結構化 verdict，父 agent 依 prose 是否有 blocking finding 判定 OKAY/Issues Found）** + findings 交付 implementer 的格式說明。**不得**在此模板寫入 `approve|needs-attention` / `Verdict:` 行解析（那是 adversarial-review 才有）。
- `final-code-reviewer-prompt.md`（reviewer 7）：改為 `adversarial-review --base <IMPL_BASE>` + focus（跨 task 整合縫隙 + 偏離 plan 整體意圖 + ship/no-ship）；模板改寫為：IMPL_BASE 取得 + companion 呼叫 + focus 文字 + verdict 對應。

### 9.4 共用片段的重複

§4 路徑解析與 §6 verdict 對應為跨 skill 共用知識。因本 repo 以「個別 skill 子樹」vendoring（見 README 的 vendor 分支三方合併模型），跨 skill 共用檔會破壞個別 vendoring。**決策：接受在各 prompt 模板內重複這段小片段**，以維持每個 skill 自我完備、可獨立 vendoring；不建立跨 skill 共用檔。重複時須依各 reviewer 的機制只貼對應片段：機制 A（task）貼 `OKAY|Issues Found` 契約；機制 B（adversarial-review，reviewer 2/7）貼 `Verdict: approve|needs-attention` 解析；機制 C（native review，reviewer 6）貼 prose 解讀規則——**不可把 B 的 Verdict 解析誤貼到 reviewer 6**。

## 10. 與 CLAUDE.md 的衝突（本次不改，待 user 後續處理）

全域 `~/.claude/CLAUDE.md` 多節明文且 override skill，與本設計改用 codex 的方向衝突。本次依 user 決定**僅改 repo skill 模板、不動 CLAUDE.md**；以下區段需 user 後續自行更新，否則主 agent 仍會被 CLAUDE.md 規則綁住而部分抵銷 skill 變更：

1. 「Superpowers 設計與計畫文件：Subagent 審查迴圈」整節（要求「禁止自我審查、必須啟動獨立 Agent、審查 subagent 一律 opus、loop until OKAY」）——需改為允許/指定改由 codex companion 執行。
2. 「Subagent-Driven Development：模型指定」表（Spec/Final Reviewer = opus 等）與「Spec Reviewer 額外要求」（須附修正 code）——reviewer 5 改為 codex task 後，模型欄與「啟 subagent」語意需調整；「附修正 code」要求保留並轉嫁到 codex task prompt。
3. 散見的「禁止 self-review、必須獨立 subagent」語句。

> ⚠️ 重要：在 user 更新上述 CLAUDE.md 區段前，這些 skill 變更可能無法完全生效（CLAUDE.md 仍會強制主 agent 啟 opus subagent）。

## 11. 設計取捨記錄

- **重跑策略採「變動內容重審 + 改動單位 reviewer 守接縫」而非「每輪全重跑」**：以較少的 codex 執行換取效率，同時透過「改動 Task 的 reviewer 負責跨 Task 一致性」歸責，避免犧牲「修 A 弄壞 B」的偵測。代價：Per-Task reviewer 的職責加重（須帶 sibling 脈絡、檢查接縫）。
- **reviewer 1 保留並改 `task`，而非以 reviewer 2 adversarial 取代**：兩者目標不同（結構完整度 vs 設計對抗），互補並行。
- **reviewer 6 採原生 `review`（無自訂準則）**：信任 Codex 原生 reviewer 的品質/bug 掃描；放棄原模板的細項 checklist 控制權，換取較精煉的 findings。**已查證 source**：native `review` 不回結構化 `approve|needs-attention`，只回自由格式 prose（`renderNativeReviewResult` 原樣輸出 reviewer prose）。因此 reviewer 6 的迴圈判定改採「父 agent 解讀 prose」（§6 機制 C），而非結構化 verdict——這仍符合 user 選定的「父 agent 解讀 → 自動 loop」整合。代價：reviewer 6 的 pass/fail 判定不如結構化 verdict 機械化，仰賴父 agent 對 prose 的判讀。
- **接受跨 skill 片段重複**：維持個別 skill 可獨立 vendoring。

## 12. 非目標

- 不更動 `~/.claude/CLAUDE.md`（僅列出待改清單）。
- 不更動 `finishing-a-development-branch`（無 review subagent）。
- 不新增 codex plugin 本身的功能；僅作為呼叫端使用既有 companion subcommand。
- 不改變既有 git commit discipline、User Review Gate、實作階段（implementer）流程，除了把 reviewer 的執行載體換成 codex。
