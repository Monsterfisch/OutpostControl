# Outpost Control

A UCP3 module for Stronghold Crusader (Extreme and vanilla) that gives map makers a Defenders
page in the outpost panel (which troops guard an outpost, up to 50), wave size, growth and timing controls, and
splits each outpost wave into troops with jobs by unit type (fill the moat, attack walls and
gates, burn buildings, fight troops, ride round the castle, hunt the lord). Per-outpost settings
and jobs are stored in maps and saves through `map-extensions`. Player-facing description:
[module/locale/description-en.md](module/locale/description-en.md).

## The outpost panel

Select an outpost in the map editor. The button at the top of its panel now switches between
two pages. Each slider shows its value to its right.

- **Attackers** - the troop buttons choose which troops the outpost sends. When fixed intervals
  are enabled, the second button switches between Size (Size and Growth) and Timing
  (Start Delay and Interval).
  - **Size:** exactly how many troops each wave has, from 0 (no waves at all) up to the most the
    game itself ever sends at its biggest size. (With "Set the exact number of troops per wave"
    off it is the game's own slider again: 6 steps of random group sizes.) Without the module the
    map keeps the nearest of the game's own sizes.
  - **Start Delay:** how long it waits before the first wave (the game's own), shown in seconds
    at normal speed.
  - **Growth:** how much bigger each wave gets, in percent of the first wave per wave. 0 (the
    start) keeps every wave as big as the first, as the game does; 50 adds half the first wave
    each time; 100 adds a whole first wave each time. Waves stop growing at 999 troops.
  - **Interval:** seconds to wait after a wave launches before forming the next, from 10 to 600.
    Set it to 0 for the game's timing. Start Delay controls the first wave.
- **Defenders** - the same eight troop buttons with a new meaning, and one slider:
  - **Troop buttons:** which troops guard the outpost. Pick several and they take turns. A
    European outpost offers archers, crossbowmen, spearmen, pikemen, macemen, swordsmen,
    knights and black monks; an Arabian one Arabian archers, slingers, horse archers, Arabian
    swordsmen, slaves, assassins, fire throwers and crossbowmen. With nothing picked the
    outpost uses archers, as the game does.
  - **Amount:** how many guards stand around the outpost, from none to 50. Fallen guards come
    back one at a time; the more you set, the quicker they come, so a full set takes about as
    long to come back as the game's 8 guards do (a guard every 30 seconds for 8, every 5
    seconds for 50, at normal speed).
  - **Stances:** foot soldiers who fight hand to hand (spearmen, pikemen, macemen, swordsmen,
    black monks, assassins) guard in the defensive stance and go for enemies who come near;
    slaves are aggressive and charge enemies further off; knights are aggressive and ride a patrol
    round the outpost, attacking enemy troops and any enemy building that comes within 10 tiles; horse archers are aggressive
    too and ride a patrol round the outpost: six spots at random places 7 to 15 tiles
    out, one in each direction, moved to a free spot nearby when a building, a wall or water is
    in the way. Archers, crossbowmen, slingers and fire throwers
    stand and shoot as the game's own outpost archers do.
  - **On the walls:** guards on foot go up onto the owner's walls, stone towers and stone
    gatehouses within 16 tiles of the outpost, if they can walk there - each to the free spot
    with the fewest guards round it, so they spread out and fill the places of guards who fell.
    Knights and horse archers stay below. This works for every outpost, also those without
    settings (a setting).

## Attackers' jobs

Normally a whole wave does the same thing: walk up and attack a building, digging at the moat
now and then. With this module, each wave splits up by unit type when it leaves, and each part
gets a job that suits it:

| Preset key under `outpost-control.jobs` | Assignment (default share) | The rest |
| --- | --- | --- |
| `slaves` | Slaves assigned to moat filling (50%) | Burn and wreck buildings |
| `spearmen` | Spearmen assigned to moat filling (40%) | Escort |
| `macemen` | Macemen assigned to flanking (40%) | Wreck buildings |
| `swordsmen`, `arab_swordsmen` | Swordsmen or Arabian swordsmen assigned to wall breaching (60%) | Escort |
| `knights` | Knights assigned to flanking and lord hunting (50%) | Patrol |
| `archers`, `arab_archers` | Archers or Arabian archers assigned to overwatch (60%) | Escort |
| | Crossbowmen assigned to overwatch (100%) | |
| `slingers` | Slingers assigned to flanking (40%) | Overwatch |
| `horse_archers` | Horse archers assigned to patrol (70%) | Flank |
| `fire_throwers` | Fire throwers assigned to burning buildings (50%) | Escort |

Overwatch groups hold defensive firing positions and look for nearby high ground. Escorts screen
a sibling siege, breach or moat group when one is available. Flankers approach from the side.
Bow standoff uses Rebalancer's applied bow ranges when available, then the game's native range if its read instruction is intact.
The other groups in a wave share an approach, and faster assault troops can wait briefly for
a slow sibling group. Set `jobs.variation` in the preset to vary shares and approaches by
percentage. Its default is 0. Set `diagnostics.log` to trace outpost decisions.
Troops that transfer to the AI army leave outpost command before jobs are assigned.
Job IDs are kept in saves. Reloaded groups choose
positions from the target castle when their shared launch state is unavailable.
If the game has no slot for a split, ranged troops stay with the original tribe and use
defensive orders.

## Siege engines on the way

Catapults and fire ballistas from an outpost walk towards the castle they attack, and stop to
shoot as soon as something of the enemy is in range - like your own siege engines do with a
target:

- **Catapults**, trebuchets and mangonels prefer towers and gatehouses, then walls, then
  other damageable buildings.
- **Fire ballistas** shoot only enemy troops and workers in range.

Engines without a shot advance toward a firing position on the near side of a fortification.

Whether something is in range is decided by the game itself, with each engine's own range (the
one the Rebalancer sets, if you use it), exactly as for a player's engine. They only ever aim at
enemies: players on another team than the outpost's owner, never its allies and never nobody's
buildings or animals. A siege troop holds where it is as long as any of its engines has
something in range, so they never walk past a target; when nothing is left in range they walk on.

