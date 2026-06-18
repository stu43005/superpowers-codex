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
- `scripts/dispatch.sh`：共用 dispatch script（§4）。
- `scripts/preflight-plugin-install.sh`：遷移防呆 preflight（§3.1）。
- README 改寫「散布形式」與「安裝方式」段落：由「丟進 `~/.claude/skills/`」改為
  `/plugin marketplace add <owner/repo>` + `/plugin install`，並納入遷移移除 legacy 與事後
  驗證指令。

**vendor 維護模型不受影響**：`plugin.json`、`marketplace.json`、`scripts/` 皆為 top-level
維護檔，依現行原則只存在於 main 分支；vendor 分支僅持有 skill 子集，三方合併不會拖動這些檔。

### 3.1 遷移與相容性（從既有 skills-collection 安裝）

新機制只在「以 plugin 形式安裝」時成立。若沿用舊的 skills-collection 安裝（把 skill 丟進
`~/.claude/skills/`、或經 `~/.agents/skills/` symlink），會出現兩種破口：(a) 非 plugin 環境下
SKILL.md 內文的 `${CLAUDE_PLUGIN_ROOT}` **不會被 inline 展開**，字面字串原樣進入 Bash →
路徑 `${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh` 找不到；(b) 舊安裝根本沒有 `scripts/dispatch.sh`。
兩者都會在「首次呼叫 reviewer」時才壞，且錯誤訊息隱晦。

因此本設計必須包含明確的遷移與防呆：

- **SKILL.md dispatch 區塊預設以 plugin 形式安裝（無 SKILL 內守衛）**：dispatch 區塊直接呼叫
  `"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh"`，**不在 SKILL 內加 plugin 偵測守衛**（保持指令
  簡單、可靜態分析）。非 plugin／被遮蔽安裝時 `${CLAUDE_PLUGIN_ROOT}` 不會 inline 展開，該指令
  會以一般 shell 錯誤失敗（路徑找不到）。此失敗可接受：因為**遮蔽情境本來就無法靠 SKILL 內守衛
  攔截**——被遮蔽時 Claude 載入的是舊 SKILL.md，任何寫在 plugin 版 SKILL.md 的守衛根本不會跑。
  遷移安全因此**完全**依賴下面兩項「skill 路徑之外」的機制。
- **具體 preflight artifact（skill 路徑之外、不依賴新 SKILL.md 載入）**：新增一支
  **`scripts/preflight-plugin-install.sh`**（隨 plugin 出貨）。它掃描已知 legacy 位置——
  本三個 skill 名於 `~/.claude/skills/<name>`、`~/.agents/skills/<name>`（含 symlink 目標）
  ——**只要存在任何會遮蔽 plugin 副本的 legacy 路徑就以非零退出**，印出該路徑與移除指引。
  此 script 不 source 任何 SKILL.md，因此**不受遮蔽影響**。
- **呼叫點與「誠實限制」**：plan 階段須**實測**確定 (a) `~/.claude/skills/<name>`、
  `~/.agents/skills/<name>`、plugin cache 三者的發現/優先順序（不得臆測、寫入文件），以及
  (b) Claude `/plugin install` 是否能經 plugin hook **自動**執行上述 preflight。
  - 若可自動執行 → 在 plugin manifest 宣告該 hook，使「安裝未通過 preflight 即不算完成」。
  - 若**不可**自動執行 → spec **明確聲明此限制**，並改以**強制的事後驗證指令**把關：遷移文件
    要求使用者於安裝後執行 `preflight-plugin-install.sh`（以及一個「證明被載入的是 plugin 版
    SKILL.md」的確定性檢查，例如確認該 skill 解析到的 `dispatch.sh` 落在 plugin cache 路徑、
    且無 legacy skill dir 殘留）；此指令是遷移完成的必要條件，並納入 §8 smoke test。
