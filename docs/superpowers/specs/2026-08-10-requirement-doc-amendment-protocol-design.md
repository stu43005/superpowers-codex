# 需求檔修正協定：實作期間修改 spec/plan 的順序、權限與 reviewer carve-out

- **日期**：2026-08-10
- **狀態**：spec 雙審查迴圈已通過（structural `OKAY`；design-soundness 剩餘 findings 全屬已裁決的 accepted limitations），待使用者確認
- **影響檔案**：
  - `skills/subagent-driven-development/SKILL.md`（主改動）
  - `skills/subagent-driven-development/spec-reviewer-prompt.md`（carve-out）
  - `skills/subagent-driven-development/final-code-reviewer-focus.md`（carve-out）
  - `skills/subagent-driven-development/implementer-prompt.md`（權限限制）
- **提交類型**：`feat:`（新增行為契約：改變 agent 執行此 skill 時的流程與權限）

## 1. 問題

`subagent-driven-development` 執行 plan 時，reviewer 提出的 finding 有時揭露的是**需求檔（spec / plan）本身有缺陷**，而非實作寫錯。此時必須同時修改需求檔與 code。目前的 SKILL.md 對這個情境完全沒有規範，導致兩個具體病理：

**病理一：commit 順序錯誤。** 若先簽入修正 code、再簽入需求檔，git 歷史讀起來是「先違反需求、再改需求來事後追認」，也讓 reviewer 在下一輪看到的 plan 與 code 的因果關係顛倒。

**病理二：需求檔變更落在 task diff 內被判為超出範圍。** `spec-compliance` reviewer 的唯一真相是 `git diff <TASK_BASE>..HEAD`（見 `spec-reviewer-prompt.md`），其職責包含抓出「Extra/unneeded work — 做了 Task 沒要求的事」。需求檔的修正 commit 必然落在這個 diff 區間內，於是被判為超出範圍的變更。本 repo 的 git 歷史留有此病理的實例：`81a3e3b docs(plan): revert out-of-scope grep-count edit to keep Task 3 diff to SKILL.md only`（為了讓 task diff 乾淨而把正確的 plan 修正 revert 掉），隨後 `71e58cf docs(plan): correct Task 3 verify-grep expected count to 3` 又補回來。

關鍵推導：**單靠規範 commit 順序無法消除病理二**。需求檔的修正 commit 無論排在 code 之前或之後，都仍落在 `<TASK_BASE>..HEAD` 之內，reviewer 照樣看得到、照樣可能判為超出範圍。因此順序規範**必須**搭配 reviewer 端的 carve-out 才構成完整解法。

而 carve-out 一旦開啟，reviewer 原本「抓出實作者偷改需求檔來遷就爛 code」的守門功能即失效。此守門功能必須由**權限限制 + 完整性檢查**補回，否則 carve-out 會成為「改需求遷就實作」的後門。

## 2. 目標與非目標

### 目標

- 為「reviewer finding 需要回頭修改需求檔」定義一套明確、可機械依循的協定：何時可改、誰能改、以什麼順序 commit、base 如何處理。
- 消除病理二：讓需求檔的合法修正不再被 reviewer 判為超出範圍的變更。
- 在開啟 carve-out 的同時，用權限限制與完整性檢查守住「不得改需求遷就實作」的邊界。

### 非目標

- **不改 `writing-plans`。** 該 skill 的審查迴圈發生在 code 存在之前，不受此問題影響。
- **不改 `brainstorming`。** 同上；且 spec 的原始審查迴圈已有自己的機制。
- **不改任何 wrapper 腳本**（`review-impl.sh`、`review-final.sh`、`dispatch.sh`、`review-batch-lib.sh`）。本設計只改 SKILL.md 的流程契約、兩份 reviewer prompt / focus（`spec-reviewer-prompt.md`、`final-code-reviewer-focus.md`），以及 implementer prompt（`implementer-prompt.md`）的內容。
- **不引入新的 CLI 旗標、新的 base 參數、或需求檔的機器可讀 metadata 欄位。**
- 不試圖讓 `code-quality` reviewer 也接受 prompt 注入——見 §8.3，該 reviewer 是 codex 原生 review，機制上不支援。

