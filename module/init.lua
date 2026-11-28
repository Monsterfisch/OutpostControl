--[[
  Outpost Control

  Outposts (the European and Arabian outposts of the map editor) send waves of attackers
  and keep a handful of archers around themselves. This module adds to that:

  1. Defenders. A second page in the outpost's panel (a button over the panel's title switches
     it) uses the same eight troop buttons and the size slider: the buttons pick which troops
     guard the outpost (several may be picked, they take turns), the slider how many (0 to 50).
     The game only has 8 defender slots, so an outpost with settings keeps its guards in a list
     of its own, and waits 9600 / amount ticks between guards (the game: 1200 for its 8). The
     game's own defender count field gets the amount (1 to 8), so the map still means about
     the same without the module.
  2. Wave settings. The Attackers panel has Size and Timing views when fixed intervals
     are enabled. Growth sets how much each wave grows, and Interval sets the wait before
     the next wave starts forming. Zero interval uses the game's timing.
  3. Jobs. When a wave leaves, its troops are split by unit type into troops with a job of
     their own: filling the moat, hacking at walls and gates, burning or wrecking buildings,
     holding ground at firing distance, screening another tribe, or flanking the castle.
     Sibling tribes share an approach. Variation changes the split and approach per wave.
     Ranged troops that cannot split use defensive orders in the original tribe.
  4. Siege engines advance toward fortifications and use the game's shooting code.
     Engines prioritize towers and gatehouses, then walls, then other buildings.
     Fire ballistas shoot only enemy troops.

  The per-outpost settings and the jobs live in the save (and in the map) through the
  map-extensions module. Without this module the game ignores that data.
]]

local MODULE_NAME = "outpost-control"

-- Constants live in one table: a chunk may only have 200 locals.
local K = {}
K.SAVE_SECTION = "outpost-control"
K.SAVE_BUILDINGS = "buildings.bin"
K.SAVE_JOBS = "jobs.bin"
K.SAVE_GUARDS = "guards.bin"
K.SAVE_WAVES = "waves.bin"
K.SAVE_GROWTH = "growth.bin"      -- the size growth (buildings.bin keeps a 0 where 1.0.15 kept speed)

K.SAVE_INTERVAL = "interval.bin"

local templates = require("templates")

-- Jobs.
K.JOB_NONE, K.JOB_ENGAGE, K.JOB_BUILDINGS, K.JOB_MOAT, K.JOB_WALLS, K.JOB_LORD, K.JOB_PATROL = 0, 1, 2, 3, 4, 5, 6
K.JOB_SIEGE = 7
K.JOB_OVERWATCH, K.JOB_ESCORT, K.JOB_FLANK = 8, 9, 10
K.JOB_UNSPLIT_RANGED = 11
K.JOB_LAST = K.JOB_UNSPLIT_RANGED
K.JOB_NAMES = { [0] = "as the game does", "fight troops", "attack buildings", "fill the moat",
  "attack walls and gates", "hunt the lord", "ride round the castle", "shoot on the way", "overwatch",
  "escort", "flank", "defend with ranged troops" }
K.ANCHOR_PRIORITY = { [K.JOB_SIEGE] = 3, [K.JOB_WALLS] = 2, [K.JOB_MOAT] = 1 }