- **升級指引（README）＋強制移除**：從 skills-collection 遷移到 plugin 時，**必須移除/停用**
  殘留的 `~/.claude/skills/<name>`（含 `~/.agents/skills/<name>` symlink 目標）。此步驟不是
  建議而是遷移的必要條件，並由上述 preflight 驗證把關。
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
  implementer report 經**專屬旗標** `--report-file` 傳入（不走 generic `--set`，見 §6）；
  dispatch.sh 將其內容複製到自己的私有暫存檔，並以**私有副本路徑**填入 prompt 的
  `[REPORT_FILE_PATH]`。
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
   驗證其存在後，**將其內容複製到自己的私有 `mktemp` 副本，並把該私有副本路徑填入
   `[REPORT_FILE_PATH]`**（生命週期與擁有權見 §6）；填入 prompt 的不是來源路徑。

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
  斷言 **≥ 釘選的最低相容版本**（最低版本為 plan 的**明確交付物**：對實際安裝版本 `1.0.4`
  校準後寫定於 dispatch.sh 與文件）；
  若無法取得版本或低於門檻，stderr 輸出明確訊息（含「run /codex:setup 更新 codex」）並非零
  退出。此檢查由 dispatch.sh 內部一次性執行，**不等同**讓 agent 每次 dispatch 前自行
  `--help` 探測（後者仍禁止）。
- `mktemp` 建 temp prompt 檔與（若有 `--report-file`）報告私有副本，`trap cleanup EXIT INT TERM`
  清理。**trap 只刪除 dispatch.sh 自己以 `mktemp` 建立的暫存檔**（temp prompt、報告私有副本），
  涵蓋正常結束、驗證失敗提早退出、被取消/逾時中斷；**絕不刪除任何 `--set` 值、`--report-file`
  來源檔或其他外部傳入路徑**——避免誤刪 repo/使用者檔，亦避免並行 reviewer 互相早刪（見 §6）。
- **companion 進度噪音過濾（`[codex]` 行）**：codex companion 會把每回合進度行（前綴
  `[codex]`）寫到 **stderr**（已驗證於 `tracked-jobs.mjs`），reviewer 真正結果（agent 需要的
  `Status:`／`Verdict:` 內容）走 **stdout**。dispatch.sh 在每次**真實**呼叫 companion 時須濾掉
  這些 `[codex]` stderr 行，**保留 stdout 原樣**、保留非 `[codex]` 的真實 stderr（錯誤訊息不被
  吞掉），並**傳遞 companion 自身的 exit code**（不得被過濾器的退出碼取代）。`--dry-run` 不受影響
  （僅印出 `node …` 指令、不呼叫 companion）。
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
  - **companion 解析在 dry-run 採寬鬆預覽語意（刻意設計，供 hermetic 測試）**：若能解析到
    companion，dry-run 仍做版本守衛（§4.2）並印出真實的 `node <companion> …` 指令；**若解析
    不到** companion，dry-run 印出 `<companion-unresolved>` placeholder 並仍以 0 退出，使
    placeholder 替換／路徑驗證等行為可在未安裝 codex 的環境被測試。§4.2 的「找不到 companion →
    stderr 訊息並非零退出」之強制，僅作用於**真實執行路徑**（非 `--dry-run`）。
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

### 5.2 Type B（刪除冗餘的 `-prompt.md`，dispatch 用法移入 SKILL.md）

這三個 reviewer **不**經由 `--prompt` sidecar dispatch，其 `-prompt.md` 不被任何東西消費。
重構後 dispatch 用法、verdict 解析（與 code-quality 的 severity calibration）一律寫進**消費端
SKILL.md**，故這三個 `-prompt.md` 冗餘且易與 SKILL.md drift，**一律刪除**：

- **`subagent-driven-development/code-quality-reviewer-prompt.md`**：**刪除**。改由
  `dispatch.sh review --base <SHA>` 呼叫（`review` 子命令**不吃任何 prompt 檔**、無 focus
  字串）。其「何時跑、`review` 回傳 prose（非 `Verdict:` 行）的解讀、severity calibration、
  不問使用者自動 loop」等說明移入 `subagent-driven-development/SKILL.md`。