## Non-goals / Accepted limitations

（本節記錄審查過程中，使用者裁決「不實作」的顧慮，格式為 Concern / Decision / Rationale。供本設計自身的下游對抗式驗收依 `subagent-driven-development` 的 carve-out 依此 canonical 標題定位並尊重。）

### 下游已完成 Task 的「明列 + 排除」重驗契約

- **Concern**：§9 的修正 Task 機制要求 controller 辨識哪些已完成的後續 Task 依賴被修改的需求，其 fail-closed 退路卻是「涵蓋受該需求影響的部分」——reviewer 指出這是循環論證：若 controller 判不出依賴，也就判不出哪些部分受影響。由於本設計刻意不做 end-SHA 追蹤、不改 wrapper、不做 replay，沒有任何機械化證據能證明所有陳舊實作都被回頭處理過；漏判的依賴會帶著依舊需求建構的實作一路到 merge。reviewer 建議改為機械化的保守契約：修正 Task 必須逐一列舉「被改到的 Task 之後所有已完成 Task」，每一個要嘛附上驗收/修正標準納入範圍，要嘛記錄一筆使用者核准的排除與理由。
- **Decision**：不實作。不要求修正 Task 逐一列舉後續已完成 Task，也不引入排除清單與其核准流程。維持由 controller 當場依 plan 內容判定依賴。
- **Rationale**：(1) **與 skill 的適用前提相符**——`subagent-driven-development` 的 When to Use gate 明定只在「Tasks mostly independent」時使用本 skill，緊密耦合的計畫本就該走人工執行；在此前提下，逐一列舉全部後續 Task 的成本大多落在明顯無關的項目上。(2) **仍有最後一道網**——`review-final.sh` 的 final adversarial gate 專責跨 task 整合縫隙（見 `final-code-reviewer-focus.md`），漏判的依賴仍有被攔下的機會。(3) **不成比例**——此情境（amendment 改到**已完成** Task 的需求）本身罕見，常見情況是修改**進行中** Task 的需求、完全不觸發下游重驗；為罕見情境要求每次都逐 task 走查並寫入 plan，成本高於其防護價值。**前提**：以「本 skill 僅用於 mostly-independent 的 plan，且 final adversarial gate 維持有效」為裁決前提；若日後放寬 When to Use 的獨立性要求、或 final gate 被移除弱化，此前提即改變，須依 stale-waiver 規則重新評估。

### amendment 已 commit、實作未完成的部分失敗回復機制

- **Concern**：§6.1 要求需求檔的 amendment 先於 code 修正 commit，因此 amendment 會在「對應實作是否做得出來」尚未確定前就成為 HEAD 上的持久狀態。若隨後 implementer 回報 `BLOCKED`、未能 commit、產出無法通過 review 的 code，或 session 中斷，repo 會停留在「需求已更新但實作未跟上」的不一致中間態；而本協定又禁止自動 revert / reset，且 amendment SHA 記錄不持久化。reviewer 建議引入回復契約：把 amendment 先留在私有分支直到 code 通過 review、維護 pending-amendment 狀態標記阻擋收尾、並明定使用者核准的 rollback 或後續任務建立流程。
- **Decision**：不實作。不引入私有分支、不引入 pending-amendment 狀態標記、不引入 finalization blocker，也不定義 rollback 演算法。
- **Rationale**：(1) **已由現有機制覆蓋**——未被實作的 amendment 會被 `spec-compliance` 依 HEAD 上的需求判為 missing requirement，並在 `review-final.sh` 的 merge gate 被擋下，不可能靜默通過收尾；implementer 回報 `BLOCKED` 時，SKILL.md 既有的「Handling Implementer Status」已規定 controller 必須評估並在必要時升級給人類。(2) **不是新風險**——「plan 已寫、對應 code 尚未實作」本來就是本 skill 在每兩個 task 之間的正常中間態，也是任何被中斷的 plan 執行必然停留的狀態；amendment 只是讓這個既有狀態多一個來源，並未創造新的失敗模式。(3) **不成比例**——reviewer 建議的機制會把分支切換與持久化狀態引入一個刻意不持久化狀態的協定，並與現有 `TASK_BASE` / `IMPL_BASE` base 契約產生新的交互複雜度，成本高於它防的情境。**前提**：以「per-task 與 final 兩道 review gate 皆維持有效、且 `Handling Implementer Status` 的 escalation 路徑仍在」為裁決前提；若日後任一 gate 被移除或弱化，此前提即改變，須依 stale-waiver 規則重新評估。

