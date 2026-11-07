# hspnv 动态学习笔画输入法

基于 **Rime / 元书（Hamster）** 的五笔画输入方案：**整句解码 + 上下文联想 + 个人语料 + 自学习**。

打一串笔画，直接给你一句候选；打两笔，先出单字；打 `1'1`，出「或者」。

> 当前版本：2026-11-07（重置键 + 词库增强 + gram/ext 恢复 + 个人三元组扩容）
> 实测：整句首位还原 18/18，每键 15~35ms（150→60 候选 + 桶缓存 + DP 缓存）

---

## ✨ 核心特性

### 1. 连续输入 / 整句输入

分词输入（`31'32'45`）时，候选按三层排布，任何一步都能上屏、能继续打：

| 顺序 | 候选 | 用途 |
|---|---|---|
| ① 整词 ×5 | 覆盖全部输入 | 一次上屏最多字 |
| ② 前缀词 ×2 | 前几段 | **提前上屏**，剩余继续 |
| ③ 末段单字 ×4 | 最后一段 | 当前这个字随时可选 |

**句子级 DP 解码**（真概率版）：把每 1~4 段合成一个词，用 `log10 P(词)` + 上下文相加取最优切分：

```
31'32'3445'1134  →  我们今天      （实测首位）
31'32'251'3553   →  我们吃饭
```

不再用「字数奖励 + 常数加权」的拍脑袋打分，字和词同一量纲，成词与否由 PMI 决定。

### 2. 不打分词符也能出词

连续码（≥4 位）自动切成 2~3 段查词组索引：

```
3132  → 升 / 亣 / 刋（同码单字） + 我们
31324 → 我们 / 我的家 / 每段话 / 每袋米
```

### 3. 联想预测（上下文分层）

| 优先级 | 来源 | 说明 |
|---|---|---|
| 最高 | **用户三元组** | 常打「今天 天气 怎么」→ 再打「今天 天气」，首位就是「怎么」 |
| 高 | 离线三元组 / 四连短语 | `next_words_tri`、`phrase_assoc_tri/quad` |
| 中 | 短语联想 + 离线 bigram | `phrase_assoc`、`next_words_big` |
| 中 | 用户 bigram 直出 | 真实词对搭配，最多 4 个 |
| 低 | 词内补全 / 末尾组词 / 通用兜底 | 长尾 |

- 同首字最多 2 个候选（避免「我们的/我们这/我们不」刷屏）
- 句号后按「标点→下一句首词」预测
- 首页混合候选**预算制**：真实联想最多 6 个，其余名额给 emoji / 标点 / 常用语

### 4. 个人语料（让联想像自己说话）

```
tools/gen_personal_ngram.lua  →  personal_ngram.tsv
```

把你的聊天记录/常用语喂进去，生成 bigram + trigram，启动时作为**低权重种子**并入上下文模型（用户实时学习仍优先）。

当前种子规模：bigram **6,834** 条 / trigram **6,474** 条（2026-11-07 从 5,507 条个人消息中挖掘补充 1,090 条）。

> 语料文件含个人内容，**不要提交到公开仓库**（已在 `.gitignore` 中排除，仓库里也没有）。

### 5. 简码（带分词符）

`custom_phrase.dict.yaml` 里 3026 条「每字首笔」简码，2026-10-30 起改为带分词符：

```
或者 1'1    只有 2'1    选择 3'1    没有 4'1    我们 3'3
```

- 打 `11` → 只出单字（天/于/三/二…），不再冒出「或者」
- 打 `1'1` → 「或者 / 现在 / 需要」置顶
- 双保险：词库层（带 `'` 的编码）+ `lua/quick_codes.lua`（lua 层精确命中的兜底）

### 6. 手动干预：置顶 / 上移 / 下移 / 降权 / 重置

