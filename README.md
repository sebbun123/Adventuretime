# AdventureTime

A MacroQuest Lua UI for driving a boxed group on EverQuest Project Lazarus, built to sit alongside E3.

## Installation

1. Download `init.lua`
2. Create a folder: `Lua` → `AdventureTime`
3. Drag and drop `init.lua` into the `AdventureTime` folder
4. In game, type `/lua run adventuretime`

## Troubleshooting DanNet issues

Sometimes DanNet doesn't start properly, or is on a defunct network adapter. You can fix it with the following steps:

1. Find the DanNet config — it'll be in `E3 folder` → `Config` → `MQ2DanNet`
2. Update **Interface** (likely `0`) to `1`, click save
3. Reload DanNet by typing `/plugin mq2dannet unload` (you can broadcast this)
4. On each character, type `/plugin mq2dannet load`. You can't broadcast this.

   (Or log off all of your characters except the driver and reload them in.)

If this doesn't work, type `/dnet interface` and send me a screenshot of the results from the driver and a bot.
