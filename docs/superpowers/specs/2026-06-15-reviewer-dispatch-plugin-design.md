# 設計規格：包成 plugin + 共用 dispatch script，reviewer 改傳路徑自讀檔

## 1. 背景與目標

目前各 skill 的 reviewer dispatch 機制散落在多個 `*-prompt.md` 檔，每個檔在「How to
Dispatch」區塊內嵌一整段 bash（companion 路徑解析、`mktemp`、`<<'PROMPT'` heredoc、
`sed` 注入、呼叫 codex、`rm`）。這帶來四個脆弱點：

1. **agent 經手 prompt body**：每次 dispatch 都要複製 heredoc 內文，可能被改寫、截斷、漏段。
2. **貼大段文字**：`plan-document-reviewer` 與 `sdd/spec-reviewer` 要求把 Task 全文／
   sibling Tasks／implementer report 貼進 heredoc，是最大的人為失誤面。
3. **機制重複**：8 個檔共用同一段 companion 路徑解析與防禦性警告，重複維護。
4. **無共用之處**：skills collection 形態下，skill 之間沒有共用路徑，任何共用 script
   都得每個 skill 各帶一份複本。

**目標**：把 dispatch 機制集中到**一份共用 script**，prompt 檔瘦成純 prompt body
（sidecar），所有 reviewer 改成「**傳路徑/識別子，reviewer 自己讀檔**」，徹底消滅貼大段
文字與複本問題。達成此目標的前提是把本專案**包成 Claude Code plugin**，以取得 plugin
root 作為共用 script 的落點與穩定的路徑解析機制。

## 2. plugin 機制（已查證，官方文件）

- **`$CLAUDE_PLUGIN_ROOT` 作為環境變數**僅 export 給 hook 進程與 MCP/LSP subprocess，
  **不會**進入一般 Bash tool 呼叫的環境（直接在 Bash 用 `$CLAUDE_PLUGIN_ROOT` 會是空值）。
- **但** `${CLAUDE_PLUGIN_ROOT}` 寫在 **skill content（SKILL.md 內文）** 時，Claude Code
  會在 skill 載入時**就地 inline 展開**成真實絕對路徑。agent 讀到的已是解析後路徑，貼進
  Bash 呼叫即可。→ 這是 skill 引用 bundled script 的官方支援機制，亦為本設計採用的方式。
- marketplace plugin 安裝時，**整棵 plugin 目錄樹原樣複製**進
  `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`，**不是** symlink 進
  `~/.claude/skills/`。因此 `skills/<name>/` 與 `scripts/` 在 cache 中為同根 siblings。
- plugin 內 `skills/<name>/SKILL.md` **自動發現**，無須在 manifest 列舉。
- 最小結構：`.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`。

> 待驗證點：inline `$CLAUDE_PLUGIN_ROOT` 展開雖有官方文件背書，建置後仍須跑 smoke test
> （安裝成 plugin、呼叫一個 skill、確認路徑確實展開且 script 可執行）才算最終確認。

> 未採用：研究過程中提及「`bin/` 自動加進 PATH」一說，未獲官方文件確證，**本設計不依賴**。

## 3. plugin 化

新增檔案（皆 top-level，只活在 main 分支）：

- `.claude-plugin/plugin.json`：欄位 `name`、`description`、`version`、`author`。
- `.claude-plugin/marketplace.json`：列出本 plugin。本 repo 為**單一 plugin、plugin 即 repo
  根**，故 `source` **預設為 `"./"`**。plan 階段須包含一個驗證任務：實際 `/plugin marketplace
  add` + `/plugin install` 後確認此 `source` 解析正確（若安裝佈局要求子目錄則據實調整）。
- README 改寫「散布形式」與「安裝方式」段落：由「丟進 `~/.claude/skills/`」改為
  `/plugin marketplace add <owner/repo>` + `/plugin install`。

**vendor 維護模型不受影響**：`plugin.json`、`marketplace.json`、`scripts/` 皆為 top-level
維護檔，依現行原則只存在於 main 分支；vendor 分支僅持有 skill 子集，三方合併不會拖動這些檔。

### 3.1 遷移與相容性（從既有 skills-collection 安裝）

新機制只在「以 plugin 形式安裝」時成立。若沿用舊的 skills-collection 安裝（把 skill 丟進
`~/.claude/skills/`、或經 `~/.agents/skills/` symlink），會出現兩種破口：(a) 非 plugin 環境下
SKILL.md 內文的 `${CLAUDE_PLUGIN_ROOT}` **不會被 inline 展開**，字面字串原樣進入 Bash →
路徑 `${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh` 找不到；(b) 舊安裝根本沒有 `scripts/dispatch.sh`。
兩者都會在「首次呼叫 reviewer」時才壞，且錯誤訊息隱晦。

