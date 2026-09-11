# AdventureTime

A MacroQuest Lua UI for driving a boxed group on EverQuest Project Lazarus, built to sit alongside E3.

## Installation

1. Download `init.lua`
2. Create a folder: `Lua` → `AdventureTime`
3. Drag and drop `init.lua` into the `AdventureTime` folder
4. In game, type `/lua run adventuretime`

## Peer transport and bot control

AdventureTime can talk to peer characters through E3, EQBC, or DanNet. Open
**Settings → Peer transport** to choose:

- **Auto**: default; preserves existing behavior and picks the first available transport.
- **E3**: recommended for Linux/Wine setups that already run E3BC.
- **EQBC**: use this if your box crew runs through EQBC.
- **DanNet**: use this if your setup already runs DanNet.

E3/EQBC peer features need AdventureTime running on the peer characters because they use
request/reply commands. DanNet mode can use DanNet queries directly.

AdventureTime can also pause either E3 or RGMercs while it performs trades, cursor
work, ports, invis, and other coordinated actions. Open **Settings → Bot control** to
choose:

- **Auto**: uses RGMercs when `rgmercs` is running, otherwise E3.
- **E3**: forces `/e3p on` and `/e3p off`.
- **RGMercs**: forces `/rgl pause` and `/rgl unpause`.

If RGMercs Chase/Camp While Paused is enabled, AdventureTime warns but does not change
your RGMercs settings. Turn it off with `/rgl set runmovepaused false`.

## Troubleshooting DanNet issues

If you only see your driver populating stuff while using DanNet, you're likely having trouble with DanNet. The below should fix most DanNet issues.

Sometimes DanNet doesn't start properly, or is on a defunct network adapter. You can fix it with the following steps:

1. Find the DanNet config — it'll be in `E3 folder` → `Config` → `MQ2DanNet`
2. Update **Interface** (likely `0`) to `1`, click save
3. Reload DanNet by typing `/plugin mq2dannet unload` (you can broadcast this)
4. On each character, type `/plugin mq2dannet load`. You can't broadcast this.

   (Or log off all of your characters except the driver and reload them in.)

If this doesn't work, type `/dnet interface` and send me a screenshot of the results from the driver and a bot.
