-- auto_segment.lua: 连续笔画自动分词
-- 用户不按分词键连续输入多字笔画码时，自动识别 words.lua 中整词码完全等于输入的词，
-- 返回按词频排序的词候选（每字笔画数可不同，词码长度自适应）。
-- 用法: local auto_segment = require("auto_segment"); auto_segment.segment(input, max_n)
local words = require("words")
local stroke = require("stroke")

-- 完整码 -> {字,...}（含同码字）
local code_to_chars = {}
for ch, code in pairs(stroke) do
  local list = code_to_chars[code]
  if not list then list = {}; code_to_chars[code] = list end
  list[#list + 1] = ch
end

-- 首字 -> 以该字开头的全部词组（只索引纯汉字词，字节数 %3==0）
local char_words = {}
for w in pairs(words) do
  local n = #w
  if n >= 6 and n % 3 == 0 then
    local first = w:sub(1, 3)
    local bucket = char_words[first]
    if not bucket then bucket = {}; char_words[first] = bucket end
    bucket[#bucket + 1] = w
  end
end

local function is_pure_code(s)
  return s:match("^[1-5]+$") ~= nil
end

-- 判断词 w 的整词码是否完全等于 input（按字依次比对，码长自适应，提前剪枝）
local function word_code_matches(w, input)
  local n = #input
  local pos = 1
  local wpos = 1
  local wn = #w
  while wpos <= wn do
    local ch = w:sub(wpos, wpos + 2)
    local code = stroke[ch]
    if not code then return false end
    if pos + #code - 1 > n then return false end
    if input:sub(pos, pos + #code - 1) ~= code then return false end
    pos = pos + #code
    wpos = wpos + 3
  end
  return pos == n + 1
end

local M = {}

-- 结果缓存（LRU 简化版，容量 64）
local cache = {}
local cache_order = {}
local CACHE_LIMIT = 64

-- 快速边界可达性：input 能否切分为 >=2 个完整字码（用于预检，避免每次按键都遍历词桶）
local function has_multi_char_segmentation(input)
  local n = #input
  local min_seg = {}
  min_seg[0] = 0
  for i = 1, n do
    local best = nil
    local j0 = math.max(0, i - 24)
    for j = j0, i - 1 do
      if min_seg[j] ~= nil then
        local seg = input:sub(j + 1, i)
        if code_to_chars[seg] then
          local cand = min_seg[j] + 1
          if not best or cand < best then best = cand end
        end
      end
    end
    min_seg[i] = best
  end
  return (min_seg[n] or 0) >= 2
end

-- 自动分词：输入连续码串，返回按词频降序的词候选（最多 max_n 个）
function M.segment(input, max_n)
  max_n = max_n or 9
  if not input or input == "" then return {} end
  if not is_pure_code(input) then return {} end
  local n = #input
  if n < 2 or n > 60 then return {} end
  -- 预检：必须是可切分为 >=2 个完整字码的串，才做词库匹配
  if not has_multi_char_segmentation(input) then return {} end
  if cache[input] then return cache[input] end

  local seen = {}
  local hits = {}
  -- 枚举 input 的前缀作为"首字完整码"（首字笔画数通常 <= 24），反查首字，再遍历该首字词桶
  for l = 1, math.min(n, 24) do
    local first_code = input:sub(1, l)
    local first_chars = code_to_chars[first_code]
    if first_chars then
      for _, ch in ipairs(first_chars) do
        local bucket = char_words[ch]
        if bucket then
          for _, w in ipairs(bucket) do
            if not seen[w] and word_code_matches(w, input) then
              seen[w] = true
              hits[#hits + 1] = w
            end
          end
        end
      end
    end
  end

  table.sort(hits, function(a, b) return (words[a] or 0) > (words[b] or 0) end)
  local out = {}
  for i = 1, math.min(#hits, max_n) do out[i] = hits[i] end
  -- 写入缓存
  cache[input] = out
  cache_order[#cache_order + 1] = input
  if #cache_order > CACHE_LIMIT then
    cache[cache_order[1]] = nil
    table.remove(cache_order, 1)
  end
  return out
end

return M