## 3. 核心原則

**需求檔是使用者意圖的載體，不是實作的附屬品。** 預設一律修改 code 以符合需求；只有在需求檔本身有**客觀缺陷**時才修改需求檔。判不出是否為客觀缺陷 → fail closed，當一般 code finding 處理。

**修改需求檔是 controller 的職權，不是 implementer 的。** implementer 的視野僅限單一 task 與 controller 餵給它的 context，缺乏判斷「這是需求缺陷還是我理解錯了」所需的全局資訊。

## 4. Amendment 觸發判定

controller 解析 reviewer findings 時，**逐條**分類。預設所有 finding 都是 code finding（由 implementer 修 code）。只有當 finding 揭露需求檔本身有下列**客觀缺陷**之一，才升級為 amendment：

1. **自相矛盾** —— 需求檔內部、或不同 Task 之間，存在互相衝突的指示。
2. **事實性錯誤** —— 需求檔陳述了可被客觀否證的事實，例如 verify 步驟寫的預期值算錯、引用不存在的檔案路徑、引用不存在的函式或符號。
3. **與既成事實衝突** —— 與已通過 review 的先前 Task 的產出牴觸。
4. **依據的外部事實已變** —— 需求檔所依據的第三方 API 簽名、套件版本、檔案結構等已改變。

**Fail closed**：若 controller 無法確信該 finding 屬於上述四類之一，一律**不**升級為 amendment，當一般 code finding 處理。「reviewer 說需求有問題」本身**不是**充分理由——reviewer 對實作只有局部視野，容易把「實作偏離」描述成「需求錯了」。

## 5. 權限與核准層級

### 5.1 權限

- **只有 controller 能修改 `docs/superpowers/**`。**
- **implementer subagent 一律禁止**建立或修改 `docs/superpowers/**` 之下的任何檔案。

### 5.2 核准層級

- **plan（`docs/superpowers/plans/**`）** → controller 直接修改並 commit，不打斷執行。這與本 skill 既有的 continuous-execution 原則一致：plan 是實作分解，其客觀缺陷屬執行細節。
- **spec（`docs/superpowers/specs/**`）** → controller **必須先以 `AskUserQuestion` 徵詢使用者**。spec 是使用者在 brainstorming 階段核准過的需求，實作期間逕自修改等同繞過該核准 gate。
  - 使用者同意 → 依 §6 程序修改。
  - 使用者否決 → 該 finding **退回當一般 code finding** 處理（fail closed），由 implementer 改 code。

## 6. 修正程序與 base 契約

### 6.1 嚴格順序

一旦 controller 判定某 finding 為 amendment，必須依下列順序執行。任一步驟顛倒即為流程違規：

1. controller 判定為 amendment（若涉及 spec，先依 §5.2 徵詢使用者並取得同意）。
2. controller 修改需求檔。
3. **單獨 commit 需求檔變更** —— 該 commit 的 diff **只**含 `docs/superpowers/**`，不得夾帶任何實作檔。commit message 依專案慣例用 `docs(plan):` / `docs(spec):`。
4. **才** dispatch implementer 修改 code。
5. implementer commit code —— 該 commit 的 diff **不**含 `docs/superpowers/**`。
6. 重跑 `review-impl.sh`，`--task-base` 沿用**原本的** `TASK_BASE`。

