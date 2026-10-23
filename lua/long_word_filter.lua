-- long_word_filter.lua: 长词优先（借鉴雾凇拼音 long_word_filter）
-- 场景：笔画短码/前缀输入时，候选区前几个常是单字，多字词容易被淹没。
-- 此过滤器把「比首候选更长」的词插入到第 idx 位之后（默认第 4、5 位），短词沉后。
-- 保护：若前 idx-1 个候选中已有多字词（如完整码输入、自动分词已把词置顶），则原样透传不干预。
--
-- 挂载：lua_filter@*long_word_filter（放在 super_sequence*F 之后、demote_filter 之前）
-- 配置：
--   long_word_filter:
--     count: 2    # 最多提升的词数
--     idx: 4      # 提升到第 idx 位起

local M = {}

function M.init(env)
  local config = env.engine.schema.config
  if not config then return end
  env.name_space = (env.name_space or ''):gsub("^*", "")
  M.count = config:get_int(env.name_space .. '/count') or 2
  M.idx = config:get_int(env.name_space .. '/idx') or 4
end

function M.func(input)
  -- 把所有候选读入数组（librime 的 input:iter() 在不同实现下行为有差异，读数组最稳）
  local cands = {}
  for cand in input:iter() do
    cands[#cands + 1] = cand
  end
  if #cands < 2 then
    for _, c in ipairs(cands) do yield(c) end
    return
  end

  local M_id = M.idx or 4
  local M_count = M.count or 2

  -- 保护：前 idx-1 个候选中已有多字词（长度>=2）则原样透传
  local has_word_in_front = false
  for i = 1, math.min(#cands, M_id - 1) do
    local t = cands[i] and cands[i].text
    if t and utf8.len(t) >= 2 then
      has_word_in_front = true
      break
    end
  end
  if has_word_in_front then
    for _, c in ipairs(cands) do yield(c) end
    return
  end

  local l = {}            -- 短词暂存（沉后）
  local firstWordLength = 0
  local done = 0
  local last_i = 0
  local i = 1
  for j = 1, #cands do
    local cand = cands[j]
    last_i = j
    local t = cand.text or ''
    local leng = utf8.len(t)
    if firstWordLength < 1 then
      firstWordLength = leng
    end
    if i < M_id then
      i = i + 1
      yield(cand)
    elseif leng <= firstWordLength or t:find("[%a%d]") then
      l[#l + 1] = cand
    else
      yield(cand)
      done = done + 1
    end
    if done >= M_count or #l > 50 then
      break
    end
  end

  -- 暂存的短词
  for _, cand in ipairs(l) do
    yield(cand)
  end
  -- 剩余未处理的候选
  for k = last_i + 1, #cands do
    yield(cands[k])
  end
end

return M