-- Windower-only platform dependencies. The application receives this explicit host table.
local https_ok, ssl = pcall(require, 'ssl')
local http = require('socket.http')
local socket = require('socket')
local https = https_ok and loadfile(windower.addon_path .. 'lib/verified-https.lua')().new(
  http,socket,ssl,windower.addon_path .. 'assets/cacert.pem') or nil
local host = {
  metadata = _addon,
  addon_path = windower.addon_path,
  game_path = windower.ffxi_path,
  config = require('config'),
  http = http, network_socket=socket, network_ssl=https_ok and ssl or nil,
  ltn12 = require('ltn12'),
  https_ok = https_ok, https = https,
  texts = require('texts'),
  panel = loadfile(windower.addon_path .. 'lib/panel.lua')(),
  field = loadfile(windower.addon_path .. 'lib/field.lua')(),
}
host.panel.pointer_alignment=loadfile(windower.addon_path..'lib/windower-pointer.lua')().new(windower.get_windower_settings)
host.panel.pointer_coordinates=host.panel.pointer_alignment.map
host.pointer_status=host.panel.pointer_alignment.describe
host.client_reader = loadfile(windower.addon_path .. 'lib/windower-state.lua')().new(
  function() return windower.ffxi.get_player() end,
  function() return windower.ffxi.get_party() end
)
function host.logged_in()
  local info = windower.ffxi.get_info and windower.ffxi.get_info()
  return info and info.logged_in or false
end
function host.resources() return require('resources') end
function host.read_jobs()
  local p=windower.ffxi.get_player()
  if not p then return nil end
  return {name=p.name,levels=p.jobs or {}, main={job=p.main_job,level=p.main_job_level}, sub={job=p.sub_job,level=p.sub_job_level}}
end
function host.read_target()
  local target=windower.ffxi.get_mob_by_target('t')
  return target and target.name or nil
end
function host.read_treasure() return windower.ffxi.get_items('treasure') end
function host.register_event(name, fn) return windower.register_event(name, fn) end
function host.chat(colour, text) return windower.add_to_chat(colour, text) end
function host.open_url(url)
  if type(windower.open_url) ~= 'function' then return false end
  windower.open_url(url)
  return true
end
function host.chat_is_open() return windower.chat.is_open() end
function host.get_chat_draft()
  return windower.chat.get_input()
end
function host.set_chat_draft(text)
  windower.chat.set_input(text)
  return true
end
return host
