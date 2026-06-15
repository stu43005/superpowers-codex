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
- `.claude-plugin/marketplace.json`：列出本 plugin，`source` 指向 plugin 根（單一 plugin
  repo，`source` 為 `"./"` 或 plugin 子目錄相對路徑，最終值於 plan 階段依實測決定）。
- README 改寫「散布形式」與「安裝方式」段落：由「丟進 `~/.claude/skills/`」改為
  `/plugin marketplace add <owner/repo>` + `/plugin install`。

**vendor 維護模型不受影響**：`plugin.json`、`marketplace.json`、`scripts/` 皆為 top-level
維護檔，依現行原則只存在於 main 分支；vendor 分支僅持有 skill 子集，三方合併不會拖動這些檔。

## 4. 共用 `scripts/dispatch.sh`（plugin root 一份）

唯一一份 dispatch script，置於 plugin root 的 `scripts/dispatch.sh`，三個 skill 共用。

### 4.1 三個子命令

```bash
dispatch.sh task        --prompt <ABS_PATH> [--set KEY=VALUE]... [--dry-run]
dispatch.sh review      --base <SHA>                          [--dry-run]
dispatch.sh adversarial --base <SHA> --focus <ABS_PATH>       [--dry-run]
```

- `task`：對應 Type A（有 prompt body）。讀 `--prompt` 指向的 sidecar，套用所有
  `--set` 注入，寫入 temp 檔，呼叫 `node <companion> task --prompt-file <temp>`。
- `review`：對應 `sdd/code-quality`。呼叫 `node <companion> review --base <SHA> --wait`。
- `adversarial`：對應 `adversarial-spec-review`、`sdd/final-code`。呼叫
  `node <companion> adversarial-review --base <SHA> --wait "$(cat <focus>)"`。

所有路徑參數（`--prompt`、`--focus`、以及 `--set` 的檔案路徑值）均為**絕對路徑**，由
SKILL.md 的 `${CLAUDE_PLUGIN_ROOT}` inline 展開提供；script 本身不需自我定位 sidecar。

### 4.2 共通內含

- **codex companion 路徑解析**：沿用現行片段
  `ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | sort -V | tail -1`，
  fallback 至 `~/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs`；
  找不到則 stderr 輸出「codex plugin not found; run /codex:setup. Do NOT fall back to
  inline self-review.」並以非零退出。
- `mktemp` 建 temp prompt 檔，`trap '… rm -f' EXIT` 確保清理。
- `--set KEY=VALUE`：對 temp prompt 執行 `sed -i "s#\[KEY\]#VALUE#g"`。值均為路徑／task
  識別子／SHA，短、無換行、無 `#`，對 sed 安全。

### 4.3 安全機制

- **殘留 placeholder 偵測**：所有 `--set` 注入完成後，grep temp prompt 是否仍含
  `\[[A-Z_][A-Z0-9_]*\]`；若有，視為漏給 `--set`，stderr 報出殘留 token 並非零退出
  （絕不送出帶有未替換 placeholder 的 prompt 給 codex）。
- **`--dry-run`**：印出注入後的 temp prompt 內容與「將要執行的 codex 指令」，但**不**呼叫
  codex。供 `bash -n` / `shellcheck` 之外的逐 reviewer 行為驗證。
- 參數驗證：未知子命令、缺 `--prompt`/`--base`/`--focus`、檔案不存在 → 報錯非零退出。

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
  `[PLAN_FILE_PATH]`、`[TASK_ID]`、`[TASK_BASE]`、`[REPORT_FILE_PATH]`。指示 reviewer 讀
  plan 中標題 `[TASK_ID]` 的 Task、讀 `[REPORT_FILE_PATH]`（implementer report，見 §6）、
  並執行 `git diff [TASK_BASE]..HEAD` 比對宣稱與實作。
