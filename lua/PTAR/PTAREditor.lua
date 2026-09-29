-- /lua run PTAR/PTAREditor
-- Manual capture/editor only. No movement, door clicks, targeting, combat or TAC calls.
-- (It only records the optional TAC before/after events on waypoints, DL-013; the Runner is what sends them.)
local mq = require('mq')
local imgui = require('ImGui')
local core = require('PTAR.PTARRouteData')
local files = require('PTAR.PTARFiles')
local path_setup=require('PTAR.PTARPaths')
local version=require('PTAR.PTARVersion')
local paths,path_error=path_setup.prepare(mq.configDir)
if not paths then error('PTAR directory setup stopped: '..tostring(path_error)) end
local route,filename,selected,last_creation,last_capture
local state,message='Unsaved','Create or load a route.'
local file_draft={value='NewRoute'}
local import_draft={value=''}
local show_create=false; local show_register=false
local existing,existing_file={},nil
local name_draft={value='New Route'}
local description_draft={value=''}
local capture={label='',notes='',radius='',manual_handoff=false,door_after='continue',underwater_radius='5',exit_radius='5',tac_before='none',tac_after='none'}
local traverse_capture=nil
local action=1
local running=true
local edit={}; local edit_original={}; local route_edit={}; local route_edit_original={}
local pending_selection=nil; local delete_confirm_id=nil; local replace_confirm_id=nil
local TYPES={'normal','door','finish'}
local ACTIONS={
  {label='Add Waypoint',kind='normal',where='append'},
  {label='Capture Door',kind='door',where='append'},
  {label='Add Finish',kind='finish',where='append'},
  {label='Ground drop',kind='traverse',preset='ground'},
  {label='Drop into water',kind='traverse',preset='water_drop'},
  {label='Water crossing',kind='traverse',preset='water_cross'},
}
local CAPTURE_TYPES={
  {kind='normal',label='Waypoint'}, {kind='door',label='Door'}, {kind='finish',label='Finish'},
  {kind='traverse',preset='ground',label='Ground drop'},
  {kind='traverse',preset='water_drop',label='Drop into water'},
  {kind='traverse',preset='water_cross',label='Water crossing'},
}
for _,placement in ipairs({{where='before',label='Before'},{where='after',label='After'}}) do
  for _,kind in ipairs(TYPES) do
    local name=({normal='Waypoint',door='Door',finish='Finish'})[kind]
    ACTIONS[#ACTIONS+1]={label='Insert '..name..' '..placement.label,kind=kind,where=placement.where}
  end
end
local function capture_type_index()
  local current=ACTIONS[action]
  for i,choice in ipairs(CAPTURE_TYPES) do
    if choice.kind==current.kind and choice.preset==current.preset then return i end
  end
  return 1
end
local function choose_capture(kind,preset,where)
  for i,choice in ipairs(ACTIONS) do
    if choice.kind==kind and choice.preset==preset and choice.where==where then action=i; return end
  end
end
local function set_message(s) message=tostring(s or '') end
-- TAC events (DL-013): the forms hold 'none' | 'pause' | 'run'; a waypoint stores only 'pause' or 'run' (none = no field).
local function tac_value(v) if v=='pause' or v=='run' then return v end; return nil end
local function tac_behavior(w)
  local parts={}
  if w.tac_before then parts[#parts+1]=w.tac_before..' before' end
  if w.tac_after then parts[#parts+1]=w.tac_after..' after' end
  return #parts>0 and table.concat(parts,', ') or 'None'
end
local function safe_filename(name)
  local generated,err=files.filename(name)
  if not generated then return nil,err end
  return paths.config..'/'..generated
end
local function refresh_routes()
  local found,err=files.scan(paths.config)
  if not found then set_message('Route scan failed: '..tostring(err)); return end
  existing=found
  local present=false
  for _,entry in ipairs(existing) do if entry.file==existing_file then present=true end end
  if not present then existing_file=existing[1] and existing[1].file or nil end
end
local function current_zone()
  local ok,z=pcall(function() return mq.TLO.Zone.ShortName() end)
  return ok and z or nil
end
local function position()
  local ok,p=pcall(function()
    return {x=tonumber(mq.TLO.Me.X()),y=tonumber(mq.TLO.Me.Y()),z=tonumber(mq.TLO.Me.Z()),heading=tonumber(mq.TLO.Me.Heading.Degrees())}
  end)
  return ok and p or nil
end
local function location_text(p)
  if not p or not p.x or not p.y or not p.z then return 'Current position: unavailable' end
  return string.format('Current position: X %.3f  Y %.3f  Z %.3f',p.x,p.y,p.z)
end
local function zone_ok()
  if not route then set_message('Create or load a route first'); return false end
  local zone=current_zone()
  if not zone or zone~=route.zone_short_name then
    set_message('Capture blocked: current zone '..tostring(zone)..' differs from route '..route.zone_short_name); return false end
  return true
end
local function candidate_door()
  local ok,d=pcall(function()
    local t=mq.TLO.DoorTarget
    return {id=tonumber(t.ID()),name=t.Name(),x=tonumber(t.X()),y=tonumber(t.Y()),z=tonumber(t.Z()),distance=tonumber(t.Distance3D())}
  end)
  if not ok or not d or not d.id or d.id%1~=0 or type(d.name)~='string' or d.name=='' or not d.x or not d.y or not d.z then return nil end
  return d
end
local function selected_wp()
  if not route or not selected then return nil end
  for i,w in ipairs(route.waypoints) do if w.id==selected then return w,i end end
end
local function sync_edit(w)
  edit={label=w.label or '',type=w.type or 'normal',notes=w.notes or '',radius=w.radius and tostring(w.radius) or '',manual_handoff=w.manual_handoff or false,
    door_after=w.door_after or 'continue',
    door_id=w.door and tostring(w.door.id) or '',door_name=w.door and w.door.name or '',
    door_x=w.door and tostring(w.door.x) or '',door_y=w.door and tostring(w.door.y) or '',door_z=w.door and tostring(w.door.z) or '',
    underwater_radius=w.underwater_target and tostring(w.underwater_target.radius) or '',
    exit_radius=w.exit and tostring(w.exit.radius) or '',
    tac_before=w.tac_before or 'none',tac_after=w.tac_after or 'none'}
  edit_original={}; for k,v in pairs(edit) do edit_original[k]=v end
end
local function draft_changed(draft,original)
  for k,v in pairs(draft) do if original[k]~=v then return true end end
  return false
end
local function edit_dirty() return selected~=nil and draft_changed(edit,edit_original) end
local function route_edit_dirty() return route~=nil and draft_changed(route_edit,route_edit_original) end
local function select(w)
  local id=w and w.id or nil
  if selected==id then return end
  selected=id; pending_selection=nil; delete_confirm_id=nil; replace_confirm_id=nil
  if w then sync_edit(w) end
end
local function saved()
  if not route or not filename then state='Unsaved'; return end
  local ok,e=core.save(route,filename)
  if ok then
    local registered,reg_error=files.add(paths.config,filename:match('[^/\\]+$'))
    if not registered then state='Saved (not listed)'; set_message('Route saved, but could not add it to the route list: '..tostring(reg_error)); return end
    state='Saved '..os.date('%H:%M:%S'); local _,warnings=core.validate(route)
    set_message(#warnings>0 and ('Saved. Warnings: '..table.concat(warnings,'; ')) or 'Saved.')
  else state='Save failed'; set_message('Save failed: '..tostring(e)) end
end
local function parse_radius(text,required)
  if text=='' then if required then return nil,'An explicit radius is required' end; return nil end
  local r=tonumber(text); if not r or r<=0 or r==math.huge or r~=r then return nil,'Radius must be a positive number' end
  return r
end
local function prepared_fields(draft,kind)
  local radius,e=parse_radius(draft.radius or '',kind=='finish'); if e then return nil,e end
  if kind=='traverse' then
    radius=radius or 3
    if radius>5 then return nil,'Traversal approach radius must be at most 5' end
  end
  local fields={label=draft.label,type=kind,notes=draft.notes,radius=radius,manual_handoff=draft.manual_handoff,
    tac_before=tac_value(draft.tac_before),tac_after=tac_value(draft.tac_after)}
  if kind=='door' then
    local d=candidate_door(); if not d then return nil,'Select a door with /doortarget before capture' end
    fields.door={id=d.id,name=d.name,x=d.x,y=d.y,z=d.z}; fields.door_after=draft.door_after
  end
  return fields
end
local function capture_waypoint()
  if edit_dirty() or route_edit_dirty() then set_message('Apply or discard typed edits before capturing a waypoint'); return end
  if not zone_ok() then return end
  local chosen=ACTIONS[action]
  local p=position(); if not p then set_message('Could not read character position and heading'); return end
  local w,index=selected_wp()
  if chosen.kind=='traverse' then
    local session=traverse_capture
    if not session then
      if capture.label=='' then set_message('Enter a traversal label before the first capture'); return end
      local r,e=parse_radius(capture.radius or '',false); if e then set_message(e); return end
      if r and r>5 then set_message('Traversal approach radius must be at most 5'); return end
      local ur,ue=parse_radius(capture.underwater_radius or '',chosen.preset~='ground'); if ue then set_message(ue); return end
      local er,ee=parse_radius(capture.exit_radius or '',true); if ee then set_message(ee); return end
      traverse_capture={preset=chosen.preset,label=capture.label,notes=capture.notes,radius=r or 3,
        underwater_radius=ur,exit_radius=er,departure=assert(core.round_position(p)),
        tac_before=tac_value(capture.tac_before),tac_after=tac_value(capture.tac_after),
        anchor_id=w and w.id or nil,step=chosen.preset=='water_cross' and 'target' or 'ledge'}
      set_message('Captured departure and heading. Next: capture '..(traverse_capture.step=='ledge' and 'ledge before the fall.' or 'underwater target.'))
      return
    end
    if session.preset~=chosen.preset then set_message('Finish or cancel the active traversal capture first'); return end
    if session.step=='ledge' then
      local rounded=assert(core.round_position(p))
      session.ledge={x=rounded.x,y=rounded.y,z=rounded.z}
      session.step=session.preset=='ground' and 'exit' or 'target'
      set_message('Captured ledge. Next: capture '..(session.step=='target' and 'underwater target.' or 'ground exit.'))
      return
    end
    if session.step=='target' then
      local ok,feet,head=pcall(function() return mq.TLO.Me.FeetWet(),mq.TLO.Me.HeadWet() end)
      if not ok or feet~=true or head~=true then
        set_message('Submerge first (FeetWet and HeadWet true) before capturing the underwater target'); return
      end
      local rounded=assert(core.round_position(p))
      session.target={x=rounded.x,y=rounded.y,z=rounded.z,radius=session.underwater_radius}
      session.step='exit'; set_message('Captured underwater target. Next: capture dry exit.'); return
    end
    if session.preset~='ground' then
      local ok,feet=pcall(function() return mq.TLO.Me.FeetWet() end)
      if not ok or feet~=false then set_message('Stand on dry ground (FeetWet false) before capturing exit'); return end
    end
    local rounded=assert(core.round_position(p))
    local exit={x=rounded.x,y=rounded.y,z=rounded.z,radius=session.exit_radius}
    local phases=session.preset=='ground' and {'fall'} or session.preset=='water_drop' and
      {'fall','descend','cross','ascend'} or {'descend','cross','ascend'}
    local where,anchor='append',nil
    if session.anchor_id then
      for i,entry in ipairs(route.waypoints) do if entry.id==session.anchor_id then where='after'; anchor=i; break end end
      if not anchor then set_message('Insertion waypoint was removed during capture'); return end
    end
    local created,e=core.create(route,where,anchor,{label=session.label,type='traverse',notes=session.notes,
      radius=session.radius,phases=phases,ledge=session.ledge,underwater_target=session.target,exit=exit,
      tac_before=session.tac_before,tac_after=session.tac_after},
      session.departure,mq.gettime())
    if not created then set_message(e); return end
    local errors=core.validate(route)
    if #errors>0 then core.remove(route,created.id); set_message('Traversal invalid: '..table.concat(errors,'; ')); return end
    traverse_capture=nil; last_creation=created.id; select(created); saved()
    capture={label='',notes='',radius='',manual_handoff=false,door_after='continue',underwater_radius='5',exit_radius='5',tac_before='none',tac_after='none'}
    if state:match('^Saved') then set_message('Captured '..created.id..' - '..created.label..' with exit.') end
    return
  end
  if chosen.where~='append' and not w then set_message('Select a waypoint for Insert Before/After'); return end
  local fields,e=prepared_fields(capture,chosen.kind); if not fields then set_message(e); return end
  local now=mq.gettime()
  local created,where_or_error=core.create(route,chosen.where,index,fields,p,now,last_capture)
  if not created then set_message(where_or_error); return end
  last_creation=created.id; last_capture={time=now,x=created.x,y=created.y,z=created.z}
  select(created); saved()
  capture={label='',notes='',radius='',manual_handoff=false,door_after='continue',underwater_radius='5',exit_radius='5',tac_before='none',tac_after='none'}; action=1
  if state:match('^Saved') then set_message('Captured '..created.id..' - '..created.label) end
end
local function do_new()
  if traverse_capture then set_message('Finish or cancel the traversal capture before creating another route'); return end
  if edit_dirty() or route_edit_dirty() then set_message('Apply or discard typed edits before changing routes'); return end
  if route and not state:match('^Saved') then set_message('Current route is unsaved; fix/save it before switching routes'); return end
  local path,e=safe_filename(file_draft.value); if not path then set_message(e); return end
  if core.exists(path) or core.exists(path..'.tmp') or core.exists(path..'.bak') then set_message('File already exists; choose another filename or Load Route'); return end
  local zone=current_zone(); if not zone or zone=='' then set_message('Cannot read current zone'); return end
  route=core.new(name_draft.value,zone,description_draft.value); filename=path; last_creation=nil; last_capture=nil; select(nil)
  route_edit={name=route.route_name,description=route.description}; route_edit_original={name=route_edit.name,description=route_edit.description}; saved()
  show_create=false
  refresh_routes(); existing_file=path:match('[^/\\]+$')
  set_message('Created route in zone '..zone..'. '..message)
end
local function do_load()
  if traverse_capture then set_message('Finish or cancel the traversal capture before loading another route'); return end
  if edit_dirty() or route_edit_dirty() then set_message('Apply or discard typed edits before changing routes'); return end
  if route and not state:match('^Saved') then set_message('Current route is unsaved; fix/save it before switching routes'); return end
  if not existing_file then set_message('Select an existing route'); return end
  local path=paths.config..'/'..existing_file
  if not core.exists(path) and not core.exists(path..'.tmp') and not core.exists(path..'.bak') then set_message('Route file not found'); return end
  local loaded,notice=core.recover(path); if not loaded then set_message(notice); return end
  route=loaded; filename=path; last_creation=nil; last_capture=nil; select(nil)
  route_edit={name=route.route_name,description=route.description or ''}
  route_edit_original={name=route_edit.name,description=route_edit.description}
  state=notice and 'Recovered' or 'Saved (loaded)'; set_message(notice or 'Route loaded.')
end
local function commit_route_edit()
  if not route then return end
  local old_name,old_description=route.route_name,route.description
  route.route_name=route_edit.name; route.description=route_edit.description; saved()
  if state:match('^Saved') then route_edit_original={name=route_edit.name,description=route_edit.description} end
  if state=='Save failed' then route.route_name=old_name; route.description=old_description end
end
local function apply_metadata()
  local w=selected_wp(); if not w then return end
  local old={}; for k,v in pairs(w) do old[k]=v end
  local old_underwater_radius=w.underwater_target and w.underwater_target.radius
  local old_exit_radius=w.exit and w.exit.radius
  local radius,e=parse_radius(edit.radius,edit.type=='finish'); if e then set_message(e); return end
  if edit.type=='traverse' and (not radius or radius>5) then
    set_message('Traversal approach radius must be from 0 to 5'); return
  end
  if edit.type=='traverse' and w.underwater_target then
    local ur,ue=parse_radius(edit.underwater_radius,true)
    if ue then set_message(ue); return end
    w.underwater_target.radius=ur
  end
  if edit.type=='traverse' and w.exit then
    local er,ee=parse_radius(edit.exit_radius,true)
    if ee then set_message(ee); return end
    w.exit.radius=er
  end
  local door
  if edit.type=='door' then
    door={id=tonumber(edit.door_id),name=edit.door_name,x=tonumber(edit.door_x),y=tonumber(edit.door_y),z=tonumber(edit.door_z)}
    if not door.id or door.id%1~=0 or not door.name or door.name=='' or not door.x or not door.y or not door.z then
      set_message('Door requires ID, name, X, Y, Z'); return end
  end
  local old_type=w.type
  w.label=edit.label; w.type=edit.type; w.notes=edit.notes; w.radius=radius
  w.manual_handoff=edit.type=='normal' and (edit.manual_handoff and true or nil) or nil
  w.tac_before=tac_value(edit.tac_before); w.tac_after=tac_value(edit.tac_after)
  if edit.type~='traverse' then w.phases=nil; w.ledge=nil; w.underwater_target=nil; w.exit=nil end
  if edit.type=='door' then
    w.door=door; w.door_after=edit.door_after~='continue' and edit.door_after or nil
  else w.door=nil; w.door_after=nil end
  if old_type~=edit.type then set_message('Type changed; checking required metadata') end
  saved()
  if state:match('^Saved') then sync_edit(w); pending_selection=nil end
  if state=='Save failed' then
    for k in pairs(w) do w[k]=nil end
    for k,v in pairs(old) do w[k]=v end
    if w.underwater_target then w.underwater_target.radius=old_underwater_radius end
    if w.exit then w.exit.radius=old_exit_radius end
  end
end
local function field_label(id)
  local label,scope=id:match('^(.-)##(.+)$')
  if label then return label,label:gsub('[^%w_]','_')..'_'..scope end
  return id,id:gsub('[^%w_]','_')
end
local FIELD_X=315
local function field_row(label)
  imgui.AlignTextToFramePadding()
  imgui.Text(label)
  imgui.SameLine(FIELD_X)
  imgui.SetNextItemWidth(-1)
end
local function labeled_combo(id,preview)
  local label,scope=field_label(id)
  field_row(label)
  return imgui.BeginCombo('##'..scope,preview)
end
local function text_input(label,obj,key)
  local visible,scope=field_label(label)
  field_row(visible)
  obj[key]=imgui.InputText('##'..scope,obj[key] or '')
end
local function type_combo(id,obj)
  if labeled_combo(id,obj.type or 'normal') then
    for _,kind in ipairs(TYPES) do
      if imgui.Selectable(kind,obj.type==kind) then obj.type=kind end
    end
    imgui.EndCombo()
  end
end
local function handoff_combo(id,obj)
  if labeled_combo(id,obj.manual_handoff and 'Manual handoff' or 'Continue route') then
    if imgui.Selectable('Continue route',not obj.manual_handoff) then obj.manual_handoff=false end
    if imgui.Selectable('Manual handoff',obj.manual_handoff) then obj.manual_handoff=true end
    imgui.EndCombo()
  end
end
local function tac_combo(id,obj,key)
  local labels={none='None',pause='Pause TAC',run='Run TAC'}
  local current=obj[key] or 'none'
  if labeled_combo(id,labels[current] or labels.none) then
    for _,choice in ipairs({'none','pause','run'}) do
      if imgui.Selectable(labels[choice],current==choice) then obj[key]=choice end
    end
    imgui.EndCombo()
  end
end
local function door_after_combo(id,obj)
  local labels={continue='Continue to next waypoint',finish_open='Finish upon open',finish_zone='Click door, then finish after zoning'}
  local current=obj.door_after or 'continue'
  if labeled_combo(id,labels[current]) then
    for _,choice in ipairs({'continue','finish_open','finish_zone'}) do
      if imgui.Selectable(labels[choice],current==choice) then obj.door_after=choice end
    end
    imgui.EndCombo()
  end
end
local function draw()
  imgui.SetNextWindowSize(ImVec2(800,680),ImGuiCond.FirstUseEver)
  imgui.SetNextWindowPos(ImVec2(55,55),ImGuiCond.FirstUseEver)
  local open,visible=imgui.Begin('Project Triune AutoRoute Editor v'..version.VERSION..'###Project Triune AutoRoute Editor',true)
  if open==false then running=false end
  if visible then
    imgui.Text('Routes')
    if labeled_combo('Existing route##existing_route',existing_file or '(none)') then
      for _,entry in ipairs(existing) do
        if imgui.Selectable(entry.label..'##'..entry.file,existing_file==entry.file) then existing_file=entry.file end
      end
      imgui.EndCombo()
    end
    if imgui.Button('Load Route') then do_load() end
    imgui.SameLine(); if imgui.Button('Refresh Routes') then refresh_routes() end
    imgui.SameLine(); if imgui.Button(show_create and 'Hide New Route' or 'New Route...') then show_create=not show_create end
    if show_create then
      text_input('New route filename (PTAR_ added)',file_draft,'value')
      text_input('New route name',name_draft,'value')
      text_input('New route description',description_draft,'value')
      if imgui.Button('Create Route') then do_new() end
    end
    if imgui.Button(show_register and 'Hide Register File' or 'Register Route File...') then show_register=not show_register end
    if show_register then
      imgui.TextWrapped('Register a valid route file already in config/PTAR but missing from the list.')
      text_input('Route file to register (PTAR_ added)',import_draft,'value')
      if imgui.Button('Register Existing File') then
        local name,err=files.filename(import_draft.value)
        if not name then set_message(err)
        else
          local ok,reason=files.add(paths.config,name)
          if ok then refresh_routes(); existing_file=name; set_message('Added '..name..' to route list.')
          else set_message(reason) end
        end
      end
    end
    imgui.Separator()
    imgui.Text('Status: '..state)
    imgui.TextWrapped(message)
    if route then
      imgui.TextWrapped('Captures and route-order actions save immediately. Typed route and waypoint fields need Apply & Save.')
      if state=='Save failed' or state=='Saved (not listed)' then
        if imgui.Button('Retry Save') then saved() end
      end
      if edit_dirty() or route_edit_dirty() then
        imgui.TextColored(1,0.8,0.2,1,'Typed changes have not been applied.')
        if imgui.Button('Discard Typed Changes') then
          route_edit={name=route_edit_original.name,description=route_edit_original.description}
          local current=selected_wp(); if current then sync_edit(current) end
          pending_selection=nil; set_message('Unapplied typed changes discarded.')
        end
      end
      local errors,warnings=core.validate(route)
      for _,s in ipairs(errors) do imgui.TextWrapped('ERROR: '..s) end
      for _,s in ipairs(warnings) do imgui.TextWrapped('Warning: '..s) end
      imgui.Separator()
      imgui.Text('Loaded: '..(filename or '')..' | Zone: '..route.zone_short_name..' | Here: '..tostring(current_zone()))
      text_input('Route name',route_edit,'name')
      text_input('Description',route_edit,'description')
      if imgui.Button('Apply Route Details & Save') then commit_route_edit() end
      imgui.Separator()
      local here=position()
      imgui.Text('New waypoint (capture at current character position)')
      imgui.Text(location_text(here))
      local type_index=capture_type_index()
      if labeled_combo('Capture type##capture_type',CAPTURE_TYPES[type_index].label) then
        for i,choice in ipairs(CAPTURE_TYPES) do
          if imgui.Selectable(choice.label..'##capture_type_'..i,type_index==i) then
            if traverse_capture and i~=type_index then
              set_message('Finish or cancel the traversal capture before changing type')
            else
              local where=choice.kind=='traverse' and nil or (ACTIONS[action].where or 'append')
              choose_capture(choice.kind,choice.preset,where)
            end
          end
        end
        imgui.EndCombo()
      end
      local kind=ACTIONS[action].kind
      if kind~='traverse' then
        local placement=ACTIONS[action].where
        local labels={append='At end',before='Before selected',after='After selected'}
        if labeled_combo('Placement##capture_placement',labels[placement]) then
          for _,where in ipairs({'append','before','after'}) do
            if imgui.Selectable(labels[where],placement==where) then choose_capture(kind,nil,where) end
          end
          imgui.EndCombo()
        end
        if placement~='append' and not selected then imgui.TextWrapped('Select a waypoint in Route Order for this placement.') end
      end
      if kind=='traverse' then
        imgui.TextWrapped('The traversal is inserted after the selected waypoint, or appended if none is selected. Use this same Capture button at each point in order: departure and heading, ledge (if falling), underwater target (if swimming), and exit.')
      end
      text_input('Label##capture',capture,'label')
      text_input('Notes##capture',capture,'notes'); text_input('Radius##capture',capture,'radius')
      if kind=='traverse' then
        imgui.TextWrapped('Radius is the nav arrival tolerance at departure (blank = 3; maximum 5).')
        if ACTIONS[action].preset~='ground' then
        text_input('Underwater target radius##capture',capture,'underwater_radius')
        end
        text_input('Exit radius##capture',capture,'exit_radius')
        local next_label={ledge='capture ledge before the fall',target='capture underwater target',exit='capture exit'}
        imgui.TextWrapped('Next: '..(traverse_capture and next_label[traverse_capture.step] or 'capture departure and heading'))
        if traverse_capture and imgui.Button('Cancel Traversal Capture') then traverse_capture=nil; set_message('Traversal capture canceled; route unchanged.') end
      end
      tac_combo('TAC before##capture',capture,'tac_before'); tac_combo('TAC after##capture',capture,'tac_after')
      if kind=='traverse' then
        imgui.TextWrapped('TAC events are read when the departure is captured. "After" fires once the exit is reached.')
      end
      if kind=='normal' then handoff_combo('After waypoint##capture',capture) end
      if kind=='door' then
        door_after_combo('After door##capture',capture)
        if imgui.Button('Select Nearest Door') then
          mq.cmd('/doortarget clear')
          mq.cmd('/doortarget')
          set_message('Nearest door requested. Verify the door target below before capture.')
        end
        local d=candidate_door()
        if d then imgui.Text(string.format('Door target: %s | ID %d | distance %.1f | X %.3f Y %.3f Z %.3f',d.name,d.id,d.distance or -1,d.x,d.y,d.z))
        else imgui.Text('No valid door target. Select Nearest Door or choose a door with /doortarget id <number>.') end
      end
      local capture_label=kind=='traverse' and (traverse_capture and
        ({ledge='Capture Ledge',target='Capture Underwater Target',exit='Capture Exit'})[traverse_capture.step] or 'Capture Departure') or
        ({normal='Capture Waypoint',door='Capture Door',finish='Capture Finish'})[kind]
      if imgui.Button(capture_label) then capture_waypoint() end
      imgui.Separator(); imgui.Text('Route Order (click a label to edit)')
      local table_flags=ImGuiTableFlags.Borders+ImGuiTableFlags.RowBg+ImGuiTableFlags.Resizable
      if imgui.BeginTable('##route_order',6,table_flags) then
        imgui.TableSetupColumn('Number',ImGuiTableColumnFlags.WidthFixed,68)
        imgui.TableSetupColumn('Label',ImGuiTableColumnFlags.WidthStretch)
        imgui.TableSetupColumn('Waypoint ID',ImGuiTableColumnFlags.WidthFixed,110)
        imgui.TableSetupColumn('Type',ImGuiTableColumnFlags.WidthFixed,88)
        imgui.TableSetupColumn('From Previous',ImGuiTableColumnFlags.WidthFixed,125)
        imgui.TableSetupColumn('TAC Behavior',ImGuiTableColumnFlags.WidthFixed,180)
        imgui.TableHeadersRow()
        for i,w in ipairs(route.waypoints) do
          local delta=core.distance(w,route.waypoints[i-1])
          imgui.TableNextRow()
          imgui.TableSetColumnIndex(0); imgui.Text(tostring(i))
          imgui.TableSetColumnIndex(1)
          if imgui.Selectable(w.label..'##route_order_'..w.id,selected==w.id) then
            if edit_dirty() and selected~=w.id then
              pending_selection=w.id; set_message('Apply or discard the selected waypoint edits before switching.')
            else select(w) end
          end
          imgui.TableSetColumnIndex(2); imgui.Text(w.id)
          imgui.TableSetColumnIndex(3); imgui.Text(w.type)
          imgui.TableSetColumnIndex(4); imgui.Text(delta and string.format('%.1f',delta) or '—')
          imgui.TableSetColumnIndex(5); imgui.Text(tac_behavior(w))
        end
        imgui.EndTable()
      end
      if pending_selection then
        imgui.TextWrapped('Waypoint edits are not applied. Apply them below, or discard them to select another waypoint.')
        if imgui.Button('Discard Edits & Switch') then
          for _,entry in ipairs(route.waypoints) do if entry.id==pending_selection then select(entry); break end end
        end
        imgui.SameLine(); if imgui.Button('Stay Here') then pending_selection=nil end
      end
      local w,index=selected_wp()
      if w then
        imgui.Separator()
        local distance=core.distance(w,here)
        imgui.Text(string.format('Selected: #%d %s | distance from you: %s',index,w.id,distance and string.format('%.1f',distance) or 'unknown'))
        imgui.Text(string.format('Saved position: X %.3f  Y %.3f  Z %.3f',w.x,w.y,w.z))
        imgui.Text(location_text(here))
        text_input('Label##edit',edit,'label'); type_combo('Type##edit',edit)
        text_input('Notes##edit',edit,'notes'); text_input('Radius##edit',edit,'radius')
        if w.type=='traverse' then
          imgui.Text('Phases: '..table.concat(w.phases or {},' -> '))
          if w.ledge then imgui.Text(string.format('Ledge: X %.3f Y %.3f Z %.3f',w.ledge.x,w.ledge.y,w.ledge.z)) end
          if w.underwater_target then
            imgui.Text(string.format('Underwater target: X %.3f Y %.3f Z %.3f',
              w.underwater_target.x,w.underwater_target.y,w.underwater_target.z))
            text_input('Underwater target radius##edit',edit,'underwater_radius')
          end
          if w.exit then
            imgui.Text(string.format('Exit: X %.3f Y %.3f Z %.3f',w.exit.x,w.exit.y,w.exit.z))
            text_input('Exit radius##edit',edit,'exit_radius')
          end
        end
        tac_combo('TAC before##edit',edit,'tac_before'); tac_combo('TAC after##edit',edit,'tac_after')
        if edit.type=='normal' then handoff_combo('After waypoint##edit',edit) end
        if edit.type=='door' then
          door_after_combo('After door##edit',edit)
          text_input('Door ID',edit,'door_id'); text_input('Door name',edit,'door_name')
          text_input('Door X',edit,'door_x'); text_input('Door Y',edit,'door_y'); text_input('Door Z',edit,'door_z')
          local d=candidate_door()
          if d then imgui.Text(string.format('Current /doortarget: %s (%d)',d.name,d.id))
            if imgui.Button('Use Current Door Target') then
              edit.door_id=tostring(d.id); edit.door_name=d.name
              edit.door_x=tostring(d.x); edit.door_y=tostring(d.y); edit.door_z=tostring(d.z)
            end
          end
        end
        if imgui.Button('Apply Waypoint Edits & Save') then apply_metadata() end
        if edit_dirty() then imgui.BeginDisabled() end
        if imgui.Button('Replace Position') then
          if zone_ok() then replace_confirm_id=w.id; delete_confirm_id=nil end
        end
        if replace_confirm_id==w.id then
          local p=position(); local dist=core.distance(w,p)
          imgui.Text('Old to current position: '..(dist and string.format('%.2f',dist) or 'unavailable'))
          if imgui.Button('Confirm Replace Position') then
            if zone_ok() then
              local ok,e=core.replace_position(w,position()); if ok then saved() else set_message(e) end
            end; replace_confirm_id=nil
          end
          imgui.SameLine(); if imgui.Button('Cancel Replace') then replace_confirm_id=nil end
        end
        if imgui.Button('Move Up') then local j,e=core.move(route,w.id,-1); if j then saved() else set_message(e) end end
        imgui.SameLine(); if imgui.Button('Move Down') then local j,e=core.move(route,w.id,1); if j then saved() else set_message(e) end end
        if imgui.Button('Delete Selected') then delete_confirm_id=w.id; replace_confirm_id=nil end
        if delete_confirm_id==w.id then
          imgui.Text('Delete '..w.id..' - '..w.label..'?')
          if imgui.Button('Confirm Delete') then
            core.remove(route,w.id); if last_creation==w.id then last_creation=nil end
            select(nil); saved()
          end
          imgui.SameLine(); if imgui.Button('Cancel Delete') then delete_confirm_id=nil end
        end
        if edit_dirty() then imgui.EndDisabled() end
      end
      if last_creation then
        if edit_dirty() then imgui.BeginDisabled() end
        if imgui.Button('Undo Last Creation') then
          local ok,e=core.remove(route,last_creation)
          if ok then if selected==last_creation then select(nil) end; last_creation=nil; saved()
          else last_creation=nil; set_message(e) end
        end
        if edit_dirty() then imgui.EndDisabled() end
      end
    end
  end
  imgui.End()
end
refresh_routes()
mq.imgui.init('PTAREditor',draw)
while running do mq.delay(100) end
mq.imgui.destroy('PTAREditor')