| 键 | 发送 | 作用 |
|---|---|---|
| 下移 | `Control+k` | 当前候选下移一位 |
| 下移（上滑） | `Control+j` | 当前候选上移一位 |
| 降权 | `Control+Delete` | 当前候选写入 `demote.user.tsv`，沉底 + 学习频次减半 |
| 降权（下滑） | `Control+p` | 当前候选置顶 |
| **重置（第三行）** | `Control+l` | **当前候选完全重置：恢复默认排序 + 取消降权 + 频次恢复** |

**重置键**（皮肤 V116 新增）：原来第三行的「连打」键改为「重置」。按下后：

1. `super_sequence` 写入重置墓碑，清掉该词的手动排序 → 回默认位置；
2. 从 `demote.user.tsv` 移除该词 → 不再被 `demote_filter` 沉底；
3. `learning.undemote` 把被减半的学习频次 ×2 恢复。

> 降权本身**不会自动过期**（`demote.user.tsv` 里的时间戳只记录、不参与恢复）。想让降权词回到前面，就按「重置」键，或再按一次「降权」键取消。

### 7. 其他

- **首两笔选字**：1~2 笔时静态字频主导，与《首两笔速查手册》逐码一致
- **3 笔以上**：用户上屏频次优先（学「呗」6 次后，它的完整码首位就是「呗」）
- **自学习**：上屏加频（封顶 10 次）、30 天半衰期衰减、组合造词
- **以词定字**：皮肤「首」「末」键
- **连打**：上屏后按 Tab 直接接力联想词（仅桌面；皮肤第三行已改为重置键）
- **自动上屏**：唯一候选 + 高置信首位（阈值 0.8）

---

## 🎨 皮肤 V116

- 文件：`skins/hspnv-多功能-v116.cskin`（4.16 MB，219 个条目，config.yaml 在根）
- 改动（2026-11-07）：第三行 `numSwitchButton` 由「连打」（`Tab`）改为「重置」（`Control+l`）
- 四套配色/布局同步：`light/dark × portrait/landscape`

---

## 📊 性能与内存

| 项 | 数值 |
|---|---|
| Lua 内存（GC 后） | 59 MB |
| 每键耗时 | 15~35 ms（150→60 候选 + 桶缓存 + DP 缓存） |
| 整句还原 | 18/18（常用句首位） |
| 方案体积 | 81.2 MB（恢复 gram/ext 后，2026-11-06） |

优化手段（都是实测过的）：

- `head_words` 打包成字符串（19MB → 2MB），按需解析
- `phrase_stroke_index` 的 I 表打包成整数（24MB → 9MB）
- `next_words_tri/big` 按词频裁剪（5.3+2.2MB → 1.6+1.6MB）
- 一阶 Trie 桶落盘缓存（`bg5_bucket_cache.tsv`）
- 候选上限 60，联想结果按上下文缓存（20ms → 0.2ms）

> 恢复 `script_translator@gram` / `table_translator@ext` 后，**首次部署需要构建 stroke_script / stroke_ext 两个 prism，明显变慢**；`gram_model.enable` 仍为 false（省内存）。

---

## 📦 仓库结构

