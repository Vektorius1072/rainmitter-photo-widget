-- PhotoWidget.lua — вертикальная галерея для Rainmeter.
-- Версия 4.1 (слежение за курсором через полоски, без мигания при смене фото). Архитектура 3.8: один viewport-контейнер, три Image meter,
-- относительное позиционирование слотов и обновление только смещения ленты.

local IMG = { jpg = true, jpeg = true, png = true, bmp = true, webp = true, gif = true }
local files, order, count
local W, H, R, INTERVAL, THR, SCALE, GAP, T_SHRINK, T_SLIDE, SHUFFLE, BG, DRAG_FOLLOW
local state, mode, scanT0
local cur, vals, tweens
local lastChange, lastFrame
local downX, downY, dragOff, dragVisualOff
local dragVelocity, lastDragY, lastDragT
local cache
local rel, pending
local SLOTS = { 'ImgPrev', 'ImgCurrent', 'ImgNext' }

local function log(msg, level)
  SKIN:Bang('!Log', 'PhotoWidget: ' .. msg, level or 'Notice')
end

local function num(name, default)
  local v = tonumber(SKIN:GetVariable(name))
  if v == nil then return default end
  return v
end

local function round(v) return math.floor(v + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function wrap(i)
  return ((i - 1) % count) + 1
end

local function path(i)
  if count == 0 then return '' end
  return files[order[wrap(i)]]
end

local function setOption(meter, option, value)
  value = tostring(value)
  local key = meter .. '.' .. option
  if cache[key] == value then return false end
  cache[key] = value
  SKIN:Bang('!SetOption', meter, option, value)
  return true
end

-- Начальная раскладка фото по слотам (при загрузке/перезагрузке списка).
-- Дальше слоты не перезагружаются: они меняются ролями, а в каждый момент
-- подгружается только одно новое фото и только за кадром.
local function updateSlots()
  for i, meter in ipairs(SLOTS) do
    local p = ''
    if rel[i] == 0 or count > 1 then p = path(cur + rel[i]) end
    setOption(meter, 'ImageName', p)
  end
  SKIN:Bang('!UpdateMeterGroup', 'PhotoSlots')
  SKIN:Bang('!Redraw')
end

local function reset()
  files, order, count = {}, {}, 0
  state, mode = 'loading', 'idle'
  cur = 1
  rel = { -1, 0, 1 } -- роль каждого слота: -1 сверху, 0 по центру, 1 снизу
  pending = nil
  vals = { s = 0, off = 0 }
  tweens = {}
  lastChange = os.clock()
  lastFrame = lastChange
  downX, downY, dragOff, dragVisualOff = nil, nil, nil, nil
  dragVelocity, lastDragY, lastDragT = 0, nil, nil
  cache = {}
  setOption('ImgPrev', 'ImageName', '')
  setOption('ImgCurrent', 'ImageName', '')
  setOption('ImgNext', 'ImageName', '')
  setOption('ImgPrev', 'ImageAlpha', 0)
  setOption('ImgNext', 'ImageAlpha', 0)
end

function Initialize()
  W = round(num('W', 300))
  H = round(num('H', 300))
  R = round(num('R', 28))
  INTERVAL = num('Interval', 10)
  THR = num('Threshold', 35)
  DRAG_FOLLOW = math.max(num('DragFollow', 90), 1)
  SCALE = num('ShrinkScale', 0.72)
  GAP = num('Gap', 10)
  T_SHRINK = math.max(num('ShrinkTime', 0.24), 0.01)
  T_SLIDE = math.max(num('SlideTime', 0.42), 0.01)
  SHUFFLE = num('Shuffle', 0) == 1
  BG = SKIN:GetVariable('BgColor') or '58,58,60'
  math.randomseed(os.time())
  math.random()
  reset()
end

local function render()
  local s = vals.s
  local off = (mode == 'pressed' and dragVisualOff ~= nil) and dragVisualOff or vals.off
  local scale = 1 - (1 - SCALE) * s
  local cw, ch = round(W * scale), round(H * scale)
  local x0, y0 = round((W - cw) / 2), round((H - ch) / 2)
  local step = ch + GAP * s
  local dirty = false

  if cache.geometryW ~= cw or cache.geometryH ~= ch then
    cache.geometryW, cache.geometryH = cw, ch
    for _, meter in ipairs(SLOTS) do
      setOption(meter, 'W', cw)
      setOption(meter, 'H', ch)
    end
    dirty = true
  end

  -- Соседние фото видны, пока лента уменьшена или движется.
  -- В полном размере они всё равно за кадром.
  local neighborsVisible = count > 1 and (s > 0.02 or math.abs(off) > 0.025)

  for i, meter in ipairs(SLOTS) do
    local y = y0 + round((rel[i] - off) * step)
    dirty = setOption(meter, 'X', x0) or dirty
    dirty = setOption(meter, 'Y', y) or dirty
    dirty = setOption(meter, 'ImageAlpha', (rel[i] == 0 or neighborsVisible) and 255 or 0) or dirty

    -- Новое фото подгружаем в тот слот, который сейчас полностью за кадром,
    -- поэтому на экране не видно ни мигания, ни подвисания.
    if pending and pending.slot == i and not pending.done and (y + ch <= 0 or y >= H) then
      setOption(meter, 'ImageName', pending.path)
      SKIN:Bang('!UpdateMeter', meter)
      pending.done = true
      dirty = true
    end
  end

  local bgAlpha = round(255 * s)
  if cache.bgAlpha ~= bgAlpha then
    cache.bgAlpha = bgAlpha
    setOption('MeterBg', 'Shape',
      string.format('Rectangle 0,0,%d,%d,%d | Fill Color %s,%d | StrokeWidth 0', W, H, R, BG, bgAlpha))
    SKIN:Bang('!UpdateMeter', 'MeterBg')
    dirty = true
  end

  if dirty then
    SKIN:Bang('!UpdateMeterGroup', 'PhotoSlots')
    SKIN:Bang('!Redraw')
  end
end

local function ease(t)
  -- Smoothstep quintic: мягкий старт и остановка.
  return t * t * t * (t * (t * 6 - 15) + 10)
end

local function tween(key, target, duration, done)
  tweens[key] = {
    from = vals[key], to = target, start = os.clock(),
    duration = math.max(duration, 0.01), done = done
  }
end

local function stepTweens(now)
  local active = false
  local keys = {}
  for key in pairs(tweens) do keys[#keys + 1] = key end
  for _, key in ipairs(keys) do
    local a = tweens[key]
    if a then
      local t = (now - a.start) / a.duration
      if t >= 1 then
        vals[key] = a.to
        tweens[key] = nil
        if a.done then a.done() end
      else
        vals[key] = a.from + (a.to - a.from) * ease(t)
      end
      active = true
    end
  end
  return active
end

local function expand()
  tween('s', 0, T_SHRINK * math.max(vals.s, 0.3), function()
    mode = 'idle'
    vals.off = 0
    lastChange = os.clock()
    render()
  end)
end

local function finishSlide(dir)
  cur = wrap(cur + dir)
  -- Вращаем роли слотов: ни одно видимое фото не перезагружается.
  for i = 1, #SLOTS do
    rel[i] = rel[i] - dir
    if rel[i] < -1 then rel[i] = 1 elseif rel[i] > 1 then rel[i] = -1 end
  end
  -- Если подгрузка за кадром не успела (очень быстрый жест), делаем её сейчас
  if pending and not pending.done then
    setOption(SLOTS[pending.slot], 'ImageName', pending.path)
    SKIN:Bang('!UpdateMeter', SLOTS[pending.slot])
  end
  pending = nil
  vals.off = 0
  render()
  expand()
end

local function startSlide(dir, duration)
  -- Слот, который уедет за кадр, получит фото на другой стороне ленты
  pending = { slot = nil, path = path(cur + 2 * dir), done = false }
  for i = 1, #SLOTS do
    if rel[i] == -dir then pending.slot = i end
  end
  tween('off', dir, duration, function() finishSlide(dir) end)
end

local function advance(dir)
  if count < 2 then return end
  mode = 'busy'
  local function slide() startSlide(dir, T_SLIDE) end
  if vals.s < 0.99 then
    tween('s', 1, T_SHRINK * (1 - vals.s), slide)
  else
    vals.s = 1
    slide()
  end
end

local function startScan()
  state = 'scanning'
  scanT0 = os.clock()
  SKIN:Bang('!CommandMeasure', 'mScan', 'Run')
end

function Loaded()
  if state ~= 'scanning' then return end
  local folder = SKIN:ReplaceVariables(SKIN:GetVariable('Folder') or '')
  folder = folder:gsub('[\\/]+$', '')
  local f = io.open(SKIN:ReplaceVariables('#CURRENTPATH#') .. 'files.txt', 'rb')
  if not f then
    state = 'empty'
    log('cannot open files.txt (scan failed)', 'Error')
    return
  end
  local first = true
  for line in f:lines() do
    line = line:gsub('\r', '')
    if first then
      line = line:gsub('^\239\187\191', '')
      first = false
    end
    local ext = line:match('%.(%w+)$')
    if ext and IMG[ext:lower()] then
      files[#files + 1] = folder .. '\\' .. line
    end
  end
  f:close()
  count = #files
  if count == 0 then
    state = 'empty'
    log('no images found in: ' .. folder, 'Error')
    return
  end
  for i = 1, count do order[i] = i end
  if SHUFFLE then
    for i = count, 2, -1 do
      local j = math.random(i)
      order[i], order[j] = order[j], order[i]
    end
  end
  cur = 1
  updateSlots()
  state, mode = 'ready', 'idle'
  render()
  lastChange = os.clock()
  log('loaded photos: ' .. count)
end

function Update()
  if state == 'loading' then
    startScan()
    return 0
  elseif state == 'scanning' then
    if os.clock() - scanT0 > 8 then
      state = 'empty'
      log('scan timed out', 'Error')
    end
    return 0
  elseif state ~= 'ready' then
    return 0
  end

  local now = os.clock()
  local dt = clamp(now - (lastFrame or now), 0.001, 0.05)
  lastFrame = now
  local changed = stepTweens(now)

  if mode == 'pressed' then
    local previous = dragVisualOff or 0
    local alpha = 1 - math.exp(-DRAG_FOLLOW * dt)
    dragVisualOff = previous + ((dragOff or 0) - previous) * alpha
    if math.abs((dragOff or 0) - dragVisualOff) < 0.0005 then
      dragVisualOff = dragOff or 0
    end
    if math.abs(dragVisualOff - previous) > 0.0001 then changed = true end
  end

  if changed then render() end
  if mode == 'idle' and count > 1 and INTERVAL > 0 and now - lastChange >= INTERVAL then
    advance(1)
  end
  return 0
end

function Step(dir)
  if state ~= 'ready' or mode ~= 'idle' then return end
  advance(dir)
end

function Down(x, y)
  if state ~= 'ready' or mode ~= 'idle' then return end
  downX, downY = tonumber(x), tonumber(y)
  if not downX or not downY then return end
  dragOff, dragVisualOff = 0, 0
  dragVelocity = 0
  lastDragY, lastDragT = downY, os.clock()
  mode = 'pressed'
  tween('s', 1, T_SHRINK * (1 - vals.s))
  render()
end

function Drag(x, y)
  if mode ~= 'pressed' or not downY then return end
  y = tonumber(y)
  if not y then return end
  local dy = y - downY
  local step = math.max(H * SCALE + GAP, 1)
  local now = os.clock()
  if lastDragY and lastDragT then
    local sampleDt = now - lastDragT
    if sampleDt > 0.001 then
      local sampleV = clamp((y - lastDragY) / sampleDt, -3000, 3000)
      dragVelocity = dragVelocity * 0.55 + sampleV * 0.45
    end
  end
  lastDragY, lastDragT = y, now
  dragOff = clamp(-dy / step, -1, 1)
end

function Up(x, y)
  if mode ~= 'pressed' or not downY then return end
  x, y = tonumber(x), tonumber(y)
  if y then Drag(x or downX, y) end

  local dy = (y or downY) - downY
  local dx = (x or downX) - downX
  local offset = dragVisualOff or dragOff or 0
  local velocity = dragVelocity or 0
  local step = math.max(H * SCALE + GAP, 1)
  local projected = offset - (velocity * 0.10 / step)

  downX, downY, dragOff, dragVisualOff = nil, nil, nil, nil
  dragVelocity, lastDragY, lastDragT = 0, nil, nil
  mode = 'busy'
  vals.off = offset

  local vertical = math.abs(dy) > math.abs(dx)
  local distanceSwipe = math.abs(dy) >= THR and vertical
  local quickFlick = math.abs(velocity) >= 520 and math.abs(dy) > 12 and vertical
  if (distanceSwipe or quickFlick) and count > 1 then
    local dir = math.abs(projected) > 0.08 and (projected > 0 and 1 or -1) or (dy < 0 and 1 or -1)
    local remaining = math.max(0.12, math.abs(dir - offset))
    startSlide(dir, T_SLIDE * remaining)
  else
    tween('off', 0, T_SLIDE * math.max(0.15, math.abs(offset)), function()
      vals.off = 0
      expand()
    end)
  end
end

function CancelPress()
  if mode ~= 'pressed' then return end
  vals.off = dragVisualOff or 0
  downX, downY, dragOff, dragVisualOff = nil, nil, nil, nil
  dragVelocity, lastDragY, lastDragT = 0, nil, nil
  mode = 'busy'
  tween('off', 0, T_SLIDE * math.max(0.15, math.abs(vals.off)), function()
    vals.off = 0
    expand()
  end)
end

function Reload()
  reset()
end

-- ===== Слежение за курсором через полоски (см. [StripN] в .ini) =====
local STRIPS = 75

local function stripY(k, my)
  return (k * H / STRIPS) + (tonumber(my) or 0)
end

-- Курсор въехал в полоску k: если кнопка зажата, фото следует за ним
function Hover(k)
  if mode ~= 'pressed' then return end
  Drag(0, (k + 0.5) * H / STRIPS)
end

function DownS(k, mx, my)
  Down(mx, stripY(k, my))
end

function UpS(k, mx, my)
  Up(mx, stripY(k, my))
end

-- Курсор покинул виджет с зажатой кнопкой: считаем это отпусканием
function Release()
  if mode ~= 'pressed' then return end
  Up(downX, lastDragY or downY)
end