若 spec 與 plan 同時需要修正，兩者可在同一個 commit，或連續兩個 commit；唯一硬性要求是**全部需求檔變更都必須在任何相關 code 變更之前完成並 commit**。

**順序的適用範圍（重要）**：amendment 的觸發點是 reviewer finding，而 finding 出現時該 Task 的初始實作 commit **必然已經存在**。因此上述順序約束的是「amendment 被判定**之後**」的 commit 序列：

- 約束對象是**後續的修正 commit** —— 需求檔的 amendment commit 必須早於任何**因該 amendment 而產生的 code 修正 commit**。
- **不回溯約束已建立的 commit**。已存在的初始實作 commit 保持原樣。
- **絕不改寫歷史**：不得為了讓需求檔 commit 排到實作 commit 之前而 `rebase`、`reset`、`commit --amend` 或重排既有 commit。本協定完全不涉及歷史改寫。

### 6.2 Base 契約

- **amendment 之後不得重新捕捉 `TASK_BASE`。** 若把 `TASK_BASE` 重設到需求檔 commit 之上，該 Task 的 diff 就只剩修正 code，原始實作落在 base 之下不可見，reviewer 會誤判「需求未實作」而報出大量假的 missing-requirement findings。
- **`IMPL_BASE` 一如既往不重新捕捉。** amendment commit 落在 `<IMPL_BASE>..HEAD` 之內是預期行為，由 §8.2 的 final-gate carve-out 處理。
- **amendment commit 受既有 HEAD 契約約束**：不得在任何 `review-*.sh` 執行期間 commit。需求檔的修正必須在下一次 wrapper 呼叫**之前**完成提交。

### 6.3 carve-out 的完整性檢查

carve-out 的安全性完全建立在「只有 controller 改需求檔」之上，因此該前提需要可執行的驗證，否則 carve-out 會靜默掩蓋 implementer 的違規修改。

**適用時機（每個 gate 都要，各用自己的 base）**：

- 重跑 `review-impl.sh` 之前 → 檢查範圍 `<TASK_BASE>..HEAD`。
- 重跑 `review-final.sh` 之前 → 檢查範圍 `<IMPL_BASE>..HEAD`。final gate 階段同樣可能發生 amendment（§9），且 final-adversarial 的 carve-out（§8.2）同樣會排除需求檔，因此**必須**有對應的檢查，否則未授權的需求檔變更會在最終 merge gate 被靜默放行。final-gate 期間建立的 amendment commit 與 per-task 階段一樣記錄其 SHA，且因 `IMPL_BASE` 涵蓋整個實作區間，`<IMPL_BASE>..HEAD` 的檢查會同時涵蓋所有 per-task 階段的 amendment。

**檢查的三個部分**（三者都必須通過）：

0. **需求檔無未提交狀態** —— `spec-compliance` reviewer 讀的是**工作區**的 plan 檔（`review-impl.sh` 以 `--set PLAN_FILE_PATH=...` 傳入路徑，reviewer 自行開檔），但實作證據是 `git diff <BASE>..HEAD`。若需求檔有未 commit 的修改（未暫存或已暫存皆然），reviewer 會拿「不在 HEAD 上、也不在 amendment SHA 稽核範圍內」的需求文字去驗證 code，讓 gate 通過在隨時可能消失、或稍後才亂序 commit 的需求上，等於整個繞過本節的來源檢查。因此在**每一次** review 重跑之前：

   ```bash
   git status --porcelain -- docs/superpowers/
   ```

   輸出必須為**空**。只要有任何輸出（未暫存、已暫存、或未追蹤的需求檔）→ 依下方 fail-closed 規則停止：屬於合法 amendment 的變更先依 §6.1 步驟 3 完成 commit，其餘則回報使用者。