```
├── stroke_hspnv_learning.schema.yaml   # 主方案
├── custom_phrase.schema.yaml           # 简码词典的构建载体（缺它置顶词会失效）
├── custom_phrase.dict.yaml             # 简码 + 全码短语（3026 简码 + 3030 全码）
├── stroke_hspnv.dict.yaml              # 主词库（387k 词条）
├── stroke_script.dict.yaml             # 整句/gram 翻译器词库（15.6MB）
├── stroke-zh-hans.gram                 # 语法模型（10.1MB）
├── stroke_ext.dict.yaml                # 扩展词库入口（成语/地理/人名/医学）
├── stroke_ext_*.dict.yaml              # 四本扩展词典（8.2MB）
├── 使用说明.md                           # 完整文档（含常见问题排查）
├── 首两笔速查手册.md                     # 每码前几位的单字顺序
├── lua/
│   ├── segment_phrase.lua               # 主翻译器：单字/分词/整句DP/联想/自动组词
│   ├── demote.lua                       # 降权处理器（写 demote.user.tsv）
│   ├── demote_filter.lua                # 降权过滤器（沉底/隐藏）
│   ├── filter_seg_count.lua             # 分词过滤 + 预编辑兜底
│   ├── predict_next.lua                 # 上屏预测状态机 + 混合候选预算
│   ├── learning.lua / ngram.lua         # 用户词频 / 上下文（bigram+trigram）
│   ├── lm.lua                           # log10 概率（整句 DP 用）
│   ├── preedit_util.lua                 # 预编辑统一实现（各段笔画符号）
│   ├── quick_codes.lua                  # 简码 → 词
│   ├── words.lua / head_words.lua       # 词库（含打包格式）
│   ├── phrase_stroke_index.lua          # 词组笔画索引（打包格式）
│   ├── next_words_big/tri.lua           # 离线 bigram / trigram（裁剪版）
│   ├── char_freq_token.lua              # 字 token 频率（概率底座）
│   ├── hspnv/                           # 万象系模块（改名后）
│   │   ├── hspnv.lua / userdb.lua / bit.lua
│   │   ├── super_sequence.lua           # 手动排序 + 重置键
│   │   ├── context_reorder.lua / partial_commit.lua
│   │   └── custom_phrase.lua / charset_filter.lua
│   ├── data/                            # 英文、符号、颜文字、提示语
│   └── …（共 50+ 模块）
├── opencc/
│   ├── hspnv/                           # 简繁 / 变体 / emoji 词典
│   └── hspnv_s2t.json / s2hk.json / s2tw.json
├── tools/
│   ├── add_words.lua                    # 加自造词（自动算全码+简码）
│   ├── split_short_codes.lua            # 简码加分词符
│   ├── gen_quick_codes.lua              # 生成简码表
│   ├── pack_head_words.lua              # 打包首字词表
│   ├── pack_phrase_index.lua            # 打包词组索引
│   ├── trim_predict_tables.lua          # 裁剪离线预测表
│   ├── gen_personal_ngram.lua           # 个人语料 → n-gram
│   └── hotword_update.py                # 热词订阅
└── skins/
    └── hspnv-多功能-v116.cskin           # 最新皮肤（重置键）
```

---

## 🚀 部署

1. 把方案文件复制到元书的 Rime 用户目录（`stroke_hspnv_learning.schema.yaml`、`custom_phrase*.yaml`、`stroke_script/gram/ext`、`lua/`、`opencc/`、`tools/`）
2. 元书 → 设置 → 皮肤 → 导入 `skins/hspnv-多功能-v116.cskin`
3. 元书 → **重新部署方案**（首次构建 prism 约 1~2 分钟）

> 改了 `lua/` 或词典后都要重新部署；只改 lua 可跳过重建词典。
> `personal_ngram.tsv` 只能本地放（`<user_dir>/personal_ngram.tsv` 或方案目录），重新部署时载入。

---

## ⌨️ 常用操作

| 想做的事 | 操作 |
|---|---|
| 单字（首两笔选字） | `12`、`44`、`32` |
| 两字词 | `31'32` → 我们 |
| 整句 | `31'32'3445'1134` → 我们今天 |
| 简码 | `1'1` → 或者 |
| 不打分词出词 | `3132` → 我们 |
| 提前上屏前缀 | 选候选里的「我们」（前缀词） |
| 以词定字 | 「首」键取首字 /「末」键取末字 |
| 连打（桌面） | 上屏后按 Tab |
| 上移 / 下移 | 皮肤「下移」键（点按 / 上滑） |
| 置顶 | 皮肤「降权」键下滑 |
| 降权 | 皮肤「降权」键点按 |
| **重置当前候选** | **皮肤第三行「重置」键** |

---

## ⚙️ 关键配置（schema）

