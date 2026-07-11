# 反過度設計逃生閥：brainstorming 審查迴圈 + 下游對抗式驗收

- **日期**：2026-07-11
- **狀態**：設計已核准，待 spec 審查
- **影響檔案**：
  - `skills/brainstorming/SKILL.md`（主改動）
  - `skills/subagent-driven-development/SKILL.md`（下游連動，輕量）
- **提交類型**：`feat:`（新增能力：改變 agent 執行 skill 的行為契約）

## 1. 問題

brainstorming 的 spec 審查迴圈目前是**零容忍**設計：每個 finding 都必須修到 design-soundness 對抗式 reviewer 回傳 `Verdict: approve` 為止（見 `skills/brainstorming/SKILL.md` 的 "Round loop — zero tolerance"）。

design-soundness reviewer（`skills/brainstorming/adversarial-spec-review-focus.md`）天生會挑 failure paths / partial failure / rollback / concurrency / 邊界 / 未言明假設。這是對抗式審查的本意，但在零容忍迴圈下產生一個病理：

- agent 過度相信 reviewer 回傳的 findings，逐條照修；
- 於是為極邊緣、幾乎不會發生的特例，引入本應用不需要的機制——例如寫入原子性、佈署/還原步驟、為確保輸入語法正確而實作非必要的 parser；
- 這些顧慮在小應用不需要，或早已由其他機制覆蓋，卻在同一議題上被反覆 finding → 修正 → 再對抗，持續加碼，造成過度設計。

根本觀察：對抗式 reviewer 在某些議題上本來就無法被「滿足到完美」。為了消滅一個幾乎不會發生的特例而不斷引入更多要做的事，是不成比例的成本。判斷「這個顧慮值不值得付出代價」應該是使用者的決定，而不是讓 agent 盲從 reviewer 一路加碼。

## 2. 目標與非目標

### 目標
- 在 brainstorming 審查迴圈加入逃生閥，讓 agent 能把「是否值得為某顧慮付出代價」交還使用者裁決。
- 提供一個**客觀信號**（同一議題連續三輪被 flag），在 agent 主觀判斷失靈時強制停下來問人。
- 讓使用者的裁決被持久記錄在 spec，並貫通到下游對抗式驗收，不被重新翻案。

### 非目標
- 不改 writing-plans。其審查非對抗式，且幾乎只要求遵守 spec 設計。
- 不改 finishing-a-development-branch。它沒有任何對抗式審查（純測試 → 收尾選項）。
- 不修改任何 reviewer 的 prompt / focus（`adversarial-spec-review-focus.md`、`final-code-reviewer-focus.md`）或 wrapper 腳本（`review-brainstorm.sh` 等）。本設計只改 SKILL.md 層的迴圈契約與 agent 行為指示。
- 不引入自動化的語意比對工具或計數程式。三輪計數由 agent 以顯式 ledger 自行維護。

## 3. 核心原則

**agent 永不擅自認定「已接受限制」。** 是否接受某個顧慮、放棄某個修正，一律是使用者的決定。agent 的職責是「偵測 → 停下來問使用者」，絕不代替使用者判斷 YAGNI，也不在使用者沒表態時自行把 finding 標為已接受並跳過。

## 4. brainstorming 迴圈契約的改動

以下三個機制加到 `skills/brainstorming/SKILL.md` 的 spec 審查迴圈（"Round loop" 一節及其鄰近段落）。

### 4.1 每輪 ledger（顯式追蹤）

每一輪跑完 `review-brainstorm.sh` 並解析 `=== Summary ===` 後，agent **必須**在該輪回覆中輸出/更新一份可見的 ledger 表，逐輪維護：

| 欄位 | 意義 |
|---|---|
| 議題 | 以**語意**歸納的顧慮（例：「spec 檔寫入非原子」）。reviewer 每輪換句話說仍算同一議題。 |
| 連續被 flag 輪數 | 此議題**連續**出現在 reviewer findings 的輪數；某輪未被 flag 則歸零。 |
| 狀態 | `open`（處理中）／`adjudicated-implement`（使用者裁決要做，修復中/已修）／`adjudicated-reject`（使用者裁決不做，已記入 spec）。 |

ledger 是這份逃生閥機制的持久計數載體，用來抵抗長迴圈與上下文壓縮：每輪重新寫出完整 ledger，不依賴對話記憶回溯。

**「同一議題」判定**：以底層顧慮的語意為準，不看字面措辭。reviewer 換不同句子描述同一個根本顧慮，計為同一議題、輪數累加。

### 4.2 兩個升級觸發點 → 一律 `AskUserQuestion`

任一觸發點成立時，agent 停止該議題的自動修復，改用 `AskUserQuestion` 交給使用者裁決。兩個觸發點是同一逃生閥的兩個入口，彼此互補、不衝突：

- **主觀觸發（提早問，可自由裁量）**：agent 判斷某 finding 可能是過度設計——對這個應用的實際規模不成比例、或針對幾乎不會發生的特例、或已由其他機制覆蓋——即可**當場**升級詢問，不必等三輪。此時 agent 既不逕自修，也不逕自跳過。
- **客觀觸發（強制，backstop）**：ledger 顯示某 `open` 議題**連續三輪**被 flag（第三輪結束時輪數達到 3），agent **必須**升級詢問，即使它每一輪都覺得自己修得合理。這個客觀信號用來接住 agent 主觀判斷失靈、naively 一路照修的情況。

兩觸發點的關係：一個議題只有在 agent「每輪都覺得修得合理、從未主觀升級」時，才會走到三輪 backstop；一旦 agent 主觀升級或使用者裁決過，該議題即離開 `open`，不會再觸發 backstop。

**升級時 `AskUserQuestion` 的內容**：