- **`brainstorming/adversarial-spec-review-prompt.md`**、
  **`subagent-driven-development/final-code-reviewer-prompt.md`**：**刪除**。既有的長 focus
  字串抽成同目錄 sidecar `<x>-focus.md`（純 focus 文字，由 dispatch 消費）；dispatch 用法
  `dispatch.sh adversarial --base <SHA> --focus ${CLAUDE_PLUGIN_ROOT}/skills/<name>/<x>-focus.md`
  與 verdict 解析寫進對應的 SKILL.md（brainstorming／subagent-driven-development）。

## 6. implementer report 改以路徑傳遞

`sdd/spec-reviewer` 原本貼入 implementer 的回報文字。改為：orchestrator（sdd SKILL 流程）
將 implementer 回報寫入一個來源檔，透過**專屬旗標 `--report-file <path>`** 傳入。如此**沒有
任何大段文字進入 prompt**，貫徹「傳路徑、自己讀檔」原則。

**生命週期：reviewer 正確性完全由 dispatch.sh 自包（不依賴 orchestrator 的背景通知時序）。**
這是針對「prose 契約無法強制、漏通知洩漏、錯關聯早刪」的具體機制化解法：

- **dispatch.sh 讀入 `--report-file` 後，立刻把其內容複製到自己以 `mktemp` 建立的私有暫存檔**
  （與 temp prompt 同屬 dispatch.sh 私有），並把**該私有副本的路徑**填入 prompt 的
  `[REPORT_FILE_PATH]`。reviewer 全程讀的是 dispatch.sh 的私有副本。
- **私有副本生命週期 = dispatch.sh 行程生命週期**：dispatch.sh 以前景阻塞呼叫 companion
  （§4.1 同步性接地），私有副本在整個 reviewer 執行期間存活；dispatch.sh 安裝
  `trap cleanup EXIT INT TERM`，**只刪除自己建立的私有暫存檔**（temp prompt + 報告私有副本），
  涵蓋正常結束、驗證失敗提早退出、以及被取消/逾時中斷。
- **與 orchestrator 的來源檔解耦**：因為 dispatch.sh 在呼叫 codex **之前**已複製內容，reviewer
  的正確性**不再取決於** orchestrator 何時刪除 `--report-file` 來源檔。orchestrator 可在
  dispatch.sh 返回後刪除自己的來源檔；即使因中斷而漏刪，那只是 orchestrator 自身的良性暫存
  殘留，**不影響任何 reviewer 的輸入**。dispatch.sh **絕不刪除** `--report-file` 來源檔或任何
  `--set`/外部路徑。
- **並行安全**：每次 dispatch.sh 呼叫各有獨立的 `mktemp` 私有副本，天然唯一；reviewer 正確性
  不需要 orchestrator 維護 job→path 對應（該對應僅用於 orchestrator 自身來源檔的良性清理）。

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
- **預設 plugin 安裝、無 SKILL 內守衛**（§3.1）：dispatch 區塊直接呼叫
  `"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh"`，不在 SKILL 內加 plugin 偵測守衛；非 plugin
  安裝時 inline 展開不發生、指令以一般 shell 錯誤失敗，遷移安全改由 preflight 與安裝後驗證
  （§3.1、§8）保證。
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
- **報告檔生命週期實測**：確認 dispatch.sh 把 `--report-file` 內容複製到私有副本、reviewer
  讀到的是私有副本路徑；`--report-file` 來源檔與任何 `--set` 路徑**永不被 dispatch.sh 刪除**；
  trap 在正常結束、驗證失敗提早退出、以及 `INT`/`TERM` 中斷時都只清掉自建私有副本（無洩漏、
  不破壞外部檔）；兩個並行 dispatch 各自私有副本互不干擾（§6）。