1. **無不明來源** —— 範圍內所有觸及需求檔的 commit 都必須是已記錄的 amendment：

   ```bash
   git log --format='%H' <BASE>..HEAD -- docs/superpowers/
   ```

   輸出的每個 commit SHA 都必須是 controller 自己在 §6.1 步驟 3 建立的 amendment commit（controller 在其任務狀態中記錄這些 SHA）。

2. **每個 amendment 都是 docs-only** —— 僅檢查「有沒有碰到需求檔」不足以保證 §6.1 步驟 3 的「單獨 commit」不變式：一個同時改了需求檔與實作檔的混合 commit，在第 1 部分會以已記錄 SHA 的身分通過。因此對**每一個**已記錄的 amendment SHA，還要驗證其完整檔案清單：

   ```bash
   git diff-tree --no-commit-id --name-only -r <AMENDMENT_SHA>
   ```

   輸出的**每一條**路徑都必須位於 `docs/superpowers/` 之下。只要有任何一條不是，該 amendment 違反單獨 commit 規則 → 依下方 fail-closed 規則停止。

**威脅模型（界定此檢查要擋什麼）**：implementer 是受 prompt 約束的合作型 subagent，此檢查的目的是攔截**意外違規**（subagent 順手改了需求檔、或人為手動編輯混入），**不是**防禦刻意規避的對手。因此不需要密碼學等級的來源證明，但必須保證「無法確認時不放行」。

**Fail-closed 降級（記錄不可得時的行為）**：amendment SHA 記錄與既有 escape-valve ledger 同屬 **in-session 啟發式狀態**，不持久化。若上下文被壓縮、迴圈由另一個 agent 接手、或任務從既有 commit 重新進入，導致該記錄遺失或不完整：

- **不得**用敘事重建信任（例如「這個 commit message 長得像我寫的」）而放行。
- 只要檢查範圍（`<TASK_BASE>..HEAD` 或 `<IMPL_BASE>..HEAD`）內存在**任何**無法明確歸屬到記錄中 amendment 的 `docs/superpowers/**` commit → **停下來回報使用者**，說明哪些 commit 無法歸屬、以及記錄為何遺失，由使用者判定該 commit 是否為合法 amendment 後再繼續。
- 此偏誤方向刻意如此：低估違規等於讓 carve-out 靜默掩蓋未授權的需求變更，恰好架空本檢查；故寧可誤停、也不放行。

**回復程序（任一部分檢查未通過時）**：**硬性停止，不自動回復**。無論是第 0 部分發現未提交的需求檔變更（且不屬於待 commit 的合法 amendment）、第 1 部分發現不可歸屬的 commit、或第 2 部分發現某 amendment 混入了實作檔，controller 都**不得**自行 `revert`、`reset`、`checkout --` 丟棄工作區變更或改寫歷史，理由是：問題 commit 可能位於歷史中段、其後已疊上合法 amendment 與 code commit，自動回復會產生順序敏感的衝突，且可能抹掉使用者核准過的 spec 變更。controller 的職責到「偵測 + 停下來回報」為止，如何處置由使用者決定。這也讓本協定不需要定義任何 revert / 重驗演算法。

此檢查刻意維持為三道 git 指令 + 路徑比對 + fail-closed 停止，不引入 hook、不引入 commit trailer、不引入 sidecar 記錄檔、不引入任何持久化狀態。

### 6.4 findings 的新鮮度檢查

controller 端的既有紀律已排除**自己**造成的不一致：`review-*.sh` 是單一前景阻塞呼叫（SKILL.md 的 invocation discipline 明令不得 `run_in_background`），controller 在其回傳前不做任何事，且既有 HEAD 契約禁止在 wrapper 執行期間推進 HEAD。

