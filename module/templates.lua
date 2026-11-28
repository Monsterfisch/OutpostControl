-- Injected code. Every script is assembled on its own (fasm has a small fixed buffer), and
-- the scripts reach each other by address. Building entries are 16 bytes, one per building id:
-- +0 the building's uid (the entry only counts while it matches), +4 the defender troop
-- buttons (bit per button), +6 the number of defenders, +7 the growth in percent, +8 the exact
-- wave size (0xFFFF: game size), +10 the interval in seconds (0: game timing).

local templates = {}

-- eax = building id -> eax = its entry, or 0 when it has none. Changes edx.
templates.entryGet = [[
cmp eax,MAX_BUILDINGS
jae none
mov edx,eax
imul edx,edx,B_STRIDE
mov edx,[edx+B_UID]
shl eax,ENTRY_SHIFT
add eax,TABLE
test edx,edx
jz none
cmp edx,[eax]
jne none
ret
none:
xor eax,eax
ret
]]

-- eax = building id -> eax = its entry, made with the game's own values if it had none (0 for
-- a bad id), its guard list emptied. Changes edx.
templates.entryMake = [[
push ecx
push ebx
mov ecx,eax
call ENTRY_GET
test eax,eax
jnz done
cmp ecx,MAX_BUILDINGS
jae done
mov edx,ecx
imul edx,edx,B_STRIDE
mov ebx,[edx+B_UID]
xor eax,eax
test ebx,ebx
jz done
push edi
push ecx
mov eax,ecx
imul eax,eax,SLOT_BYTES
lea edi,[SLOTS+eax]
mov ecx,SLOT_DWORDS
xor eax,eax
rep stosd
pop ecx
pop edi
mov eax,ecx
shl eax,ENTRY_SHIFT
add eax,TABLE
mov [eax],ebx
mov word [eax+8],0xFFFF
mov word [eax+10],0
mov word [eax+4],1
movsx ebx,byte [edx+B_DEFENDERS]
cmp ebx,1
jl usual
cmp ebx,MAX_DEFENDERS
jle keep
usual:
mov ebx,USUAL_DEFENDERS
keep:
mov [eax+6],bl
mov byte [eax+7],0
done:
pop ebx
pop ecx
ret
]]

-- UpdateOutpostBuilding, where it asks whether the defender count is set yet (cmp/jle, 13
-- bytes). An outpost set to no defenders skips the defender part.
templates.defenderCount = [[
push edx
mov eax,[CURRENT_BUILDING]
call ENTRY_GET
pop edx
test eax,eax
jz usual
cmp byte [eax+6],0
jne usual
jmp SKIP
usual:
cmp byte [ecx+B_DEFENDERS],0
jle ROLL
jmp RESUME
]]