- **`writing-plans/coverage-verifier-prompt.md`**：本即只注入路徑。placeholder
  `[PLAN_FILE_PATH]`、`[SPEC_FILE_PATH]`，改由 `--set` 提供。
- **`brainstorming/spec-document-reviewer-prompt.md`**：本即只注入路徑。placeholder
  `[SPEC_FILE_PATH]`，改由 `--set` 提供。

### 5.2 Type B

- **`subagent-driven-development/code-quality-reviewer-prompt.md`**：無 focus 字串。
  改由 `dispatch.sh review --base <SHA>` 呼叫；本檔的 dispatch 段刪除，僅保留說明性內容
  （何時跑、回傳格式），無 sidecar prompt body。
- **`brainstorming/adversarial-spec-review-prompt.md`**、
  **`subagent-driven-development/final-code-reviewer-prompt.md`**：將既有的長 focus 字串
  抽成同目錄 sidecar `<x>-focus.md`（純 focus 文字）；改由
  `dispatch.sh adversarial --base <SHA> --focus ${CLAUDE_PLUGIN_ROOT}/skills/<name>/<x>-focus.md`
  呼叫。

## 6. implementer report 改以路徑傳遞

`sdd/spec-reviewer` 原本貼入 implementer 的回報文字。改為：orchestrator（sdd SKILL 流程）
將 implementer 回報寫入一個 temp 檔，透過 `--set REPORT_FILE_PATH=<temp 檔絕對路徑>` 傳入，
reviewer prompt 指示其讀取該路徑。如此**沒有任何大段文字進入 prompt**，貫徹「傳路徑、
自己讀檔」原則。temp 檔由 orchestrator 於該次 dispatch 後自行清理。

## 7. 三個 SKILL.md 更新

對 `brainstorming`、`writing-plans`、`subagent-driven-development` 三個 SKILL.md：

- 將原本「以此 bash 區塊 dispatch」的引用，改為呼叫共用 script 的用法，例如：
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" task \
    --prompt "${CLAUDE_PLUGIN_ROOT}/skills/writing-plans/plan-document-reviewer-prompt.md" \
    --set PLAN_FILE_PATH=docs/superpowers/plans/<…>-plan.md \
    --set SPEC_FILE_PATH=docs/superpowers/specs/<…>-design.md \
    --set TASK_ID="Task 3"
  ```
- 原本散落在各 prompt 檔的 Purpose／dispatch context 說明，移入對應 SKILL.md。
- sdd SKILL.md 增加一步：spec compliance review 前，把 implementer 回報寫入 temp 檔並以
  `REPORT_FILE_PATH` 傳入（§6）。
- base SHA（`SPEC_BASE`/`TASK_BASE`/`IMPL_BASE`）的擷取時機與既有規定不變，僅改為以
  `--base` 傳給 dispatch.sh。
- 並行 dispatch（per-Task reviewer、雙 spec reviewer 等）的 `run_in_background` 行為不變，
  僅替換為呼叫 dispatch.sh。

## 8. 驗證策略

- `bash -n scripts/dispatch.sh` 與 `shellcheck scripts/dispatch.sh`。
- 對每個 reviewer 以 `--dry-run` 驗證：注入後的 prompt 無殘留 placeholder、codex 指令正確。
- 殘留 placeholder 偵測之正向／負向案例（故意漏 `--set` 應非零退出）。
- plugin 安裝 smoke test：安裝成 plugin、實際呼叫一個 skill、確認 `${CLAUDE_PLUGIN_ROOT}`
  inline 展開生效且 dispatch.sh 可定位並執行。

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

## 10. 非目標

- 不改 `sdd/implementer-prompt.md`。
- 不變更 reviewer 的審查準則內容（僅搬移注入機制與輸入方式）。
- 不變更 base SHA 的擷取時機與 round-loop 重跑策略。
- 不處理與既有 CLAUDE.md 規則的潛在衝突（若有，留待 user 後續處理）。