因此本設計必須包含明確的遷移與防呆：

- **SKILL.md 內建防呆守衛**：呼叫 dispatch.sh 前，先檢查解析後的路徑是否仍含**字面
  `${CLAUDE_PLUGIN_ROOT}`**（代表非 plugin 安裝、inline 展開未發生）或 `dispatch.sh`
  不存在／不可執行；若是，立即以清楚訊息中止：「本 skill 需以 plugin 形式安裝
  （`/plugin install`）；偵測到非 plugin 安裝，reviewer dispatch 不可用」，並指引補救。
  此守衛須能在 darwin 上實測觸發（見 §8）。
- **升級指引（README）**：說明從 skills-collection 遷移到 plugin 時，需移除或停用殘留的
  `~/.claude/skills/<name>`（含 `~/.agents/skills/<name>` symlink 目標），避免舊的
  SKILL.md 遮蔽 plugin 版本。
- **不提供雙模式相容**：不為「同時支援 plugin 與非 plugin」投入額外抽象（YAGNI）；非 plugin
  安裝一律以上述守衛明確擋下，而非靜默降級。

## 4. 共用 `scripts/dispatch.sh`（plugin root 一份）

唯一一份 dispatch script，置於 plugin root 的 `scripts/dispatch.sh`，三個 skill 共用。

### 4.1 三個子命令

```bash
dispatch.sh task        --prompt <ABS_PATH> [--report-file <PATH>] [--set KEY=VALUE]... [--dry-run]
dispatch.sh review      --base <SHA>                                              [--dry-run]
dispatch.sh adversarial --base <SHA> --focus <ABS_PATH>                           [--dry-run]
```

- `task`：對應 Type A（有 prompt body）。讀 `--prompt` 指向的 sidecar，套用所有
  `--set` 注入，寫入 temp 檔，**以前景阻塞方式**呼叫 `node <companion> task --prompt-file <temp>`。
  implementer report 經**專屬旗標** `--report-file` 傳入（不走 generic `--set`，見 §6），
  dispatch.sh 以其值填入 prompt 的 `[REPORT_FILE_PATH]`。
  - **同步性接地（重要，§6 生命週期契約所依賴）**：`task` **沒有** `--wait` 旗標
    （`--wait` 只屬 `review`/`adversarial-review`），但 `task` 仍是**同步**的——其同步性
    來自「dispatch.sh 以前景指令呼叫該 process、阻塞到它 exit」，**而非** `--wait`。已驗證：
    本 spec review 的**每一次** `node companion task --prompt-file` 都在同一次呼叫內印出
    **完整 reviewer 輸出 + 最終 `Status:` 行**並 exit 0（若為 fire-and-forget 不可能取得
    review 內文）。**機械化保證**：dispatch.sh 必須以前景方式呼叫 companion（**禁止**用 `&`
    背景化、禁止 fire-and-forget），如此 dispatch.sh 的返回與 EXIT trap 必嚴格晚於 companion
    exit；reviewer 在 companion 執行期間讀取 `--prompt`/`[REPORT_FILE_PATH]`，兩者全程存活。
- `review`：對應 `sdd/code-quality`。呼叫 `node <companion> review --base <SHA> --wait`。
- `adversarial`：對應 `adversarial-spec-review`、`sdd/final-code`。呼叫
  `node <companion> adversarial-review --base <SHA> --wait "$(cat <focus>)"`。

**路徑契約（三類路徑，務必分清，否則 reviewer 會讀到空檔或錯檔）：**

1. **plugin-bundled 路徑**（`--prompt`、`--focus`、以及 dispatch.sh 自身路徑）：指向 plugin
   cache 內的檔，**必為絕對路徑**，由 SKILL.md 的 `${CLAUDE_PLUGIN_ROOT}` inline 展開提供。
2. **受審 repo 檔路徑**（`--set PLAN_FILE_PATH`／`SPEC_FILE_PATH` 等指向受版控檔案的值）：
   由 **codex companion 以其自身 cwd 讀取**。已驗證 codex companion 在 **repo 根目錄**執行
   （review 過程中 codex 實際跑 `pwd && ls`、`rg --files` 並成功以 `docs/…` 相對路徑讀檔）。
   因此這類值為 **repo-root-relative**，且 **orchestrator 必須在 repo 根目錄呼叫 dispatch.sh**。