但這些只約束 controller 自己。SKILL.md 自承 **「the engine does not detect HEAD movement; this is a documented caller contract」**——契約沒有任何機械化驗證。若使用者、另一個 agent、hook，或一個逾時轉背景後才回傳的 wrapper 呼叫，在 review 執行期間動到 HEAD 或需求檔工作區，controller 會把 findings 套用到一棵 reviewer 從未檢視過的樹上，或把「通過」記在錯誤的 diff 上。§6.3 第 0 部分只在 review **之前**檢查，攔不到執行期間的變動。

因此本協定為每一次 `review-*.sh` 呼叫加一道**前後對照**（適用本 skill 的所有 review wrapper 呼叫，不限 amendment 情境）：

```bash
# wrapper 呼叫之前
git rev-parse HEAD
git status --porcelain -- docs/superpowers/
```

wrapper 回傳後，重跑同樣兩道指令並比對。**兩者都必須與呼叫前完全一致**：

- `HEAD` 有移動、或需求檔工作區狀態有變 → **fail closed**：本次 review 結果作廢，**不得**依其 findings 做任何修復或判定 amendment；先釐清變動來源（若是不明來源，依 §6.3 的硬性停止規則回報使用者），確認狀態穩定後**重跑整個 wrapper 呼叫**。
- 完全一致 → findings 確定對應到產生它們的那個 HEAD 與那份需求檔內容，照常處理。

此檢查是兩道唯讀 git 指令的前後比對，不引入鎖、不引入持久化狀態，也不改動任何 wrapper；它把 SKILL.md 既有但無人驗證的 caller HEAD 契約變成可執行的檢查。

## 7. implementer 端限制

`implementer-prompt.md` 新增一段，明確告知 subagent：

- 禁止建立或修改 `docs/superpowers/**` 之下的任何檔案（spec 與 plan 皆然）。
- 若在實作過程中認為需求本身有缺陷：
  - 仍能產出可行實作 → 回報 `DONE_WITH_CONCERNS`，並在 concerns 中具體說明疑似缺陷所在。
  - 缺陷導致無法實作 → 回報 `BLOCKED`，說明卡在哪裡。
- 由 controller 依 §4 判定是否升級為 amendment。

這與既有的 `BLOCKED` / `DONE_WITH_CONCERNS` 處理流程銜接：SKILL.md 的「Handling Implementer Status」一節已規定 controller 收到這兩種狀態時要評估並決定後續，amendment 成為該評估的其中一條出路。

## 8. reviewer carve-out 的三個落點

三個 reviewer 的注入能力不同，carve-out 因此落在不同層級。

### 8.1 `spec-compliance` → `spec-reviewer-prompt.md`

該 reviewer 由 `dispatch.sh task --prompt` 啟動，prompt 檔完全受控。加入 carve-out：

- 在「Extra/unneeded work」的檢查中，**排除** `docs/superpowers/specs/**` 與 `docs/superpowers/plans/**` 的變更。這些檔案的變更由 controller 負責，不屬於實作範圍問題，不得因此回報 `Status: Issues Found`。
- 其餘行為完全不變：reviewer 仍以 **HEAD 上的 plan 檔內容**作為需求真相（既有行為），仍以 `git diff <TASK_BASE>..HEAD` 驗證實作。

### 8.2 `final-adversarial` → `final-code-reviewer-focus.md`

該 reviewer 由 `dispatch.sh adversarial --focus` 啟動，focus 檔完全受控。在 focus 內容末尾加入同一條 carve-out：`docs/superpowers/specs/**` 與 `docs/superpowers/plans/**` 的變更不列入實作範圍或 scope-drift 的評估。

**與既有 spec-adjudicated rejection carve-out 的關係**：兩者**正交、互不覆蓋**，各自獨立判定。

- 既有的處理「finding 的**內容**對應到使用者已接受的限制」。
- 本設計新增的處理「finding 針對的**檔案**是需求檔本身的變更」。

