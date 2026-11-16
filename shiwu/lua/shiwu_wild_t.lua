-- 十五键笔画 · 通配符展开（多路径 + 自诊断）
local ALPHA = 'qwertasdfghjklm'
local MAX_CODES = 400

local kvdb, db, err_msg, tried

local function fsize(p)
  local f = io.open(p, 'rb')
  if not f then return -1 end
  local sz = f:seek('end')
  f:close()
  return sz or -2
end

local function init()
  if db or err_msg then return end
  local ok, mod = pcall(require, 'shiwu_wild.kvdb')
  if not ok then
    err_msg = 'REQ:' .. tostring(mod):gsub('^.-: ', ''):sub(1, 30)
    return
  end
  kvdb = mod
  local paths = {}
  local okapi, ud = pcall(function() return rime_api.get_user_data_dir() end)
  if okapi and ud and ud ~= '' then
    paths[#paths + 1] = ud .. '/lua/shiwu_wild/idx.bin'
    paths[#paths + 1] = ud .. '/shiwu_wild/idx.bin'
  end
  paths[#paths + 1] = 'lua/shiwu_wild/idx.bin'
  paths[#paths + 1] = './lua/shiwu_wild/idx.bin'
  tried = {}
  for _, p in ipairs(paths) do
    local sz = fsize(p)
    tried[#tried + 1] = p:sub(-24) .. ':' .. sz
    if sz > 0 then
      local ok2, d = pcall(function() return kvdb.open(p) end)
      if ok2 and d then db = d; return end
    end
  end
  err_msg = 'NOIDX ' .. table.concat(tried, ' ')
end

local function expand(pat)
  local parts = { pat }
  local stars = 0
  for i = 1, #pat do
    if pat:sub(i, i) == '*' then
      stars = stars + 1
      if stars > 2 then break end
      local nxt = {}
      for _, p in ipairs(parts) do
        for c in ALPHA:gmatch('.') do
          nxt[#nxt + 1] = p:sub(1, i - 1) .. c .. p:sub(i + 1)
        end
      end
      parts = nxt
      if #parts > MAX_CODES then
        local keep = {}
        for k = 1, MAX_CODES do keep[k] = parts[k] end
        parts = keep
        break
      end
    end
  end
  return parts
end

local function translator(input, seg, env)
  if not input or input == '' then return end
  if not input:find('*', 1, true) then return end
  init()
  if err_msg then
    yield(Candidate('shiwu_wild', seg.start, seg._end, err_msg:sub(1, 60), ' 诊断'))
    return
  end
  local codes = expand(input)
  local seen, out = {}, {}
  for _, c in ipairs(codes) do
    local items = db:get_list(c)
    if items then
      for _, it in ipairs(items) do
        local w, f = it[1], it[2]
        if w and not seen[w] then
          seen[w] = true
          out[#out + 1] = { w, f or 0, c }
        end
      end
    end
  end
  if #out == 0 then
    yield(Candidate('shiwu_wild', seg.start, seg._end, 'NOEXP:' .. #codes .. '码', ' 诊断'))
    return
  end
  table.sort(out, function(a, b) return a[2] > b[2] end)
  local n = #out
  if n > 30 then n = 30 end
  for i = 1, n do
    yield(Candidate('shiwu_wild', seg.start, seg._end, out[i][1], ' ' .. out[i][3]))
  end
end

return translator