3. **report temp 檔路徑**（`--report-file` 的值）：這是 orchestrator 以 `mktemp` 產生的
   **絕對路徑**暫存檔，**非**受版控 repo 檔，故不屬第 2 類、不適用 repo-relative。dispatch.sh
   驗證其存在後，將該絕對路徑填入 `[REPORT_FILE_PATH]`。

為避免「cwd 不符 → 相對路徑指向空」的靜默失敗，**dispatch.sh 必須對每一個檔案路徑值
（三類皆然）做存在性驗證**：解析後若檔案不存在即 stderr 報錯、非零退出（見 §4.3）。如此
cwd 錯誤會「大聲」失敗，而非送出指向空檔的 prompt。script 本身不需自我定位 sidecar。

### 4.2 共通內含

- **codex companion 路徑解析**：沿用現行片段
  `ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | sort -V | tail -1`，
  fallback 至 `~/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs`；
  找不到則 stderr 輸出「codex plugin not found; run /codex:setup. Do NOT fall back to
  inline self-review.」並以非零退出。
- **companion 版本/能力守衛（不盲信「最新版」）**：`sort -V | tail -1` 只挑到最新快取，不保證
  介面相容。dispatch.sh 在 dispatch 前須做一次**能力檢查**：以 companion 的版本指令取得版本，
  斷言 **≥ 釘選的最低相容版本**（最低版本於 plan 階段對實際安裝版本 `1.0.4` 校準確定）；
  若無法取得版本或低於門檻，stderr 輸出明確訊息（含「run /codex:setup 更新 codex」）並非零
  退出。此檢查由 dispatch.sh 內部一次性執行，**不等同**讓 agent 每次 dispatch 前自行
  `--help` 探測（後者仍禁止）。
- `mktemp` 建 temp prompt 檔，`trap '… rm -f' EXIT` 清理。**EXIT trap 只刪除 dispatch.sh
  自己以 `mktemp` 建立的暫存檔**（temp prompt 等），**絕不刪除任何 `--set` 值、`--report-file`
  值或其他外部傳入路徑**——避免誤刪 repo/使用者檔，亦避免並行 reviewer 互相早刪（見 §6）。
- **`--set KEY=VALUE` 必須 data-safe（強制，非慣例）**：替換時 `VALUE` 一律當作**字面字串**
  處理，不得被解讀為 regex／sed replacement metacharacter。realistic 的路徑與 task title 可能
  含空格、`#`、`&`、`\`、`[]` 等，慣例式「假設值安全」會損毀 prompt 或留下殘餘 placeholder。
  - 採用對兩側都字面安全的機制，例如 bash 參數展開（pattern 加引號以關閉 glob、replacement
    為字面）：`content="${content//"[$KEY]"/"$VALUE"}"`；或以 `awk -v val="$VALUE"` /
    `python` 等把值當字面參數帶入的引擎。**禁止** `sed -i`（BSD/macOS 會靜默失敗——本次
    review 第 1 輪實證）與任何把 `VALUE` 當 regex/replacement 語法的寫法。
  - 輸入驗證：拒絕含**換行**的 `VALUE`（破壞單行假設）；其餘 metacharacter 因字面處理而安全。
  - 須經 §8 在 darwin 上以含空格／`#`／`&`／`\`／`[]` 的值實測通過。

### 4.3 安全機制

- **殘留 placeholder 偵測**：所有 `--set` 注入完成後，grep temp prompt 是否仍含
  `\[[A-Z_][A-Z0-9_]*\]`；若有，視為漏給 `--set`，stderr 報出殘留 token 並非零退出
  （絕不送出帶有未替換 placeholder 的 prompt 給 codex）。
- **`--dry-run`**：印出注入後的 temp prompt 內容與「將要執行的 codex 指令」，但**不**呼叫
  codex。供 `bash -n` / `shellcheck` 之外的逐 reviewer 行為驗證。
- 參數驗證：未知子命令、缺 `--prompt`/`--base`/`--focus` → 報錯非零退出。
- **路徑存在性驗證（§4.1 路徑契約的執行點）**：`--prompt`、`--focus`、`--report-file`，
  以及所有指向受審 repo 檔的 `--set` 值（`PLAN_FILE_PATH`／`SPEC_FILE_PATH` 等），解析後
  若檔案不存在 → stderr 報出該路徑、非零退出。確保 cwd 錯誤或路徑錯誤「大聲」失敗，而非把
  指向空檔的 prompt 送進 codex。