-- Siege engines an outpost sends (catapults, and fire ballistas at an Arabian one; trebuchets
-- and mangonels if a map's outposts were made to send them): like the AI's raid engines they are
-- ordered at whatever is in their range on their way. Fire ballistas shoot only troops.
K.FIRE_BALLISTA = 77
K.SIEGE = { [39] = "catapult", [40] = "catapult", [41] = "catapult", [K.FIRE_BALLISTA] = "ballista" }
-- Their projectile, whose range (in tiles, straight line) the game's range table holds.
K.SIEGE_PROJECTILE = { [39] = 2, [40] = 3, [41] = 4, [77] = 0x25 }

K.SIEGE_RANGE_KEY = { [39] = "catapult", [40] = "trebuchet", [77] = "fire_ballista" }

-- The AI's attack army: behaviour types and their troop slots (aiTribeIDs), lord-hunt's table.
K.BEHAVIOUR_MAIN, K.BEHAVIOUR_BACKUP = 20, 17
K.ARMY_SLOTS = { [20] = { 0xC0, 0xC7 }, [17] = { 0xBA, 0xBC } }
K.RANGED_PROJECTILE = { [22] = 1, [23] = 7, [70] = 1, [72] = 0x21, [74] = 1, [76] = 0x22 }
K.MOAT_CAPABLE = { [22] = true, [24] = true, [25] = true, [26] = true, [30] = true, [71] = true }
-- AICState::addUnitToItsTribe(unit, behaviour) (lord-hunt's pattern).
K.AOB_ADD_TO_ITS_TRIBE = "56 57 8B 7C 24 0C 8B C7 69 C0 90 04 00 00 0F BF 90 ? ? ? ? 8B F2 69 F6 F4 39 00 00"

-- Each unit type an outpost sends: the first job, its default share in percent, the job of the
-- rest, and the setting that holds the share.
K.PLANS = {
  { kind = 71, name = "slaves", first = K.JOB_MOAT, rest = K.JOB_BUILDINGS, share = 50 },
  { kind = 24, name = "spearmen", first = K.JOB_MOAT, rest = K.JOB_ESCORT, share = 40 },
  { kind = 26, name = "macemen", first = K.JOB_FLANK, rest = K.JOB_BUILDINGS, share = 40 },
  { kind = 27, name = "swordsmen", first = K.JOB_WALLS, rest = K.JOB_ESCORT, share = 60 },
  { kind = 75, name = "arab_swordsmen", first = K.JOB_WALLS, rest = K.JOB_ESCORT, share = 60 },
  { kind = 28, name = "knights", first = K.JOB_FLANK, rest = K.JOB_PATROL, share = 50 },
  { kind = 22, name = "archers", first = K.JOB_OVERWATCH, rest = K.JOB_ESCORT, share = 60 },
  { kind = 70, name = "arab_archers", first = K.JOB_OVERWATCH, rest = K.JOB_ESCORT, share = 60 },
  { kind = 72, name = "slingers", first = K.JOB_FLANK, rest = K.JOB_OVERWATCH, share = 40 },
  { kind = 74, name = "horse_archers", first = K.JOB_PATROL, rest = K.JOB_FLANK, share = 70 },
  { kind = 76, name = "fire_throwers", first = K.JOB_BUILDINGS, rest = K.JOB_ESCORT, share = 50 },
}

K.DEFAULTS = {
  defenders = { enabled = false, walls = false, knights = false },
  waves = { exact = false, interval = false },
  growth = { enabled = false },
  jobs = { enabled = false, variation = 0 },
  siege = { enabled = false },
  join = { enabled = false },
  retarget = { enabled = false },
  diagnostics = { log = false },
}
for _, plan in ipairs(K.PLANS) do K.DEFAULTS.jobs[plan.name] = plan.share end

-- Defender troops per button, European outpost then Arabian outpost.
K.DEFENDER_TYPES = {
  22, 23, 24, 25, 26, 27, 28, 37,
  70, 72, 74, 75, 71, 73, 76, 23,
}
-- Their names: the unit buttons' help texts (group 8), at the same index in every edition.
K.UNIT_HELP_GROUP = 8
K.DEFENDER_TEXTS = {
  244, 248, 245, 246, 247, 249, 250, 254,
  315, 317, 319, 320, 316, 318, 321, 248,
}
K.CATALOGS = { german = "de", french = "fr", russian = "ru", hungarian = "hu", turkish = "tr",
  chinese = "ch", spanish = "es", persian = "fa" }

-- The left column of the panel. The game has the size slider at y 510 and the start delay
-- slider at 568, with their names at the left and their ends written above them. With growth on
-- the two move up and the growth slider goes below them; the ends are left out. A slider's knob
-- reaches 5 px above the bar and 31 below its top, so three rows of 36 px just fit.
K.SLIDER_X, K.SLIDER_W, K.SLIDER_H = 130, 104, 26
K.GAME_SIZE_Y, K.GAME_DELAY_Y = 510, 568
K.SIZE_Y, K.DELAY_Y, K.GROWTH_Y = 494, 530, 566
K.SECOND_ROW_Y = 530
K.INTERVAL_FIELD, K.INTERVAL_MAX, K.INTERVAL_STEP = 10, 600, 10
K.LABEL_X, K.LABEL_DROP = 0x19, 7
K.TEXT_SIZE, K.TEXT_DELAY = 0x12, 0x15     -- the game's own "Size" and "Start Delay"
K.NUMBER_X = 242                  -- each slider's value, right of it (the troop buttons start at 280)
K.TICKS_PER_SECOND = 40           -- at normal game speed
K.SIZE_FIELD, K.DELAY_FIELD = 0x30E, 0x310
K.WAVE_FIELD = 0x30A              -- the size the forming wave troop leaves at
K.VANILLA_TOP = 5                 -- the game's size slider: multiplier 1 to 6
K.GROWTH_CAP = 999                -- the biggest a grown wave gets
-- The outpost troop kinds: 16 x 0x34 (8 European, 8 Arabian): +8 base size, +0xC size range.
K.KIND_STRIDE, K.KIND_BASE, K.KIND_RANGE, K.KINDS = 0x34, 8, 0xC, 16
-- UpdateOutpostBuilding: a new wave troop's size, (rand % range + base) * (size + 1).
K.AOB_WAVE_SIZE = "66 8B 81 ? ? ? ? 66 05 01 00 66 C7 86 ? ? ? ? ? 00 66 03 97 ? ? ? ? 66 0F AF D0 66 89 91"
K.WAVE_SIZE_AT, K.WAVE_SIZE_SIZE = 0x1F, 7
K.WAVE_SIZE_KINDS = { 0x14, { 0x66, 0x03, 0x97 } }
K.WAVE_START_AT, K.WAVE_START_SIZE = 4, 8  -- from the end of the guard slots: test ebp,ebp / jne
K.KNOB_W, K.KNOB_ABOVE, K.KNOB_H = 15, 5, 36

-- Guards in a troop of their own per outpost, for a stance: melee guards defensive, slaves
-- aggressive, knights aggressive and on patrol round the outpost (attacking enemy buildings they
-- come near), horse archers aggressive and on patrol round the outpost. Archers, crossbowmen,
-- slingers and fire throwers stay as the game has its archers (no troop).
K.STANCE_DEFENSIVE, K.STANCE_AGGRESSIVE = 1, 2
K.GUARD_GROUP = {
  [24] = "defensive", [25] = "defensive", [26] = "defensive", [27] = "defensive", [37] = "defensive",
  [73] = "defensive", [75] = "defensive",
  [71] = "aggressive", [74] = "patrol", [28] = "knights",
}
K.GUARD_STANCE = { defensive = 1, aggressive = 2, patrol = 2, knights = 2 }
K.GUARD_INDEX = { defensive = 1, aggressive = 2, patrol = 3, knights = 4 }
K.GUARD_PATROLS = { patrol = true, knights = true }
K.RIDER_REACH = 10                -- tiles: an enemy building this close draws a patrolling knight troop
K.KNIGHT = 28
-- Guards who man walls and towers near their outpost: every foot soldier; riders stay below.
K.WALL_GUARDS = { [22] = true, [23] = true, [24] = true, [25] = true, [26] = true, [27] = true,
  [37] = true, [70] = true, [71] = true, [72] = true, [73] = true, [75] = true, [76] = true }
K.WALL_RADIUS = 16                -- tiles from the outpost's middle
K.WALL_CROWD = 2                  -- guards closer than this to a spot (tiles) crowd it
K.WALL_TRIES = 24                 -- least crowded spots offered to the area test
-- Stone gatehouses and towers, whose tops guards stand on (walls are tiles, not buildings).
K.WALL_BUILDINGS = { [45] = true, [46] = true, [60] = true, [61] = true, [74] = true, [75] = true,
  [76] = true, [77] = true, [78] = true }
K.NOT_WALKABLE_FLAG = 0x2         -- with the wall flag: a wall tile nobody stands on
K.FLAGS_TO_WALL_OWNER = 0x2C6E50 - 0x165160
-- UpdateOutpostBuilding, before the guard site: where it sends a new guard (the area map, the
-- path finder and its area test, setDestinationForUnit).
K.GUARD_AREA = { -0x99, { 0x0F, 0xBF, 0x04, 0x55 } }
K.GUARD_PATHS = { -0x67, { 0xB9 } }
K.GUARD_NAVIGATE = -0x62
K.GUARD_DESTINATION = -0x05
K.GUARD_PATROL_NEAR, K.GUARD_PATROL_FAR = 7, 15   -- tiles from the outpost's middle
K.GUARD_PATROL_POINTS = 6         -- a troop route holds 9 points; the first is where it starts
K.GUARD_PATROL_TRIES = 12
K.WALL_FLAG = 0x100               -- tile flag: a wall stands here
-- The tile flags (lord-hunt's pattern) and, at a fixed distance from them, the building on each
-- tile and the map rows (both exes).
K.AOB_TILE_FLAGS = "F7 04 9D ? ? ? ? 00 01 00 00"
K.TILE_FLAGS_OPERAND = 0x03
K.FLAGS_TO_BUILDINGS = 0x2029B0 - 0x165160
K.FLAGS_TO_ROWS = 0x8A40F8 - 0x165160

K.MAX_DEFENDERS = 50
K.VANILLA_SLOTS = 8           -- the game's own defender slots
K.USUAL_DEFENDERS = 7         -- the game rolls 6 or 7 when the field is unset
K.MAX_GUARDS = K.MAX_DEFENDERS  -- the module's guard list, per outpost: unit id, unit uid
K.GUARD_PACE = 9600           -- ticks for a full refill (the game: 8 guards, 1200 each)
K.LONGEST_WAIT, K.SHORTEST_WAIT = 1200, 100
K.ENTRY_SIZE, K.ENTRY_SHIFT = 16, 4  -- per building: uid, troop bits, amount, growth, wave size
K.MAX_BUILDINGS = 2000         -- the building array, both exes
K.MAX_TRIBES = 1250            -- the troop array, both exes
K.EURO_ARCHER, K.ARAB_ARCHER = 22, 70
K.OUTPOST_EURO, K.OUTPOST_ARAB = 106, 107
K.STANCE_AGGRESSIVE = 2
K.ORDER_ATTACK_UNIT, K.ORDER_ATTACK_WALL_AT, K.ORDER_FILL_MOAT = 4, 0x17, 7
K.ORDER_ATTACK_BUILDING = 9
K.TEXT_BUTTON = 332           -- the outpost's own text button picture
-- The page button, over the panel's title (the title is drawn at 25, 463).
K.TOGGLE_X, K.TOGGLE_Y, K.TOGGLE_W, K.TOGGLE_H = 18, 456, 125, 30
K.SCOPE_X = 148

K.PATROL_RADIUS = 25          -- tiles round the lord
K.PATROL_ARRIVED = 4
K.FLANK_MISSES = 3           -- failed moves before a flank turns inward
K.WAIT = { [K.JOB_MOAT] = 3, [K.JOB_WALLS] = 3, [K.JOB_LORD] = 2, [K.JOB_PATROL] = 10 }

---------------------------------------------------------------------------------------
-- What the game's code looks like where this module reads it (the same in both exes)
---------------------------------------------------------------------------------------

-- UpdateOutpostBuilding: is the defender count set (cmp byte [ecx+field],0 / jle roll).
K.AOB_DEFENDER_COUNT = "80 B9 ? ? ? ? 00 0F 8E ? ? ? ? 66 83 81 ? ? ? ? FF 0F B7 81 ? ? ? ? 66 85 C0 0F 8D"
K.DEFENDER_COUNT_SIZE = 13
K.DEFENDER_COUNT_FIELD = 0x2A7
-- UpdateOutpostBuilding: every 1200 ticks, before counting its defenders (mov word [timer],1200).
K.AOB_GUARD_COUNT = "8B 3D ? ? ? ? 8B C7 69 C0 2C 03 00 00 66 C7 81 ? ? ? ? B0 04 0F B7 90"
K.GUARD_COUNT_AT, K.GUARD_COUNT_SIZE = 0x0E, 9
K.TIMER_FIELD = 0x29A
-- UpdateOutpostBuilding: finding a free slot for the new defender (mov ebp,[current]).
K.AOB_GUARD_RECORD = "8B 2D ? ? ? ? 8B D5 69 D2 2C 03 00 00 33 C9 81 C2 ? ? ? ? EB"
K.GUARD_RECORD_SIZE = 6
K.GUARD_RECORDED = 0x90       -- mov ebp,[esp+0x10], after the slot loop
-- UpdateOutpostBuilding: the defender's type (archer, or Arab archer at an Arabian outpost).
K.AOB_DEFENDER_TYPE = "66 83 B9 ? ? ? ? 6B BA 16 00 00 00 75 05 BA 46 00 00 00"
K.DEFENDER_TYPE_SIZE = 20
-- UpdateOutpostBuilding, after a wave: add 100 to the wave counter, 4 to the unit pace.
K.AOB_GROWTH = "66 83 80 ? ? ? ? 64 66 83 80 ? ? ? ? 04 5D 5F 5E 5B 83 C4 1C C3"
K.GROWTH_SIZE = 16
K.WAVES_FIELD, K.PACE_FIELD = 0x316, 0x318
-- The idle wait after the game applies either of its mode-dependent minimums.
K.AOB_INTERVAL = "83 F9 64 7D 05 B9 64 00 00 00 66 83 80 ? ? ? ? 01 0F B7 90 ? ? ? ? 0F BF D2 3B D1 0F 8C"
K.INTERVAL_AT, K.INTERVAL_SIZE = 10, 8
K.IDLE_TIMER_FIELD = 0x308
-- UpdateOutpostBuilding: aiRegisterTribeAndAssignTarget(tribe, uid) sends the wave.
K.AOB_LAUNCH = "8B 80 ? ? ? ? 50 56 B9 ? ? ? ? E8 ? ? ? ? A1 ? ? ? ? 69 C0 2C 03 00 00 66 C7 80 ? ? ? ? 00 00 66 83"
K.LAUNCH_AI = { 0x08, { 0xB9 } }
K.LAUNCH_CALL = 0x0D
K.LAUNCH_CURRENT = { 0x12, { 0xA1 } }
K.REGISTER_SET_TARGET = 0x89      -- aiRegisterTribeAndAssignTarget: call setTargetForTribe...
-- makeOutpostTribesAttack: every registered outpost troop -> decideOnTribeAttackLocation.
K.AOB_MAKE = "53 55 56 8B E9 57 8D ? ? ? ? 00 8D ? ? ? ? 00 BB E8 03 00 00 0F BF 06 85 C0 74 ? 8B C8 "
  .. "69 C9 ? ? 00 00 8B 91 ? ? ? ? 3B 17 75 ? 50 8B CD E8"
K.MAKE_STRIDE = { 0x20, { 0x69, 0xC9 } }
K.MAKE_UID = { 0x26, { 0x8B, 0x91 } }
K.MAKE_CALL = 0x33
-- decideOnTribeAttackLocation(tribe): the outpost troops' own order logic.
K.AOB_DECIDE = "83 EC 0C 57 8B 7C 24 14 6A 01 6A 00 57 89 4C 24 10 E8 ? ? ? ? 85 C0"
K.DECIDE_BUSY = 0x11
K.DECIDE_TARGET = { 0x41, { 0x0F, 0xBF, 0xAE } }
K.DECIDE_TRIBES = { 0x91, { 0xB9 } }
K.DECIDE_LEAD = 0xA9
K.DECIDE_UNIT_Y = { 0xC6, { 0x0F, 0xBF, 0x88 } }
K.DECIDE_OWNER = { 0xD9, { 0x8B, 0x86 } }
K.DECIDE_PATHS = { 0xE3, { 0xB9 } }
K.DECIDE_PATH = 0xE8
K.DECIDE_ROWS = { 0xFE, { 0x8B, 0x14, 0x8D } }
K.DECIDE_UNITS_THIS = { 0x10F, { 0xB9 } }
K.DECIDE_RELAY = 0x114
K.DECIDE_KIND = { 0x145, { 0x0F, 0xB7, 0x86 } }
K.DECIDE_BUILDING_UID = { 0x187, { 0x8B, 0x90 } }
K.DECIDE_CAMP = { 0x229, { 0x8B, 0x98 } }
K.DECIDE_REACH = 0x24C
K.DECIDE_COMMAND = 0x263

-- The outpost panel: its text, the troop buttons, their click, the two sliders.
K.AOB_PANEL = "A1 ? ? ? ? 69 C0 2C 03 00 00 33 D2 66 83 B8 ? ? ? ? 6B 75 05 BA 09 00 00 00 A1 ?"
K.PANEL_SELECTED = { 0x00, { 0xA1 } }
K.PANEL_TYPE = { 0x0D, { 0x66, 0x83, 0xB8 } }
K.PANEL_MENU_Y = { 0x1C, { 0xA1 } }
K.PANEL_MENU_X = { 0x21, { 0x8B, 0x0D } }
K.PANEL_TEXT_MANAGER = { 0x3E, { 0xB9 } }
K.PANEL_RENDER_TEXT = 0x4E
K.AOB_BUTTON_RENDER = "56 57 8B 7C 24 0C 8B CF BA 01 00 00 00 D3 E2 8B 0D ? ? ? ? 8B C1 69 C0 2C 03 00 00 "
  .. "33 F6 66 83 B8 ? ? ? ? 6B 75"
K.BUTTON_RENDER_SIZE = 8
K.RENDER_SELECTED = { 0x0F, { 0x8B, 0x0D } }
K.RENDER_HOVER = { 0x2E, { 0x83, 0x3D } }
K.RENDER_MASK = { 0x3B, { 0x0F, 0xBF, 0x80 } }
K.RENDER_BUTTON = 0x5A
K.RENDER_W = { 0xA6, { 0xA1 } }
K.RENDER_Y = { 0xAB, { 0x8B, 0x0D } }
K.RENDER_X = { 0xBC, { 0x03, 0x05 } }
K.RENDER_TEXT_MANAGER = { 0xCA, { 0xB9 } }
K.RENDER_SHADOW_TEXT = 0xDA
K.AOB_BUTTON_CLICK = "A1 ? ? ? ? 8B 4C 24 04 69 C0 2C 03 00 00 BA 01 00 00 00 D3 E2 8D 80 ? ? ? ? 66 31 10"
K.BUTTON_CLICK_SIZE = 5
K.AOB_SLIDER = "8B 4C 24 08 A1 ? ? ? ? 83 C1 FF 83 F9 05 0F 87 ? ? ? ? FF 24 8D ? ? ? ? 8B 4C 24 0C "
  .. "69 C0 2C 03 00 00 8B 54 24 10 C7 01 00 00 00 00 8B 4C 24 14 C7 02 "
K.AOB_SIZE = K.AOB_SLIDER .. "05 00 00 00"
K.AOB_DELAY = K.AOB_SLIDER .. "C0 5D 00 00"
K.PANEL_GET_TEXT = 0x43
K.SLIDER_FIELD = { 0x3A, { 0x0F, 0xBF, 0x80 } }   -- msg 1: movsx eax, word [eax + field]
K.SLIDER_SIZE = 9
K.SLIDER_SELECTED = { 0x04, { 0xA1 } }
-- The game's button picture renderer: the picture index and the draw buffer choice.
K.BUTTON_IMAGE = { 0x00, { 0x8B, 0x0D } }
K.BUTTON_DRAW_CHOICE = { 0x1A, { 0xC7, 0x05 } }

-- handleMenuElementsCallbacks: the mouse (+0x10 x, +0x14 y, +0x34 left click this frame).
K.AOB_MENU_ITEM = "8B 56 10 8B 46 4C 8B 4E 0C 52 8B 50 08 03 56 08 8B 40 04 03 46 04 51 52 50 B9 ? ? ? ? E8"
K.MENU_ITEM_MOUSE = { 0x19, { 0xB9 } }
K.MOUSE_X, K.MOUSE_Y, K.LEFT_CLICK, K.LEFT_HELD = 0x10, 0x14, 0x34, 0x40
-- ToolbarButtonPressed (found 0x1B in, improved-tunnelers jumps over its start): the click sound.
K.AOB_TOOLBAR = "A1 ? ? ? ? 8B C8 69 C9 F4 39 00 00 39 99 ? ? ? ? 74 18 39 1D ?"
K.TOOLBAR_PATTERN_OFFSET = 0x1B
K.TOOLBAR_SOUND_ID = { 0x227, { 0x68 } }
K.TOOLBAR_SOUNDS = { 0x22C, { 0xB9 } }
K.TOOLBAR_PLAY_SOUND = 0x23D

-- Troop functions (the same patterns lord-hunt uses).
K.AOB_ADD_TO_TRIBE = "53 8B 5C 24 08 56 57 8B 7C 24 14 8B C7 69 C0 ? ? 00 00 66 83"
K.AOB_REMOVE_FROM_TRIBE = "53 55 56 8B 74 24 10 8B D9 8B CE 69 C9 90 04 00 00 66 83 B9 ? ? ? ? 00 57 8B 7C 24 18"
K.AOB_CREATE_TRIBE = "53 55 8B 6C 24 0C 56 57 BF ? ? 00 00 2B FD 33 DB 3B FB 7E"
K.AOB_INSTRUCTION = "83 EC 1C 8B 44 24 20 69 C0 ? ? 00 00 53 8B 5C 24 30 55 8D 2C 08 33 D2 56 0F BF 75 5C"
K.AOB_STANCE = "8B 44 24 04 66 8B 54 24 08 69 C0 ? ? 00 00 66 89 94 08 ? ? 00 00 C7 05"
-- giveTribeMoveInstruction(tribe, x, y, patrol, store as route, speed) and addRallyPoint(tribe,
-- x, y, step) (lord-hunt's and attack-move's ground): a patrol is a move order flagged 1 plus
-- route points; the troop walks them in a loop.
K.AOB_MOVE = "83 EC 34 33 C0 55 8B 6C 24 44 57 8B 7C 24 44 3B F8 89 4C 24 08 89 44 24 18"
K.AOB_ADD_POINT = "8B 44 24 04 8B D0 69 C0 ? ? 00 00 69 D2 ? ? 00 00 56 8B 74 24 14 57 66 8B 7C 24 10 03 D6"
-- The team table (lord-hunt's pattern): dword per player.
K.AOB_TEAMS = "8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?"
K.TEAMS_OPERAND = 0x03
-- acquireShootTarget and its native range-table instruction.
K.AOB_ACQUIRE = "83 EC 40 53 56 57 8B 7C 24 50 69 FF 90 04 00 00 8B F1 0F BF 84 37 AA 06 00 00"
K.ACQUIRE_RANGE = 0x131
K.RANGE_READ = { 0x8B, 0x04, 0x85 }
-- The native crossbow range check also reads from that table.
K.AOB_XBOW_RANGE = "83 FB 17 75 0B 8B 0D ? ? ? ? 0F AF C9 EB 44 83 FB 46"
K.XBOW_RANGE_ENTRY = { 5, { 0x8B, 0x0D } }
-- updateUnits, where it calls each unit's update function from the table by unit type.
K.AOB_UPDATE_CALL = "0F BF 91 A2 06 00 00 8B 04 95 ? ? ? ? FF D0"
K.UPDATE_TABLE = { 0x07, { 0x8B, 0x04, 0x95 } }
K.UPDATE_CURRENT = { -0x19, { 0xA1 } }        -- mov eax,[current unit], before the patched part
K.BALLISTA_IDLE_DELAY = { 0xC3, { 0x8B, 0x86 } }  -- native idle countdown before target acquisition
-- The game tick counter: mov ecx, [edi+0x998] / mov edx, [ticks] in updateUnits. The mask load
-- before it is patched by other modules.
K.AOB_TICKS = "8B 8F 98 09 00 00 8B 15 ? ? ? ?"
K.TICKS_OPERAND = 8
K.OUTPOST_BEHAVIOUR = 0x32        -- every unit an outpost spawns
K.SIEGE_EVERY = 15                -- check each engine every 16 ticks (0.4 s at normal speed)
K.STATE_MOVING = 0x65
K.STATE_WALKING = 1               -- siege engines walk in state 1 as well as 0x65
K.STATE_CREEPING = 9              -- the AI siege code walking an engine forward in steps
K.UNIT_TYPES = 80
K.STATE_SHOOT, K.STATE_LOAD, K.STATE_FIRE = 8, 2, 4
K.SHOOTING = { [K.STATE_SHOOT] = true, [K.STATE_LOAD] = true, [K.STATE_FIRE] = true }
K.SHOOT_BEFORE_STOP = 10          -- what the game's own idle code sets
K.SIEGE_TRIES, K.SIEGE_REFRESH = 3, 160
K.SIEGE_WALL_RADIUS, K.SIEGE_CELL = 48, 4
K.SIEGE_BUCKET, K.SIEGE_RETRY_DISTANCE = 32, 12
K.SIEGE_SHORTLIST = { 8, 6, 6 }
K.SIEGE_GATE = { [47] = true, [48] = true, [49] = true }
K.MAP_TILES = 80400
K.UNSAFE_TERRAIN = 0xC0100109 -- oil, moat, river, walls, pitch and sea
K.STATION_OFFSETS = {
  { 0, 0 }, { 2, 0 }, { 0, 2 }, { -2, 0 }, { 0, -2 },
  { 2, 2 }, { 2, -2 }, { -2, 2 }, { -2, -2 },
}
-- acquireShootTarget's attack-at-tile branch.
K.AOB_SHOOT_WALL = "66 3D 17 00 0F 85 ? ? ? ? 0F B7 84 37 FE 09 00 00 0F B7 8C 37 FC 09 00 00 "
  .. "0F BF C0 0F BF C9 8D 14 40 8B 1C 95 ? ? ? ? 50 03 D9 51 B9 ? ? ? ? E8 ? ? ? ? 85 C0"
-- processDamageToBuilding tests health and then the building kind's damageability.
K.AOB_DAMAGEABLE = "0F B7 8E ? ? ? ? 89 15 ? ? ? ? 0F BF D1 83 3C 95 ? ? ? ? 00 74 ? F7 84 9F"
-- The game's "stop walking" (clears the unit's path), used by its attack orders.
K.AOB_HALT = "8B 44 24 04 69 C0 90 04 00 00 03 C1 33 C9 66 89 88 ? ? 00 00 66 89 88 ? ? 00 00 66 89 88 "
  .. "? ? 00 00 66 89 88 ? ? 00 00 C2 04 00"

-- MenuItem layout (0x50 bytes) and the outpost's static size slider item, which leads to the
-- building menu's item table and its constructor.
K.ITEM_SIZE, K.ITEM_TYPE, K.ITEM_ACTION, K.ITEM_PARAM, K.ITEM_IMAGE = 0x50, 0x00, 0x14, 0x18, 0x20
K.ITEM_MIN, K.ITEM_MAX, K.ITEM_VALUE = 0x3C, 0x40, 0x44
K.ITEM_Y, K.ITEM_RENDER, K.ITEM_HIDDEN = 0x08, 0x1C, 0x36
K.TYPE_GROUP, K.TYPE_LAST = 0x01000000, 0x66
K.AOB_BUILDING_MENU = "68 ? ? ? ? B9 ? ? ? ? E8 81 93 F5 FF C3 68 ? ? ? ? B9 ? ? ? ? E8 71 93 F5 FF C3"
K.AOB_BUILDING_MENU_EXTREME = "68 ? ? ? ? B9 ? ? ? ? E8 E1 92 F5 FF C3 68 ? ? ? ? B9 ? ? ? ? E8 D1 92 F5 FF C3"
K.SIZE_ITEM_FROM_GROUP = 9    -- group header, eight buttons, then the size slider

---------------------------------------------------------------------------------------
-- Layouts (read from the code above where they differ between the exes)
---------------------------------------------------------------------------------------

local U = { STRIDE = 0x490, STATE = 0x8C, TYPE = 0x8E, OWNER = 0x96, UID = 0x98, X = 0xC4, Y = 0xC6,
  TILE = 0xD4, DYING = 0x2A0, CLIMB = 0x360, ACTION = 0x2C0, TRIBE = 0x2D8, TRIBE_UID = 0x2E4, TARGET_BUILDING = 0x336,
  SHOOT_UNIT = 0x344, TARGETING = 0x39C, SHOOT_BEFORE_STOP = 0x3D8, TARGET_UNIT = 0x39E, TARGET_UID = 0x3A0, WALL_X = 0x3E8, WALL_Y = 0x3EA, BEHAVIOUR = 0x42A,
  IDLE_DELAY = 0x3BC, STATE_OFFSET = 0x614 }
local T = { OWNER = 0x2C, UID = 0x34, STATE = 0x40, SIZE = 0x5C }
local B = { STRIDE = 0x32C, STATE = 0xD0, TYPE = 0xD2, OWNER = 0xD6, UID = 0xD8, X = 0xEE, Y = 0xF0,
  SIZE = 0xF8, HEALTH = 0x10C, TRIBE_UID = 0x304, MASK = 0x300 }
local P = { STRIDE = 0x39F4, CAMP = 0x1D8, LORD = 0x21F8, LORD_UID = 0x21FC, AI_TYPE = 0x2300,
  TRIBE_IDS = 0x310C, TRIBE_UIDS = 0x329C }
K.LORD_TYPE = 55
K.MAP_SIZE = 400

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local rd32, rd16, rd8 = core.readInteger, core.readSmallInteger, core.readByte
local wr32, wr16, wr8 = core.writeInteger, core.writeSmallInteger, core.writeByte

local function scan(pattern, purpose)
  local found, address = pcall(core.AOBScan, pattern)
  if not found then
    error(MODULE_NAME .. ": " .. purpose .. " not found")
  end
  return address
end

local function expectBytes(address, bytes, purpose)
  for index, byte in ipairs(bytes) do
    if (rd8(address + index - 1) & 0xFF) ~= byte then
      error(string.format("%s: %s at 0x%X is not the code this module knows", MODULE_NAME, purpose, address))
    end
  end
end

local function readOperand(base, site, purpose)
  expectBytes(base + site[1], site[2], purpose)
  return rd32(base + site[1] + #site[2])
end

local function readCallTarget(base, offset, purpose)
  expectBytes(base + offset, { 0xE8 }, purpose)
  return base + offset + 5 + rd32(base + offset + 1)
end

local function readJumpTarget(at, purpose)
  expectBytes(at, { 0x0F }, purpose)
  return at + 6 + rd32(at + 2)
end

local function same(a, b, purpose)
  if a ~= b then
    error(string.format("%s: %s is not laid out as the module expects (0x%X, 0x%X)", MODULE_NAME, purpose, a, b))
  end
end

local function setting(config, group, name, maximum)
  local default = K.DEFAULTS[group][name]
  local section = config[group]
  if section == nil then return default end
  if type(section) ~= "table" then
    log(ERROR, MODULE_NAME .. ": invalid " .. group .. " settings type.")
    return default
  end
  local value = section[name]
  if value == nil then return default end
  if maximum and type(value) == "table" then value = value.sliderValue end
  local field = group .. "." .. name
  if type(value) ~= type(default) then
    log(ERROR, MODULE_NAME .. ": invalid " .. field .. " type.")
    return default
  end
  if maximum and (math.tointeger(value) == nil or value < 0 or value > maximum) then
    log(WARNING, MODULE_NAME .. ": invalid " .. field .. ". Using " .. default .. ".")
    return default
  end
  return value
end

local function strip(script)
  local lines = {}
  for line in script:gmatch("[^\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then lines[#lines + 1] = line end
  end
  return table.concat(lines, "\n") .. "\n"
end

-- Only the constants a script names go to the assembler (its buffer is small).
local function assemble(script, values)
  script = strip(script)
  local used = {}
  for name, value in pairs(values) do
    if script:find(name, 1, true) then used[name] = value end
  end
  return core.allocateAssembly(script, used)
end

local function relativePatch(opcode, site, target, size)
  local bytes = { opcode, core.itob(core.getRelativeAddress(site, target, -5)) }
  for _ = 6, size do bytes[#bytes + 1] = 0x90 end
  return bytes
end

---------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------

local G = {}             -- addresses
local F = {}             -- the game's functions, exposed to lua
local O = {}             -- options
local siegeCache = {}
local siegeRetries = {}
local orders = {}        -- per troop id: what this module last told it
local waveOf = {}         -- per troop id: UID and shared launch state
local guardTroops = {}   -- per outpost and stance group: the guards' troop (id, uid)
local wallSpots = {}     -- per guard sent onto a wall: { uid, x, y }
local guardInfo = {}     -- per guard troop id: { uid, outpost, group, attack = { id, uid } }
local words = {}         -- per panel word: the core.CString the game's label points to
local broken = false

local function diag(fmt, ...)
  if O.log then
    log(INFO, MODULE_NAME .. ": " .. string.format(fmt, ...))
  end
end

local function unit(id) return G.units + id * U.STRIDE end
local function tribe(id) return G.tribes + id * G.tribeStride end
local function building(id) return G.buildings + id * B.STRIDE end
local function player(p) return G.players + p * P.STRIDE end

local function tileAt(x, y)
  if x < 0 or y < 0 or x >= K.MAP_SIZE or y >= K.MAP_SIZE then return nil end
  return rd32(G.rows + y * 12) + x
end

local function team(p) return rd32(G.teams + p * 4) end

local function distance(ax, ay, bx, by)
  local dx, dy = math.abs(ax - bx), math.abs(ay - by)
  return dx > dy and dx or dy
end

local function setJob(id, job)
  if id <= 0 or id >= K.MAX_TRIBES then return end
  wr8(G.jobs + id, job)
  wr32(G.jobUids + id * 4, job ~= 0 and rd32(tribe(id) + T.UID) or 0)
  orders[id] = nil
  waveOf[id] = nil
end

local function aliveLord(p)
  if p < 1 or p > 8 then return nil end
  local id = rd32(player(p) + P.LORD)
  if id <= 0 then return nil end
  local u = unit(id)
  if rd16(u + U.STATE) ~= 2 or rd16(u + U.TYPE) ~= K.LORD_TYPE then return nil end
  if rd32(u + U.UID) ~= rd32(player(p) + P.LORD_UID) then return nil end
  return { id = id, uid = rd32(u + U.UID), x = rd16(u + U.X), y = rd16(u + U.Y), tile = rd32(u + U.TILE) }
end

---------------------------------------------------------------------------------------
-- Jobs: splitting a wave when it leaves
---------------------------------------------------------------------------------------

local function newTribe(owner, units, from, kind)
  local id = F.createTribe(G.tribesThis, owner)
  if id == nil or id <= 0 or id >= K.MAX_TRIBES then return nil end
  for _, u in ipairs(units) do
    F.removeFromTribe(G.tribesThis, u, from)
    F.addToTribe(G.tribesThis, u, id)
  end
  F.setStance(G.tribesThis, id, K.STANCE_AGGRESSIVE)
  wr16(tribe(id) + G.tribeKind, kind)
  return id
end

-- The option to hand a wave to its AI owner's attack army: every unit but the siege engines goes
-- into the attack troop the game's own reinforcement code (spawnUnitsForAITribe) would give it -
-- archers, crossbowmen, slingers, horse archers and fire throwers the backup troops, the rest the
-- main army - with the AI's own addUnitToItsTribe, which takes the smallest such troop. A unit
-- whose troop the AI does not have stays with the wave.
local function aiHasTroop(owner, behaviour)
  local slots = K.ARMY_SLOTS[behaviour]
  local base = player(owner)
  for slot = slots[1], slots[2] do
    local id = rd16(base + P.TRIBE_IDS + slot * 2)
    if id > 0 and id < K.MAX_TRIBES and rd32(tribe(id) + T.UID) == rd32(base + P.TRIBE_UIDS + slot * 4)
        and rd16(tribe(id) + T.STATE) == 2 then
      return true
    end
  end
  return false
end

local function joinArmy(t, owner)
  if rd32(player(owner) + P.AI_TYPE) == 0 then return end
  local joined, kept = 0, 0
  for id = 1, rd32(G.unitsThis) - 1 do
    local u = unit(id)
    if rd16(u + U.TRIBE) == t and rd16(u + U.STATE) == 2 and rd16(u + U.OWNER) == owner
        and K.SIEGE[rd16(u + U.TYPE)] == nil then
      local behaviour = K.RANGED_PROJECTILE[rd16(u + U.TYPE)] and K.BEHAVIOUR_BACKUP or K.BEHAVIOUR_MAIN
      if aiHasTroop(owner, behaviour) then
        F.removeFromTribe(G.tribesThis, id, t)
        F.addToItsTribe(G.aiState, id, behaviour)
        joined = joined + 1
      else
        kept = kept + 1
      end
    end
  end
  diag("player %d wave (troop %d): %d units to the attack army, %d stay", owner, t, joined, kept)
end

local function waveRoll(outpost, uid, counter)
  local value = (outpost * 0x9E3779B1 ~ uid ~ counter * 0x85EBCA77) & 0xFFFFFFFF
  value = ((value ~ (value >> 16)) * 0x7FEB352D) & 0xFFFFFFFF
  return value ~ (value >> 15)
end

local function onLaunch()
  local t, ai = rd32(G.launchTribe), rd32(G.launchThis)
  if t <= 0 or t >= K.MAX_TRIBES then return end
  local tb = tribe(t)
  if rd16(tb + T.STATE) ~= 2 then return end
  setJob(t, K.JOB_NONE)
  local owner = rd32(tb + T.OWNER)
  local wave, variation = nil, O.variation
  if O.jobs then
    local id = rd32(G.current)
    local b = building(id)
    local seed = waveRoll(id, rd32(tb + T.UID), rd16(b + K.WAVES_FIELD))
    wave = { x = rd16(b + B.X), y = rd16(b + B.Y), seed = seed, rank = 0,
      shift = variation >= 10 and seed % 3 - 1 or 0, side = (variation >= 10 and seed or id) % 2 * 2 - 1 }
  end

  if O.join then joinArmy(t, owner) end
  if not (O.jobs or O.siege) or rd16(tb + T.STATE) ~= 2 then return end

  local byKind, kinds = {}, {}
  local count = rd32(G.unitsThis)
  for index = 1, count - 1 do
    local u = unit(index)
    if rd16(u + U.TRIBE) == t and rd16(u + U.STATE) == 2 and rd16(u + U.OWNER) == owner then
      local kind = rd16(u + U.TYPE)
      if byKind[kind] == nil then
        byKind[kind] = {}
        kinds[#kinds + 1] = kind
      end
      table.insert(byKind[kind], index)
    end
  end
  table.sort(kinds)

  local groups, rangedGroups = {}, {}
  local twist = wave and variation >= 20 and wave.seed % 5 == 0
  local function put(job, id, ranged)
    groups[job] = groups[job] or {}
    table.insert(groups[job], id)
    if ranged then rangedGroups[job] = true end
  end
  for _, kind in ipairs(kinds) do
    local list = byKind[kind]
    local plan = O.jobs and O.plans[kind] or nil
    local ranged = K.RANGED_PROJECTILE[kind] ~= nil
    if O.siege and K.SIEGE[kind] ~= nil then
      for _, id in ipairs(list) do put(K.JOB_SIEGE, id) end
    elseif plan == nil then
      for _, id in ipairs(list) do put(K.JOB_NONE, id, ranged) end
    else
      local jitter = variation > 0 and waveRoll(kind, wave.seed, #list) % (2 * variation + 1) - variation or 0
      local share = math.max(0, math.min(100, plan.share + jitter))
      local first = (#list * share + 50) // 100
      local rest = plan.rest
      if twist and first < #list and (kind == 22 or kind == 70 or kind == 26) then
        rest = kind == 26 and K.JOB_LORD or K.JOB_FLANK
        twist = false
      end
      for index, id in ipairs(list) do put(index <= first and plan.first or rest, id, ranged) end
    end
  end

  -- The wave's own troop keeps whatever the game handles itself (siege engines), else its
  -- largest group.
  local keeper = groups[K.JOB_NONE] and K.JOB_NONE or nil
  for job = K.JOB_ENGAGE, K.JOB_LAST do
    if keeper == nil and groups[job] then keeper = job end
    if groups[job] and keeper ~= K.JOB_NONE and #groups[job] > #groups[keeper] then keeper = job end
  end
  if keeper == nil then return end

  local kind = rd16(tb + G.tribeKind)
  local made = {}
  local retained, retainedRanged, missedSplit = #groups[keeper], rangedGroups[keeper], false
  local function assign(id, job)
    setJob(id, job)
    if not wave or job == K.JOB_NONE then return end
    local uid = rd32(tribe(id) + T.UID)
    waveOf[id] = { uid = uid, wave = wave }
    local rank = K.ANCHOR_PRIORITY[job]
    if rank and rank > wave.rank then
      wave.rank, wave.anchor, wave.anchorUid = rank, id, uid
    end
  end
  for job = K.JOB_ENGAGE, K.JOB_LAST do
    if groups[job] and job ~= keeper then
      local id = newTribe(owner, groups[job], t, kind)
      if id ~= nil then
        F.register(ai, id, rd32(tribe(id) + T.UID))
        assign(id, job)
        made[#made + 1] = string.format("%d %s (troop %d)", #groups[job], K.JOB_NAMES[job], id)
      else
        retained = retained + #groups[job]
        retainedRanged = retainedRanged or rangedGroups[job]
        missedSplit = true
      end
    end
  end
  local job = keeper
  if O.jobs and retainedRanged and (missedSplit or keeper == K.JOB_NONE) then job = K.JOB_UNSPLIT_RANGED end
  assign(t, job)
  diag("player %d wave (troop %d): %d %s%s", owner, t, retained, K.JOB_NAMES[job],
    #made > 0 and (", " .. table.concat(made, ", ")) or "")
end

---------------------------------------------------------------------------------------
-- Jobs: orders, each time the game looks at an outpost troop
---------------------------------------------------------------------------------------

-- Returns the first obstacle on the game's path to the castle and whether it is a wall.
local function breach(owner, target, x, y)
  wr32(G.scratch, 0)
  wr32(G.scratch + 4, 0)
  wr32(G.scratch + 8, 0)
  if (F.path(G.paths, owner, target, x, y, G.scratch, G.scratch + 4, G.scratch + 8) & 0xFF) == 0 then
    return nil
  end
  return (rd8(G.scratch) & 0xFF) ~= 0, rd32(G.scratch + 4), rd32(G.scratch + 8)
end

local function patrolPoint(ai, t, cx, cy, step, radius)
  for try = 0, 7 do
    local angle = ((step + try) % 8) * math.pi / 4
    local x = math.floor(cx + radius * math.cos(angle) + 0.5)
    local y = math.floor(cy + radius * math.sin(angle) + 0.5)
    x = math.max(1, math.min(K.MAP_SIZE - 2, x))
    y = math.max(1, math.min(K.MAP_SIZE - 2, y))
    local tile = tileAt(x, y)
    if tile ~= nil and F.reach(ai, t, tile) ~= 0 then return x, y, step + try + 1 end
  end
  return nil
end

local function enemies(owner)
  local list = {}
  for p = 1, 8 do
    if p ~= owner and team(p) ~= team(owner) then list[p] = true end
  end
  return list
end

local function squared(ax, ay, bx, by) return (ax - bx) * (ax - bx) + (ay - by) * (ay - by) end

local function wallAt(tile, owner)
  return rd32(G.tileFlags + tile * 4) & K.WALL_FLAG ~= 0 and (rd8(G.wallOwner + tile) & 7) + 1 == owner
end

local function siegeBuilding(b, owner)
  local state, kind = rd16(b + B.STATE), rd16(b + B.TYPE)
  return state ~= 0 and state ~= 3 and rd16(b + B.OWNER) == owner and rd16(b + B.HEALTH) > 0
    and kind > 0 and kind <= K.OUTPOST_ARAB and rd32(G.damageable + kind * 4) ~= 0
end

local function refreshSiegeTargets()
  local now = G.ticks and rd32(G.ticks) or 0
  local thenTick = siegeCache.tick
  if not thenTick or now - thenTick < 0 or now - thenTick >= K.SIEGE_REFRESH then
    siegeCache = { tick = now, shortlists = {}, census = {} }
    for p = 1, 8 do siegeCache[p] = { {}, {}, {} } end
    for id = 1, K.MAX_BUILDINGS - 1 do
      local b = building(id)
      local p = rd16(b + B.OWNER)
      if siegeCache[p] and siegeBuilding(b, p) then
        local half = rd32(b + B.SIZE) // 2
        local kind = rd16(b + B.TYPE)
        local list = siegeCache[p][(K.WALL_BUILDINGS[kind] or K.SIEGE_GATE[kind]) and 1 or 3]
        list[#list + 1] = { id = id, uid = rd32(b + B.UID), owner = p,
          x = rd16(b + B.X) + half, y = rd16(b + B.Y) + half }
      end
    end
  end
end

local function siegeTargets(owner)
  refreshSiegeTargets()
  return siegeCache[owner]
end

local function siegeWalls(owner)
  local walls = {}
  if F.playable and aliveLord(owner) then
    local cx, cy = rd32(player(owner) + P.CAMP), rd32(player(owner) + P.CAMP + 4)
    local radius = K.SIEGE_WALL_RADIUS
    local minX, maxX = math.max(0, cx - radius), math.min(K.MAP_SIZE - 1, cx + radius)
    for y = math.max(0, cy - radius), math.min(K.MAP_SIZE - 1, cy + radius) do
      local row = rd32(G.rows + y * 12)
      for x = minX + (y - cy) % 3, maxX, 3 do
        local tile = row + x
        if tile >= 0 and tile < K.MAP_TILES and wallAt(tile, owner) and F.playable(G.siegeMap, x, y) ~= 0 then
          walls[#walls + 1] = { tile = tile, x = x, y = y, owner = owner }
        end
      end
    end
  end
  return walls
end

local function siegeBuckets(owner)
  local targets = siegeTargets(owner)
  if targets.buckets then return targets.buckets end
  local buckets = {}
  for priority, list in ipairs({ targets[1], siegeWalls(owner), targets[3] }) do
    for _, target in ipairs(list) do
      local cell = (target.y // K.SIEGE_BUCKET) * K.MAP_SIZE + target.x // K.SIEGE_BUCKET
      local bucket = buckets[cell]
      if not bucket then
        bucket = { {}, {}, {} }
        buckets[cell] = bucket
      end
      local tier = bucket[priority]
      tier[#tier + 1] = target
    end
  end
  targets.buckets = buckets
  return buckets
end

local function rankSiegeTarget(tier, limit, target, d)
  local index = #tier
  if index == limit and d >= tier[index].d then return end
  index = math.min(index, limit - 1)
  while index > 0 and d < tier[index].d do
    tier[index + 1] = tier[index]
    index = index - 1
  end
  tier[index + 1] = { target = target, d = d }
end

local function liveSiegeTarget(target)
  if target.tile then return wallAt(target.tile, target.owner) end
  local b = building(target.id)
  return rd32(b + B.UID) == target.uid and siegeBuilding(b, target.owner)
end

local function inWaveApproach(candidate, wave, cx, cy)
  local x, y = candidate.x - cx, candidate.y - cy
  return x * wave.dx + y * wave.dy >= math.abs(x * wave.dy - y * wave.dx)
end

local function siegeApproach(owner, x, y, wave, cx, cy)
  local targets = siegeTargets(owner)
  local key
  if wave then
    key = string.format("%d:%d:%d:%d:%d", x, y, wave.shift, cx, cy)
  else
    local cell = K.SIEGE_CELL
    x, y = x - x % cell + cell // 2, y - y % cell + cell // 2
    key = x * K.MAP_SIZE + y
  end
  targets.approaches = targets.approaches or {}
  local approach = targets.approaches[key]
  if approach then
    -- Rebuild once every cached wall is down, so standing walls further out are found.
    if #approach[2] == 0 then return approach end
    for _, wall in ipairs(approach[2]) do
      if liveSiegeTarget(wall) then return approach end
    end
  end

  local nearestBuckets, size = {}, K.SIEGE_BUCKET
  for cell, bucket in pairs(siegeBuckets(owner)) do
    if #bucket[2] > 0 then
      local bx, by = (cell % K.MAP_SIZE) * size, (cell // K.MAP_SIZE) * size
      local dx, dy = math.max(bx - x, x - bx - size + 1, 0), math.max(by - y, y - by - size + 1, 0)
      nearestBuckets[#nearestBuckets + 1] = { cell = cell, walls = bucket[2], d = dx * dx + dy * dy }
    end
  end
  table.sort(nearestBuckets, function(a, b) return a.d < b.d or (a.d == b.d and a.cell < b.cell) end)
  local ranked, walls, limit = {}, {}, K.SIEGE_SHORTLIST[2]
  for _, bucket in ipairs(nearestBuckets) do
    if #ranked == limit and bucket.d > ranked[limit].d then break end
    for _, candidate in ipairs(bucket.walls) do
      if (not wave or inWaveApproach(candidate, wave, cx, cy)) and liveSiegeTarget(candidate) then
        rankSiegeTarget(ranked, limit, candidate, squared(x, y, candidate.x, candidate.y))
      end
    end
  end
  for index, entry in ipairs(ranked) do walls[index] = entry.target end
  approach = { targets[1], walls, targets[3] }
  targets.approaches[key] = approach
  return approach
end

-- Rank nearby candidates once per approach cell and census. Keep space for every tier.
local function siegeShortlist(foes, key, x, y, range)
  local cached = siegeCache.shortlists[key]
  if cached then return cached end
  local tiers, shortlist = { {}, {}, {} }, {}
  local radius = range + K.SIEGE_CELL
  local minX, maxX = math.max(0, x - radius) // K.SIEGE_BUCKET,
    math.min(K.MAP_SIZE - 1, x + radius) // K.SIEGE_BUCKET
  local minY, maxY = math.max(0, y - radius) // K.SIEGE_BUCKET,
    math.min(K.MAP_SIZE - 1, y + radius) // K.SIEGE_BUCKET
  for p = 1, 8 do
    if foes[p] then
      local buckets = siegeBuckets(p)
      for by = minY, maxY do
        for bx = minX, maxX do
          local bucket = buckets[by * K.MAP_SIZE + bx]
          if bucket then
            for priority, targets in ipairs(bucket) do
              for _, target in ipairs(targets) do
                rankSiegeTarget(tiers[priority], K.SIEGE_SHORTLIST[priority], target,
                  squared(x, y, target.x, target.y))
              end
            end
          end
        end
      end
    end
  end
  for _, tier in ipairs(tiers) do
    for _, ranked in ipairs(tier) do shortlist[#shortlist + 1] = ranked.target end
  end
  siegeCache.shortlists[key] = shortlist
  return shortlist
end

-- Enemy buildings standing within reach (squared, straight line) of x, y, nearest first.
local function buildingsInReach(owner, x, y, reach)
  local foes = enemies(owner)
  local found = {}
  for id = 1, K.MAX_BUILDINGS - 1 do
    local b = building(id)
    if rd16(b + B.STATE) ~= 0 and foes[rd16(b + B.OWNER)] then
      local size = rd32(b + B.SIZE)
      local half = size > 0 and size // 2 or 0
      local d = squared(x, y, rd16(b + B.X) + half, rd16(b + B.Y) + half)
      if d <= reach then found[#found + 1] = { id = id, d = d } end
    end
  end
  table.sort(found, function(p, q) return p.d < q.d or (p.d == q.d and p.id < q.id) end)
  return found
end

-- What a player's idle siege engine does with a target (UpdateCatapult, state 0): the game's
-- acquireShootTarget decides whether it can be shot from here - the game's own range, as the
-- Rebalancer set it - and aims; then the engine stops and goes into its shooting state. The AI's
-- own idle code never does this for an engine outside an AI siege, so outpost engines walked
-- past everything.
local function startShooting(id, u)
  F.halt(G.unitsThis, id)
  wr16(u + U.SHOOT_BEFORE_STOP, K.SHOOT_BEFORE_STOP)
  wr16(u + U.ACTION, K.STATE_SHOOT)
end

local function tryBuilding(id, u, b)
  local targeting, target, uid = rd16(u + U.TARGETING), rd16(u + U.TARGET_BUILDING), rd32(u + U.TARGET_UID)
  wr16(u + U.TARGETING, K.ORDER_ATTACK_BUILDING)
  wr16(u + U.TARGET_BUILDING, b)
  wr32(u + U.TARGET_UID, rd32(building(b) + B.UID))
  if F.acquire(G.unitsThis, id) ~= 0 then return true end
  wr16(u + U.TARGETING, targeting)
  wr16(u + U.TARGET_BUILDING, target)
  wr32(u + U.TARGET_UID, uid)
  return false
end

local function tryWall(id, u, wall)
  local order, x, y = rd16(u + U.TARGETING), rd16(u + U.WALL_X), rd16(u + U.WALL_Y)
  wr16(u + U.TARGETING, K.ORDER_ATTACK_WALL_AT)
  wr16(u + U.WALL_X, wall.x)
  wr16(u + U.WALL_Y, wall.y)
  if F.acquire(G.unitsThis, id) ~= 0 then return true end
  wr16(u + U.TARGETING, order)
  wr16(u + U.WALL_X, x)
  wr16(u + U.WALL_Y, y)
  return false
end

-- The game's own search for an enemy unit in range (acquireShootTarget with no target), which
-- fire ballistas use when idle.
local function tryUnits(id, u, foes)
  local targeting = rd16(u + U.TARGETING)
  wr16(u + U.TARGETING, 0)
  if F.acquire(G.unitsThis, id) ~= 0 then
    local v = rd16(u + U.SHOOT_UNIT)
    if v > 0 and foes[rd16(unit(v) + U.OWNER)] then return v end
  end
  wr16(u + U.TARGETING, targeting)
  return nil
end

-- A new guard of an outpost with settings (asm, when it is put in the outpost's list): melee
-- guards go into the outpost's defensive troop, knights into its aggressive one, horse archers
-- into its patrol troop, which is sent round the outpost again with every new rider. A troop
-- the AI has not registered never gets AI orders, so they stay at their outpost.
-- A patrol point is free when no building or wall stands on it and the troop can walk there.
local function freeSpot(t, x, y)
  local tile = tileAt(x, y)
  if tile == nil then return false end
  if rd32(G.tileFlags + tile * 4) & K.WALL_FLAG ~= 0 then return false end
  if rd16(G.buildingLayer + tile * 2) ~= 0 then return false end
  return F.reach(G.aiState, t, tile) ~= 0
end

-- The patrol: GUARD_PATROL_POINTS spots round the outpost, one in each sixth of the circle at a
-- random angle and distance in it. A blocked spot moves - nearer and further, then round the
-- circle - until a free one is found. The random numbers come from the game state (outpost,
-- troop, tick), so every player of a multiplayer game gets the same patrol.
local function patrolRound(t, bid)
  if not O.patrol then return end
  local b = building(bid)
  local half = rd32(b + B.SIZE) // 2
  local cx, cy = rd16(b + B.X) + half, rd16(b + B.Y) + half
  local seed = (bid * 7919 + t * 104729 + rd32(G.ticks)) & 0x7FFFFFFF
  local function random(n)
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    return (seed >> 8) % n
  end
  local sector = 2 * math.pi / K.GUARD_PATROL_POINTS
  local span = K.GUARD_PATROL_FAR - K.GUARD_PATROL_NEAR + 1
  local points = {}
  for index = 0, K.GUARD_PATROL_POINTS - 1 do
    local angle = (index + random(100) / 100) * sector
    local radius = K.GUARD_PATROL_NEAR + random(span)
    for try = 0, K.GUARD_PATROL_TRIES - 1 do
      local r = K.GUARD_PATROL_NEAR + (radius - K.GUARD_PATROL_NEAR + (try % 3) * 3) % span
      local turn = try // 3
      local a = angle + (turn + 1) // 2 * sector / 4 * (turn % 2 == 0 and 1 or -1)
      local x = math.max(1, math.min(K.MAP_SIZE - 2, math.floor(cx + r * math.cos(a) + 0.5)))
      local y = math.max(1, math.min(K.MAP_SIZE - 2, math.floor(cy + r * math.sin(a) + 0.5)))
      if freeSpot(t, x, y) then
        points[#points + 1] = { x, y }
        break
      end
    end
  end
  if #points == 0 then return end
  F.move(G.tribesThis, t, points[1][1], points[1][2], 1, 1, 0)
  for index = 2, #points do F.addPoint(G.tribesThis, t, points[index][1], points[index][2], index) end
end

-- A new foot guard goes up onto the owner's walls, stone towers or stone gatehouses within
-- WALL_RADIUS of the outpost: the free spot with the fewest guards round it (nearest the outpost
-- on a tie), which also fills the places of guards who fell. A spot counts only when the guard
-- can walk there (the game's own area test, as for the outpost's own spot). With none, the guard
-- keeps the spot the game gave it.
local function manWalls(id, bid)
  local u = unit(id)
  if not K.WALL_GUARDS[rd16(u + U.TYPE)] then return end
  local owner = rd16(u + U.OWNER)
  local b = building(bid)
  local half = rd32(b + B.SIZE) // 2
  local cx, cy = rd16(b + B.X) + half, rd16(b + B.Y) + half
  local r = K.WALL_RADIUS

  -- where the owner's people stand or are going, near the outpost
  local taken = {}
  local function mark(x, y) local k = y * K.MAP_SIZE + x taken[k] = (taken[k] or 0) + 1 end
  for other = 1, rd32(G.unitsThis) - 1 do
    if other ~= id then
      local o = unit(other)
      if rd16(o + U.STATE) == 2 and rd16(o + U.OWNER) == owner then
        local spot = wallSpots[other]
        if spot ~= nil and spot.uid == rd32(o + U.UID) then
          mark(spot.x, spot.y)
        else
          wallSpots[other] = nil
          local ox, oy = rd16(o + U.X), rd16(o + U.Y)
          if math.abs(ox - cx) <= r + K.WALL_CROWD and math.abs(oy - cy) <= r + K.WALL_CROWD then mark(ox, oy) end
        end
      end
    end
  end

  local spots = {}
  for y = math.max(1, cy - r), math.min(K.MAP_SIZE - 2, cy + r) do
    for x = math.max(1, cx - r), math.min(K.MAP_SIZE - 2, cx + r) do
      local tile = tileAt(x, y)
      if tile ~= nil and (taken[y * K.MAP_SIZE + x] or 0) == 0 then
        local flags = rd32(G.tileFlags + tile * 4)
        local ok = false
        if flags & K.WALL_FLAG ~= 0 then
          ok = flags & K.NOT_WALKABLE_FLAG == 0 and (rd8(G.wallOwner + tile) & 7) + 1 == owner
        else
          local on = rd16(G.buildingLayer + tile * 2)
          if on > 0 then
            local bb = building(on)
            ok = K.WALL_BUILDINGS[rd16(bb + B.TYPE)] == true and rd16(bb + B.OWNER) == owner
          end
        end
        if ok then
          local crowd = 0
          for dy = -K.WALL_CROWD, K.WALL_CROWD do
            for dx = -K.WALL_CROWD, K.WALL_CROWD do
              crowd = crowd + (taken[(y + dy) * K.MAP_SIZE + x + dx] or 0)
            end
          end
          spots[#spots + 1] = { x = x, y = y, tile = tile, crowd = crowd, d = distance(x, y, cx, cy) }
        end
      end
    end
  end
  if #spots == 0 then return end
  table.sort(spots, function(p, q)
    if p.crowd ~= q.crowd then return p.crowd < q.crowd end
    if p.d ~= q.d then return p.d < q.d end
    return p.tile < q.tile
  end)

  local from = rd16(G.area + rd32(u + U.TILE) * 2) & 0xFFFF
  local climb = rd16(u + U.CLIMB)
  for index = 1, math.min(#spots, K.WALL_TRIES) do
    local spot = spots[index]
    local to = rd16(G.area + spot.tile * 2) & 0xFFFF
    if to ~= 0 and (to == from or F.navigate(G.pathFinder, owner, from, to, climb) ~= 0) then
      F.setDestination(G.unitsThis, id, spot.x, spot.y, 0)
      wallSpots[id] = { uid = rd32(u + U.UID), x = spot.x, y = spot.y }
      diag("outpost %d: guard %d to the wall at %d,%d", bid, id, spot.x, spot.y)
      return
    end
  end
end

local function onGuard()
  local id, bid = rd32(G.guardUnit), rd32(G.current)
  if O.walls then manWalls(id, bid) end
  local u = unit(id)
  local group = K.GUARD_GROUP[rd16(u + U.TYPE)]
  if group == nil or rd16(u + U.TRIBE) > 0 then return end
  local owner = rd16(u + U.OWNER)
  local key = bid * 8 + K.GUARD_INDEX[group]
  local g = guardTroops[key]
  local buildingUid = rd32(building(bid) + B.UID)
  if g == nil or g.building ~= buildingUid or rd16(tribe(g.id) + T.STATE) ~= 2
      or rd32(tribe(g.id) + T.UID) ~= g.uid then
    local t = F.createTribe(G.tribesThis, owner)
    if t == nil or t <= 0 or t >= K.MAX_TRIBES then return end
    F.setStance(G.tribesThis, t, K.GUARD_STANCE[group])
    g = { id = t, uid = rd32(tribe(t) + T.UID), building = buildingUid }
    guardTroops[key] = g
    guardInfo[t] = { uid = g.uid, outpost = bid, group = group }
  end
  F.addToTribe(G.tribesThis, id, g.id)
  if K.GUARD_PATROLS[group] then patrolRound(g.id, bid) end
  diag("outpost %d: %s guard %d in troop %d", bid, group, id, g.id)
end

local function siegeRange(kind)
  return G.siegeRanges and G.siegeRanges[K.SIEGE_RANGE_KEY[kind]]
    or rd32(G.ranges + K.SIEGE_PROJECTILE[kind] * 4)
end

-- Stop an outpost engine when its native shooting code can acquire a target.
local function shootIfInRange(id)
  local u = unit(id)
  local kind = rd16(u + U.TYPE)
  if not K.SIEGE[kind] or rd16(u + U.STATE) ~= 2 or rd16(u + U.BEHAVIOUR) ~= K.OUTPOST_BEHAVIOUR then
    return false
  end
  local owner = rd16(u + U.OWNER)
  local foes = enemies(owner)
  if K.SIEGE[kind] == "ballista" then
    local enemy = tryUnits(id, u, foes)
    if enemy then
      startShooting(id, u)
      diag("fire ballista %d shoots unit %d", id, enemy)
      return true
    end
    -- Fire ballistas do no damage to buildings and walls.
    return false
  end

  local x, y = rd16(u + U.X), rd16(u + U.Y)
  local range = siegeRange(kind)
  local cellX, cellY = x // K.SIEGE_CELL, y // K.SIEGE_CELL
  local foeMask = 0
  for p = 1, 8 do
    if foes[p] then foeMask = foeMask | (1 << (p - 1)) end
  end
  local key = string.format("%d:%d:%d", cellY * K.MAP_SIZE + cellX, foeMask, range)
  local uid = rd32(u + U.UID)
  refreshSiegeTargets()
  local retry = siegeRetries[id]
  if not retry or retry.uid ~= uid or retry.foes ~= foeMask
      or squared(x, y, retry.x, retry.y) > K.SIEGE_RETRY_DISTANCE ^ 2
      or (retry.next > #retry.targets and (retry.census ~= siegeCache.census or retry.key ~= key)) then
    local center = K.SIEGE_CELL // 2
    retry = { uid = uid, key = key, foes = foeMask, x = x, y = y, attempted = {}, census = siegeCache.census,
      targets = siegeShortlist(foes, key, cellX * K.SIEGE_CELL + center, cellY * K.SIEGE_CELL + center, range) }
    siegeRetries[id] = retry
  end
  -- Recheck range misses on movement while retaining native acquisition failures.
  if retry.checkedX ~= x or retry.checkedY ~= y then
    retry.checkedX, retry.checkedY, retry.next = x, y, 1
  end
  local tries = 0
  local reach = range * range
  for index = retry.next, #retry.targets do
    local target = retry.targets[index]
    retry.next = index + 1
    if not retry.attempted[index] and squared(x, y, target.x, target.y) <= reach and liveSiegeTarget(target) then
      retry.attempted[index] = true
      local ready
      if target.tile then ready = tryWall(id, u, target) else ready = tryBuilding(id, u, target.id) end
      if ready then
        siegeRetries[id] = nil
        startShooting(id, u)
        if target.tile then
          diag("%s %d shoots wall (%d,%d)", K.SIEGE[kind], id, target.x, target.y)
        else
          diag("%s %d shoots building %d (range %d)", K.SIEGE[kind], id, target.id, range)
        end
        return true
      end
      tries = tries + 1
      if tries == K.SIEGE_TRIES then return false end
    end
  end
  return false
end

-- A patrolling knight guard, standing or riding (asm hands it over every 16 ticks): its troop
-- attacks the nearest enemy building within RIDER_REACH with the game's own attack order, and
-- rides its patrol again once that building is down. Enemy troops it meets it fights anyway
-- (aggressive stance).
local function onRider()
  local id = rd32(G.riderUnit)
  local u = unit(id)
  if rd16(u + U.TYPE) ~= K.KNIGHT or rd16(u + U.STATE) ~= 2 then return end
  local t = rd16(u + U.TRIBE)
  local info = guardInfo[t]
  if info == nil or info.group ~= "knights" or rd32(tribe(t) + T.UID) ~= info.uid
      or rd32(u + U.TRIBE_UID) ~= info.uid then
    return
  end
  local owner = rd16(u + U.OWNER)
  local foes = enemies(owner)
  if info.attack ~= nil then
    local b = building(info.attack.id)
    if rd16(b + B.STATE) ~= 0 and rd32(b + B.UID) == info.attack.uid and foes[rd16(b + B.OWNER)] then return end
    info.attack = nil
    patrolRound(t, info.outpost)
    diag("outpost %d: knights back on patrol", info.outpost)
    return
  end
  local near = buildingsInReach(owner, rd16(u + U.X), rd16(u + U.Y), K.RIDER_REACH * K.RIDER_REACH)
  if #near > 0 then
    local b = near[1].id
    local buid = rd32(building(b) + B.UID)
    F.instruction(G.tribesThis, t, K.ORDER_ATTACK_BUILDING, b, buid, 0)
    info.attack = { id = b, uid = buid }
    diag("outpost %d: patrolling knights attack building %d", info.outpost, b)
  end
end

-- An outpost siege engine standing, walking (state 1 or 0x65), or creeping forward in the AI's
-- siege steps (asm hands it over every 16 ticks).
local function onSiegeUnit()
  shootIfInRange(rd32(G.siegeUnit))
end

local function moveToward(t, x, y, tx, ty, standoff)
  local d = math.sqrt(squared(x, y, tx, ty))
  if d <= standoff then return end
  local scale = standoff / d
  local px = math.floor(tx + (x - tx) * scale + 0.5)
  local py = math.floor(ty + (y - ty) * scale + 0.5)
  for _, step in ipairs({ 0, 2, -2 }) do
    if freeSpot(t, px + step, py - step) then
      F.command(G.tribesThis, t, px + step, py - step, 1)
      return true
    end
  end
end

-- Advance toward a reachable firing position on the near side of a fortification.
local function siegeOrders(t, lead, target, focus)
  local size = rd16(tribe(t) + T.SIZE)
  local holding = false
  for index = 0, size - 1 do
    local id = F.lead(G.tribesThis, t, index)
    if id and id > 0 and (K.SHOOTING[rd16(unit(id) + U.ACTION)] or shootIfInRange(id)) then holding = true end
  end
  if holding or target < 1 or target > 8 then return end

  local u = unit(lead)
  local kind = rd16(u + U.TYPE)
  if not K.SIEGE_PROJECTILE[kind] then return end
  local x, y = rd16(u + U.X), rd16(u + U.Y)
  local nearest = focus
  local d2 = nearest and squared(x, y, nearest.x, nearest.y)
  if not nearest then
    for priority, list in ipairs(siegeApproach(target, x, y)) do
      if priority == 3 and nearest then break end
      for _, candidate in ipairs(list) do
        local d = squared(x, y, candidate.x, candidate.y)
        if (not nearest or d < d2) and liveSiegeTarget(candidate) then
          nearest, d2 = candidate, d
        end
      end
    end
  end
  if not nearest or d2 == 0 then return end

  moveToward(t, x, y, nearest.x, nearest.y, math.min(siegeRange(kind) * 0.8, math.sqrt(d2) * 0.7))
end

local function rangedRange(kind)
  local projectile = K.RANGED_PROJECTILE[kind]
  if projectile == 1 then return G.bowRanges and G.bowRanges[kind] or G.bowRange end
  if projectile and G.ranges then return rd32(G.ranges + projectile * 4) end
end

local function engageRanged(t, kind, ux, uy, x, y)
  F.setStance(G.tribesThis, t, K.STANCE_DEFENSIVE)
  local range = rangedRange(kind)
  if range then moveToward(t, ux, uy, x, y, range * 0.7) end
end

local function waveFocus(wave, target, cx, cy)
  if not wave then return nil end
  local tick = G.ticks and rd32(G.ticks)
  if wave.target ~= target or (wave.focus and not liveSiegeTarget(wave.focus))
      or (tick and not wave.focus and (tick < wave.focusTick or tick - wave.focusTick >= K.SIEGE_REFRESH)) then
    wave.target, wave.focus = target, nil
    wave.focusTick = tick
    local angle = math.atan(wave.y - cy, wave.x - cx) + wave.shift * math.pi / 4
    wave.dx, wave.dy = math.cos(angle), math.sin(angle)
    if not tick or not G.damageable then return nil end
    local nearest
    for priority, list in ipairs(siegeApproach(target, wave.x, wave.y, wave, cx, cy)) do
      if priority == 3 and wave.focus then break end
      for _, candidate in ipairs(list) do
        local d = squared(wave.x, wave.y, candidate.x, candidate.y)
        if inWaveApproach(candidate, wave, cx, cy)
            and (not nearest or d < nearest) and liveSiegeTarget(candidate) then
          wave.focus, nearest = candidate, d
        end
      end
    end
  end
  return wave.focus
end

local function safeStationTile(x, y)
  if F.playable(G.siegeMap, x, y) == 0 then return nil end
  local tile = tileAt(x, y)
  if not tile or tile < 0 or tile >= K.MAP_TILES then return nil end
  for dy = -1, 1 do
    for dx = -1, 1 do
      local near = tileAt(x + dx, y + dy)
      if not near or near < 0 or near >= K.MAP_TILES or rd32(G.tileFlags + near * 4) & K.UNSAFE_TERRAIN ~= 0 then
        return nil
      end
      local id = rd16(G.buildingLayer + near * 2)
      if id > 0 and rd16(building(id) + B.TYPE) == 67 then return nil end
    end
  end
  return tile
end

-- Prefer height among a small set of stations, then test native path reachability.
local function station(t, ux, uy, x, y, focusX, focusY, minRange, maxRange)
  local spots = {}
  for _, offset in ipairs(K.STATION_OFFSETS) do
    local px, py = math.floor(x + offset[1] + 0.5), math.floor(y + offset[2] + 0.5)
    local d = squared(px, py, focusX, focusY)
    if d >= minRange * minRange and d <= maxRange * maxRange then
      local tile = safeStationTile(px, py)
      if tile then spots[#spots + 1] = { x = px, y = py, height = rd8(G.height + tile) & 0xFF } end
    end
  end
  table.sort(spots, function(a, b)
    if a.height ~= b.height then return a.height > b.height end
    return squared(a.x, a.y, x, y) < squared(b.x, b.y, x, y)
  end)
  for index = 1, math.min(3, #spots) do
    local spot = spots[index]
    if freeSpot(t, spot.x, spot.y) then
      if distance(ux, uy, spot.x, spot.y) > 1 then F.command(G.tribesThis, t, spot.x, spot.y, 1) end
      return true
    end
  end
  return false
end

local function overwatch(t, kind, ux, uy, x, y, wave)
  local range = rangedRange(kind)
  F.setStance(G.tribesThis, t, K.STANCE_DEFENSIVE)
  if not range then return end
  if G.height then
    local angle = math.atan(uy - y, ux - x)
    local dx, dy = wave and wave.dx or math.cos(angle), wave and wave.dy or math.sin(angle)
    if station(t, ux, uy, x + dx * range * 0.75, y + dy * range * 0.75,
        x, y, range * 0.65, range * 0.85) then return end
  end
  moveToward(t, ux, uy, x, y, range * 0.7)
end

local function anchorLead(t, wave)
  local anchor = wave and wave.anchor
  if not anchor or anchor == t then return nil end
  local tb = tribe(anchor)
  if rd16(tb + T.STATE) ~= 2 or rd32(tb + T.UID) ~= wave.anchorUid then return nil end
  local lead = F.lead(G.tribesThis, anchor, 0)
  if lead and lead > 0 then return lead end
end

local function escort(t, ranged, ux, uy, x, y, wave)
  local lead = anchorLead(t, wave)
  if not lead then return false end
  local u = unit(lead)
  local ax, ay = rd16(u + U.X), rd16(u + U.Y)
  local angle = math.atan(y - ay, x - ax)
  local offset = ranged and -4 or 5
  local tx, ty = ax + math.cos(angle) * offset, ay + math.sin(angle) * offset
  if ranged then
    F.setStance(G.tribesThis, t, K.STANCE_DEFENSIVE)
    if G.height then
      return station(t, ux, uy, tx, ty, ax, ay, 3, 5)
    end
  end
  return distance(ux, uy, tx, ty) <= 1 or moveToward(t, ux, uy, tx, ty, 1)
end

local function flank(t, ux, uy, cx, cy, wave, S)
  if not S.flankX then
    local x, y = wave and wave.x or ux, wave and wave.y or uy
    local side = wave and wave.side or S.uid % 2 * 2 - 1
    local angle = math.atan(y - cy, x - cx) + side * math.pi * 5 / 12
    local radius = 30 + (wave and wave.seed or S.uid) % 11
    S.flankX = math.max(1, math.min(K.MAP_SIZE - 2, math.floor(cx + math.cos(angle) * radius + 0.5)))
    S.flankY = math.max(1, math.min(K.MAP_SIZE - 2, math.floor(cy + math.sin(angle) * radius + 0.5)))
    S.flankMisses = 0
  end
  if distance(ux, uy, S.flankX, S.flankY) <= 8 then
    S.flanked = true
  elseif moveToward(t, ux, uy, S.flankX, S.flankY, 0) then
    S.wait = 2
  else
    S.flankMisses = S.flankMisses + 1
    S.flanked = S.flankMisses >= K.FLANK_MISSES
  end
end

local function attackBuilding(ai, t, owner, x, y)
  if not G.damageable then return false end
  local nearest, d2
  local targets = siegeTargets(owner)
  for _, list in ipairs({ targets[3], targets[1] }) do
    for _, candidate in ipairs(list) do
      local d = squared(x, y, candidate.x, candidate.y)
      local tile = tileAt(candidate.x, candidate.y)
      if (not nearest or d < d2) and tile and liveSiegeTarget(candidate) and F.reach(ai, t, tile) ~= 0 then
        nearest, d2 = candidate, d
      end
    end
    if nearest then
      F.instruction(G.tribesThis, t, K.ORDER_ATTACK_BUILDING, nearest.id, nearest.uid, 0)
      return true
    end
  end
  return false
end

local function onDecide()
  local t, ai = rd32(G.decideTribe), rd32(G.decideThis)
  local tb = tribe(t)
  local job = rd8(G.jobs + t) & 0xFF
  if F.busy(ai, t, 0, 1) ~= 0 then return end
  local uid = rd32(tb + T.UID)
  local S = orders[t]
  if S == nil or S.uid ~= uid then
    S = { uid = uid, wait = 0, step = t % 8 }
    orders[t] = S
  end

  local owner = rd32(tb + T.OWNER)
  local target = rd16(tb + G.tribeTarget)
  local lead = F.lead(G.tribesThis, t, 0)
  if target < 1 or target > 8 or not lead or lead <= 0 then return end
  if not G.ticks then siegeCache = {} end
  local lu = unit(lead)
  local ux, uy = rd16(lu + U.X), rd16(lu + U.Y)
  local kind = rd16(lu + U.TYPE)
  local ranged = K.RANGED_PROJECTILE[kind] ~= nil
  local cx, cy = rd32(player(target) + P.CAMP), rd32(player(target) + P.CAMP + 4)
  local entry = waveOf[t]
  local wave = entry and entry.uid == uid and entry.wave or nil
  local focus = waveFocus(wave, target, cx, cy)
  local fx, fy = focus and focus.x or cx, focus and focus.y or cy
  if job == K.JOB_SIEGE then
    siegeOrders(t, lead, target, focus)
    return
  end
  if job == K.JOB_UNSPLIT_RANGED then
    for index = 0, rd16(tb + T.SIZE) - 1 do
      local id = F.lead(G.tribesThis, t, index)
      if id and id > 0 then
        local u = unit(id)
        local memberKind = rd16(u + U.TYPE)
        if K.RANGED_PROJECTILE[memberKind] and rd16(u + U.STATE) == 2 then
          engageRanged(t, memberKind, rd16(u + U.X), rd16(u + U.Y), fx, fy)
          return
        end
      end
    end
    moveToward(t, ux, uy, fx, fy, 3)
    return
  end
  if ranged and (job == K.JOB_OVERWATCH or job == K.JOB_ESCORT) and (S.fx ~= fx or S.fy ~= fy) then
    S.fx, S.fy, S.wait = fx, fy, 0
  end
  if job == K.JOB_FLANK and S.target ~= target then
    S.target, S.flankX, S.flankY, S.flanked, S.wait = target, nil, nil, nil, 0
  end

  if not S.rallied then
    S.rallied = true
    if wave and wave.rank >= 2 and (kind == 24 or kind == 26) and job ~= K.JOB_FLANK
        and job ~= K.JOB_PATROL and anchorLead(t, wave) then
      S.wait = wave.seed % 2
      return
    end
  end

  if job == K.JOB_PATROL and S.x ~= nil then
    if distance(ux, uy, S.x, S.y) > K.PATROL_ARRIVED and S.wait > 0 then
      S.wait = S.wait - 1
      return
    end
  elseif S.wait > 0 then
    S.wait = S.wait - 1
    return
  end

  if job == K.JOB_MOAT or job == K.JOB_WALLS then
    local isWall, x, y = breach(owner, target, ux, uy)
    if isWall == false and job == K.JOB_MOAT and K.MOAT_CAPABLE[kind] then
      F.instruction(G.tribesThis, t, K.ORDER_FILL_MOAT, x, y, 1000)
      S.wait = K.WAIT[job]
      return
    end
    if isWall and job == K.JOB_WALLS and not ranged then
      local tile = tileAt(x, y)
      if tile then
        F.instruction(G.tribesThis, t, K.ORDER_ATTACK_WALL_AT, tile, 0, 0)
        S.wait = K.WAIT[job]
        return
      end
    end
    job = K.JOB_BUILDINGS
  end

  if job == K.JOB_ESCORT then
    if escort(t, ranged, ux, uy, fx, fy, wave) then
      S.wait = 2
      return
    end
    job = ranged and K.JOB_OVERWATCH or K.JOB_BUILDINGS
  end

  if job == K.JOB_FLANK then
    if not S.flanked then
      flank(t, ux, uy, cx, cy, wave, S)
      if not S.flanked then return end
    end
    job = kind == K.KNIGHT and K.JOB_LORD or K.JOB_BUILDINGS
  end

  if job == K.JOB_OVERWATCH then
    overwatch(t, kind, ux, uy, fx, fy, wave)
    S.wait = 4
    return
  end

  if job == K.JOB_BUILDINGS and attackBuilding(ai, t, target, ux, uy) then
    S.wait = 2
    return
  end

  local lord = aliveLord(target)
  if job == K.JOB_LORD then
    if lord ~= nil and F.reach(ai, t, lord.tile) ~= 0 then
      F.instruction(G.tribesThis, t, K.ORDER_ATTACK_UNIT, lord.id, lord.uid, 0)
      S.wait = K.WAIT[job]
      return
    end
    job = K.JOB_PATROL            -- the lord is out of reach: ride round his castle instead
  end

  if job == K.JOB_PATROL then
    local radius = kind == K.KNIGHT and 22 or K.PATROL_RADIUS
    if kind == 74 then radius = math.max(radius, (rangedRange(kind) or 0) * 0.65) end
    local x, y, step = patrolPoint(ai, t, lord and lord.x or cx, lord and lord.y or cy, S.step, radius)
    if x ~= nil then
      F.command(G.tribesThis, t, x, y, 1)
      S.x, S.y, S.step, S.wait = x, y, step, K.WAIT[K.JOB_PATROL]
      return
    end
  end

  if ranged then
    engageRanged(t, kind, ux, uy, fx, fy)
    S.wait = 3
  else
    moveToward(t, ux, uy, fx, fy, 3)
    S.wait = 2
  end
end

---------------------------------------------------------------------------------------
-- The outpost panel: the two sliders in the live menu
---------------------------------------------------------------------------------------

-- The live menu's two outpost sliders (the ui module may have copied the item table).
local function liveSliders(each)
  if G.menu == nil then return end
  local item, limit = rd32(G.menu), 4000
  if item == 0 then return end
  while rd32(item + K.ITEM_TYPE) ~= K.TYPE_LAST and limit > 0 do
    local action = rd32(item + K.ITEM_ACTION)
    if action == G.sizeSlider or action == G.delaySlider then each(item, action) end
    item = item + K.ITEM_SIZE
    limit = limit - 1
  end
end

-- Refresh the live slider items and keep the static items in sync for newly opened menus.
local function refreshSliders()
  local defenders = rd32(G.mode) ~= 0
  local timing = O.interval and rd32(G.scope) == 1
  local sizeHidden = not defenders and timing and 1 or 0
  local delayHidden = (defenders or (O.interval and not timing)) and 1 or 0
  if O.interval then
    core.writeCodeSmallInteger(G.sizeItem + K.ITEM_HIDDEN, sizeHidden)
    core.writeCodeSmallInteger(G.delayItem + K.ITEM_HIDDEN, delayHidden)
    wr32(G.drag, 0)
  end
  liveSliders(function(item, action)
    if action == G.sizeSlider then
      if O.interval then wr16(item + K.ITEM_HIDDEN, sizeHidden) end
      if sizeHidden == 0 then
        F.sizeSlider(rd32(item + K.ITEM_PARAM), 1, item + K.ITEM_MIN, item + K.ITEM_MAX, item + K.ITEM_VALUE)
      end
    else
      wr16(item + K.ITEM_HIDDEN, delayHidden)
    end
  end)
end

-- Move the native sliders in both the static item table and the live menu.
local function moveSliders()
  local function move(item, action)
    local y = (action == G.sizeSlider or O.interval) and K.SIZE_Y or K.DELAY_Y
    if rd32(item + K.ITEM_Y) ~= y then core.writeCodeInteger(item + K.ITEM_Y, y) end
  end
  move(G.sizeItem, G.sizeSlider)
  move(G.delayItem, G.delaySlider)
  liveSliders(move)
end

---------------------------------------------------------------------------------------
-- The save: per outpost settings, their guards and the troops' jobs
---------------------------------------------------------------------------------------

local function wipe()
  core.setMemory(G.table, 0, K.MAX_BUILDINGS * K.ENTRY_SIZE)
  core.setMemory(G.slots, 0, K.MAX_BUILDINGS * K.MAX_GUARDS * 8)
  core.setMemory(G.jobs, 0, K.MAX_TRIBES)
  siegeCache = {}
  siegeRetries = {}
  waveOf = {}
  guardTroops = {}
  wallSpots = {}
  guardInfo = {}
  core.setMemory(G.jobUids, 0, K.MAX_TRIBES * 4)
  orders = {}
end

local function isOutpost(id)
  local kind = rd16(building(id) + B.TYPE)
  return kind == K.OUTPOST_EURO or kind == K.OUTPOST_ARAB
end

local function resolveUnitCapacity()
  if not G.unitCapacityResolved then
    G.unitCapacityResolved = true
    local ok, result = pcall(function()
      -- The reinforcement check subtracts the live unit count from the last unit index.
      local limit = scan("8D 44 38 06 B9 ? ? ? ? 2B 0D ? ? ? ? 50 51 B9 ? ? ? ? E8", "the unit limit")
      same(G.unitsThis + 4, readOperand(limit, { 9, { 0x2B, 0x0D } }, "the active unit count"),
        "the active unit count")
      local lastUnit = rd32(limit + 5)
      assert(lastUnit > 0 and lastUnit < 0xFFFF, "invalid unit table limit")
      return lastUnit + 1
    end)
    if ok then
      G.unitCapacity = result
    else
      log(ERROR, "Outpost defenders and saved defender slots are off: " .. tostring(result))
    end
  end
  return G.unitCapacity
end

local function serialize(handle)
  local unitCount = G.unitCapacity and math.min(rd32(G.unitsThis), G.unitCapacity) or 0
  local entries = {}
  for id = 1, K.MAX_BUILDINGS - 1 do
    local entry = G.table + id * K.ENTRY_SIZE
    local uid = rd32(entry)
    if uid ~= 0 and uid == rd32(building(id) + B.UID) then
      entries[#entries + 1] = string.pack("<I2I4I2BB", id, uid, rd16(entry + 4) & 0xFFFF, rd8(entry + 6) & 0xFF,
        rd8(entry + 7) & 0xFF)
    end
  end
  handle:put(K.SAVE_BUILDINGS, table.concat(entries))
  local jobs = {}
  for id = 1, K.MAX_TRIBES - 1 do
    local job = rd8(G.jobs + id) & 0xFF
    local uid = rd32(G.jobUids + id * 4)
    if job ~= 0 and uid ~= 0 and uid == rd32(tribe(id) + T.UID) then
      jobs[#jobs + 1] = string.pack("<I2I4B", id, uid, job)
    end
  end
  handle:put(K.SAVE_JOBS, table.concat(jobs))
  local guards = {}
  for id = 1, K.MAX_BUILDINGS - 1 do
    local uid = rd32(G.table + id * K.ENTRY_SIZE)
    if uid ~= 0 and uid == rd32(building(id) + B.UID) then
      local slots = G.slots + id * K.MAX_GUARDS * 8
      for slot = 0, K.MAX_GUARDS - 1 do
        local u = rd16(slots + slot * 8) & 0xFFFF
        local unitUid = rd32(slots + slot * 8 + 4)
        if u > 0 and u < unitCount and unitUid ~= 0 and unitUid == rd32(unit(u) + U.UID) then
          guards[#guards + 1] = string.pack("<I2I2I4", id, u, unitUid)
        end
      end
    end
  end
  handle:put(K.SAVE_GUARDS, table.concat(guards))
  local waves, intervals = {}, {}
  for id = 1, K.MAX_BUILDINGS - 1 do
    local entry = G.table + id * K.ENTRY_SIZE
    local uid = rd32(entry)
    local size = rd16(entry + 8) & 0xFFFF
    if uid ~= 0 and uid == rd32(building(id) + B.UID) then
      if size ~= 0xFFFF then waves[#waves + 1] = string.pack("<I2I2", id, size) end
      local interval = rd16(entry + K.INTERVAL_FIELD) & 0xFFFF
      if interval ~= 0 then intervals[#intervals + 1] = string.pack("<I2I2", id, interval) end
    end
  end
  handle:put(K.SAVE_WAVES, table.concat(waves))
  if #intervals > 0 then handle:put(K.SAVE_INTERVAL, table.concat(intervals)) end
  local growth = {}
  for id = 1, K.MAX_BUILDINGS - 1 do
    local entry = G.table + id * K.ENTRY_SIZE
    local uid = rd32(entry)
    if uid ~= 0 and uid == rd32(building(id) + B.UID) and (rd8(entry + 7) & 0xFF) ~= 0 then
      growth[#growth + 1] = string.pack("<I2B", id, rd8(entry + 7) & 0xFF)
    end
  end
  handle:put(K.SAVE_GROWTH, table.concat(growth))
end

local function deserialize(handle)
  wipe()
  if handle:exists(K.SAVE_BUILDINGS) then
    local data = handle:get(K.SAVE_BUILDINGS)
    local size = string.packsize("<I2I4I2BB")
    for offset = 1, #data - size + 1, size do
      local id, _, mask, defenders, growth = string.unpack("<I2I4I2BB", data, offset)
      if id > 0 and id < K.MAX_BUILDINGS and isOutpost(id) then
        local entry = G.table + id * K.ENTRY_SIZE
        wr32(entry, rd32(building(id) + B.UID))
        wr16(entry + 8, 0xFFFF)
        wr16(entry + 4, mask)
        wr8(entry + 6, math.min(defenders, K.MAX_DEFENDERS))
        wr8(entry + 7, 0)          -- older saves held a speed growth: see growth.bin
      end
    end
  end
  if handle:exists(K.SAVE_GROWTH) then
    local data = handle:get(K.SAVE_GROWTH)
    local size = string.packsize("<I2B")
    for offset = 1, #data - size + 1, size do
      local id, growth = string.unpack("<I2B", data, offset)
      if id > 0 and id < K.MAX_BUILDINGS and rd32(G.table + id * K.ENTRY_SIZE) ~= 0 then
        wr8(G.table + id * K.ENTRY_SIZE + 7, math.min(growth, 100))
      end
    end
  end
  if handle:exists(K.SAVE_WAVES) then
    local data = handle:get(K.SAVE_WAVES)
    local size = string.packsize("<I2I2")
    for offset = 1, #data - size + 1, size do
      local id, wave = string.unpack("<I2I2", data, offset)
      if id > 0 and id < K.MAX_BUILDINGS and rd32(G.table + id * K.ENTRY_SIZE) ~= 0 then
        wr16(G.table + id * K.ENTRY_SIZE + 8, math.min(wave, G.waveMax or wave))
      end
    end
  end
  if handle:exists(K.SAVE_INTERVAL) then
    local data = handle:get(K.SAVE_INTERVAL)
    local size = string.packsize("<I2I2")
    for offset = 1, #data - size + 1, size do
      local id, interval = string.unpack("<I2I2", data, offset)
      if id > 0 and id < K.MAX_BUILDINGS and rd32(G.table + id * K.ENTRY_SIZE) ~= 0 then
        wr16(G.table + id * K.ENTRY_SIZE + K.INTERVAL_FIELD, math.min(interval, K.INTERVAL_MAX))
      end
    end
  end
  local guardData = handle:exists(K.SAVE_GUARDS) and handle:get(K.SAVE_GUARDS)
  local guardSize = string.packsize("<I2I2I4")
  if guardData and #guardData >= guardSize and resolveUnitCapacity() then
    local used = {}
    for offset = 1, #guardData - guardSize + 1, guardSize do
      local id, u, unitUid = string.unpack("<I2I2I4", guardData, offset)
      local slot = used[id] or 0
      if id > 0 and id < K.MAX_BUILDINGS and slot < K.MAX_GUARDS
          and u > 0 and u < G.unitCapacity and unitUid ~= 0
          and rd32(G.table + id * K.ENTRY_SIZE) ~= 0 then
        local at = G.slots + (id * K.MAX_GUARDS + slot) * 8
        wr16(at, u)
        wr32(at + 4, unitUid)
        used[id] = slot + 1
      end
    end
  end
  if handle:exists(K.SAVE_JOBS) then
    local data = handle:get(K.SAVE_JOBS)
    local size = string.packsize("<I2I4B")
    for offset = 1, #data - size + 1, size do
      local id, uid, job = string.unpack("<I2I4B", data, offset)
      if id > 0 and id < K.MAX_TRIBES and job <= K.JOB_LAST and uid == rd32(tribe(id) + T.UID) then
        wr8(G.jobs + id, job)
        wr32(G.jobUids + id * 4, uid)
      end
    end
  end
end

---------------------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------------------

local function pad(callback, what)
  local address = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
  core.detourCode(function(registers)
    if not broken then
      local done, problem = pcall(callback)
      if not done then
        broken = true
        log(WARNING, MODULE_NAME .. ": " .. what .. " stopped after an error: " .. tostring(problem))
      end
    end
    return registers
  end, address, 5)
  return address
end

local function matches(address, bytes)
  for index, byte in ipairs(bytes) do
    if (rd8(address + index - 1) & 0xFF) ~= byte then return false end
  end
  return true
end

local function nativeRangeTable(site)
  if site and matches(site, K.RANGE_READ) then return rd32(site + #K.RANGE_READ) end
end

local function resolveState()
  local make = scan(K.AOB_MAKE, "the outpost troops' update")
  G.tribeStride = readOperand(make, K.MAKE_STRIDE, "the troop size")
  G.decideSite = make + K.MAKE_CALL
  G.decide = readCallTarget(make, K.MAKE_CALL, "decideOnTribeAttackLocation")
  same(scan(K.AOB_DECIDE, "decideOnTribeAttackLocation"), G.decide, "decideOnTribeAttackLocation")
  local d = G.decide
  G.tribesThis = readOperand(d, K.DECIDE_TRIBES, "the troop array")
  G.tribes = G.tribesThis
  same(readOperand(make, K.MAKE_UID, "the troop uid"), G.tribes + T.UID, "the troop array")
  G.tribeTarget = readOperand(d, K.DECIDE_TARGET, "the troop's target player") - G.tribes
  G.tribeKind = readOperand(d, K.DECIDE_KIND, "the troop's kind") - G.tribes
  same(readOperand(d, K.DECIDE_OWNER, "the troop owner"), G.tribes + T.OWNER, "the troop owner")
  G.units = readOperand(d, K.DECIDE_UNIT_Y, "the unit array") - U.Y
  G.unitsThis = readOperand(d, K.DECIDE_UNITS_THIS, "the unit state")
  same(G.unitsThis, G.units - U.STATE_OFFSET, "the unit array")
  G.rows = readOperand(d, K.DECIDE_ROWS, "the map rows")
  G.buildings = readOperand(d, K.DECIDE_BUILDING_UID, "the building uid") - B.UID
  G.players = readOperand(d, K.DECIDE_CAMP, "the player array") - P.CAMP
end

local function findLaunch()
  if not G.launch then G.launch = scan(K.AOB_LAUNCH, "where an outpost sends its wave") end
  return G.launch
end

local function resolveLaunch()
  if not G.current then G.current = readOperand(findLaunch(), K.LAUNCH_CURRENT, "the current building") end
end

local function resolveOrderAI()
  if not G.aiState then G.aiState = readOperand(findLaunch(), K.LAUNCH_AI, "the AI state") end
end

local function resolveGuardRecord()
  if G.guardRecorded then return end
  G.guardRecord = scan(K.AOB_GUARD_RECORD, "where an outpost puts away a new defender")
  local recorded = G.guardRecord + K.GUARD_RECORDED
  expectBytes(recorded, { 0x8B, 0x6C, 0x24, 0x10, 0x85, 0xED }, "the end of the defender slots")
  G.guardRecorded = recorded
end

local function resolveTribeActions()
  if F.setStance then return end
  F.createTribe = core.exposeCode(scan(K.AOB_CREATE_TRIBE, "createTribeForPlayer"), 2, 1)
  F.addToTribe = core.exposeCode(scan(K.AOB_ADD_TO_TRIBE, "addUnitToTribe"), 3, 1)
  F.setStance = core.exposeCode(scan(K.AOB_STANCE, "setUnitStance"), 3, 1)
end

local function resolveReach()
  if F.reach then return end
  local d = G.decide
  F.reach = core.exposeCode(readCallTarget(d, K.DECIDE_REACH, "canNavigateUnitsFromTileToTargetTile"), 3, 1)
end

local function resolveInstruction()
  if F.instruction then return end
  local d = G.decide
  local relay = readCallTarget(d, K.DECIDE_RELAY, "relayTribeInstruction")
  local instruction = scan(K.AOB_INSTRUCTION, "giveTribeAnInstruction")
  expectBytes(relay, { 0xB9 }, "relayTribeInstruction")
  same(relay + 10 + rd32(relay + 6), instruction, "giveTribeAnInstruction")
  F.instruction = core.exposeCode(instruction, 6, 1)
end

local function resolveTeams()
  if G.teams then return end
  G.teams = rd32(scan(K.AOB_TEAMS, "the team table") + K.TEAMS_OPERAND)
end

local function resolveMove()
  if F.move then return end
  F.move = core.exposeCode(scan(K.AOB_MOVE, "giveTribeMoveInstruction"), 7, 1)
end

local function resolvePatrol()
  resolveOrderAI()
  resolveReach()
  resolveMove()
  F.addPoint = core.exposeCode(scan(K.AOB_ADD_POINT, "addRallyPoint"), 5, 1)
  if O.riders then
    resolveInstruction()
    resolveTeams()
  end
end

local function resolveDefenders()
  resolveLaunch()
  resolveTribeActions()
  local count = scan(K.AOB_DEFENDER_COUNT, "where an outpost checks its defender count")
  G.defenderCount = count
  local defendersField = readOperand(count, { 0x00, { 0x80, 0xB9 } }, "the defender count")
  same(defendersField, G.buildings + K.DEFENDER_COUNT_FIELD, "the defender count")
  G.roll = readJumpTarget(count + 7, "the defender roll")
  expectBytes(count + 0x1C, { 0x66, 0x85, 0xC0 }, "the defender timer")
  G.skip = readJumpTarget(count + 0x1F, "the end of the defender part")

  local guards = scan(K.AOB_GUARD_COUNT, "where an outpost counts its defenders")
  G.guardCount = guards + K.GUARD_COUNT_AT
  same(readOperand(guards, { K.GUARD_COUNT_AT, { 0x66, 0xC7, 0x81 } }, "the defender timer"),
    G.buildings + K.TIMER_FIELD, "the defender timer")
  resolveGuardRecord()
  G.area = readOperand(G.guardRecord, K.GUARD_AREA, "the area map")
  G.pathFinder = readOperand(G.guardRecord, K.GUARD_PATHS, "the path finder")
  F.navigate = core.exposeCode(readCallTarget(G.guardRecord, K.GUARD_NAVIGATE, "the area test"), 5, 1)
  F.setDestination = core.exposeCode(readCallTarget(G.guardRecord, K.GUARD_DESTINATION,
    "setDestinationForUnit"), 5, 1)
  G.defenderType = scan(K.AOB_DEFENDER_TYPE, "where an outpost picks its defenders")
  same(readOperand(G.defenderType, { 0x00, { 0x66, 0x83, 0xB9 } }, "the outpost type"), G.buildings + B.TYPE,
    "the building array")

end

local function resolveWaveSize()
  resolveLaunch()
  local wave = scan(K.AOB_WAVE_SIZE, "where an outpost sizes its waves")
  G.waveSize = wave + K.WAVE_SIZE_AT
  same(readOperand(wave, { K.WAVE_SIZE_AT, { 0x66, 0x89, 0x91 } }, "the wave size"), G.buildings + K.WAVE_FIELD,
    "the wave size")
end

local function resolveExactWaves()
  resolveGuardRecord()
  G.kinds = readOperand(G.waveSize - K.WAVE_SIZE_AT, K.WAVE_SIZE_KINDS, "the outpost troop kinds") - K.KIND_BASE
  G.waveMax = 0
  for kind = 0, K.KINDS - 1 do
    local at = G.kinds + kind * K.KIND_STRIDE
    local most = (rd32(at + K.KIND_BASE) + rd32(at + K.KIND_RANGE) - 1) * (K.VANILLA_TOP + 1)
    if most > G.waveMax then G.waveMax = most end
  end
  G.waveStart = G.guardRecorded + K.WAVE_START_AT
  expectBytes(G.waveStart, { 0x85, 0xED, 0x0F, 0x85 }, "the start of the wave part")
  G.forming = G.waveStart + 8 + rd32(G.waveStart + 4)
  G.waveResume = G.waveStart + K.WAVE_START_SIZE

  G.growth = scan(K.AOB_GROWTH, "where an outpost speeds up after a wave")
  same(readOperand(G.growth, { 0x00, { 0x66, 0x83, 0x80 } }, "the wave counter"), G.buildings + K.WAVES_FIELD,
    "the wave counter")
  same(readOperand(G.growth, { 0x08, { 0x66, 0x83, 0x80 } }, "the unit pace"), G.buildings + K.PACE_FIELD,
    "the unit pace")

  expectBytes(G.growth + K.GROWTH_SIZE, { 0x5D, 0x5F, 0x5E, 0x5B }, "the end of the outpost update")
end

local function resolveWaveRegister()
  local launch = findLaunch()
  same(readOperand(launch, { 0x00, { 0x8B, 0x80 } }, "the wave troop"), G.buildings + B.TRIBE_UID, "the wave troop")
  G.launchSite = launch + K.LAUNCH_CALL
  G.register = readCallTarget(launch, K.LAUNCH_CALL, "aiRegisterTribeAndAssignTarget")
end

local function resolveMerge()
  resolveOrderAI()
  F.addToItsTribe = core.exposeCode(scan(K.AOB_ADD_TO_ITS_TRIBE, "addUnitToItsTribe"), 3, 1)
end

local function resolveWaveGroups()
  resolveOrderAI()
  resolveReach()
  resolveTribeActions()
  local d = G.decide
  F.busy = core.exposeCode(readCallTarget(d, K.DECIDE_BUSY, "checkTribeActivityPercentages"), 4, 1)
  F.lead = core.exposeCode(readCallTarget(d, K.DECIDE_LEAD, "getUnitIDForIndexInTribe"), 3, 1)
  F.command = core.exposeCode(readCallTarget(d, K.DECIDE_COMMAND, "commandUnitsToLocation"), 5, 1)
  F.register = core.exposeCode(G.register, 3, 1)
end

local function resolveRoleOrders()
  resolveLaunch()
  resolveInstruction()
  local d = G.decide
  G.paths = readOperand(d, K.DECIDE_PATHS, "the path finder")
  F.path = core.exposeCode(readCallTarget(d, K.DECIDE_PATH, "pathFindingToAttackCastleIncludingMoat"), 8, 1)
end

local function resolveMapLayers()
  G.tileFlags = rd32(scan(K.AOB_TILE_FLAGS, "the tile flags") + K.TILE_FLAGS_OPERAND)
  G.buildingLayer = G.tileFlags + K.FLAGS_TO_BUILDINGS
  G.wallOwner = G.tileFlags + K.FLAGS_TO_WALL_OWNER
  same(G.rows, G.tileFlags + K.FLAGS_TO_ROWS, "the map layers")
end

local function resolveInterval()
  resolveLaunch()
  local found, at = pcall(core.AOBScan, K.AOB_INTERVAL)
  if not found then error("idle wave wait not found") end
  local site = at + K.INTERVAL_AT
  local timer = G.buildings + K.IDLE_TIMER_FIELD
  same(readOperand(site, { 0, { 0x66, 0x83, 0x80 } }, "the idle wave timer"), timer, "the idle wave timer")
  same(readOperand(site, { 8, { 0x0F, 0xB7, 0x90 } }, "the idle wave timer"), timer, "the idle wave timer")
  G.interval = site
end

local function resolveSiege(acquire)
  resolveTeams()
  F.acquire = core.exposeCode(acquire, 2, 1)
  F.halt = core.exposeCode(scan(K.AOB_HALT, "the game's stop walking"), 2, 1)
end

local function resolveDamageable()
  local found, at = pcall(core.AOBScan, K.AOB_DAMAGEABLE)
  if not found then error("building damageability not found") end
  same(readOperand(at, { 0, { 0x0F, 0xB7, 0x8E } }, "the damaged building's type"),
    G.buildings + B.TYPE, "the building array")
  G.damageable = readOperand(at, { 16, { 0x83, 0x3C, 0x95 } }, "the damageable building kinds")
end

local function resolveWallShooting()
  local found, at = pcall(core.AOBScan, K.AOB_SHOOT_WALL)
  if not found then error("siege attack at wall not found") end
  same(readOperand(at, { 35, { 0x8B, 0x1C, 0x95 } }, "the wall target's map rows"), G.rows, "the map rows")
  G.siegeMap = readOperand(at, { 46, { 0xB9 } }, "the shooting map")
  F.playable = core.exposeCode(readCallTarget(at, 51, "wall target's playable tile test"), 3, 1)
  if O.jobs then
    G.height = readOperand(at, { 0x84, { 0x0F, 0xB6, 0x83 } }, "the height layer")
    same(G.height, G.tileFlags + (0x29FA30 - 0x165160), "the height layer")
  end
end

local function resolvePanel()
  local panel = scan(K.AOB_PANEL, "the outpost panel")
  G.panel = panel
  G.selected = readOperand(panel, K.PANEL_SELECTED, "the selected building")
  same(readOperand(panel, K.PANEL_TYPE, "the outpost type"), G.buildings + B.TYPE, "the building array")
  G.menuY = readOperand(panel, K.PANEL_MENU_Y, "the panel position")
  G.menuX = readOperand(panel, K.PANEL_MENU_X, "the panel position")
  G.textManager = readOperand(panel, K.PANEL_TEXT_MANAGER, "the text manager")
  G.renderText = readCallTarget(panel, K.PANEL_RENDER_TEXT, "renderTextToScreen")
  G.getText = readCallTarget(panel, K.PANEL_GET_TEXT, "getTextStringInGroupAtOffset")

  local render = scan(K.AOB_BUTTON_RENDER, "the outpost's troop buttons")
  G.buttonRender = render
  same(readOperand(render, K.RENDER_SELECTED, "the selected building"), G.selected, "the selected building")
  same(readOperand(render, K.RENDER_MASK, "the troop buttons"), G.buildings + B.MASK, "the troop buttons")
  G.hover = readOperand(render, K.RENDER_HOVER, "the button hover flag")
  G.button = readCallTarget(render, K.RENDER_BUTTON, "the button renderer")
  G.buttonX = readOperand(render, K.RENDER_X, "the button place")
  same(readOperand(render, K.RENDER_Y, "the button place"), G.buttonX + 4, "the button place")
  same(readOperand(render, K.RENDER_W, "the button place"), G.buttonX + 8, "the button place")
  same(readOperand(render, K.RENDER_TEXT_MANAGER, "the text manager"), G.textManager, "the text manager")
  G.shadowText = readCallTarget(render, K.RENDER_SHADOW_TEXT, "renderInGameTextWithShadow")
  G.buttonImage = readOperand(G.button, K.BUTTON_IMAGE, "the button picture")
  G.drawChoice = readOperand(G.button, K.BUTTON_DRAW_CHOICE, "the draw buffer")

  G.buttonClick = scan(K.AOB_BUTTON_CLICK, "the outpost's troop button click")
  same(readOperand(G.buttonClick, { 0x00, { 0xA1 } }, "the selected building"), G.selected, "the selected building")
  G.sizeSlider = scan(K.AOB_SIZE, "the outpost's size slider")
  G.delaySlider = scan(K.AOB_DELAY, "the outpost's start delay slider")
  same(readOperand(G.sizeSlider, K.SLIDER_SELECTED, "the selected building"), G.selected, "the selected building")
  same(readOperand(G.delaySlider, K.SLIDER_SELECTED, "the selected building"), G.selected, "the selected building")
  same(readOperand(G.sizeSlider, K.SLIDER_FIELD, "the wave size"), G.buildings + K.SIZE_FIELD, "the wave size")
  same(readOperand(G.delaySlider, K.SLIDER_FIELD, "the start delay"), G.buildings + K.DELAY_FIELD,
    "the start delay")

  local menuItem = scan(K.AOB_MENU_ITEM, "the menu item handler")
  G.mouse = readOperand(menuItem, K.MENU_ITEM_MOUSE, "the mouse")
  local toolbar = scan(K.AOB_TOOLBAR, "the toolbar key handler") - K.TOOLBAR_PATTERN_OFFSET
  G.clickSound = readOperand(toolbar, K.TOOLBAR_SOUND_ID, "the click sound")
  G.sounds = readOperand(toolbar, K.TOOLBAR_SOUNDS, "the sound player")
  G.playSound = readCallTarget(toolbar, K.TOOLBAR_PLAY_SOUND, "the sound player")

  -- The static initializer passes the building menu its item table.
  local constructor = scan(data.version.isExtreme() and K.AOB_BUILDING_MENU_EXTREME or K.AOB_BUILDING_MENU,
    "the building menu initializer")
  local start = rd32(constructor + 1)
  local menu = rd32(constructor + 6)
  local first, last = ucp.internal.getMainImageRange()
  if start < first or start > last - K.ITEM_SIZE + 1 or rd32(start) ~= 0
      or menu < first or menu > last - 3 then
    error("the building menu initializer has invalid operands", 0)
  end
  local sizeItem, endItem
  for index = 0, 399 do
    local item = start + index * K.ITEM_SIZE
    if item > last - K.ITEM_SIZE + 1 then break end
    if rd32(item + K.ITEM_TYPE) == K.TYPE_LAST then
      endItem = item
      break
    end
    if rd32(item + K.ITEM_ACTION) == G.sizeSlider then
      if sizeItem then error("the building menu has multiple outpost size sliders", 0) end
      sizeItem = item
    end
  end
  if not endItem or not sizeItem or sizeItem + K.ITEM_SIZE >= endItem then
    error("the building menu's outpost sliders could not be verified", 0)
  end
  local header = sizeItem - K.SIZE_ITEM_FROM_GROUP * K.ITEM_SIZE
  if header < start or rd32(header + K.ITEM_TYPE) ~= K.TYPE_GROUP then
    error("the building menu's outpost group could not be verified", 0)
  end
  local delayItem = sizeItem + K.ITEM_SIZE
  same(rd32(header + K.ITEM_SIZE + K.ITEM_IMAGE), K.TEXT_BUTTON, "the outpost's button picture")
  same(rd32(delayItem + K.ITEM_ACTION), G.delaySlider, "the outpost's start delay slider action")
  for _, slider in ipairs({ { sizeItem, K.GAME_SIZE_Y }, { delayItem, K.GAME_DELAY_Y } }) do
    local item = slider[1]
    same(rd32(item + K.ITEM_TYPE), 5, "the outpost slider type")
    same(rd32(item + 4), K.SLIDER_X, "the outpost slider x position")
    same(rd32(item + K.ITEM_Y), slider[2], "the outpost slider y position")
    same(rd32(item + 0x0C), K.SLIDER_W, "the outpost slider width")
    same(rd32(item + 0x10), K.SLIDER_H, "the outpost slider height")
  end
  G.sizeItem, G.delayItem, G.menu = sizeItem, delayItem, menu
  G.sliderRender = rd32(sizeItem + K.ITEM_RENDER)
  if G.sliderRender == 0 then error("the outpost slider renderer is missing", 0) end
  F.sizeSlider = core.exposeCode(G.sizeSlider, 5, 0)
end

local panelText = require("panel_text")
local function writeWords(catalog, encode)
  local encoded = {}
  for key in pairs(G.words) do
    local text = encode(catalog[key])
    if text:match("^ERROR:") then error("textResourceModifier cannot encode " .. catalog[key], 0) end
    encoded[key] = core.CString(text)
  end
  for key, text in pairs(encoded) do
    wr32(G.words[key], text.address)
    words[key] = text
  end
end

local function localizeWords()
  local catalog = panelText[K.CATALOGS[data.version.getGameLanguage()]]
  if catalog == nil then return end
  local owner = modules.textResourceModifier
  local ok, problem = pcall(writeWords, catalog, function(text) return owner:TransformText(text) end)
  if not ok then log(WARNING, "the outpost panel keeps its English words: " .. tostring(problem)) end
end

local function allocate()
  G.table = core.allocate(K.MAX_BUILDINGS * K.ENTRY_SIZE, true)
  G.slots = core.allocate(K.MAX_BUILDINGS * K.MAX_GUARDS * 8, true)
  G.drag = core.allocate(4, true)
  G.siegeUnit = core.allocate(4, true)
  G.riderUnit = core.allocate(4, true)
  G.guardUnit = core.allocate(4, true)
  G.numberText = core.allocate(16, true)
  G.jobs = core.allocate(K.MAX_TRIBES, true)
  G.jobUids = core.allocate(K.MAX_TRIBES * 4, true)
  G.mode = core.allocate(4, true)
  if O.interval then G.scope = core.allocate(4, true) end
  G.launchTribe = core.allocate(4, true)
  G.launchThis = core.allocate(4, true)
  G.decideTribe = core.allocate(4, true)
  G.decideThis = core.allocate(4, true)
  G.scratch = core.allocate(16, true)
  G.defenderTypes = core.allocate(16, true)
  for index, kind in ipairs(K.DEFENDER_TYPES) do wr8(G.defenderTypes + index - 1, kind) end
  G.defenderTexts = core.allocate(16 * 4, true)
  for index, text in ipairs(K.DEFENDER_TEXTS) do wr32(G.defenderTexts + (index - 1) * 4, text) end
  G.pageTexts = core.allocate(2 * 4, true)
  -- Labels: x, y, text (0 = the game's text with that id), id.
  local function labels(list)
    local at = core.allocate(#list * 16, true)
    for index, label in ipairs(list) do
      for field = 1, 4 do wr32(at + (index - 1) * 16 + (field - 1) * 4, label[field]) end
    end
    return at, #list
  end
  local attack = { { K.LABEL_X, K.SIZE_Y + K.LABEL_DROP, 0, K.TEXT_SIZE } }
  if not O.interval then attack[2] = { K.LABEL_X, K.DELAY_Y + K.LABEL_DROP, 0, K.TEXT_DELAY } end
  if O.growth then
    attack[#attack + 1] = { K.LABEL_X, (O.interval and K.SECOND_ROW_Y or K.GROWTH_Y) + K.LABEL_DROP, 0, 0 }
  end
  G.attackLabels, G.attackLabelCount = labels(attack)
  local sizeY = (O.growth or O.interval) and K.SIZE_Y or K.GAME_SIZE_Y
  G.defendLabels, G.defendLabelCount = labels({ { K.LABEL_X, sizeY + K.LABEL_DROP, 0, 0 } })
  G.words = { panel_attackers = G.pageTexts, panel_defenders = G.pageTexts + 4, panel_amount = G.defendLabels + 8 }
  if O.growth then G.words.panel_growth = G.attackLabels + (#attack - 1) * 16 + 8 end
  if O.interval then
    G.scopeTexts = core.allocate(8, true)
    G.timingLabels, G.timingLabelCount = labels({
      { K.LABEL_X, K.SIZE_Y + K.LABEL_DROP, 0, K.TEXT_DELAY },
      { K.LABEL_X, K.SECOND_ROW_Y + K.LABEL_DROP, 0, 0 },
    })
    G.words.panel_size = G.scopeTexts
    G.words.panel_timing = G.scopeTexts + 4
    G.words.panel_interval = G.timingLabels + 16 + 8
  end
  writeWords(panelText.en, function(text) return text end)
end

local function install(self)
  local values = {
    MAX_BUILDINGS = K.MAX_BUILDINGS, MAX_TRIBES = K.MAX_TRIBES, B_STRIDE = B.STRIDE,
    B_UID = G.buildings + B.UID, B_TYPE = G.buildings + B.TYPE, B_DEFENDERS = G.buildings + K.DEFENDER_COUNT_FIELD,
    B_WAVES = G.buildings + K.WAVES_FIELD, B_PACE = G.buildings + K.PACE_FIELD,
    TABLE = G.table, ENTRY_SHIFT = K.ENTRY_SHIFT, MAX_DEFENDERS = K.MAX_DEFENDERS, USUAL_DEFENDERS = K.USUAL_DEFENDERS,
    CURRENT_BUILDING = G.current, ARAB_OUTPOST = K.OUTPOST_ARAB, EURO_ARCHER = K.EURO_ARCHER,
    ARAB_ARCHER = K.ARAB_ARCHER, DEFENDER_TYPES = G.defenderTypes,
    SLOTS = G.slots, SLOT_BYTES = K.MAX_GUARDS * 8, SLOT_DWORDS = K.MAX_GUARDS * 2, MAX_GUARDS = K.MAX_GUARDS,
    U_STRIDE = U.STRIDE, U_UID = G.units + U.UID, UNIT_CAPACITY = G.unitCapacity,
    UNIT_COUNT = G.unitsThis, VANILLA_SLOTS = K.VANILLA_SLOTS,
  }
  local saved, writes = {}, {}
  local function keep(address, size)
    saved[#saved + 1] = { address = address, bytes = core.readBytes(address, size) }
  end
  local function stage(site, bytes)
    local code = core.compile(bytes, site)
    keep(site, #code)
    writes[#writes + 1] = function() core.writeCode(site, code, false) end
  end
  local function stageJump(site, target, size)
    stage(site, relativePatch(0xE9, site, target, size))
  end

  values.ENTRY_GET = assemble(templates.entryGet, values)
  values.ENTRY_MAKE = assemble(templates.entryMake, values)

  if O.defenders then
    values.SKIP, values.ROLL, values.RESUME = G.skip, G.roll, G.defenderCount + K.DEFENDER_COUNT_SIZE
    stageJump(G.defenderCount, assemble(templates.defenderCount, values), K.DEFENDER_COUNT_SIZE)
    values.B_TIMER, values.GUARD_PACE = G.buildings + K.TIMER_FIELD, K.GUARD_PACE
    values.LONGEST_WAIT, values.SHORTEST_WAIT = K.LONGEST_WAIT, K.SHORTEST_WAIT
    values.PICK, values.RESUME = G.defenderType, G.guardCount + K.GUARD_COUNT_SIZE
    stageJump(G.guardCount, assemble(templates.guardCount, values), K.GUARD_COUNT_SIZE)
    values.DONE, values.RESUME = G.guardRecorded, G.guardRecord + K.GUARD_RECORD_SIZE
    values.GUARD_UNIT, values.PAD = G.guardUnit, pad(onGuard, "outpost guards")
    stageJump(G.guardRecord, assemble(templates.guardRecord, values), K.GUARD_RECORD_SIZE)
    values.RESUME = G.defenderType + K.DEFENDER_TYPE_SIZE
    stageJump(G.defenderType, assemble(templates.defenderType, values), K.DEFENDER_TYPE_SIZE)
  end

  values.WAVES_ON, values.GROWTH_ON = O.waves and 1 or 0, O.growth and 1 or 0
  values.B_WAVE, values.GROWTH_CAP = G.buildings + K.WAVE_FIELD, K.GROWTH_CAP
  if O.interval then
    values.INTERVAL_FIELD, values.TICKS_PER_SECOND = K.INTERVAL_FIELD, K.TICKS_PER_SECOND
    values.B_IDLE_TIMER, values.RESUME = G.buildings + K.IDLE_TIMER_FIELD, G.interval + K.INTERVAL_SIZE
    stageJump(G.interval, assemble(templates.intervalWait, values), K.INTERVAL_SIZE)
  end
  if O.waves or O.growth then
    values.RESUME = G.waveSize + K.WAVE_SIZE_SIZE
    stageJump(G.waveSize, assemble(templates.waveSize, values), K.WAVE_SIZE_SIZE)
  end
  if O.waves then
    values.KINDS, values.KIND_STRIDE = G.kinds, K.KIND_STRIDE
    values.KIND_BASE, values.KIND_RANGE = K.KIND_BASE, K.KIND_RANGE
    values.B_MASK, values.B_SIZE = G.buildings + B.MASK, G.buildings + K.SIZE_FIELD
    values.B_WAVE, values.WAVE_MAX, values.VANILLA_TOP = G.buildings + K.WAVE_FIELD, G.waveMax, K.VANILLA_TOP
    values.KIND_AVERAGE = assemble(templates.kindAverage, values)
    values.WAVE_VALUE = assemble(templates.waveValue, values)
    values.UPDATE_END, values.FORMING, values.RESUME = G.growth + K.GROWTH_SIZE, G.forming, G.waveResume
    stageJump(G.waveStart, assemble(templates.waveStart, values), K.WAVE_START_SIZE)
  end


  local orders = O.jobs or O.siege
  if orders or O.join then
    values.LAUNCH_TRIBE, values.LAUNCH_THIS, values.REGISTER = G.launchTribe, G.launchThis, G.register
    values.PAD = pad(onLaunch, "splitting waves")
    stage(G.launchSite, relativePatch(0xE8, G.launchSite, assemble(templates.launch, values), 5))
  end
  if orders or O.retarget then
    values.ORDERS = orders and 1 or 0
    values.JOBS, values.JOB_UIDS, values.TRIBE_STRIDE = G.jobs, G.jobUids, G.tribeStride
    values.TRIBE_UID = G.tribes + T.UID
    values.JOBS_ON, values.SIEGE_ON = O.jobs and 1 or 0, O.siege and 1 or 0
    values.JOB_SIEGE = K.JOB_SIEGE
    values.DECIDE_TRIBE, values.DECIDE_THIS, values.DECIDE = G.decideTribe, G.decideThis, G.decide
    values.RETARGET, values.SET_TARGET = O.retarget and 1 or 0, G.setTarget
    values.TRIBE_TARGET, values.TRIBE_OWNER = G.tribes + G.tribeTarget, G.tribes + T.OWNER
    values.P_STRIDE, values.P_LORD, values.P_LORD_UID = P.STRIDE, G.players + P.LORD, G.players + P.LORD_UID
    values.U_STATE, values.U_TYPE, values.LORD_TYPE = G.units + U.STATE, G.units + U.TYPE, K.LORD_TYPE
    if orders then values.PAD = pad(onDecide, "outpost troop orders") end
    stage(G.decideSite, relativePatch(0xE8, G.decideSite, assemble(templates.decide, values), 5))
  end

  local siegeUpdates = O.siege and G.updateTable ~= nil
  if siegeUpdates or O.riders then
    G.originalUpdates = core.allocate(K.UNIT_TYPES * 4, true)
    for kind = 0, K.UNIT_TYPES - 1 do wr32(G.originalUpdates + kind * 4, rd32(G.updateTable + kind * 4)) end
    values.CURRENT_UNIT, values.TICKS, values.SIEGE_EVERY = G.currentUnit, G.ticks, K.SIEGE_EVERY
    values.U_BEHAVIOUR, values.U_ACTION, values.U_TYPE = G.units + U.BEHAVIOUR, G.units + U.ACTION, G.units + U.TYPE
    values.OUTPOST_BEHAVIOUR, values.STATE_MOVING = K.OUTPOST_BEHAVIOUR, K.STATE_MOVING
    values.STATE_WALKING, values.ORIGINAL_UPDATES = K.STATE_WALKING, G.originalUpdates
  end
  if siegeUpdates then
    values.STATE_CREEPING, values.SIEGE_UNIT = K.STATE_CREEPING, G.siegeUnit
    values.PAD = pad(onSiegeUnit, "siege engines on the way")
    values.BALLISTA = 0
    local check = assemble(templates.siegeCheck, values)
    for kind in pairs(K.SIEGE) do
      if kind ~= K.FIRE_BALLISTA then stage(G.updateTable + kind * 4, core.itob(check)) end
    end
    if G.ballistaIdleDelay then
      values.BALLISTA, values.IDLE_DELAY = 1, G.ballistaIdleDelay
      values.U_TARGETING, values.U_TARGET_BUILDING = G.units + U.TARGETING, G.units + U.TARGET_BUILDING
      values.U_TARGET_UID, values.U_WALL_X = G.units + U.TARGET_UID, G.units + U.WALL_X
      values.U_SHOOT_UNIT = G.units + U.SHOOT_UNIT
      values.ATTACK_BUILDING, values.ATTACK_WALL_AT = K.ORDER_ATTACK_BUILDING, K.ORDER_ATTACK_WALL_AT
      values.STATE_SHOOT, values.STATE_LOAD, values.STATE_FIRE = K.STATE_SHOOT, K.STATE_LOAD, K.STATE_FIRE
      stage(G.updateTable + K.FIRE_BALLISTA * 4, core.itob(assemble(templates.siegeCheck, values)))
    end
  end
  if O.riders then
    -- the same check for knight guards; their states 0, 1 and 0x65 only
    values.BALLISTA = 0
    values.STATE_CREEPING, values.SIEGE_UNIT = K.STATE_MOVING, G.riderUnit
    values.PAD = pad(onRider, "patrolling knights")
    stage(G.updateTable + K.KNIGHT * 4, core.itob(assemble(templates.siegeCheck, values)))
  end

  if O.defenders or O.growth or O.waves or O.interval then
    values.MODE, values.SELECTED = G.mode, G.selected
    values.MENU_X, values.MENU_Y = G.menuX, G.menuY
    values.TEXT_MANAGER, values.RENDER_TEXT, values.SHADOW_TEXT = G.textManager, G.renderText, G.shadowText
    values.GET_TEXT, values.PAGE_TEXTS, values.DEFENDER_TEXTS = G.getText, G.pageTexts, G.defenderTexts
    values.UNIT_HELP_GROUP = K.UNIT_HELP_GROUP
    values.MOUSE, values.MOUSE_X, values.MOUSE_Y = G.mouse, K.MOUSE_X, K.MOUSE_Y
    values.LEFT_CLICK, values.LEFT_HELD = K.LEFT_CLICK, K.LEFT_HELD
    values.CLICK_SOUND, values.SOUNDS, values.PLAY_SOUND = G.clickSound, G.sounds, G.playSound
    values.BUTTON_X, values.BUTTON_HOVER, values.BUTTON_IMAGE = G.buttonX, G.hover, G.buttonImage
    values.DRAW_CHOICE, values.BUTTON_RENDER, values.TEXT_BUTTON = G.drawChoice, G.button, K.TEXT_BUTTON
    values.TOGGLE_X, values.TOGGLE_Y, values.TOGGLE_W, values.TOGGLE_H = K.TOGGLE_X, K.TOGGLE_Y, K.TOGGLE_W, K.TOGGLE_H
    values.TOGGLE_HALF = K.TOGGLE_W // 2
    values.GROWTH_ON, values.TOGGLE_ON = O.growth and 1 or 0, O.defenders and 1 or 0
    values.NUMBER_TEXT, values.NUMBER_X, values.TICKS_PER_SECOND = G.numberText, K.NUMBER_X, K.TICKS_PER_SECOND
    values.B_SIZE, values.B_DELAY = G.buildings + K.SIZE_FIELD, G.buildings + K.DELAY_FIELD
    values.INTERVAL_ON, values.SCOPE = O.interval and 1 or 0, G.scope
    values.SIZE_ROW = ((O.growth or O.interval) and K.SIZE_Y or K.GAME_SIZE_Y) + K.LABEL_DROP
    values.DELAY_ROW = (O.interval and K.SIZE_Y or O.growth and K.DELAY_Y or K.GAME_DELAY_Y) + K.LABEL_DROP
    values.GROWTH_ROW = (O.interval and K.SECOND_ROW_Y or K.GROWTH_Y) + K.LABEL_DROP
    values.INTERVAL_ROW = K.SECOND_ROW_Y + K.LABEL_DROP
    values.NUMBERS = assemble(templates.numbers, values)

    if O.growth or O.interval then
      values.LABEL_TABLE, values.LABEL_COUNT = G.attackLabels, G.attackLabelCount
      values.ATTACK_LABELS = assemble(templates.labels, values)
      values.SLIDER_X, values.SLIDER_W, values.SLIDER_H = K.SLIDER_X, K.SLIDER_W, K.SLIDER_H
      values.KNOB_W, values.KNOB_HALF, values.KNOB_SPAN = K.KNOB_W, K.KNOB_W // 2, K.SLIDER_W - K.KNOB_W
      values.KNOB_ABOVE, values.KNOB_H = K.KNOB_ABOVE, K.KNOB_H
      values.DRAG, values.SLIDER_RENDER = G.drag, G.sliderRender
      if O.growth then
        values.SLIDER_Y, values.STEPS = O.interval and K.SECOND_ROW_Y or K.GROWTH_Y, 100
        values.ENTRY_FIELD, values.STEP, values.WIDE = 7, 1, 0
        values.GROWTH_SLIDER = assemble(templates.entrySlider, values)
      end
      if O.interval then
        values.LABEL_TABLE, values.LABEL_COUNT = G.timingLabels, G.timingLabelCount
        values.TIMING_LABELS = assemble(templates.labels, values)
        values.SLIDER_Y, values.STEPS = K.SECOND_ROW_Y, K.INTERVAL_MAX // K.INTERVAL_STEP
        values.ENTRY_FIELD, values.STEP, values.WIDE = K.INTERVAL_FIELD, K.INTERVAL_STEP, 1
        values.INTERVAL_SLIDER = assemble(templates.entrySlider, values)
      end
      keep(G.sizeItem + K.ITEM_Y, 4)
      keep(G.delayItem + K.ITEM_Y, 4)
      liveSliders(function(item) keep(item + K.ITEM_Y, 4) end)
      writes[#writes + 1] = moveSliders
    end

    if O.defenders or O.interval then
      values.PAD = pad(refreshSliders, "the outpost panel")
      if O.defenders then
        values.TOGGLE_STATE, values.TOGGLE_TEXTS = G.mode, G.pageTexts
        values.TOGGLE = assemble(templates.toggle, values)
      end
      if O.interval then
        keep(G.sizeItem + K.ITEM_HIDDEN, 2)
        keep(G.delayItem + K.ITEM_HIDDEN, 2)
        liveSliders(function(item, action)
          keep(item + K.ITEM_HIDDEN, 2)
          if action == G.sizeSlider then keep(item + K.ITEM_MIN, 12) end
        end)
        values.TOGGLE_X, values.TOGGLE_STATE, values.TOGGLE_TEXTS = K.SCOPE_X, G.scope, G.scopeTexts
        values.SCOPE_TOGGLE = assemble(templates.toggle, values)
        writes[#writes + 1] = refreshSliders
      end
    end

    if O.defenders then
      values.LABEL_TABLE, values.LABEL_COUNT = G.defendLabels, G.defendLabelCount
      values.DEFENDER_LABELS = assemble(templates.labels, values)

      values.RESUME = G.buttonRender + K.BUTTON_RENDER_SIZE
      stageJump(G.buttonRender, assemble(templates.buttonRender, values), K.BUTTON_RENDER_SIZE)
      values.RESUME = G.buttonClick + K.BUTTON_CLICK_SIZE
      stageJump(G.buttonClick, assemble(templates.buttonClick, values), K.BUTTON_CLICK_SIZE)
    end
    if O.defenders or O.waves then
      if O.waves then values.WAVE_SLIDER = assemble(templates.waveSlider, values) end
      values.RESUME, values.FIELD, values.TOP, values.STEP, values.SYNC = G.sizeSlider + K.SLIDER_SIZE, 6,
        K.MAX_DEFENDERS, 1, 1
      stageJump(G.sizeSlider, assemble(templates.slider, values), K.SLIDER_SIZE)
    end

    values.RESUME = G.panel + 5
    stageJump(G.panel, assemble(templates.panel, values), 5)
  end
  self.saved = saved
  for _, write in ipairs(writes) do write() end
  if O.growth or O.interval then
    hooks.registerHookCallback("afterInit", function()
      if self.saved == nil then return end
      moveSliders()
      if O.interval then refreshSliders() end
    end)
  end
end

local function enable(self, config)
  if config ~= nil and type(config) ~= "table" then
    log(ERROR, MODULE_NAME .. ": invalid settings type. Using defaults.")
    return
  end
  config = config or {}
  O.defenders = setting(config, "defenders", "enabled") == true
  O.walls = O.defenders and setting(config, "defenders", "walls") == true
  O.waves = setting(config, "waves", "exact") == true
  O.interval = setting(config, "waves", "interval") == true
  O.riders = O.defenders and setting(config, "defenders", "knights") == true
  O.growth = setting(config, "growth", "enabled") == true
  O.jobs = setting(config, "jobs", "enabled") == true
  O.variation = O.jobs and setting(config, "jobs", "variation", 50) or 0
  O.siege = setting(config, "siege", "enabled") == true
  O.join = setting(config, "join", "enabled") == true
  O.retarget = setting(config, "retarget", "enabled") == true
  O.log = setting(config, "diagnostics", "log") == true
  O.plans = {}
  if O.jobs then
    for _, plan in ipairs(K.PLANS) do
      O.plans[plan.kind] = { first = plan.first, rest = plan.rest, share = setting(config, "jobs", plan.name, 100) }
    end
  end
  O.plans[23] = { first = K.JOB_OVERWATCH, rest = K.JOB_OVERWATCH, share = 100 }
  G.ticks, G.updateTable, G.ballistaIdleDelay = nil, nil, nil
  O.patrol = false
  if O.defenders or O.siege or O.jobs then
    local found, site = pcall(core.AOBScan, K.AOB_TICKS)
    if found then
      G.ticks = rd32(site + K.TICKS_OPERAND)
    else
      log(ERROR, MODULE_NAME .. ": game tick counter not found"
        .. "; defender patrols and periodic knight and siege updates stay off")
      O.riders = false
    end
  end
  if not O.defenders and not O.growth and not O.jobs and not O.siege and not O.join and not O.retarget
      and not O.waves and not O.interval then
    log(INFO, MODULE_NAME .. ": every part is off")
    return
  end

  -- A part whose code is not found (another module changed it) stays off on its own.
  local ok, problem = pcall(resolveState)
  if not ok then
    log(ERROR, "Outpost Control is off. Shared outpost state could not be bound: " .. tostring(problem))
    return
  end
  G.unitCapacity, G.unitCapacityResolved = nil, false
  if O.defenders and not resolveUnitCapacity() then
    O.defenders, O.walls, O.riders = false, false, false
  end
  if O.defenders then
    ok, problem = pcall(resolveDefenders)
    if not ok then
      log(ERROR, "Outpost defenders and patrols are off: " .. tostring(problem))
      O.defenders, O.walls, O.riders = false, false, false
    end
  end
  if O.waves or O.growth then
    ok, problem = pcall(resolveWaveSize)
    if not ok then
      log(ERROR, "Outpost wave sizes and growth are off: " .. tostring(problem))
      O.waves, O.growth = false, false
    end
  end
  if O.waves then
    ok, problem = pcall(resolveExactWaves)
    if not ok then
      log(ERROR, "Exact outpost wave sizes are off: " .. tostring(problem))
      O.waves = false
    end
  end
  if O.jobs or O.siege or O.join or O.retarget then
    ok, problem = pcall(resolveWaveRegister)
    if not ok then
      log(ERROR, "Outpost wave roles, siege orders, merging and retargeting are off: " .. tostring(problem))
      O.jobs, O.siege, O.join, O.retarget = false, false, false, false
    end
  end
  if O.retarget then
    ok, problem = pcall(readCallTarget, G.register, K.REGISTER_SET_TARGET, "setTargetForTribeBasedOnTargetChoiceLogic")
    if ok then
      G.setTarget = problem
    else
      log(ERROR, "Outpost retargeting is off: " .. tostring(problem))
      O.retarget = false
    end
  end
  if O.jobs or O.siege or O.join then
    ok, problem = pcall(function()
      F.removeFromTribe = core.exposeCode(scan(K.AOB_REMOVE_FROM_TRIBE, "removeUnitFromTribe"), 3, 1)
    end)
    if not ok then
      log(ERROR, "Outpost wave roles, siege orders and merging are off: " .. tostring(problem))
      O.jobs, O.siege, O.join = false, false, false
    end
  end
  if O.join then
    ok, problem = pcall(resolveMerge)
    if not ok then
      log(ERROR, "Outpost wave merging is off: " .. tostring(problem))
      O.join = false
    end
  end
  if O.jobs or O.siege then
    ok, problem = pcall(resolveWaveGroups)
    if not ok then
      log(ERROR, "Outpost wave roles and siege orders are off: " .. tostring(problem))
      O.jobs, O.siege = false, false
    end
  end
  if O.jobs then
    ok, problem = pcall(resolveRoleOrders)
    if not ok then
      log(ERROR, "Outpost wave roles are off: " .. tostring(problem))
      O.jobs = false
    end
  end
  if O.defenders and G.ticks then
    ok, problem = pcall(resolvePatrol)
    O.patrol = ok
    if not ok then
      log(ERROR, "Outpost patrols are off: " .. tostring(problem))
      O.riders = false
    end
  end
  if O.walls or O.patrol or O.jobs or O.siege then
    ok, problem = pcall(resolveMapLayers)
    if not ok then
      log(ERROR, "Outpost wall defenders, patrols, wave roles and siege targeting are off: " .. tostring(problem))
      O.walls, O.patrol, O.riders, O.jobs, O.siege = false, false, false, false, false
    end
  end
  if O.interval then
    ok, problem = pcall(resolveInterval)
    if not ok then
      log(ERROR, "Fixed outpost wave intervals are off: " .. tostring(problem))
      O.interval = false
    end
  end
  if O.defenders or O.growth or O.waves or O.interval then
    ok, problem = pcall(resolvePanel)
    if not ok then
      log(ERROR, "Outpost panel controls, defenders, growth and wave sizes are off: " .. tostring(problem))
      O.defenders, O.growth, O.waves, O.walls, O.riders, O.interval = false, false, false, false, false, false
    end
  end
  if O.siege or O.jobs then
    local found, acquire = pcall(core.AOBScan, K.AOB_ACQUIRE)
    local site = found and acquire + K.ACQUIRE_RANGE or nil
    local acquireProblem = not found and "acquireShootTarget not found"
    local rangeProblem
    G.ranges = nativeRangeTable(site)
    if not G.ranges then
      local found, crossbow = pcall(core.AOBScan, K.AOB_XBOW_RANGE)
      if found then
        local ok, entry = pcall(readOperand, crossbow, K.XBOW_RANGE_ENTRY, "the crossbow range")
        if ok then
          G.ranges = entry - K.RANGED_PROJECTILE[23] * 4
        else
          rangeProblem = tostring(entry)
        end
      else
        rangeProblem = "crossbow range binding not found"
      end
    end
    if O.jobs then
      if rangeProblem then
        log(ERROR, MODULE_NAME .. ": projectile standoff stays off: " .. rangeProblem)
      end
      hooks.registerHookCallback("afterInit", function()
        local rebalancer = modules.rebalancer
        if rebalancer and type(rebalancer.getBowRanges) == "function" then
          G.bowRanges = rebalancer:getBowRanges()
          if G.bowRanges then return end
        end
        local ranges = nativeRangeTable(site)
        if ranges then
          G.bowRange = rd32(ranges + 4)
        else
          log(ERROR, MODULE_NAME .. ": bow standoff stays off: "
            .. (acquireProblem or "native bow range instruction changed"))
        end
      end)
    end
    if O.siege then
      local siegeProblem = acquireProblem or rangeProblem
      if not siegeProblem then
        local ok, problem = pcall(resolveSiege, acquire)
        if not ok then siegeProblem = tostring(problem) end
      end
      if siegeProblem then
        log(ERROR, MODULE_NAME .. ": siege engines on the way stay off: " .. siegeProblem)
        O.siege = false
      end
    end
  end
  if O.siege or O.jobs then
    ok, problem = pcall(resolveDamageable)
    if not ok then
      log(ERROR, tostring(problem) .. "; damageable targets and siege orders stay off")
      O.siege = false
    end
    ok, problem = pcall(resolveWallShooting)
    if not ok then
      G.height, F.playable = nil, nil
      log(ERROR, "Outpost terrain targeting is off: " .. tostring(problem))
    end
  end
  if O.siege then
    hooks.registerHookCallback("afterInit", function()
      local rebalancer = modules.rebalancer
      if rebalancer and type(rebalancer.getSiegeRanges) == "function" then
        G.siegeRanges = rebalancer:getSiegeRanges()
      end
    end)
  end
  if G.ticks and (O.siege or O.riders) then
    ok, problem = pcall(function()
      -- smarter-recruits patches the 8 bytes before the update table read.
      local found, call = pcall(core.AOBScan, K.AOB_UPDATE_CALL)
      if not found then error(MODULE_NAME .. ": unit update dispatch not found") end
      G.currentUnit = readOperand(call, K.UPDATE_CURRENT, "the current unit")
      G.updateTable = readOperand(call, K.UPDATE_TABLE, "the update function table")
    end)
    if not ok then
      log(ERROR, tostring(problem) .. "; periodic knight and siege updates stay off")
      O.riders = false
    elseif O.siege then
      ok, problem = pcall(function()
        local update = rd32(G.updateTable + K.FIRE_BALLISTA * 4)
        local delay = readOperand(update, K.BALLISTA_IDLE_DELAY, "fire ballista idle delay")
        same(delay, G.units + U.IDLE_DELAY, "fire ballista idle delay")
        G.ballistaIdleDelay = delay
      end)
      if not ok then log(ERROR, tostring(problem) .. "; outpost fire ballista targeting stays off") end
    end
  end
  if not (O.defenders or O.growth or O.jobs or O.siege or O.join or O.retarget or O.waves or O.interval) then
    return
  end
  allocate()
  local installed, installProblem = pcall(install, self)
  if not installed then
    local restored = true
    for index = #(self.saved or {}), 1, -1 do
      local saved = self.saved[index]
      if not pcall(core.writeCode, saved.address, saved.bytes, false) then restored = false end
    end
    self.saved = nil
    local reason = restored and "" or " Some game code could not be restored."
    log(ERROR, "Outpost Control is off. Its patches could not be installed: " .. tostring(installProblem) .. reason)
    return
  end
  if O.defenders or O.growth or O.waves or O.interval then hooks.registerHookCallback("afterInit", localizeWords) end
  modules["map-extensions"]:registerSection(K.SAVE_SECTION, {
    initialize = function(_) wipe() end,
    serialize = function(_, handle) serialize(handle) end,
    deserialize = function(_, handle) deserialize(handle) end,
  })
end

local function disable(self, config)
  if self.saved ~= nil then
    for _, saved in ipairs(self.saved) do core.writeCode(saved.address, saved.bytes) end
    self.saved = nil
  end
end

return {
  enable = enable,
  disable = disable,
}