- 呈現：該議題的具體 finding、agent 為何懷疑它過度設計（或已被反覆對抗三輪的事實與 ledger 輪數）、實作它大致要付出什麼代價。
- 選項（沿用「是否該實現這個修正」的二元框架）：
  1. **實作** — reviewer 是對的，照修（議題轉 `adjudicated-implement`）。
  2. **不實作** — 記為明確非目標（議題轉 `adjudicated-reject`，理由寫入 spec，見 §5）。
- `AskUserQuestion` 自動附帶的「Other」讓使用者可提中間方案（例如較簡化的緩解）；agent 依使用者所述處理，並據結果將議題歸入 `adjudicated-implement` 或 `adjudicated-reject`。

### 4.3 已裁決清單 + 放寬的退場條件

- 使用者選「不實作」後，該議題在 ledger 標為 `adjudicated-reject`，理由寫入 spec 的 Non-goals / Accepted limitations 區塊（§5），並提交。
- 之後若對抗式 reviewer 再度 flag 同一個 `adjudicated-reject` 議題 → **非阻斷**：agent 不重修、不重新升級詢問，僅在 ledger 保留其 `adjudicated-reject` 狀態。
- 退場條件由「reviewer `approve`」放寬為以下**任一**成立：
  1. design-soundness 回傳 `Verdict: approve`（且 structural-completeness 為 `Status: OKAY`）；或
  2. structural-completeness 為 `Status: OKAY`，且 design-soundness 剩下的 findings **全部**對應 ledger 中 `adjudicated-reject` 的議題（即沒有任何新的或未裁決的阻斷 finding）。

structural-completeness reviewer 不受此逃生閥影響：它檢查 placeholder / 內部一致性 / scope / ambiguity / YAGNI，其 `Issues Found` 一律照舊修復。逃生閥只作用於 design-soundness（對抗式）reviewer 的 findings。

## 5. spec 的 Non-goals / Accepted limitations 記錄結構

被裁決為 `adjudicated-reject` 的議題，寫入**正在撰寫的那份 spec**（brainstorming 產出的 design 文件）的一個 **「Non-goals / Accepted limitations」** 區塊。每筆記錄：

- **顧慮**：對抗式 reviewer 提出的顧慮摘要。
- **裁決**：不實作。
- **理由**：為何不做——規模不成比例／已有其他機制覆蓋／屬幾乎不會發生的極邊緣特例（採使用者裁決時所述）。

此區塊是持久裁決記錄：撐過上下文壓縮，並作為下游對抗式驗收（§6）的依據。若 spec 已有等義區塊（如既有的「非目標」段落），沿用即可，不強制新增重複標題。

## 6. 下游連動：subagent-driven-development 的 final adversarial gate

（釐清：對抗式終審 gate 位於 subagent-driven-development 的 `review-final.sh` + `final-code-reviewer-focus.md`，而非 finishing-a-development-branch；後者無任何對抗式審查。）

在 `skills/subagent-driven-development/SKILL.md` 的 final adversarial reviewer 處理流程（"Final adversarial reviewer" 一節）加一條規則：

- 在對 final-adversarial 的 findings 動手修復前，agent **先讀該實作所依據 spec 的 Non-goals / Accepted limitations 區塊**。
- 若某條 final-adversarial finding 命中一個 spec 已明確記為 `adjudicated-reject` 的過度設計項 → **視為非阻斷**，不實作、不因它擋下 merge gate；agent 在回報中註明「此 finding 對應 spec 已裁決的 accepted limitation，依裁決不實作」。
- 其餘未被 spec 裁決過的 findings 一律照舊處理（維持既有 gate 行為）。

這條把 brainstorming 階段的使用者裁決貫通到最終對抗式驗收，避免同一個已被使用者否決的過度設計顧慮在下游被翻案、重新逼迫實作。

## 7. 邊界與交互情況

- **第一輪即被 flag**：輪數為 1，不觸發 backstop；agent 可依主觀觸發選擇升級或照修。
- **議題某輪消失又重現**：連續輪數歸零後重新計數（backstop 針對「連續」三輪，非累計）。
- **使用者選「實作」後該修正又衍生新顧慮**：新顧慮是**新議題**，獨立計數，不繼承舊議題輪數。
- **使用者於 Other 給中間方案**：agent 依所述實作簡化版，將原議題歸為 `adjudicated-implement`（若中間方案本身又被 reviewer 反覆對抗三輪，backstop 照樣適用，再次升級）。
- **structural-completeness 與 design-soundness 同輪都有 finding**：structural 照修；design 側才套用逃生閥。兩者退場條件需同時滿足（structural `OKAY` 且 design 達 §4.3 的任一退場情形）。
- **HEAD 契約不變**：每輪修復（含把裁決寫入 spec）仍須在下一次 `review-brainstorm.sh` 執行**前**提交；wrapper 執行期間不得推進 HEAD。逃生閥不改變既有的 `SPEC_BASE`、commit-per-round、單次 wrapper 呼叫等紀律。

## 8. 測試 / 驗收

本設計改動的是 SKILL.md 的 agent 行為指示（Markdown 指令，即插件的執行行為），非可由單元測試覆蓋的程式邏輯；`review-brainstorm.sh` / `review-final.sh` 及其 lib 的既有測試不受影響（本設計不改腳本）。驗收方式：

- 人工審閱兩份 SKILL.md 改動，確認迴圈契約、ledger、雙觸發、退場條件、下游連動皆完整且無自相矛盾。
- 走一次 spec 審查迴圈（本 spec 自身即經此迴圈），確認新流程可被 agent 正確依循。
- 確認未改動任何 wrapper 腳本，`scripts/*.test.sh` 仍全數通過（作為未回歸的佐證）。
