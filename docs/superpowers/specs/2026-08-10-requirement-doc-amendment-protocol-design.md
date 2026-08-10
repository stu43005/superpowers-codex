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

### 把 §6.3 / §6.4 的檢查移入 wrapper 作為機械強制點

- **Concern**：本設計的安全性質依賴 controller 在每一次 `review-impl.sh` / `review-final.sh` 呼叫前後執行 §6.3 的三部分完整性檢查與 §6.4 的前後對照，但非目標明列不改 wrapper 腳本，因此沒有任何強制點：若 caller 忘記或只做了一半，carve-out 仍然生效，未授權的需求檔變更會被藏起來，而下游 review 輸出「照設計看起來就是乾淨的」，失敗難以察覺。reviewer 建議把 HEAD 前後比對、需求檔 cleanliness、需求檔 commit 歸屬三項移入 review wrapper 或共用的強制函式；若堅持不改 wrapper，則不應預設啟用 reviewer carve-out。
- **Decision**：不實作。不把任何檢查移入 `review-impl.sh` / `review-final.sh` / `review-batch-lib.sh`，也不為此新增 wrapper 參數；維持三道檢查為 SKILL.md 層級的 caller 紀律。
- **Rationale**：(1) **與整個 plugin 的強制模型一致**——這個 plugin 的產品就是給 agent 的指令，每一條規則（包含既有的 base 捕捉紀律、invocation discipline、以及 SKILL.md 自承「the engine does not detect HEAD movement; this is a documented caller contract」的 HEAD 契約）都靠 agent 遵守；單獨為本協定引入機械強制點並不會改變其餘規則的強制模型，卻會製造兩套標準。(2) **主要的檢查在機制上搬不進去**——來源歸屬檢查需要 controller 手上的 in-session amendment SHA 清單，wrapper 取不到；即使把最淺的 cleanliness 檢查搬進去，三道裡也只強制得了一道，其餘兩道照樣靠自律，安全性提升有限。(3) **成本明確**——搬移需推翻「不改 wrapper」非目標、新增 CLI 旗標與對應的 shell 測試，且 controller 仍須自律地把正確的清單傳進去（強制點只是往後挪一層）。**前提**：以「本 plugin 維持以 SKILL.md 指令為強制模型、且 §6.3／§6.4 的檢查在 SKILL.md 中被明列為每次呼叫的必要步驟並列入 Red Flags」為裁決前提；若日後 plugin 引入通用的機械強制層，此前提即改變，須依 stale-waiver 規則重新評估。

### amendment 來源記錄的持久化（commit trailer / sidecar / manifest）

- **Concern**：§6.3 的完整性檢查要求「範圍內每個觸及需求檔的 commit 都可歸屬到 controller 記錄的 amendment SHA」，但該記錄是 in-session 啟發式狀態、不持久化。上下文壓縮、換 agent 接手、或從既有 commit 重新進入任務時，記錄即失效，協定便無法機械化區分合法的 controller amendment 與 implementer／人為的需求檔變更；此時規定的行為是停下來詢問使用者，等於在最需要驗證的時刻把主要安全性質降級為人工證言。reviewer 建議改以持久且可稽核的形式保存來源，例如 commit trailer、plan 內的 ledger、或 wrapper 產生的 amendment manifest，並讓完整性檢查改讀該產物而非揮發性的 controller 記憶。
- **Decision**：不實作。不引入 commit trailer、不引入 sidecar 記錄檔或 manifest、不引入 plan 內的 amendment ledger；維持 §6.3 的 in-session 記錄 + fail-closed 詢問使用者。
- **Rationale**：(1) **失效模式是安全方向的**——記錄遺失時協定不是放行，而是停下來請使用者確認；最壞情況是多打斷使用者一次，不是靜默放過未授權的需求變更。(2) **人工確認是這個工作流本來就有的環節**——本 skill 全程有使用者在場（spec 的 amendment 本來就必須徵詢使用者，見 §5.2），在記錄遺失時多問一句與既有互動模式一致，不是新引入的負擔。(3) **持久化產物也擋不住它想擋的東西**——依 §6.3 的威脅模型，對手是「誤改需求檔的合作型 subagent」而非刻意規避者；trailer 之類的標記同樣可被誤加或漏加，換來的只是把「問使用者」變成「相信一行文字」，安全性提升有限而複雜度確定增加。**前提**：以「§6.3 的失效行為維持為 fail-closed 停止並詢問使用者、且 §5.2 的 spec amendment 使用者徵詢仍在」為裁決前提；若日後任一 fail-closed 行為被改成自動放行，此前提即改變，須依 stale-waiver 規則重新評估。

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

