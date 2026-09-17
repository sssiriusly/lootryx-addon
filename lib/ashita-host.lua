-- Ashita v4 host. One shared application; no command or payload implementation here.
local M = {}
function M.start(application)
  require('common')
  local imgui = require('imgui')
  local graphics = require('ffi')
  local d3d = require('d3d8')
  local codec = require('json')
  local http = require('socket.http')
  local ltn12 = require('socket.ltn12')
  local https_ok, ssl = pcall(require, 'socket.ssl')
  local socket = require('socket')
  local root = addon.path:gsub('\\', '/'):gsub('/+$', '') .. '/'
  local https=https_ok and loadfile(root .. 'lib/verified-https.lua')().new(http,socket,ssl,root .. 'assets/cacert.pem') or nil
  addon.name, addon.author, addon.version = 'Lootryx', 'Sirius', '0.40.26'
  local manager = AshitaCore:GetMemoryManager()
  local resources = AshitaCore:GetResourceManager()
  local R = loadfile(root .. 'lib/ashita-resources.lua')().new(resources, manager:GetInventory())
  local reader = loadfile(root .. 'lib/ashita-state.lua')().new(manager:GetParty(), R.job)
  local input = loadfile(root .. 'lib/ashita-input.lua')().new(AshitaCore:GetInputManager():GetKeyboard(), ashita.misc.get_clipboard)
  local make_panel = loadfile(root .. 'lib/ashita-panel.lua')().new
  local function format_text(text) return (tostring(text):gsub('//lootryx','/lootryx')) end
  local function panel_factory(gui,texture) return make_panel(gui,texture,format_text) end
  local textures = loadfile(root .. 'lib/ashita-textures.lua')().new(graphics,d3d,resources,root .. 'assets/')
  local storage = loadfile(root .. 'lib/ashita-storage.lua')().new(
    AshitaCore:GetInstallPath() .. '/config/lootryx', ashita.fs.exists, ashita.fs.create_directory)
  local owner, host, callbacks, failed = nil, nil, {}, false
  local retire_textures = false
  local function identity()
    local state=manager:GetPlayer()
    if not state or state:GetMainJob()==0 or state:GetIsZoning()~=0 then return nil end
    local player = reader.player()
    if not player or type(player.name) ~= 'string' or not player.name:match('^%a+$') then return nil end
    return player.name .. '_' .. string.format('%.0f',player.id)
  end
  local function stop(defer_textures)
    if callbacks.unload then pcall(callbacks.unload) end
    pcall(input.release)
    if host then pcall(host.texts.destroy);pcall(host.panel.destroy) end
    if defer_textures then retire_textures=true else textures.destroy() end
    callbacks, host = {}, nil
  end
  local function invoke(name,...)
    if not callbacks[name] then return false end
    local ok,result = pcall(callbacks[name],...)
    if not ok then
      stop();failed=true
      print('Lootryx: UI error; keyboard released. Reload Lootryx to retry.')
      return true
    end
    return result
  end
  local function current(allow_boot)
    local available, who = pcall(identity)
    if not available or not who then
      if host and host.jobs then host.jobs.cancel(true) end
      if host then pcall(host.field.blur) end
      return false
    end
    if who ~= owner then
      if not allow_boot then if host then pcall(host.field.blur) end;return false end
      stop();owner=who;failed=false
      local ok = pcall(function()
      host = {
        metadata=addon,addon_path=root,game_path=R.game_path(),client_reader=reader,
        http=http,network_socket=socket,network_ssl=https_ok and ssl or nil,ltn12=ltn12,https_ok=https_ok,https=https,
        panel=panel_factory(imgui,textures.get),
        field=loadfile(root .. 'lib/field.lua')(input),
        texts=loadfile(root .. 'lib/ashita-hud.lua')().new(panel_factory,imgui),
        config=loadfile(root .. 'lib/ashita-settings.lua')().new(storage,codec,identity),
        resources=R.resources,read_treasure=R.treasure,
        read_target=function()
          local target=manager:GetTarget();if not target then return nil end
          local index=target:GetTargetIndex(target:GetIsSubTargetActive()==0 and 0 or 1)
          if not index or index==0 then return nil end
          return manager:GetEntity():GetName(index)
        end,
        read_jobs=function()
          local p=manager:GetPlayer(); local me=reader.player(); if not p or not me then return nil end
          local levels={}
          for id=1,18 do local code=R.job(id);if code then levels[code]=p:GetJobLevel(id) end end
          return {name=me.name,levels=levels,main={job=me.main_job,level=p:GetMainJobLevel()},sub={job=me.sub_job,level=p:GetSubJobLevel()}}
        end,
        logged_in=function() return identity()==owner end,
        register_event=function(name,fn) callbacks[name]=fn end,
        chat=function(_,message) print(format_text(message)) end,
        chat_is_open=function() return AshitaCore:GetChatManager():IsInputOpen()==0x11 end,
        get_chat_draft=function() return AshitaCore:GetChatManager():GetInputTextRaw() end,
        set_chat_draft=function(text) AshitaCore:GetChatManager():SetInputText(text);return true end,
        open_url=function(url) ashita.misc.open_url(url);return true end,
      }
      application(host)
      end)
      if not ok then
        stop();failed=true
        print('Lootryx: startup failed; settings preserved. Check config/lootryx and reload.')
        return false
      end
      invoke('load')
    end
    return not failed and host ~= nil
  end
  ashita.events.register('d3d_present','lootryx_present',function()
    if retire_textures then textures.destroy();retire_textures=false end
    if not current(true) then return end
    invoke('prerender')
    if not host then return end
    local ok = pcall(function() textures.begin_frame();host.panel.present();host.texts.present() end)
    if not ok then
      stop(true);failed=true
      print('Lootryx: drawing failed; keyboard released. Reload Lootryx to retry.')
    end
  end)
  ashita.events.register('command','lootryx_command',function(e)
    local args=e.command:args()
    local command=tostring(args[1] or ''):lower()
    if command~='/lootryx' and command~='/lx' then return end
    e.blocked=true
    if current() then invoke('addon command',unpack(args,2))
    else print('Lootryx: log in with a character, then reload if startup failed.') end
  end)
  -- WNDPROC still delivers text input while our DirectInput block protects gameplay.
  -- lparam carries the scan code (bits 16..23), extended flag (24), and release (31).
  ashita.events.register('key','lootryx_keyboard',function(e)
    if not current() then return end
    local scan=math.floor(e.lparam / 65536) % 256
    if math.floor(e.lparam / 16777216) % 2 == 1 then scan=scan+128 end
    local down=math.floor(e.lparam / 2147483648) % 2 == 0
    if invoke('keyboard',scan,down,0,e.blocked) then e.blocked=true end
  end)
  ashita.events.register('mouse','lootryx_mouse',function(e)
    if e.blocked or not current() then return end
    local kind=({[512]=0,[513]=1,[514]=2,[522]=10})[e.message] or -1
    if invoke('mouse',kind,e.x,e.y,e.delta,e.blocked) then e.blocked=true
    elseif host then
      local ok, consumed=pcall(host.texts.mouse,kind,e.x,e.y)
      if not ok then stop();failed=true;e.blocked=true
      elseif consumed then e.blocked=true end
    end
  end)
  ashita.events.register('unload','lootryx_unload',function() stop() end)
end
return M
