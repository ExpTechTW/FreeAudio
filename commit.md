# Commit 格式

**commit 訊息就是更新日誌。** `scripts/notes.sh` 直接讀這些訊息產生 GitHub release
的內容，所以一則寫壞的 commit 會在使用者讀得到的地方留下一個洞——而 commit 訊息推出去
之後**改不了**，唯一的修法是 rebase。

規則沿用 DPIP 的 `commit.md`，語系換成 FreeAudio 有的三種。

---

## 檢查

```sh
git config core.hooksPath .githooks          # 只要設一次：之後每次 commit 都會先檢查訊息
scripts/check-commits.sh origin/main..HEAD   # 推送前檢查還沒推出去的 commit
scripts/check-commits.sh --message <草稿檔>  # 檢查一份還沒提交的訊息
```

pull request 的 CI（`.github/workflows/ci.yml`）也會跑同一個檢查，不合格就失敗。

---

## 格式

```
<type>(<scope>): <英文摘要>

<Category>(<locale>): <更新日誌條目>
...
```

摘要行給 `git log` 讀，條目行給使用者讀。

**沒有散文說明。** 為什麼這樣做、試過什麼、踩到什麼坑，全部寫在程式碼註解裡——那是
下一個改這段程式的人會看到的地方，而更新日誌的讀者一項都用不到。

---

## 摘要行

```
feat(update): update FreeAudio from GitHub releases
└┬─┘ └──┬─┘  └────────────────┬────────────────┘
 type  scope                 摘要
```

### type

| type | 用在 | 進更新日誌？ |
|---|---|---|
| `feat` | 使用者拿到新東西 | 🌟 新功能 |
| `fix` | 修正使用者遇得到的錯誤行為 | 🐞 錯誤修正 |
| `perf` | 一樣的行為，更少的資源 | 🔌 最佳化 |
| `refactor` | 一樣的行為，更好的結構 | 🔌 最佳化 |
| `docs` | 只有文件 | ✗ |
| `test` | 只有測試 | ✗ |
| `build` | 建置、打包、相依套件 | ✗ |
| `ci` | workflow、gate | ✗ |
| `style` | 只有排版，沒有語意 | ✗ |
| `chore` | 其他雜務 | ✗ |
| `revert` | 回退某個 commit | ✗ |

**選 type 的判準是「使用者看不看得到」，不是「改了哪個資料夾」。**

### scope

選填，小寫，對應功能區：`devices` `apps` `eq` `menu` `settings` `update` `l10n`。
跨多個區的改動就**不要寫 scope**。

### 摘要

- 英文、只用 ASCII（中文寫在條目行）
- 最多 72 個字元，結尾不加句號

---

## 更新日誌條目

```
New(zh-Hant): 可以從 GitHub 自動更新
└┬┘ └──┬──┘  └───────┬───────┘
分類    語系          條目文字
```

| 分類 | 進更新日誌的哪一區 |
|---|---|
| `New` | 🌟 新功能 |
| `Optimization` | 🔌 最佳化 |
| `Fix` | 🐞 錯誤修正 |

**分類是宣告的，不是從 `<type>` 推的。** 一個 `chore:` 的 commit 如果真的修好了使用者
看得到的東西，寫一行 `Fix(...)` 它就會出現。

### 語系

| | |
|---|---|
| **必填** | `zh-Hant`、`en-US` |
| 選填 | `ja-JP` |

FreeAudio 的介面只有這三種語言，gate 會擋其他語系。**各語言的條目數量要對得起來**：中文
寫了兩則、英文只寫一則，英文讀者拿到的就是一份少一條的清單。

`feat` / `fix` / `perf` **至少要有一行**；其他 type 通常不寫。

### 寫什麼

**一行講完一件使用者感覺得到的事。** 寫結果，不是實作。

```
✗ New(zh-Hant): 新增 Updater 類別，用 SecStaticCode 驗證 GitHub release 的 zip
✓ New(zh-Hant): 可以從 GitHub 自動更新，只安裝開發者簽署的版本
```

一則 commit 可以有多行、也可以跨分類；但**超過三行就回去看**下一節。

---

## 一個 commit 一件事

更新日誌是一則 commit 一組條目。兩件事塞在一起，revert 一件就會連帶 revert 另一件，
`git bisect` 也指不出是哪一個改動。這條 gate 驗不了，靠自己：

| 徵兆 | 例子 |
|---|---|
| 摘要裡有 **and** | `add updates and fix the slider` |
| 摘要在**列舉** | `version builds, publish releases, sign in CI` |
| 需要**兩個 type** 才講得清楚 | 一半是 `feat`、一半是 `ci` |

同一個檔案裡有兩件事的話，先寫出中間狀態、commit、再寫回最終狀態、再 commit。

---

## 禁止（gate 會擋）

- 署名給工具的 `Co-authored-by:` / `Signed-off-by:`
- 任何工具署名：`Generated with`、🤖、agent 名稱、模型名稱

commit 的作者是人。工具把自己寫進紀錄，等於讓歷史對「誰為這個改動負責」說謊。

---

## 範例

```
feat(update): update FreeAudio from GitHub releases

New(zh-Hant): 可以從 GitHub 自動更新，只安裝開發者簽署的版本
New(en-US): FreeAudio updates itself from GitHub, and only installs builds its developer signed
New(ja-JP): GitHub から自動でアップデートでき、開発者が署名したものだけをインストールします
```

```
fix(devices): keep the chosen speaker when headphones connect

Fix(zh-Hant): 修正接上耳機時會自動切換輸出裝置
Fix(en-US): connecting headphones no longer switches the output away from the chosen speaker
```

不進更新日誌的：

```
ci: run the tests on pull requests
docs: describe the release process
```

---

## 合併

只用 rebase，不要 merge commit：gate 會略過 merge commit，用 merge 等於繞過整個檢查。
pull request 裡有 merge commit，CI 會直接失敗。

```sh
git fetch origin
git rebase origin/main
git push --force-with-lease
```