**絕對禁止：放寬型 amendment。** 上述四類都是「需求檔說錯了」，不含「需求檔要求太多」。因此**不得**以 amendment 之名移除或弱化驗收標準、縮小 Task 範圍、或降低預期行為，來讓既有 code 通過 gate——即使 controller 主觀認為原需求過當。這條與 §3 核心原則同義，但必須明文，因為 plan 的 amendment 不需使用者核准（§5.2）、reviewer 又以 HEAD 上的 plan 為需求真相，三者疊加會形成「悄悄砍需求讓 code 過關」的路徑。判定準則：**若這次改動會讓「原本不合格的既有實作」變成合格，它就是放寬型 amendment**，一律禁止。真心認為需求過當時，那是 spec 層級的決定 → 依 §5.2 徵詢使用者，不得由 controller 自行在 plan 上執行。

## 5. 權限與核准層級

### 5.1 權限

- **只有 controller 能修改 `docs/superpowers/**`。**
- **implementer subagent 一律禁止**建立或修改 `docs/superpowers/**` 之下的任何檔案。

### 5.2 核准層級

- **plan（`docs/superpowers/plans/**`）——純修正型** → controller 直接修改並 commit，不打斷執行。這與本 skill 既有的 continuous-execution 原則一致：plan 是實作分解，其客觀缺陷屬執行細節。「純修正型」指變更只是**訂正錯誤事實或補上遺漏**（改對算錯的預期值、修正不存在的路徑或符號、補上被漏寫的步驟），不刪除也不收窄任何既有的驗收文字。
- **plan——刪除或收窄型** → 比照 spec，**必須先以 `AskUserQuestion` 徵詢使用者**。只要變更會**刪除**一個既有步驟／驗收項，或**收窄**驗收標準、Task 範圍、預期行為的文字，就落入此類。
  - 理由：一個變更究竟是「訂正事實」還是「弱化需求」，往往取決於原始意圖與當前實作狀態，**無法只從 diff 方向可靠判定**。把這個曖昧類別交給使用者，是唯一可靠的判準來源；也讓 §8.4 的 reviewer 端反弱化檢查得以退居 best-effort backstop，不必獨力承擔這道防線。
  - **Fail closed**：分不清屬於純修正型還是刪除／收窄型時，一律當**刪除或收窄型**處理，徵詢使用者。
  - 使用者否決 → 該 finding 退回當一般 code finding 處理，由 implementer 改 code。

### 5.3 核准內容與實際變更的綁定

使用者核准的是**特定的一項變更**，不是「動需求檔」這個泛稱。因此徵詢與提交之間必須維持一一對應：

- **徵詢時呈現確切內容**：`AskUserQuestion` 中必須寫出這次要改的**具體前後文字**（哪一段變成哪一段），不得只給摘要式描述（例如「修正 Task 3 的驗收標準」）。使用者核准的範圍**就是所呈現的那段文字**，不及於其他。
- **一個 amendment 一個 commit，不得夾帶**：§6.1 步驟 3 的 docs-only commit 只能包含這次被核准（或屬純修正型而免徵詢）的那項變更。**禁止**把未經核准的其他需求變更、順手的措辭調整、或另一項待辦的 amendment 併入同一個 commit——即使它們同樣是 docs-only、同樣能通過 §6.3 的檢查。若同時有多項 amendment，各自徵詢、各自 commit。
- **範圍變動要重新徵詢**：若在動手修改時發現實際需要改的內容超出徵詢時呈現的文字，必須帶著新內容**重新徵詢**，不得以「原本核准的延伸」為由自行擴大。

**這一節是紀律，不是機械檢查。** §6.3 的檢查能證明「這個 commit 是 controller 做的、且只碰需求檔」，但無法證明「其內容正是使用者核准的那段」——那需要持久化的核准產物（manifest / ledger / trailer），已於 Non-goals 記為不實作的兩項已接受限制。本節把該類風險收斂為明確、可被人工稽核的行為要求：核准與 commit 一一對應、內容逐字呈現、不夾帶。
- **spec（`docs/superpowers/specs/**`）** → controller **必須先以 `AskUserQuestion` 徵詢使用者**。spec 是使用者在 brainstorming 階段核准過的需求，實作期間逕自修改等同繞過該核准 gate。
  - 使用者同意 → 依 §6 程序修改。
  - 使用者否決 → 該 finding **退回當一般 code finding** 處理（fail closed），由 implementer 改 code。

## 6. 修正程序與 base 契約

### 6.1 嚴格順序

一旦 controller 判定某 finding 為 amendment，必須依下列順序執行。任一步驟顛倒即為流程違規：

1. controller 判定為 amendment（若涉及 spec，先依 §5.2 徵詢使用者並取得同意）。
2. controller 修改需求檔。
3. **單獨 commit 需求檔變更** —— 該 commit 的 diff **只**含 `docs/superpowers/**`，不得夾帶任何實作檔，也不得夾帶未經核准或不屬於本次 amendment 的其他需求變更（§5.3）。commit message 依專案慣例用 `docs(plan):` / `docs(spec):`。
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

