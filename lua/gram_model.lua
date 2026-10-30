-- gram_model.lua
-- 借鉴 Rime::Grammar（wanxiang-lts-zh-hans.gram）语言模型设计，
-- 为 hspnv 笔画方案构建的轻量 n-gram 搭配语言模型。
--
-- Rime::Grammar 思路：
--   给定「前文上下文 + 候选词」，用 n-gram 语言模型打分（collocation 搭配判定 +
--   预训练 bigram/trigram 命中），分值越高越合理。
-- 本模块用方案已有的离线语料模型（next_words_big / next_words_tri，源自万象 ARPA
--   Top 50 万真实语料）和主词库（words，含扩展词）实现等价查询，
--   返回 0~1 的「搭配合理性」分数，供联想候选排序使用。
--
-- 配置（在 stroke_hspnv_learning.schema.yaml 的 gram_model: 段）：
--   gram_model:
--     enable: true        # 是否在联想排序中启用语言模型分（默认 true）
--     weight: 60000       # 语言模型分放大倍数（用于联想排序）
--     collocation_min: 2  # 词典搭配最短字数
--     collocation_max: 6  # 词典搭配最长字数

local M = {}

local next_words_big = require('next_words_big')
local next_words_tri = require('next_words_tri')
local ok_words, words = pcall(require, 'words')
if not ok_words or type(words) ~= 'table' then
  words = {}
end
-- 大语言模型搭配表（由 stroke-zh-hans.gram 提取，源自 wanxiang-lts-zh-hans.gram 418MB 模型）
-- gram_stroke（2.7MB 源码 / 15MB 运行时）按需加载：只有真正查询搭配分时才载入，
-- 避免「启用了语法模型但整局没用到」时白占内存（P1 优化，2026-10-30）。
local gram_stroke = nil
local gram_stroke_checked = false
local function ensure_gram_stroke()
  if gram_stroke_checked then return gram_stroke end
  gram_stroke_checked = true
  local ok_gs, v = pcall(require, 'gram_stroke')
  if ok_gs and type(v) == 'table' then gram_stroke = v end
  return gram_stroke
end

-- 默认配置（可在 schema 覆盖，由 segment_phrase 调用 configure 传入）
local COLLOCATION_MIN = 2
local COLLOCATION_MAX = 6

function M.configure(cfg)
  if not cfg then return end
  if cfg.collocation_min then COLLOCATION_MIN = cfg.collocation_min end
  if cfg.collocation_max then COLLOCATION_MAX = cfg.collocation_max end
end

local function utf8_count(s)
  local n = 0
  for _ in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
    n = n + 1
  end
  return n
end

-- 从 context 中提取最后一个词（context 可能是 "前1词" 或 "前1\t前2"）
local function last_word(context)
  local tab = context:find('\t', 1, true)
  if tab then
    return context:sub(tab + 1)
  end
  return context
end

-- 核心查询：给定前文上下文 + 候选词，返回 0~1 搭配合理性分数。
-- context：上屏历史上下文（可为 前1词 或 "前1\t前2"）；word：候选词。
function M.query(context, word)
  ensure_gram_stroke()
  if not context or context == '' or not word or word == '' then
    return 0
  end
  -- 1. trigram 命中（前两词 + 当前词，最高置信）
  local tri = next_words_tri[context]
  if tri then
    for _, x in ipairs(tri) do
      if x == word then return 1.0 end
    end
  end
  -- 2. bigram 命中（前一词 + 当前词）
  local prev = last_word(context)
  local big = next_words_big[prev]
  if big then
    for _, x in ipairs(big) do
      if x == word then return 0.9 end
    end
  end
  -- 3. 大语言模型搭配（stroke-zh-hans.gram 提取的高频词串，源自 wanxiang 418MB 模型）
  local combined = prev .. word
  local n = utf8_count(combined)
  if gram_stroke and n >= COLLOCATION_MIN and n <= COLLOCATION_MAX then
    local v = gram_stroke[combined]
    if v then
      -- value = int(log(freq)*10000)，越高搭配越强；映射到 0.75~1.0
      return math.min(1.0, 0.75 + v / 800000)
    end
  end
  -- 4. 词典 collocation：prev..word 构成 2~6 字词典词（如 我想/吃饭/没问题）
  if n >= COLLOCATION_MIN and n <= COLLOCATION_MAX and words[combined] then
    return 0.7
  end
  -- 5. 高频词兜底（在词库中且词频较高，作为弱搭配）
  local wf = words[word] or 0
  if wf >= 5000 then return 0.3 end
  if wf > 0 then return 0.1 end
  return 0
end

-- 供调试/测试：返回模块信息
function M.info()
  return {
    collocation_min = COLLOCATION_MIN,
    collocation_max = COLLOCATION_MAX,
    bigram_keys = 0,
    trigram_keys = 0,
    words = 0,
  }
end

return M