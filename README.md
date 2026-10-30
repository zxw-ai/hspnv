# hspnv 动态学习笔画输入法

基于 **Rime / 元书（Hamster）** 的五笔画输入方案：**整句解码 + 上下文联想 + 个人语料 + 自学习**。

打一串笔画，直接给你一句候选；打两笔，先出单字；打 `1'1`，出「或者」。

> 当前版本：2026-10-30（整句 DP 真概率 + 数据打包 + 简码分隔符）
> 实测：启动 5.9s / Lua 内存 59MB（iSH），整句首位还原 18/18

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

> 语料文件含个人内容，**不要提交到公开仓库**（已在 `.gitignore` 中排除）。

### 5. 简码（带分词符）

`custom_phrase.dict.yaml` 里 3026 条「每字首笔」简码，2026-10-30 起改为带分词符：

```
或者 1'1    只有 2'1    选择 3'1    没有 4'1    我们 3'3
```

- 打 `11` → 只出单字（天/于/三/二…），不再冒出「或者」
- 打 `1'1` → 「或者 / 现在 / 需要」置顶
- 双保险：词库层（带 `'` 的编码）+ `lua/quick_codes.lua`（lua 层精确命中的兜底）

### 6. 其他

- **首两笔选字**：1~2 笔时静态字频主导，与《首两笔速查手册》逐码一致
- **3 笔以上**：用户上屏频次优先（学「呗」6 次后，它的完整码首位就是「呗」）
- **自学习**：上屏加频（封顶 10 次）、30 天半衰期衰减、组合造词
- **手动干预**：置顶 / 上移 / 下移 / 重置 / 降权（皮肤键）
- **以词定字**：皮肤「首」「末」键
- **连打**：上屏后按 Tab 直接接力联想词
- **自动上屏**：唯一候选 + 高置信首位（阈值 0.8）

---

## 📊 性能与内存

| 项 | 数值 |
|---|---|
| 启动（iSH） | 5.9s |
| Lua 内存（GC 后） | 59MB |
| 每键耗时 | 15~35ms（150→60 候选 + 桶缓存 + DP 缓存） |
| 整句还原 | 18/18（常用句首位） |

优化手段（都是实测过的）：

- `head_words` 打包成字符串（19MB → 2MB），按需解析
- `phrase_stroke_index` 的 I 表打包成整数（24MB → 9MB）
- `next_words_tri/big` 按词频裁剪（5.3+2.2MB → 1.6+1.6MB）
- 一阶 Trie 桶落盘缓存（`bg5_bucket_cache.tsv`）
- 候选上限 60，联想结果按上下文缓存（20ms → 0.2ms）
- 关闭 gram 翻译器 / ext 翻译器 / gram_model（省 prism 构建 + 25MB 模型）

---

## 📦 仓库结构

```
├── stroke_hspnv_learning.schema.yaml   # 主方案
├── custom_phrase.schema.yaml           # 简码词典的构建载体（缺它置顶词会失效）
├── custom_phrase.dict.yaml             # 简码 + 全码短语（3026 简码 + 3030 全码）
├── stroke_hspnv.dict.yaml               # 主词库（Rime 侧，当前未被 translator 引用）
├── 使用说明.md                           # 完整文档（含常见问题排查）
├── lua/
│   ├── segment_phrase.lua               # 主翻译器：单字/分词/整句DP/联想/自动组词
│   ├── filter_seg_count.lua             # 分词过滤 + 预编辑兜底
│   ├── predict_next.lua                 # 上屏预测状态机 + 混合候选预算
│   ├── learning.lua / ngram.lua         # 用户词频 / 上下文（bigram+trigram）
│   ├── lm.lua                           # log10 概率（整句 DP 用）
│   ├── preedit_util.lua                 # 预编辑统一实现（各段笔画符号）
│   ├── quick_codes.lua                  # 简码 → 词（238 码 / 3026 条）
│   ├── words.lua / head_words.lua       # 词库（含打包格式）
│   ├── phrase_stroke_index.lua          # 词组笔画索引（打包格式）
│   ├── next_words_big/tri.lua           # 离线 bigram / trigram（裁剪版）
│   ├── char_freq_token.lua              # 字 token 频率（概率底座）
│   └── …（共 40 个模块）
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
    ├── hspnv-多功能-v116.cskin           # 最新皮肤
    └── hspnv-多功能-v113.cskin
```

---

## 🚀 部署

1. 把方案文件复制到元书的 Rime 用户目录（`stroke_hspnv_learning.schema.yaml`、`custom_phrase*.yaml`、`lua/`、`tools/`）
2. 元书 → 设置 → 皮肤 → 导入 `skins/hspnv-多功能-v116.cskin`
3. 元书 → **重新部署方案**（首次构建词典约 1~2 分钟）

> 改了 `lua/` 或词典后都要重新部署；只改 lua 可跳过重建词典。

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
| 连打 | 上屏后按 Tab |
| 置顶/降权/重置 | 皮肤「降权」键（下滑/点击/上滑） |

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

gram_model:
  enable: false         # 关闭语法模型（省 15MB）
```

---

## 🧪 已知限制

- **多词整句**依赖词库：词库没有的组合只能退化为逐字拼接（仍可一次上屏，但可能不自然）
- **无分词连续码**只做单词级自动切分，不做整句 DP（字边界未知，组合爆炸）
- **单字个性化在短码下几乎无效**（静态字频 1e8 量级），这是为保证《首两笔速查》顺序
- **ngram 搭配不衰减**（learning 的词频会衰减，两者策略不同）
- 词里的字必须在 `stroke.lua` 笔画表（约 8500 字）内，生僻字不支持

---

## 📝 更新日志

### 2026-10-30
- 整句解码 v2：log10 真概率（新增 `lm.lua`、`char_freq_token.lua`），18 条常用句首位 18/18
- 数据格式改造：`head_words` / `phrase_stroke_index` 打包、`next_words_*` 裁剪 → 147MB→59MB、8.7s→5.9s
- 简码改为带分词符（`1'1`），新增 `quick_codes.lua` 兜底与 `add_words` 工具
- 用户三元组（上下文联想）、缓存上限、`preedit_util` 统一预编辑实现
- 关闭 `script_translator@gram` / `table_translator@ext` / `gram_model`
- 修复：预编辑区显示数字、多段 composition 无候选、简码抢占单字位

### 更早
- 分词组词、首两笔选字、联想四层模型、以词定字、连打、自动上屏

---

## 🙏 参考与致谢

- **白霜拼音**（gaboolic/rime-frost）：主词库语料
- **万象拼音**（amzxyz/rime-wanxiang）：联想机制、predict 接入、短语库
- **键道·我流**（pingshunhuangalex/rime-keydo）：顶功自动上屏、衔接词优先
- **oh-my-rime**（Mintimate/oh-my-rime）：以词定字
- **雾凇拼音**（iDvel/rime-ice）：词库净化思路
- **Rime / librime / librime-lua**：引擎与 Lua 扩展

## 📄 License

方案代码与词库遵循各自上游项目的开源协议；使用请保留来源说明。