## Next opponent

Each troop an outpost sends out goes for one enemy player. Once that player is beaten (his lord
is dead), the troop picks the next opponent the way the game picks the first one - the nearest
enemy whose lord still lives - instead of standing about. Siege engines go on shooting whatever
enemy is in their range, and when a target is destroyed they take the next one in range.

## Outposts reinforce the AI (off by default)

With this switched on, a wave leaving an AI's outpost joins that AI's own attack army instead of
attacking on its own. Each unit goes into the troop the game itself would use for it: archers,
crossbowmen, slingers, horse archers and fire throwers into the backup troops, everyone else into
the main army. They wait for the AI's next attack, fight in it, and count towards the army the AI
waits for before it attacks. Siege engines stay with the outpost and shoot what they can reach.

## Saves and maps

What you set for each outpost is kept in the map and in saves (through the Map Extensions
module). Played without this module, the map still works: the outpost keeps the number of
guards you set (at least one, as archers), and its waves are the game's own size and do not grow.

## What is in here

| Path | What |
| --- | --- |
| `module/` | the module (source of truth) |
| `tools/publish.py` | copy `module/` to `<game>\ucp\modules\outpost-control-<version>` (`--bump`, `--keep`) |
| `tools/check_resolve.py` | runs `enable()` on both exe images: every AOB unique, every operand check, dumps the asm |
| `tools/fasm_all.ps1` | assembles the dumped scripts with UCP's fasm.dll (run with 32-bit PowerShell) |

## Working on it

1. Edit `module/`.
2. `python tools/check_resolve.py`, then the 32-bit PowerShell on `tools/fasm_all.ps1`.
3. Game closed: `python tools/publish.py --bump`, F5 and apply in the UCP3 GUI.

## How it works

* `UpdateOutpostBuilding`: the defender count test (skip the defender part at 0), the defender
  check (an outpost with settings counts its guards in its own 50-slot list, waits 9600/amount
  ticks, and keeps new guards in that list instead of the game's 8 slots), the defender
  type (`mov edx,0x16/0x46` -> the picked troops, taking turns by the number alive), and the
  post-wave speed-up (`+100` wave counter, `+4` unit pace -> `+growth`, pace = counter / 25).
* The wave's `aiRegisterTribeAndAssignTarget` call -> lua splits the troop by unit type into new
  troops (`createTribeForPlayer`, `addUnitToTribe`...), each registered the same way.
* `makeOutpostTribesAttack`'s call of `decideOnTribeAttackLocation` routes job troops through
  the existing order callback. It uses the game's path-to-castle search, separate moat and
  melee-wall orders, and defensive ranged movement.
* Outpost panel: prologue hooks on the panel text, the troop button render/click and the size
  slider handler. The page and scope buttons use the native button renderer. Attackers uses
  one pair of slider rows per scope when intervals are enabled. Defenders shows only Amount.
* Panel texts use the game's unit help texts and the module's `panel_*` locale entries,
  encoded by textResourceModifier.
* Per-building settings and jobs go into the `outpost-control` Map Extensions section.
  Fixed intervals are stored in the optional `interval.bin` file. Older maps and saves use
  the game's timing.

## Vanilla and Recommended

Every option of the module is off by default, so the module alone plays like the original
game. Two plugins in this repository form the Outpost Control family in the launcher:
`outpost-control-recommended` (offered first) switches on the recommended settings, `outpost-control-vanilla`
keeps everything off. Plugins that build on the module set the options they need themselves.