## 5. 受影響的七個 prompt 檔轉換

> `sdd/implementer-prompt.md` **完全不動**（非本次範圍；接受 sdd 內部短期不一致：
> reviewers 走新 script、implementer 仍為舊 heredoc）。

### 5.1 Type A（瘦成純 prompt body）

對以下四檔：刪除整個「How to Dispatch」bash 區塊與防禦性警告引言，檔案僅保留**送給 codex
的 prompt 內文**，並以 `[PLACEHOLDER]` 標記注入點。

- **`writing-plans/plan-document-reviewer-prompt.md`**：移除「貼 Task 全文 / 貼 sibling
  Tasks」。改為指示：「讀取 `[PLAN_FILE_PATH]`。Review 其中標題為 `[TASK_ID]` 的 Task；
  將該檔其餘所有 Task 視為 sibling context 做跨 Task 一致性檢查。」placeholder：
  `[PLAN_FILE_PATH]`、`[SPEC_FILE_PATH]`、`[TASK_ID]`。
- **`subagent-driven-development/spec-reviewer-prompt.md`**：placeholder
  `[PLAN_FILE_PATH]`、`[TASK_ID]`、`[TASK_BASE]`（由 `--set` 提供）、`[REPORT_FILE_PATH]`
  （由專屬 `--report-file` 提供，見 §6）。指示 reviewer 讀 plan 中標題 `[TASK_ID]` 的 Task、
  讀 `[REPORT_FILE_PATH]`（implementer report）、並執行 `git diff [TASK_BASE]..HEAD` 比對
  宣稱與實作。
- **`writing-plans/coverage-verifier-prompt.md`**：本即只注入路徑。placeholder
  `[PLAN_FILE_PATH]`、`[SPEC_FILE_PATH]`，改由 `--set` 提供。
- **`brainstorming/spec-document-reviewer-prompt.md`**：本即只注入路徑。placeholder
  `[SPEC_FILE_PATH]`，改由 `--set` 提供。

### 5.2 Type B

- **`subagent-driven-development/code-quality-reviewer-prompt.md`**：無 focus 字串。
  改由 `dispatch.sh review --base <SHA>` 呼叫（`review` 子命令**不吃任何 prompt 檔**）。
  因此本檔不再有 sidecar prompt body，**轉為純人讀的 SKILL 支援文件**（記錄何時跑、
  `review` 的 verdict 語義與回傳格式），dispatch.sh 不會消費它。
- **`brainstorming/adversarial-spec-review-prompt.md`**、
  **`subagent-driven-development/final-code-reviewer-prompt.md`**：將既有的長 focus 字串
  抽成同目錄 sidecar `<x>-focus.md`（純 focus 文字）；改由
  `dispatch.sh adversarial --base <SHA> --focus ${CLAUDE_PLUGIN_ROOT}/skills/<name>/<x>-focus.md`
  呼叫。

## 6. implementer report 改以路徑傳遞

`sdd/spec-reviewer` 原本貼入 implementer 的回報文字。改為：orchestrator（sdd SKILL 流程）
將 implementer 回報寫入一個暫存檔，透過**專屬旗標 `--report-file <path>`** 傳入；dispatch.sh
驗證其存在後，把該路徑填入 prompt 的 `[REPORT_FILE_PATH]`，reviewer 自行讀取。如此**沒有
任何大段文字進入 prompt**，貫徹「傳路徑、自己讀檔」原則。

**擁有權與生命週期（同時消除「誤刪」與「早刪/並行競態」）：**

- **dispatch.sh 把 `--report-file` 視為唯讀輸入，絕不刪除它**（亦不刪除任何 `--set` 值或外部
  路徑）。dispatch.sh 的 EXIT trap **只清理自己以 `mktemp` 建立的暫存檔**（§4.2）。如此即使
  在驗證失敗提早退出時觸發 trap，也不會對外部檔案造成破壞性動作。
- **報告檔由 orchestrator 全程擁有**：以 `mktemp` 產生（路徑唯一、絕對），**每個 reviewer
  一份、嚴禁多個並行 dispatch 共用同一個 `--report-file`**（否則一個讀完刪除會害到另一個）。