**適用時機（無條件，每一次呼叫都要，各用自己的 base）**：

- **每一次** `review-impl.sh` 呼叫之前 → 檢查範圍 `<TASK_BASE>..HEAD`。
- **每一次** `review-final.sh` 呼叫之前 → 檢查範圍 `<IMPL_BASE>..HEAD`。final gate 階段同樣可能發生 amendment（§9），且 final-adversarial 的 carve-out（§8.2）同樣會排除需求檔，因此**必須**有對應的檢查，否則未授權的需求檔變更會在最終 merge gate 被靜默放行。final-gate 期間建立的 amendment commit 與 per-task 階段一樣記錄其 SHA，且因 `IMPL_BASE` 涵蓋整個實作區間，`<IMPL_BASE>..HEAD` 的檢查會同時涵蓋所有 per-task 階段的 amendment。

**「無條件」是安全不變式的一部分，不可退化成「有 amendment 時才做」**：carve-out 從**第一次** review 就已生效——`spec-compliance` 一開始就不把需求檔變更當成超出範圍的工作。若檢查只在「因 amendment 而重跑」時執行，則 implementer 在初次實作中誤改需求檔的情形會完全不被偵測：carve-out 壓掉了 reviewer 的訊號，而檢查又還沒被觸發。本節宣稱的不變式是「`<BASE>..HEAD` 內每一個需求檔變更都可歸屬到 controller 的 amendment」，要成立就必須在**初次與重跑、有無 amendment**的每一種情況下都執行，且與 §6.4 的新鮮度檢查同時進行（兩者都綁在「每一次 wrapper 呼叫」上）。

**檢查的三個部分**（三者都必須通過）：

0. **需求檔無未提交狀態** —— `spec-compliance` reviewer 讀的是**工作區**的 plan 檔（`review-impl.sh` 以 `--set PLAN_FILE_PATH=...` 傳入路徑，reviewer 自行開檔），但實作證據是 `git diff <BASE>..HEAD`。若需求檔有未 commit 的修改（未暫存或已暫存皆然），reviewer 會拿「不在 HEAD 上、也不在 amendment SHA 稽核範圍內」的需求文字去驗證 code，讓 gate 通過在隨時可能消失、或稍後才亂序 commit 的需求上，等於整個繞過本節的來源檢查。因此在**每一次** review wrapper 呼叫之前：

   ```bash
   git status --porcelain -- docs/superpowers/
   ```

   輸出必須為**空**。只要有任何輸出（未暫存、已暫存、或未追蹤的需求檔）→ 依下方 fail-closed 規則停止：屬於合法 amendment 的變更先依 §6.1 步驟 3 完成 commit，其餘則回報使用者。（此檢查同時是 §6.4 前後對照的「呼叫前」取樣。）

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
- **carve-out 只免除「範圍」判定，不讓需求檔的變更變成隱形**（見下方 §8.4）：若 diff 中的需求檔變更**移除或弱化了驗收標準、縮小 Task 範圍、或降低預期行為**，reviewer **必須**回報 `Status: Issues Found`，並明確指出被弱化的是哪一條標準。
- 其餘行為完全不變：reviewer 仍以 **HEAD 上的 plan 檔內容**作為需求真相（既有行為），仍以 `git diff <TASK_BASE>..HEAD` 驗證實作。

### 8.2 `final-adversarial` → `final-code-reviewer-focus.md`

該 reviewer 由 `dispatch.sh adversarial --focus` 啟動，focus 檔完全受控。在 focus 內容末尾加入同一條 carve-out：`docs/superpowers/specs/**` 與 `docs/superpowers/plans/**` 的變更不列入實作範圍或 scope-drift 的評估——但同樣受 §8.4 的反弱化例外約束：若需求檔的變更弱化了驗收標準或縮小了範圍，仍必須以 `Verdict: needs-attention` 回報。

**與既有 spec-adjudicated rejection carve-out 的關係**：兩者**正交、互不覆蓋**，各自獨立判定。

- 既有的處理「finding 的**內容**對應到使用者已接受的限制」。
- 本設計新增的處理「finding 針對的**檔案**是需求檔本身的變更」。

一條 finding 可能兩者皆不適用、適用其一、或兩者皆適用；controller 分別套用，不需要合併判定邏輯。

### 8.3 `code-quality` → `SKILL.md` 的 caller control-flow

該 reviewer 由 `dispatch.sh review --base` 啟動，是 codex 的原生 review，**機制上不接受 prompt 或 focus 注入**（`cmd_review` 只解析 `--base`）。carve-out 因此只能落在 caller 端：