- **`task` 前景同步性實測**：確認 `task` dispatch 為前景阻塞——dispatch.sh 只在印出完整
  reviewer 輸出（含最終 `Status:` 行）後才返回；且靜態檢查 dispatch.sh 對 companion 的呼叫
  **未使用 `&` 背景化**（§4.1/§6 生命週期契約的前提）。
- **路徑存在性驗證實測**：故意傳不存在的 `--set`／`--report-file` 路徑與錯誤 cwd，確認非零
  退出（§4.1/§4.3）。
- plugin 安裝 smoke test：安裝成 plugin、實際呼叫一個 skill、確認 `${CLAUDE_PLUGIN_ROOT}`
  inline 展開生效且 dispatch.sh 可定位並執行。
- **發現順序實測**：實際建立 `~/.claude/skills/<name>`、`~/.agents/skills/<name>` 與 plugin
  cache 並存的情境，確認何者勝出、寫入文件（§3.1，不得臆測）。
- **遷移 preflight 與防呆 smoke test（從既有 skills-collection 安裝起跑，非只測全新 plugin）**：
  (a) 存在會遮蔽 plugin 的 legacy 路徑時，preflight/安裝驗證**失敗**並要求移除；(b) 移除 legacy
  後，plugin 版 SKILL.md 載入、`${CLAUDE_PLUGIN_ROOT}` 展開、dispatch.sh 可執行；(c) 在仍被
  遮蔽（舊 SKILL.md 勝出）時，確認 preflight 能在 skill 路徑之外擋下（§3.1）。

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
  大幅 diverge，本次延續既有手動解衝突成本。新增檔（dispatch.sh、`preflight-plugin-install.sh`、
  `*-focus.md`、manifest）永遠 merge-safe。
- **替換改為 data-safe 且可攜（vs `sed -i` + 慣例式假設）**：`sed -i "s#…#"` 在 BSD/macOS
  靜默失敗（review 第 1 輪實證）；且「值很安全」是慣例非強制（review 第 2 輪指出真實路徑/
  task title 可能含空格、`#`、`&`、`\`、`[]`）。改為把 `VALUE` 當字面字串的 data-safe 機制
  （如 bash 引號 pattern 參數展開），darwin 與 Linux 一致，且 metacharacter 安全。
- **路徑契約分三類（bundled 絕對 / repo input 相對 / report temp 絕對）**：解決 §4.1 與 §7
  以及 `REPORT_FILE_PATH` 分類矛盾；以 dispatch.sh 的存在性驗證強制執行，cwd 錯誤大聲失敗。
- **報告檔由 dispatch.sh 複製成私有副本、reviewer 正確性脫離 orchestrator 通知（演進到終局）**：
  第 2 輪否定「dispatch.sh 刪外部檔」（誤刪/早刪），第 4 輪再否定「orchestrator 依背景完成通知
  刪除」（prose 契約無法強制、漏通知洩漏、錯關聯早刪）。終局解：dispatch.sh 呼叫 codex 前先把
  `--report-file` 內容複製到自建 mktemp 私有副本、注入私有路徑、`trap … EXIT INT TERM` 只刪自建
  檔。reviewer 讀私有副本，正確性與 orchestrator 何時刪來源檔**完全無關**；dispatch.sh 絕不刪
  外部檔；並行天然唯一。
- **遷移防呆做成具體 artifact + 誠實限制（vs 只靠 plugin SKILL.md 內守衛 / 抽象「preflight」）**：
  第 4 輪指出舊副本遮蔽時新 SKILL.md 不載入、內建守衛跑不到；第 5 輪再指出「preflight」若不落到
  具體可執行點也無法強制。終局：`scripts/preflight-plugin-install.sh`（不 source SKILL.md、不受
  遮蔽）掃 legacy 路徑、遮蔽即非零退出；plan 須實測發現順序與「`/plugin install` 能否自動跑
  preflight」，能則宣告 hook、不能則**明確聲明限制**並以強制的事後驗證指令（含「證明載入的是
  plugin 版 SKILL.md」）把關。內建守衛保留為第二層。
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