一條 finding 可能兩者皆不適用、適用其一、或兩者皆適用；controller 分別套用，不需要合併判定邏輯。

### 8.3 `code-quality` → `SKILL.md` 的 caller control-flow

該 reviewer 由 `dispatch.sh review --base` 啟動，是 codex 的原生 review，**機制上不接受 prompt 或 focus 注入**（`cmd_review` 只解析 `--base`）。carve-out 因此只能落在 caller 端：

- SKILL.md 的「Caller control-flow」第 5 點補述：若 code-quality 的某個 finding **僅**針對需求檔變更本身（例如評論 plan 的措辭、格式、或該不該改），controller 判定為**非阻斷**，不觸發 re-review 迴圈。
- 針對實作檔的 finding 一律照舊處理。

## 9. 邊界與交互情況

- **amendment 改到已通過 review 的先前 Task 的需求** → **不得**用該 Task 原本的 `TASK_BASE` 重跑 `review-impl.sh`。`review-impl.sh` 只接受 `--task-base`，其 spec-compliance reviewer 固定 diff 到 `HEAD`；一旦後續 Task 已經 commit，`git diff <原TASK_BASE>..HEAD` 就同時涵蓋所有後續 Task 的變更，reviewer 會把後續 Task 的產出當成該 Task 的超出範圍變更，也會讓真正的回歸埋沒在無關的 diff 雜訊裡。改用下述「修正 Task」機制。
- **修正 Task（已完成 Task 需要因 amendment 而回頭改動時的唯一機制）**：
  - controller 在同一次 amendment 中，於 plan **末端新增一個 Task**，其內容完整描述這次修正要達成的目標狀態（依 `writing-plans` 的 Task 結構撰寫，不使用「參照 Task N」這類佔位敘述）。此新增 Task 與需求檔的其他修改一同進入 §6.1 步驟 3 的同一個 docs-only commit。
  - 該修正 Task 之後**照一般 Task 流程執行**：捕捉一個**全新的 `TASK_BASE`**（`git rev-parse HEAD`）→ dispatch implementer → commit → 以該新 base 跑 `review-impl.sh`。此時 diff 恰好只含修正工作，而修正 Task 的需求也恰好描述這些工作，base 契約成立。
  - 與 §6.2 不衝突：§6.2 禁止的是「為**進行中**的 Task 重新捕捉 `TASK_BASE`」；修正 Task 是 plan 上一個**新的** Task，依既有規則本來就該捕捉屬於自己的 base。
- **下游重驗（amendment 使已完成 Task 的需求改變時）** → 只處理被直接改到的那個 Task **不夠**：排在它之後、已通過 review 的 Task 可能是依著舊需求建構的。因此：
  - controller 必須辨識出哪些**已完成**的後續 Task 的實作依賴被修改的那條需求（例如沿用了被改掉的介面、常數、檔案結構或行為約定）。
  - 被直接改到的 Task **與**每一個有依賴關係的後續已完成 Task，其修正工作全部納入修正 Task 的範圍（可合併為一個修正 Task，或依關注點拆成數個連續的修正 Task，各自捕捉自己的 base）。
  - **Fail closed**：若 controller 無法確信哪些後續 Task 有依賴，修正 Task 的範圍必須涵蓋「被改到的 Task 之後、所有已完成 Task」中受該需求影響的部分，不得以「大概沒影響」略過。理由與 §6.3 同向：漏驗會讓不一致的實作一路帶到 final gate，而 final gate 是跨 task 整合視角、不保證覆蓋 task 本地的需求回歸。
  - 這條規則完全複用既有的 per-task review 機制與 base 契約，不引入 end SHA 記錄、不改 wrapper、不新增 CLI 旗標、不使用隔離分支或 worktree replay；依賴判定由 controller 依 plan 內容當場為之。