- **刪除時機綁定「dispatch 完成」**：orchestrator 只在該次（背景）dispatch **完成通知**之後
  才刪除報告檔。其正確性鏈條為：dispatch.sh **以前景阻塞方式**呼叫 companion（§4.1 同步性
  接地；`task` 無 `--wait` 不影響，同步性來自前景呼叫而非旗標）→ dispatch.sh 只在 companion
  exit 後才返回 → 背景 dispatch 的「完成通知」必晚於 companion exit → 此時 reviewer 已讀畢
  `--prompt` 與報告檔。因此**不存在早刪競態**，且刪除的永遠是 orchestrator 自己建立、可追蹤
  的唯一檔案。dispatch.sh 的 EXIT trap（清自建 temp prompt）同理必晚於 companion exit。
- 若該次 dispatch 異常未送出完成通知，orchestrator 仍應在流程收尾時清掉自己建立的報告檔
  （以 `mktemp` 路徑可追蹤，無洩漏）。

## 7. 三個 SKILL.md 更新

對 `brainstorming`、`writing-plans`、`subagent-driven-development` 三個 SKILL.md：

- 將原本「以此 bash 區塊 dispatch」的引用，改為呼叫共用 script 的用法。**注意兩類路徑
  的區別（§4.1）**：`dispatch.sh` 與 `--prompt` 為 plugin-bundled，用絕對的
  `${CLAUDE_PLUGIN_ROOT}`；`--set` 的 `PLAN_FILE_PATH`／`SPEC_FILE_PATH` 為受審 repo 檔，
  用 **repo-root-relative** 路徑，且**須在 repo 根目錄呼叫**：
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" task \
    --prompt "${CLAUDE_PLUGIN_ROOT}/skills/writing-plans/plan-document-reviewer-prompt.md" \
    --set PLAN_FILE_PATH=docs/superpowers/plans/<…>-plan.md \
    --set SPEC_FILE_PATH=docs/superpowers/specs/<…>-design.md \
    --set TASK_ID="Task 3"
  ```
  （此例與 §4.1 契約一致：bundled 路徑絕對、repo 路徑相對；dispatch.sh 會驗證所有路徑存在。）
- **非 plugin 安裝防呆守衛**（§3.1）：呼叫前先確認 dispatch.sh 路徑已被 inline 展開
  （不含字面 `${CLAUDE_PLUGIN_ROOT}`）且檔案存在可執行，否則以清楚訊息中止。
- 原本散落在各 prompt 檔的 Purpose／dispatch context 說明，移入對應 SKILL.md。
- sdd SKILL.md 增加一步：spec compliance review 前，把 implementer 回報以 `mktemp` 寫入
  一個**唯一**暫存檔（每個 reviewer 一份、不共用），以 `--report-file <path>` 傳入；該次
  （背景）dispatch **完成通知後**才刪除該檔（§6）。
- base SHA（`SPEC_BASE`/`TASK_BASE`/`IMPL_BASE`）的擷取時機與既有規定不變，僅改為以
  `--base` 傳給 dispatch.sh。
- 並行 dispatch（per-Task reviewer、雙 spec reviewer 等）的 `run_in_background` 行為不變，
  僅替換為呼叫 dispatch.sh。

## 8. 驗證策略

- `bash -n scripts/dispatch.sh` 與 `shellcheck scripts/dispatch.sh`。
- 對每個 reviewer 以 `--dry-run` 驗證：注入後的 prompt 無殘留 placeholder、codex 指令正確。
- 殘留 placeholder 偵測之正向／負向案例（故意漏 `--set` 應非零退出）。
- **data-safe 替換實測（darwin）**：在 macOS 上實跑 `--set`，確認替換生效、無「invalid
  command code」之類靜默失敗；並以含**空格／`#`／`&`／`\`／`[]`** 的 `VALUE` 驗證 prompt
  不被損毀、無殘留 placeholder、無非預期注入；含**換行**的 `VALUE` 應被拒（§4.2）。
- **companion 版本/能力守衛實測**：模擬版本低於門檻或無法取得版本時，確認非零退出且訊息
  指向 `/codex:setup`（§4.2）。
- **報告檔擁有權實測**：確認 dispatch.sh **不刪除** `--report-file` 與任何 `--set` 路徑（只刪
  自建 mktemp）；驗證失敗提早退出時不破壞外部檔；兩個並行 dispatch 使用各自唯一報告檔互不
  干擾（§6）。
- **`task` 前景同步性實測**：確認 `task` dispatch 為前景阻塞——dispatch.sh 只在印出完整
  reviewer 輸出（含最終 `Status:` 行）後才返回；且靜態檢查 dispatch.sh 對 companion 的呼叫
  **未使用 `&` 背景化**（§4.1/§6 生命週期契約的前提）。
