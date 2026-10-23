-- select_character.lua: 以词定字（移植自 oh-my-rime / rime-lua-select-character）
-- 功能：候选区有词时，按「Control+[」上屏该词的第一个字，按「Control+]」上屏最后一个字。
-- 说明：触发键避开笔画方案的 [（下移）和 ]（降权），改用 Control 组合键；可用配置覆盖。
-- 挂载：lua_processor@*select_character
-- 配置：
--   select_character:
--     first_key: "Control+bracketleft"    # 取首字
--     last_key: "Control+bracketright"     # 取末字

local M = {}

local function utf8_sub(s, i, j)
  i = i or 1
  j = j or -1
  if i < 1 or j < 1 then
    local n = utf8.len(s)
    if not n then return nil end
    if i < 0 then i = n + 1 + i end
    if j < 0 then j = n + 1 + j end
    if i < 0 then i = 1 elseif i > n then i = n end
    if j < 0 then j = 1 elseif j > n then j = n end
  end
  if j < i then return '' end
  i = utf8.offset(s, i)
  j = utf8.offset(s, j + 1)
  if i and j then
    return s:sub(i, j - 1)
  elseif i then
    return s:sub(i)
  else
    return ''
  end
end

local function first_character(s)
  return utf8_sub(s, 1, 1)
end

local function last_character(s)
  return utf8_sub(s, -1, -1)
end

-- 取候选词的指定字，清空输入，只返回该字（不混入联想候选/已确认文本）
local function pick_character(ctx, fun)
  local cand = ctx:get_selected_candidate()
  if not cand or not cand.text then return nil end
  local selected = fun(cand.text)
  if not selected or selected == '' then return nil end
  -- 清空当前 composition（笔画方案中整个词是单个候选，无需保留已确认部分；
  -- 不用 clear_previous_segment+get_commit_text，避免截断后混入联想候选文本）
  pcall(function() ctx:clear() end)
  return selected
end

-- 提交文本（薄荷方案用 engine:commit_text；回退 ctx:commit_text）
local function commit_text(env, ctx, text)
  local ok = false
  pcall(function()
    if env.engine and env.engine.commit_text then
      env.engine:commit_text(text)
      ok = true
    end
  end)
  if not ok then
    pcall(function() ctx:commit_text(text) end)
  end
end

function M.func(key_event, env)
  local ctx = env.engine and env.engine.context
  if not ctx then return 2 end

  -- 用 keycode 匹配（\=0x5c、;=0x3b），repr 作为备选（元书 repr 格式可能不同）
  local keycode = key_event.keycode
  local key_repr = ''
  pcall(function() key_repr = key_event:repr() or '' end)

  local first_key = 'backslash'
  local last_key = 'semicolon'
  local config = env.engine and env.engine.schema and env.engine.schema.config
  if config then
    first_key = config:get_string('select_character/first_key') or first_key
    last_key = config:get_string('select_character/last_key') or last_key
  end

  local function is_first_key()
    if keycode == 0x5c then return true end  -- 反斜杠 \
    if key_repr == first_key or key_repr == '\\' or key_repr == 'Control+bracketleft' then return true end
    return false
  end
  local function is_last_key()
    if keycode == 0x3b then return true end  -- 分号 ;
    if key_repr == last_key or key_repr == ';' or key_repr == 'Control+bracketright' then return true end
    return false
  end

  local has_menu = false
  pcall(function() has_menu = ctx:has_menu() end)

  -- 只要有候选词（不分输入中/空输入联想），就以词定字取首/尾字。
  local function is_real_candidate()
    local cand = ctx:get_selected_candidate()
    if not cand or not cand.text or cand.text == '' then return false end
    return true
  end

  -- 总是消费这两个键（避免漏给后续处理器造成误提交/清空候选区）
  if is_first_key() then
    if has_menu and is_real_candidate() then
      local text = pick_character(ctx, first_character)
      if text then
        commit_text(env, ctx, text)
      end
    end
    return 1
  end

  if is_last_key() then
    if has_menu and is_real_candidate() then
      local text = pick_character(ctx, last_character)
      if text then
        commit_text(env, ctx, text)
      end
    end
    return 1
  end

  return 2
end

return M