- SKILL.md 的「Caller control-flow」第 5 點補述：若 code-quality 的某個 finding **僅**針對需求檔變更本身（例如評論 plan 的措辭、格式、或該不該改），controller 判定為**非阻斷**，不觸發 re-review 迴圈。
- **例外**：若該 finding 指出需求檔的變更弱化了驗收標準或縮小了範圍（§8.4），一律**阻斷**。
- 針對實作檔的 finding 一律照舊處理。

### 8.4 carve-out 的反弱化例外（三個落點共用）

carve-out 的正當理由是「需求檔的變更不是**實作範圍**問題」，**不是**「需求檔的變更不必被看」。若無條件排除，會與 §5.2（plan 的 amendment 不需使用者核准）疊加出一條無聲的需求流失路徑：controller 誤把「實作沒做到」分類成「需求寫太多」，改掉 plan、commit，下一輪 spec-compliance 便對著被弱化的 HEAD plan 驗證，而 plan 的 diff 又被 carve-out 排除，沒有任何 reviewer 會出聲。

因此三個落點的 carve-out 一律附帶同一條例外：**需求檔的變更若移除或弱化驗收標準、縮小 Task 範圍、或降低預期行為，reviewer 必須回報，且該 finding 為阻斷性。** 判定準則與 §4 的「放寬型 amendment」一致：若該變更會讓原本不合格的既有實作變成合格，就是弱化。

**此例外是 best-effort backstop，不是主要控制。** reviewer 手上只有 `git diff <BASE>..HEAD` 與 HEAD 上的 plan，判斷「刪掉一個步驟」到底是訂正事實還是弱化需求，往往取決於原始意圖與當前實作狀態，**無法可靠判定**。因此本設計不讓這條例外承重：真正把關的是 §5.2 —— 任何**刪除或收窄**驗收文字的 plan amendment 都必須先徵詢使用者，分不清就 fail closed 當成刪除／收窄型。reviewer 端的例外只負責在 controller 誤判時多攔一次；它漏判不會使協定失守，因為那類變更本來就不該在未經使用者核准下存在。

此例外不需要 reviewer 讀 spec，也不需要新的 wrapper 參數或 amendment metadata。

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
- **amendment 發生在 final gate 階段**（所有 Task 已通過、`review-final.sh` 回報 finding）→ 一樣依 §6.1 順序：先 commit 需求檔、再修 code，然後以同一個 `IMPL_BASE` 重跑 `review-final.sh`。§6.3 的完整性檢查與 §6.4 的新鮮度檢查本來就在**每一次** `review-final.sh` 呼叫前無條件執行（範圍 `<IMPL_BASE>..HEAD`），amendment 不改變這一點。
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
- 「Reviewer Dispatch」的 invocation discipline 補上兩道**無條件**的呼叫前／後檢查，適用**每一次** `review-impl.sh` 與 `review-final.sh` 呼叫（初次與重跑、有無 amendment 皆然）：§6.3 的完整性檢查（三部分）與 §6.4 的前後對照新鮮度檢查。
- 「Final adversarial reviewer」一節補上 §8.2 的正交性說明，並載明上述無條件檢查同樣適用於每一次 `review-final.sh` 呼叫，範圍用 `<IMPL_BASE>..HEAD`。
- 「Handling Implementer Status」一節補上 §7 的銜接說明。
- 「Red Flags」的 **Never** 清單補上七條：
  - 在 amendment 之後重新捕捉 `TASK_BASE`
  - 把需求檔變更與實作變更放進同一個 commit
  - 讓 implementer subagent 修改 `docs/superpowers/**`
  - 在 amendment SHA 記錄遺失時，靠推測歸屬放行 `docs/superpowers/**` 的 commit
  - 以 amendment 之名移除或弱化驗收標準／縮小 Task 範圍，來讓既有 code 通過 gate（§4 放寬型 amendment）
  - 未經使用者核准就對 plan 執行刪除或收窄驗收文字的 amendment（§5.2）
  - 在同一個 amendment commit 裡夾帶未經核准或不屬於本次 amendment 的其他需求變更（§5.3）

## 11. 測試 / 驗收

本設計改動的是 SKILL.md 與 reviewer prompt / focus（Markdown 指令，即插件的執行行為），非可由單元測試覆蓋的程式邏輯。本設計不改動任何 shell 腳本。驗收方式：

- 執行 `bash scripts/review-batch-lib.test.sh`、`bash scripts/dispatch.test.sh`、`bash scripts/preflight.test.sh`，確認全數通過（作為未回歸的佐證）。
- 以 grep 驗證四個目標檔案確實各自含有新增段落的關鍵標記。
- 人工審閱四份改動，確認觸發判定、權限、順序、base 契約、三處 carve-out 之間無自相矛盾，且與既有的 spec-adjudicated rejection carve-out 正交無衝突。