- **路徑存在性驗證實測**：故意傳不存在的 `--set`／`--report-file` 路徑與錯誤 cwd，確認非零
  退出（§4.1/§4.3）。
- plugin 安裝 smoke test：安裝成 plugin、實際呼叫一個 skill、確認 `${CLAUDE_PLUGIN_ROOT}`
  inline 展開生效且 dispatch.sh 可定位並執行。
- **遷移防呆 smoke test（從既有 skills-collection 安裝起跑，非只測全新 plugin）**：在非
  plugin 安裝環境下呼叫，確認 §3.1 守衛以清楚訊息中止（而非隱晦失敗或靜默降級）。

## 9. 設計取捨記錄

- **散布形式由 skills collection 改為 plugin**：取得 plugin root 與穩定路徑解析，代價是
  安裝方式改變、README 重寫。已確認接受。
- **共用單一 dispatch.sh（vs 每 skill 複本）**：消滅複本與機制重複；依賴 plugin root，故須
  plugin 化。
- **路徑解析採 `${CLAUDE_PLUGIN_ROOT}` inline 展開（vs Skill tool base dir）**：官方機制、
  較穩；放棄 base-dir 方案。
- **CLI 採泛用 `--set KEY=VALUE`（vs 固定具名 flag / 每 reviewer 專屬 script）**：新增
  reviewer 不必改 script，placeholder 集合僅存在於 sidecar。
- **implementer report 改傳 temp 檔路徑（vs 續貼文字）**：徹底消除 prompt 內 bulk 文字。
- **編輯到的 on-vendor 檔**（`plan-document-reviewer`、`spec-document-reviewer`、
  `sdd/spec-reviewer`、`sdd/code-quality`）未來上游改同一 hunk 會衝突；惟這些已因 codex 化
  大幅 diverge，本次延續既有手動解衝突成本。新增檔（dispatch.sh、`*-focus.md`、manifest）
  永遠 merge-safe。
- **替換改為 data-safe 且可攜（vs `sed -i` + 慣例式假設）**：`sed -i "s#…#"` 在 BSD/macOS
  靜默失敗（review 第 1 輪實證）；且「值很安全」是慣例非強制（review 第 2 輪指出真實路徑/
  task title 可能含空格、`#`、`&`、`\`、`[]`）。改為把 `VALUE` 當字面字串的 data-safe 機制
  （如 bash 引號 pattern 參數展開），darwin 與 Linux 一致，且 metacharacter 安全。
- **路徑契約分三類（bundled 絕對 / repo input 相對 / report temp 絕對）**：解決 §4.1 與 §7
  以及 `REPORT_FILE_PATH` 分類矛盾；以 dispatch.sh 的存在性驗證強制執行，cwd 錯誤大聲失敗。
- **報告 temp 檔擁有權歸 orchestrator、dispatch.sh 絕不刪外部檔（vs 由 dispatch.sh 刪）**：
  review 第 2 輪指出「dispatch.sh 刪 generic 傳入路徑」會誤刪 repo/使用者檔、並行共用會早刪、
  trap 在驗證失敗時也會刪。改為 dispatch.sh 只刪自建 mktemp；報告檔每 reviewer 唯一、由
  orchestrator 在「dispatch 完成通知後」刪除，既無誤刪也無早刪競態。
- **companion 版本/能力守衛（vs 盲選 `sort -V | tail -1` 最新版）**：避免遷移後因 companion
  版本不相容而 runtime 才壞；dispatch.sh 一次性斷言最低相容版本，不相容則指向 `/codex:setup`。
- **`task` 同步性以「前景呼叫」接地（vs 依賴 `--wait` 或裸假設）**：`task` 無 `--wait`，但
  以前景阻塞呼叫 companion 即保證 dispatch.sh 返回晚於 companion exit；生命週期契約據此成立，
  並以「禁止 `&` 背景化」機械化保證（review 第 3 輪 finding）。
- **非 plugin 安裝採明確守衛擋下（vs 雙模式相容）**：YAGNI；不投入相容抽象，遷移以守衛
  與升級指引處理。

## 10. 非目標

- 不改 `sdd/implementer-prompt.md`。
- 不變更 reviewer 的審查準則內容（僅搬移注入機制與輸入方式）。
- 不變更 base SHA 的擷取時機與 round-loop 重跑策略。
- 不處理與既有 CLAUDE.md 規則的潛在衝突（若有，留待 user 後續處理）。
