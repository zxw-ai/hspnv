-- lua/demote_filter.lua
-- 手动降权过滤器：把降权词沉底或隐藏（对任意来源候选生效）
--
-- 挂载：lua_filter@*demote_filter（放在 super_sequence*F 之后、uniquifier 之前）
-- 数据：用户目录 demote.user.tsv（由 lua/demote.lua 处理器写入），每行 词<TAB>时间戳
-- 每次过滤都重新读取文件，确保处理器刚降权的词立即生效（不依赖模块共享状态）。
--
-- 配置（stroke_bg5cgq_learning.schema.yaml 的 demote: 段）：
--   mode: demote   # demote=沉底（默认）；hide=直接隐藏

local DEMOTE_FILE = 'demote.user.tsv'

local function user_dir()
  if rime_api and rime_api.get_user_data_dir then
    local d = rime_api:get_user_data_dir()
    if d and d ~= '' then return d end
  end
  return '.'
end

-- 每次调用都从文件重新读取降权词表
local function load_demote()
  local set = {}
  local d = user_dir()
  local path = d .. '/' .. DEMOTE_FILE
  local f = io.open(path, 'r')
  if f then
    for line in f:lines() do
      local w = line:match('^([^\t]+)\t%d+$') or line:match('^([^\t]+)$')
      if w and w ~= '' then
        set[w] = true
      end
    end
    f:close()
  end
  return set
end

local function filter(input, env)
  local demoted = load_demote()

  -- 降权表为空：原样透传，零开销
  if not next(demoted) then
    for cand in input:iter() do
      yield(cand)
    end
    return
  end

  -- 读取模式配置：demote=沉底（默认），hide=隐藏
  local mode = 'demote'
  local config = env and env.engine and env.engine.schema and env.engine.schema.config
  if config then
    local m = config:get_string('demote/mode')
    if m == 'hide' then mode = 'hide' end
  end

  local normal = {}
  local demoted_cands = {}

  for cand in input:iter() do
    local text = cand.text
    if text and demoted[text] then
      if mode ~= 'hide' then
        demoted_cands[#demoted_cands + 1] = cand
      end
    else
      normal[#normal + 1] = cand
    end
  end

  -- 先输出正常候选，降权词全部沉到末尾（hide 模式直接不输出）
  for _, cand in ipairs(normal) do
    yield(cand)
  end
  for _, cand in ipairs(demoted_cands) do
    yield(cand)
  end
end

return filter