- **amendment 發生在 final gate 階段**（所有 Task 已通過、`review-final.sh` 回報 finding）→ 一樣依 §6.1 順序：先 commit 需求檔、再修 code，然後以同一個 `IMPL_BASE` 重跑 `review-final.sh`；重跑之前必須先跑 §6.3 的完整性檢查，範圍用 `<IMPL_BASE>..HEAD`。
- **spec amendment 被使用者否決** → 退回一般 code finding（§5.2），不留任何需求檔變更。
- **同一輪同時有 amendment finding 與一般 code finding** → 先完成需求檔的修改與 commit（§6.1 步驟 2–3），再讓 implementer 在同一次 dispatch 中一併修完所有 code findings，維持既有的「一次修完所有 findings 再 re-review」節奏。
- **amendment 之後 reviewer 仍報同一問題** → 依 §4 重新判定；若已不屬客觀缺陷四類，則當一般 code finding 處理，不得反覆修改需求檔追著 reviewer 跑。
- **需求檔被 gitignore** → 本協定要求需求檔可被 commit。若需求檔在 .gitignore 中，此協定無法執行，controller 應停下來要求使用者解除忽略；**絕不使用 `git add -f`**。
- **完整性檢查發現不可歸屬的 `docs/superpowers/**` commit** → 依 §6.3 硬性停止並回報使用者，不自動回復、不改寫歷史、不繼續 review 迴圈。
- **從既有 commit 重新進入既有任務**（例如新 session 接手一個做到一半的 plan）→ amendment SHA 記錄必然為空，若 `<TASK_BASE>..HEAD` 內已有 `docs/superpowers/**` commit，依 §6.3 fail-closed 停下來請使用者確認其合法性後再繼續。

## 10. 對 SKILL.md 的具體改動範圍

- 新增一節「Requirement-Document Amendment」，涵蓋 §4–§6 的內容（觸發判定、權限、核准層級、嚴格順序、base 契約、完整性檢查與其 fail-closed 降級／硬性停止規則）。
- 「Base SHA Tracking」一節補上 §6.2 的兩條硬規則（進行中 Task 的 `TASK_BASE` 不得重捕捉、amendment commit 落在 `IMPL_BASE..HEAD` 內屬預期），以及 §9 的修正 Task 例外（新增的修正 Task 依一般規則捕捉自己的全新 `TASK_BASE`）。
- 「Caller control-flow」第 5 點補上 §8.3 的 code-quality 判定。
- 「Reviewer Dispatch」的 invocation discipline 補上 §6.4 的前後對照新鮮度檢查（適用每一次 `review-*.sh` 呼叫）。
- 「Final adversarial reviewer」一節補上 §8.2 的正交性說明，以及重跑 `review-final.sh` 前須執行 §6.3 完整性檢查（範圍 `<IMPL_BASE>..HEAD`）的要求。
- 「Handling Implementer Status」一節補上 §7 的銜接說明。
- 「Red Flags」的 **Never** 清單補上四條：
  - 在 amendment 之後重新捕捉 `TASK_BASE`
  - 把需求檔變更與實作變更放進同一個 commit
  - 讓 implementer subagent 修改 `docs/superpowers/**`
  - 在 amendment SHA 記錄遺失時，靠推測歸屬放行 `docs/superpowers/**` 的 commit

## 11. 測試 / 驗收

本設計改動的是 SKILL.md 與 reviewer prompt / focus（Markdown 指令，即插件的執行行為），非可由單元測試覆蓋的程式邏輯。本設計不改動任何 shell 腳本。驗收方式：

- 執行 `bash scripts/review-batch-lib.test.sh`、`bash scripts/dispatch.test.sh`、`bash scripts/preflight.test.sh`，確認全數通過（作為未回歸的佐證）。
- 以 grep 驗證四個目標檔案確實各自含有新增段落的關鍵標記。
- 人工審閱四份改動，確認觸發判定、權限、順序、base 契約、三處 carve-out 之間無自相矛盾，且與既有的 spec-adjudicated rejection carve-out 正交無衝突。