```yaml
segment_phrase:
  predict_max: 8        # 空输入联想条数
  word_uf_step: 30000   # 用户频次权重（与 ngram/word_weight 解耦）
  char_uf_step: 100000  # 单字频次权重
  debug_input: false    # 排查用：写 bg5_input.log

ngram:
  word_weight: 200000   # 上下文权重（1 次搭配 ≈ 2/3 静态 bigram）
  tri_enable: true      # 用户三元组

predict_next:
  mix_real_keep: 6      # 首页最多留给真实联想的个数
  mix_punct_max: 1 / mix_quick_max: 2 / mix_emoji_max: 1

custom_phrase:
  enable_completion: false   # 简码不做前缀补全
  spelling_hints: 0          # 不显示编码数字
  preedit_format: xlit/12345/一丨丿丶乛/

super_sequence:
  up: "Control+j"       # 皮肤「下移」键上滑
  down: "Control+k"     # 皮肤「下移」键点按
  reset: "Control+l"    # 皮肤第三行「重置」键
  pin: "Control+p"      # 皮肤「降权」键下滑

demote:
  key: "Control+Delete" # 皮肤「降权」键点按
  mode: demote          # demote=沉底；hide=隐藏

gram_model:
  enable: false         # 关闭语法模型（省 15MB）
```

---

## 🧪 已知限制

- **多词整句**依赖词库：词库没有的组合只能退化为逐字拼接（仍可一次上屏，但可能不自然）
- **无分词连续码**只做单词级自动切分，不做整句 DP（字边界未知，组合爆炸）
- **单字个性化在短码下几乎无效**（静态字频 1e8 量级），这是为保证《首两笔速查》顺序
- **降权不会自动过期**：`demote.user.tsv` 只写时间戳不读，需要「重置」键手动恢复
- **ngram 搭配不衰减**（learning 的词频会衰减，两者策略不同）
- 词里的字必须在 `stroke.lua` 笔画表（约 8500 字）内，生僻字不支持

---

## 📝 更新日志

### 2026-11-07
- 皮肤 V116：第三行「连打」键改为「重置」键（`Control+l`），外显「重置」
- 重置语义落地：默认排序 + 取消降权（移出 `demote.user.tsv`）+ 学习频次恢复
- 修复：取消降权时仍调 `learning.demote` 反向再减半频次的 bug
- 恢复 `script_translator@gram` / `table_translator@ext` 与配套词库（之前误删文件，非停用功能）
- 个人语料扩容：trigram 5,384 → 6,474（从 5,507 条个人消息挖掘）
- 模块改名 `wanxiang/*` → `hspnv/*`，仓库结构同步

### 2026-10-30
- 整句解码 v2：log10 真概率（新增 `lm.lua`、`char_freq_token.lua`），18 条常用句首位 18/18
- 数据格式改造：`head_words` / `phrase_stroke_index` 打包、`next_words_*` 裁剪 → 147MB→59MB
- 简码改为带分词符（`1'1`），新增 `quick_codes.lua` 兜底与 `add_words` 工具
- 用户三元组（上下文联想）、缓存上限、`preedit_util` 统一预编辑实现
- 修复：预编辑区显示数字、多段 composition 无候选、简码抢占单字位

### 更早
- 分词组词、首两笔选字、联想四层模型、以词定字、连打、自动上屏

---

## 🙏 参考与致谢

- **白霜拼音**（gaboolic/rime-frost）：主词库语料
- **万象拼音**（amzxyz/rime-wanxiang）：联想机制、predict 接入、短语库、super_sequence
- **键道·我流**（pingshunhuangalex/rime-keydo）：顶功自动上屏、衔接词优先
- **oh-my-rime**（Mintimate/oh-my-rime）：以词定字
- **雾凇拼音**（iDvel/rime-ice）：词库净化思路
- **Rime / librime / librime-lua**：引擎与 Lua 扩展

## 📄 License

方案代码与词库遵循各自上游项目的开源协议；使用请保留来源说明。