-- UpdateOutpostBuilding, every defender check (mov word [ecx+timer],1200, 9 bytes, eax and edi
-- in use). An outpost with an entry counts its guards in its own list of MAX_GUARDS, waits
-- GUARD_PACE / amount ticks between guards (so a full refill takes as long as the game's 8)
-- and goes on to pick the guard's type, or skips the defender part when it has enough.
templates.guardCount = [[
push eax
push edx
mov eax,[CURRENT_BUILDING]
call ENTRY_GET
pop edx
test eax,eax
jz usual
add esp,4
push ebx
push edi
movzx ebx,byte [eax+6]
test ebx,ebx
jnz wanted
inc ebx
wanted:
mov eax,[CURRENT_BUILDING]
imul eax,eax,SLOT_BYTES
lea edi,[SLOTS+eax]
xor esi,esi
mov edx,MAX_GUARDS
alive:
movzx eax,word [edi]
test eax,eax
jz next_slot
cmp eax,UNIT_CAPACITY
jae next_slot
cmp eax,[UNIT_COUNT]
jae next_slot
imul eax,eax,U_STRIDE
mov eax,[eax+U_UID]
cmp eax,[edi+4]
jne next_slot
inc esi
next_slot:
add edi,8
dec edx
jnz alive
mov eax,GUARD_PACE
xor edx,edx
div ebx
cmp eax,LONGEST_WAIT
jbe short_enough
mov eax,LONGEST_WAIT
short_enough:
cmp eax,SHORTEST_WAIT
jae long_enough
mov eax,SHORTEST_WAIT
long_enough:
mov word [ecx+B_TIMER],ax
cmp esi,ebx
pop edi
pop ebx
jge SKIP
jmp PICK
usual:
pop eax
mov word [ecx+B_TIMER],LONGEST_WAIT
jmp RESUME
]]

-- UpdateOutpostBuilding, where it puts a new guard in a free slot (mov ebp,[current], 6 bytes;
-- ebx = the unit). An outpost with an entry keeps it in its own list instead. Either way lua then
-- sends a foot guard onto nearby walls and puts the guard in its outpost's troop for its stance.
templates.guardRecord = [[
push eax
push edx
mov eax,[CURRENT_BUILDING]
call ENTRY_GET
test eax,eax
jz usual
push esi
push ecx
mov eax,[CURRENT_BUILDING]
imul eax,eax,SLOT_BYTES
lea esi,[SLOTS+eax]
mov ecx,MAX_GUARDS
find_slot:
movzx eax,word [esi]
test eax,eax
jz take
cmp eax,UNIT_CAPACITY
jae take
cmp eax,[UNIT_COUNT]
jae take
imul eax,eax,U_STRIDE
mov eax,[eax+U_UID]
cmp eax,[esi+4]
jne take
add esi,8
dec ecx
jnz find_slot
jmp recorded
take:
mov [esi],bx
mov eax,ebx
imul eax,eax,U_STRIDE
mov eax,[eax+U_UID]
mov [esi+4],eax
recorded:
mov [GUARD_UNIT],ebx
pushad
call PAD
popad
pop ecx
pop esi
pop edx
pop eax
jmp DONE
usual:
mov [GUARD_UNIT],ebx
pushad
call PAD
popad
pop edx
pop eax
mov ebp,[CURRENT_BUILDING]
jmp RESUME
]]

-- UpdateOutpostBuilding, where it picks the defender's unit type (20 bytes, edx = the type).
-- esi = how many defenders are alive, so the picked troops take turns.
templates.defenderType = [[
mov eax,[CURRENT_BUILDING]
push edx
call ENTRY_GET
pop edx
test eax,eax
jz usual
movzx eax,word [eax+4]
and eax,0xFF
jz usual
push ebx
push edi
xor ebx,ebx
mov edx,eax
count:
test edx,edx
jz counted
mov edi,edx
and edi,1
add ebx,edi
shr edx,1
jmp count
counted:
push eax
mov eax,esi
xor edx,edx
div ebx
pop eax
xor edi,edi
find:
bt eax,edi
jnc next
test edx,edx
jz found
dec edx
next:
inc edi
cmp edi,8
jb find
xor edi,edi
found:
cmp word [ecx+B_TYPE],ARAB_OUTPOST
jne euro
add edi,8
euro:
movzx edx,byte [DEFENDER_TYPES+edi]
pop edi
pop ebx
jmp RESUME
usual:
mov edx,EURO_ARCHER
cmp word [ecx+B_TYPE],ARAB_OUTPOST
jne go
mov edx,ARAB_ARCHER
go:
jmp RESUME
]]

-- eax = building id -> eax = the average wave of the outpost's first picked troop kind at
-- multiplier 1 (base + (range - 1) / 2, at least 1). Changes ecx and edx.
templates.kindAverage = [[
imul eax,eax,B_STRIDE
movzx ecx,word [eax+B_MASK]
and ecx,0xFF
bsf ecx,ecx
jnz picked
xor ecx,ecx
picked:
cmp word [eax+B_TYPE],ARAB_OUTPOST
jne euro
add ecx,8
euro:
imul ecx,ecx,KIND_STRIDE
mov eax,[KINDS+ecx+KIND_RANGE]
dec eax
sar eax,1
add eax,[KINDS+ecx+KIND_BASE]
cmp eax,1
jge fine
mov eax,1
fine:
ret
]]

-- eax = building id -> eax = its wave size: the exact one set, else what the game's own size
-- slider makes on average. Keeps every register but eax.
templates.waveValue = [[
push ecx
push edx
push ebx
mov ebx,eax
call ENTRY_GET
test eax,eax
jz average
movzx edx,word [eax+8]
cmp edx,0xFFFF
je average
mov eax,edx
jmp known
average:
mov eax,ebx
call KIND_AVERAGE
imul ebx,ebx,B_STRIDE
movsx edx,word [ebx+B_SIZE]
inc edx
imul eax,edx
known:
pop ebx
pop edx
pop ecx
ret
]]

-- The size slider on the attacker page: the exact wave size, 0 (no waves) to WAVE_MAX. The
-- game's own size field gets the multiplier nearest to it, so the map means about the same
-- without the module.
templates.waveSlider = [[
mov eax,[SELECTED]
call ENTRY_MAKE
test eax,eax
jz done
mov ecx,[esp+8]
cmp ecx,1
jne not_setup
mov edx,[esp+0xC]
mov dword [edx],0
mov edx,[esp+0x10]
mov dword [edx],WAVE_MAX
jmp report
not_setup:
cmp ecx,2
je take
cmp ecx,3
je take
cmp ecx,5
je less
cmp ecx,6
je more
jmp report
take:
mov edx,[esp+0x14]
mov ecx,[edx]
cmp ecx,0
jge low_ok
xor ecx,ecx
low_ok:
cmp ecx,WAVE_MAX
jle set_size
mov ecx,WAVE_MAX
jmp set_size
less:
push eax
mov eax,[SELECTED]
call WAVE_VALUE
mov ecx,eax
pop eax
dec ecx
jge set_size
xor ecx,ecx
jmp set_size
more:
push eax
mov eax,[SELECTED]
call WAVE_VALUE
mov ecx,eax
pop eax
inc ecx
cmp ecx,WAVE_MAX
jle set_size
mov ecx,WAVE_MAX
set_size:
mov [eax+8],cx
push eax
push ecx
mov eax,[SELECTED]
call KIND_AVERAGE
mov ecx,eax
mov eax,[esp]
mov edx,ecx
sar edx,1
add eax,edx
xor edx,edx
div ecx
dec eax
jge size_low
xor eax,eax
size_low:
cmp eax,VANILLA_TOP
jle size_high
mov eax,VANILLA_TOP
size_high:
mov edx,[SELECTED]
imul edx,edx,B_STRIDE
mov [edx+B_SIZE],ax
pop ecx
pop eax
report:
mov eax,[SELECTED]
call WAVE_VALUE
mov edx,[esp+0x14]
mov [edx],eax
done:
ret
]]

-- UpdateOutpostBuilding, where a new wave troop gets its size (mov [ecx+wave size],dx, 7
-- bytes; ecx = building id * stride, dx = the game's size): an outpost with an exact size takes
-- that, and with growth each wave is that many percent of it bigger per wave already sent (the
-- game's wave counter, 100 per wave), up to GROWTH_CAP.
templates.waveSize = [[
push eax
push edx
mov eax,[CURRENT_BUILDING]
call ENTRY_GET
pop edx
test eax,eax
jz usual
push ebx
if WAVES_ON <> 0
movzx ebx,word [eax+8]
cmp ebx,0xFFFF
je not_exact
mov edx,ebx
not_exact:
end if
if GROWTH_ON <> 0
movzx ebx,byte [eax+7]
test ebx,ebx
jz grown
push ecx
push edx
movzx eax,word [ecx+B_WAVES]
xor edx,edx
mov ecx,100
div ecx
imul eax,ebx
add eax,100
pop edx
imul eax,edx
xor edx,edx
div ecx
cmp eax,GROWTH_CAP
jbe capped
mov eax,GROWTH_CAP
capped:
mov edx,eax
pop ecx
grown:
end if
pop ebx
usual:
pop eax
mov word [ecx+B_WAVE],dx
jmp RESUME
]]

-- UpdateOutpostBuilding, where its wave part starts (test ebp,ebp / jne, 8 bytes; ebp = the
-- forming wave troop): an outpost set to waves of 0 sends none.
templates.waveStart = [[
mov eax,[CURRENT_BUILDING]
call ENTRY_GET
test eax,eax
jz usual
cmp word [eax+8],0
jne usual
jmp UPDATE_END
usual:
test ebp,ebp
jne FORMING
jmp RESUME
]]

-- Replaces UpdateOutpostBuilding's call of aiRegisterTribeAndAssignTarget(tribe, uid): the
-- wave is sent as before, then lua splits it into jobs.
templates.launch = [[
mov eax,[esp+4]
mov [LAUNCH_TRIBE],eax
mov [LAUNCH_THIS],ecx
push dword [esp+8]
push dword [esp+8]
call REGISTER
call PAD
ret 8
]]

-- Replaces makeOutpostTribesAttack's call of decideOnTribeAttackLocation(tribe). With RETARGET,
-- a troop whose target player is beaten (his lord is dead) first gets a new one from the game's
-- own choice (setTargetForTribeBasedOnTargetChoiceLogic: the nearest enemy whose lord lives).
-- Troops with a matching job and UID use the outpost's order callback.
templates.decide = [[
if RETARGET <> 0
mov eax,[esp+4]
cmp eax,MAX_TRIBES
jae checked
push ecx
push ebx
mov ebx,eax
imul ebx,ebx,TRIBE_STRIDE
movsx edx,word [ebx+TRIBE_TARGET]
cmp edx,1
jl beaten
cmp edx,8
jg beaten
imul edx,edx,P_STRIDE
mov eax,[edx+P_LORD]
test eax,eax
jle beaten
imul eax,eax,U_STRIDE
cmp word [eax+U_STATE],2
jne beaten
cmp word [eax+U_TYPE],LORD_TYPE
jne beaten
mov eax,[eax+U_UID]
cmp eax,[edx+P_LORD_UID]
je alive
beaten:
push dword [esp+0xC]
push dword [ebx+TRIBE_OWNER]
mov ecx,[esp+0xC]
call SET_TARGET
alive:
pop ebx
pop ecx
checked:
end if
if ORDERS <> 0
mov eax,[esp+4]
cmp eax,MAX_TRIBES
jae original
movzx edx,byte [JOBS+eax]
test edx,edx
jz original
if JOBS_ON = 0
cmp edx,JOB_SIEGE
jne original
end if
if SIEGE_ON = 0
cmp edx,JOB_SIEGE
je original
end if
push ecx
mov ecx,eax
imul ecx,ecx,TRIBE_STRIDE
mov ecx,[ecx+TRIBE_UID]
cmp ecx,[JOB_UIDS+eax*4]
pop ecx
jne original
mov [DECIDE_TRIBE],eax
mov [DECIDE_THIS],ecx
call PAD
ret 4
original:
end if
jmp DECIDE
]]

-- Put in the unit update table for the siege engine types: every 16 ticks (staggered by unit)
-- an outpost unit standing (state 0), walking (1 or 0x65 - siege engines use both) or creeping
-- forward in the AI's siege steps (9) goes to lua, which may set it shooting. Then whatever update function the table held runs, by the unit's type.
templates.siegeCheck = [[
mov eax,[CURRENT_UNIT]
if BALLISTA <> 0
imul ecx,eax,U_STRIDE
cmp word [ecx+U_BEHAVIOUR],OUTPOST_BEHAVIOUR
jne go
movzx edx,word [ecx+U_TARGETING]
cmp edx,ATTACK_BUILDING
je clearTarget
cmp edx,ATTACK_WALL_AT
jne ballistaIdle
clearTarget:
xor edx,edx
mov word [ecx+U_TARGETING],dx
mov word [ecx+U_TARGET_BUILDING],dx
mov dword [ecx+U_TARGET_UID],edx
mov dword [ecx+U_WALL_X],edx
mov word [ecx+U_SHOOT_UNIT],dx
movzx edx,word [ecx+U_ACTION]
cmp edx,STATE_SHOOT
je stopShooting
cmp edx,STATE_LOAD
je stopShooting
cmp edx,STATE_FIRE
jne ballistaIdle
stopShooting:
mov word [ecx+U_ACTION],0
ballistaIdle:
; A negative countdown keeps the native idle update from acquiring a building.
cmp word [ecx+U_ACTION],0
jne stagger
cmp dword [ecx+IDLE_DELAY],0
jl stagger
mov dword [ecx+IDLE_DELAY],-1
stagger:
end if
mov edx,[TICKS]
add edx,eax
test edx,SIEGE_EVERY
jnz go
if BALLISTA = 0
imul ecx,eax,U_STRIDE
cmp word [ecx+U_BEHAVIOUR],OUTPOST_BEHAVIOUR
jne go
end if
movzx edx,word [ecx+U_ACTION]
test edx,edx
jz check
cmp edx,STATE_WALKING
je check
cmp edx,STATE_MOVING
je check
cmp edx,STATE_CREEPING
jne go
check:
mov [SIEGE_UNIT],eax
pushad
call PAD
popad
go:
mov eax,[CURRENT_UNIT]
imul eax,eax,U_STRIDE
movsx eax,word [eax+U_TYPE]
jmp dword [ORIGINAL_UPDATES+eax*4]
]]

-- UpdateOutpostBuilding's idle branch: replace the wait in ecx after the first launch.
templates.intervalWait = [[
cmp word [eax+B_WAVES],0
je original
push eax
mov eax,[CURRENT_BUILDING]
call ENTRY_GET
test eax,eax
jz saved_index
movzx edx,word [eax+INTERVAL_FIELD]
test edx,edx
jz saved_index
imul ecx,edx,TICKS_PER_SECOND
saved_index:
pop eax
original:
add word [eax+B_IDLE_TIMER],1
jmp RESUME
]]

-- The outpost panel's text (prologue: mov eax,[selected], 5 bytes).
templates.panel = [[
cmp dword [MODE],0
jne defenders
if INTERVAL_ON <> 0
cmp dword [SCOPE],1
je timing
end if
if GROWTH_ON <> 0 | INTERVAL_ON <> 0
call ATTACK_LABELS
if GROWTH_ON <> 0
call GROWTH_SLIDER
end if
else
call usual
end if
jmp numbers
if INTERVAL_ON <> 0
timing:
call TIMING_LABELS
call INTERVAL_SLIDER
end if
numbers:
call NUMBERS
if INTERVAL_ON <> 0
call SCOPE_TOGGLE
end if
if TOGGLE_ON <> 0
jmp TOGGLE
else
ret
end if
usual:
mov eax,[SELECTED]
jmp RESUME
defenders:
if TOGGLE_ON <> 0
call DEFENDER_LABELS
call NUMBERS
jmp TOGGLE
else
ret
end if
]]

-- Each slider's value, right of it: size as set, start delay in seconds at normal speed, growth
-- in percent; on the defender page the amount of guards.
templates.numbers = [[
push ebx
push esi
mov esi,[SELECTED]
cmp dword [MODE],0
jne defenders
if INTERVAL_ON <> 0
cmp dword [SCOPE],1
je delay
end if
if WAVES_ON <> 0
mov eax,esi
call WAVE_VALUE
imul esi,esi,B_STRIDE
else
imul esi,esi,B_STRIDE
movsx eax,word [esi+B_SIZE]
end if
xor ecx,ecx
mov ebx,SIZE_ROW
call show
if INTERVAL_ON <> 0
jmp growth
delay:
imul esi,esi,B_STRIDE
end if
movsx eax,word [esi+B_DELAY]
cmp eax,0
jge delay_ok
xor eax,eax
delay_ok:
xor edx,edx
mov ecx,TICKS_PER_SECOND
div ecx
mov ecx,'s'
mov ebx,DELAY_ROW
call show
if INTERVAL_ON <> 0
mov eax,[SELECTED]
call ENTRY_GET
xor edx,edx
test eax,eax
jz interval_known
movzx edx,word [eax+INTERVAL_FIELD]
interval_known:
mov eax,edx
mov ecx,'s'
mov ebx,INTERVAL_ROW
call show
jmp done
growth:
end if
if GROWTH_ON <> 0
mov eax,[SELECTED]
call ENTRY_GET
xor edx,edx
test eax,eax
jz growth_known
movzx edx,byte [eax+7]
growth_known:
mov eax,edx
mov ecx,'%'
mov ebx,GROWTH_ROW
call show
end if
jmp done
defenders:
if TOGGLE_ON <> 0
mov eax,esi
call ENTRY_MAKE
test eax,eax
jz done
movzx eax,byte [eax+6]
xor ecx,ecx
mov ebx,SIZE_ROW
call show
end if
done:
pop esi
pop ebx
ret
show:
push edi
mov edi,NUMBER_TEXT+15
mov byte [edi],0
test ecx,ecx
jz digits
dec edi
mov [edi],cl
digits:
mov ecx,10
digit:
xor edx,edx
div ecx
add dl,'0'
dec edi
mov [edi],dl
test eax,eax
jnz digit
push 0
push 0
push 0x12
push 0
push 0
mov eax,[MENU_Y]
add eax,ebx
push eax
mov eax,[MENU_X]
add eax,NUMBER_X
push eax
push edi
mov ecx,TEXT_MANAGER
call RENDER_TEXT
pop edi
ret
]]

-- Slider labels: LABEL_COUNT entries of x, y (from the panel), text, game text id (used when
-- the text is 0, group 0x40, so the game's own words stay in its language).
templates.labels = [[
push ebx
push esi
mov esi,LABEL_TABLE
mov ebx,LABEL_COUNT
again:
mov eax,[esi+8]
test eax,eax
jnz have_text
push dword [esi+12]
push 0x40
mov ecx,TEXT_MANAGER
call GET_TEXT
have_text:
push 0
push 0
push 0x12
push 0
push 0
mov ecx,[MENU_Y]
add ecx,[esi+4]
push ecx
mov ecx,[MENU_X]
add ecx,[esi]
push ecx
push eax
mov ecx,TEXT_MANAGER
call RENDER_TEXT
add esi,16
dec ebx
jnz again
pop esi
pop ebx
ret
]]

-- A slider backed by an outpost entry field, drawn by the native slider renderer.
templates.entrySlider = [[
push ebx
push esi
push edi
mov eax,[SELECTED]
call ENTRY_GET
xor edi,edi
test eax,eax
jz have
if WIDE <> 0
movzx edi,word [eax+ENTRY_FIELD]
else
movzx edi,byte [eax+ENTRY_FIELD]
end if
have:
mov ebx,[MENU_X]
add ebx,SLIDER_X
mov esi,[MENU_Y]
add esi,SLIDER_Y
cmp dword [MOUSE+LEFT_CLICK],0
je no_start
mov eax,[MOUSE+MOUSE_X]
sub eax,ebx
cmp eax,SLIDER_W
jae no_start
mov eax,[MOUSE+MOUSE_Y]
sub eax,esi
add eax,KNOB_ABOVE
cmp eax,KNOB_H
jae no_start
mov dword [DRAG],1
no_start:
cmp dword [MOUSE+LEFT_HELD],0
jne held
mov dword [DRAG],0
held:
cmp dword [DRAG],0
je draw
mov eax,[MOUSE+MOUSE_X]
sub eax,ebx
sub eax,KNOB_HALF
imul eax,eax,STEPS
cdq
mov ecx,KNOB_SPAN
idiv ecx
cmp eax,0
jge low_ok
xor eax,eax
low_ok:
cmp eax,STEPS
jle high_ok
mov eax,STEPS
high_ok:
imul eax,eax,STEP
cmp eax,edi
je draw
mov edi,eax
mov eax,[SELECTED]
call ENTRY_MAKE
test eax,eax
jz draw
mov ecx,edi
if WIDE <> 0
mov [eax+ENTRY_FIELD],cx
else
mov [eax+ENTRY_FIELD],cl
end if
draw:
push dword [BUTTON_X]
push dword [BUTTON_X+4]
push dword [BUTTON_X+8]
push dword [BUTTON_X+12]
push dword [DRAW_CHOICE]
mov [BUTTON_X],ebx
mov [BUTTON_X+4],esi
mov dword [BUTTON_X+8],SLIDER_W
mov dword [BUTTON_X+12],SLIDER_H
mov eax,edi
imul eax,eax,KNOB_SPAN
cdq
mov ecx,STEPS*STEP
idiv ecx
push 0
push KNOB_W
push edi
push eax
push 0
call SLIDER_RENDER
add esp,20
pop dword [DRAW_CHOICE]
pop dword [BUTTON_X+12]
pop dword [BUTTON_X+8]
pop dword [BUTTON_X+4]
pop dword [BUTTON_X]
pop edi
pop esi
pop ebx
ret
]]

-- The page button over the panel's title: drawn like the outpost's own troop buttons, and a
-- left click on it switches the page.
templates.toggle = [[
push ebx
push esi
mov ebx,[MENU_X]
add ebx,TOGGLE_X
mov esi,[MENU_Y]
add esi,TOGGLE_Y
xor ecx,ecx
mov eax,[MOUSE+MOUSE_X]
sub eax,ebx
cmp eax,TOGGLE_W
jae draw
mov eax,[MOUSE+MOUSE_Y]
sub eax,esi
cmp eax,TOGGLE_H
jae draw
mov ecx,1
cmp dword [MOUSE+LEFT_CLICK],0
je draw
mov dword [MOUSE+LEFT_CLICK],0
xor dword [TOGGLE_STATE],1
push ecx
push CLICK_SOUND
mov ecx,SOUNDS
call PLAY_SOUND
call PAD
pop ecx
draw:
push dword [BUTTON_X]
push dword [BUTTON_X+4]
push dword [BUTTON_X+8]
push dword [BUTTON_X+12]
push dword [BUTTON_HOVER]
push dword [BUTTON_IMAGE]
push dword [DRAW_CHOICE]
mov [BUTTON_X],ebx
mov [BUTTON_X+4],esi
mov dword [BUTTON_X+8],TOGGLE_W
mov dword [BUTTON_X+12],TOGGLE_H
mov [BUTTON_HOVER],ecx
mov dword [BUTTON_IMAGE],TEXT_BUTTON
push ecx
call BUTTON_RENDER
pop ecx
push 0
push 0
push 0x12
test ecx,ecx
jnz hot
push 0x3E66
push 0xC2F0EB
jmp words
hot:
push 0
push 0xCCFAFF
words:
push 1
lea eax,[esi+7]
push eax
lea eax,[ebx+TOGGLE_HALF]
push eax
mov eax,[TOGGLE_STATE]
push dword [TOGGLE_TEXTS+eax*4]
mov ecx,TEXT_MANAGER
call SHADOW_TEXT
pop dword [DRAW_CHOICE]
pop dword [BUTTON_IMAGE]
pop dword [BUTTON_HOVER]
pop dword [BUTTON_X+12]
pop dword [BUTTON_X+8]
pop dword [BUTTON_X+4]
pop dword [BUTTON_X]
pop esi
pop ebx
ret
]]

-- The troop button renderer (prologue: push esi / push edi / mov edi,[esp+0xC] / mov ecx,edi,
-- 8 bytes). On the defender page: lit when the troop is picked, named after it.
templates.buttonRender = [[
cmp dword [MODE],0
jne own
push esi
push edi
mov edi,[esp+0xC]
mov ecx,edi
jmp RESUME
own:
push esi
push edi
mov edi,[esp+0xC]
mov eax,[SELECTED]
call ENTRY_GET
mov esi,1
test eax,eax
jz have
movzx esi,word [eax+4]
have:
mov edx,[BUTTON_HOVER]
xor eax,eax
bt esi,edi
setc al
mov [BUTTON_HOVER],eax
push edx
call BUTTON_RENDER
pop edx
push 0
push 0
push 0x12
test edx,edx
jnz hot
push 0x3E66
push 0xC2F0EB
jmp words
hot:
push 0
push 0xCCFAFF
words:
push 1
mov ecx,[BUTTON_X+4]
add ecx,7
push ecx
mov eax,[BUTTON_X+8]
cdq
sub eax,edx
sar eax,1
add eax,[BUTTON_X]
push eax
mov eax,[SELECTED]
imul eax,eax,B_STRIDE
mov ecx,edi
and ecx,7
cmp word [eax+B_TYPE],ARAB_OUTPOST
jne euro
add ecx,8
euro:
cmp ecx,11
jne defenderWords
; Use the Arabian Attacker button's shorter native Swordsmen label.
push 11
push 0x40
jmp getDefenderWords
defenderWords:
push dword [DEFENDER_TEXTS+ecx*4]
push UNIT_HELP_GROUP
getDefenderWords:
mov ecx,TEXT_MANAGER
call GET_TEXT
push eax
mov ecx,TEXT_MANAGER
call SHADOW_TEXT
pop edi
pop esi
ret
]]

-- The troop button click (prologue: mov eax,[selected], 5 bytes). On the defender page it
-- picks or drops that troop.
templates.buttonClick = [[
cmp dword [MODE],0
jne own
mov eax,[SELECTED]
jmp RESUME
own:
mov eax,[SELECTED]
call ENTRY_MAKE
test eax,eax
jz done
mov ecx,[esp+4]
cmp ecx,8
jae done
mov edx,1
shl edx,cl
xor word [eax+4],dx
done:
ret
]]

-- The size slider, which is the amount on the defender page and with WAVES_ON the exact wave
-- size on the attacker page (prologue: mov ecx,[esp+8] / mov eax,[selected], 9 bytes). Messages: 1 set up (min, max, value), 2 and 3 set the value, 4 read
-- it, 5 one step less, 6 one more. FIELD is the entry byte (6 defenders); SYNC 1 also writes the
-- game's own defender count (1 to its 8 slots).
templates.slider = [[
cmp dword [MODE],0
jne own
if WAVES_ON <> 0
jmp WAVE_SLIDER
else
mov ecx,[esp+8]
mov eax,[SELECTED]
jmp RESUME
end if
own:
mov eax,[SELECTED]
call ENTRY_MAKE
test eax,eax
jz done
mov ecx,[esp+8]
cmp ecx,1
jne not_setup
mov edx,[esp+0xC]
mov dword [edx],0
mov edx,[esp+0x10]
mov dword [edx],TOP
jmp report
not_setup:
cmp ecx,2
je take
cmp ecx,3
je take
cmp ecx,5
je less
cmp ecx,6
je more
jmp report
take:
mov edx,[esp+0x14]
mov ecx,[edx]
cmp ecx,0
jge low_ok
xor ecx,ecx
low_ok:
cmp ecx,TOP
jle high_ok
mov ecx,TOP
high_ok:
mov [eax+FIELD],cl
jmp changed
less:
movzx ecx,byte [eax+FIELD]
sub ecx,STEP
jge less_ok
xor ecx,ecx
less_ok:
mov [eax+FIELD],cl
jmp changed
more:
movzx ecx,byte [eax+FIELD]
add ecx,STEP
cmp ecx,TOP
jle more_ok
mov ecx,TOP
more_ok:
mov [eax+FIELD],cl
changed:
if SYNC <> 0
movzx ecx,byte [eax+FIELD]
test ecx,ecx
jnz some
mov ecx,1
some:
cmp ecx,VANILLA_SLOTS
jbe fits
mov ecx,VANILLA_SLOTS
fits:
mov edx,[SELECTED]
imul edx,edx,B_STRIDE
mov [edx+B_DEFENDERS],cl
end if
report:
movzx ecx,byte [eax+FIELD]
mov edx,[esp+0x14]
mov [edx],ecx
done:
ret
]]

return templates
