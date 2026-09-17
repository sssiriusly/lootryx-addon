-- Presentation of focused tools. Reuses existing actions; never performs I/O.
local M={relink=false}
local function copy(r) local t={};for k,v in pairs(r) do t[k]=v end;return t end
local function section(title) return {kind='header',title=title} end
function M.present(ctx,rows)
  if not ctx.board then return rows end
  local out,back={},nil
  for _,r in ipairs(rows) do
    if r.tag=='BACK' and r.action then back=r.action
    else out[#out+1]=copy(r) end
  end
  local roots={connection=true,macros=true,wishlist=true,myjobs=true,events=true,standings=true,more=true}
  if roots[ctx.board] then back=nil
  elseif back and ({bank=true,loot=true,bounties=true,statics=true,polls=true,item=true})[ctx.board] then
    back={id='board:hub',label='Back to tools'}
  end
  if out[1] and (out[1].kind=='header' or out[1].kind=='pagehead') then
    out[1].kind='pagehead';out[1].actions=back and {back} or out[1].actions
  elseif back then table.insert(out,1,{kind='toolbar',actions={back}}) end
  local board=ctx.board
  if board=='connection' then
    local result={out[1]}
    if ctx.tier=='member' and not M.relink then
      result[1].title='Character connection'
      result[#result+1]={kind='banner',title=ctx.name..' is linked',subtitle=ctx.world..' / '..ctx.shell}
      result[#result+1]={kind='text',text='This addon is connected to your Lootryx account. Re-link only if you intend to replace this connection.'}
      for _,r in ipairs(out) do if r.kind=='text' then result[#result+1]=r end end
      result[#result+1]={kind='toolbar',actions={{id='connection:relink',label='Re-link character'}}}
      return result
    end
    if ctx.tier=='member' then result[1].actions={{id='connection:cancel',label='Cancel re-link'}} end
    result[1].subtitle=ctx.name..' / '..ctx.world
    result[#result+1]={kind='banner',title=ctx.tier=='member' and 'This character is linked' or 'Connect to your Lootryx account',
      subtitle=ctx.tier=='member' and ('Current linkshell: '..ctx.shell) or 'Get a pairing code on the website, then paste it below.'}
    result[#result+1]=section('Pair with your website account')
    local submit,other_options
    for i=2,#out do
      local r=out[i];local id=r.action and r.action.id
      if id=='setup:open' then result[#result+1]={kind='toolbar',title='1. Get a one-use pairing code',actions={{id=id,label='Get pairing code'}}}
      elseif id=='setup:go' then submit=r.action
      elseif id=='tools:world' or id=='tools:claim' then
        if not other_options then result[#result+1]=section('Other connection options');other_options=true end
        r.kind='banner';r.title=id=='tools:world' and 'Browse without an account' or 'Claim a public identity'
        r.subtitle=id=='tools:world' and 'Use party finder with an unverified character.' or 'For an identity created before linking an account.'
        result[#result+1]=r
      else result[#result+1]=r end
    end
    if submit then submit=copy(submit);submit.variant='primary';result[#result+1]={kind='actions',title='Pair this character',subtitle='Only submit a code issued for your account.',actions={submit}} end
    return result
  end
  if board=='statics' or board=='bounties' or board=='bank' or board=='loot' then
    local help={statics='Browse teams here. Apply or manage your team on the website.',bounties='Browse rewards here. Submit claims on the website.',bank='Browse stock here. Manage deposits and withdrawals on the website.',loot='Recorded drops. Open the website for item history and handoff details.'}
    table.insert(out,2,{kind='text',text=help[board]})
    table.insert(out,3,{kind='toolbar',actions={{id='boardweb:'..board,label=({statics='Open team board',bounties='Open bounty board',bank='Open bank',loot='Open loot history'})[board]}}})
  end
  if board=='macros' then return out end
  if board=='corrections' then
    out[1].subtitle='Choose who your attendance captures report.'
    for _,r in ipairs(out) do
      if r.action and r.action.id=='tools:correct' then r.kind='actions';r.action=copy(r.action);r.action.variant='primary';r.actions={r.action};r.action=nil
      elseif r.action and r.action.id=='tools:reset' then r.kind='toolbar';r.actions={r.action};r.action=nil;r.title='Reset to observed names'
      elseif not r.kind then r.kind='banner' end
    end
  elseif board=='statics' then
    for _,r in ipairs(out) do
      if not r.kind and r.meta then
        r.kind='record';r.columns={0.38,0.4,0.22};r.cells={{text=r.title},{text=r.subtitle,subtext=r.chip},{text=r.meta}}
      elseif not r.kind then r.kind='banner' end
    end
  elseif board=='polls' then
    for _,r in ipairs(out) do
      if r.action and r.action.id:sub(1,5)=='vote:' then
        r.kind='record';r.columns={0.5,0.3,0.2};r.cells={{text=r.title,subtext=r.tag=='YOURS' and 'Your vote' or nil},{text=r.meta,subtext='votes'}}
      elseif not r.kind and not r.action then r.kind='banner';r.subtitle=(r.subtitle or '')..(r.meta and (' / '..r.meta) or '') end
    end
  elseif board=='item' then
    for _,r in ipairs(out) do
      if r.item_name then r.kind='record';r.columns={0.5,0.5};r.cells={{text=r.title,subtext=r.subtitle},{text=r.meta,small=true}}
      elseif r.action and r.action.id=='item:go' then r.kind='toolbar';r.title='';r.actions={r.action};r.action=nil
      elseif not r.kind and not r.action then r.kind='text';r.text=r.title..': '..(r.subtitle or '')..(r.meta and (' / '..r.meta) or '') end
    end
  elseif board:sub(1,6)=='event:' then
    for _,r in ipairs(out) do
      if r.action and r.action.id:sub(1,5)=='rsvp:' then
        r.action=copy(r.action);r.action.label=r.title;r.kind='toolbar';r.title=r.subtitle;r.actions={r.action};r.action=nil
      elseif r.tag=='NOW' then r.kind='toolbar';r.title=r.title..' / Your current answer'
      elseif not r.kind then r.kind='banner';r.subtitle=(r.subtitle or '')..(r.meta and (' / '..r.meta) or '') end
    end
  end
  local body,footer={},nil
  for _,r in ipairs(out) do if r.kind=='actions' then footer=r else body[#body+1]=r end end
  if footer then body[#body+1]=footer end
  return body
end
return M
