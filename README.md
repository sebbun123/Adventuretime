# AdventureTime

A MacroQuest Lua UI for driving a boxed group on EverQuest Project Lazarus, built to sit alongside E3.

## Recommended Install / Update

Use the AdventureTime Patcher:

https://github.com/sebbun123/AdventureTimePatcher/releases/latest

### Windows

Download and run:

`AdventureTimePatcher-win-x64.exe`

Choose your MacroQuest folder, then click **Update Now**.

The patcher installs AdventureTime to:

`<MacroQuest>/lua/adventuretime/`

It preserves your `AdventureTime_targets.ini`, settings, logs, and other user files.

### Linux / Wine

Download:

`AdventureTimePatcher-linux-x64`

Then run:

```bash
chmod +x AdventureTimePatcher-linux-x64
./AdventureTimePatcher-linux-x64 update --mq "/path/to/MacroQuest"
```

The MacroQuest folder is the folder that contains `lua/` and `config/`.

## Manual Install

1. Download `init.lua`.
2. Create a folder: `lua/adventuretime/`.
3. Put `init.lua` inside the `adventuretime` folder.
4. In game, type:

```txt
/lua run adventuretime
```

## Compatibility

AdventureTime can talk to peer characters through E3, EQBC, or DanNet.

Open **Settings → Peer transport** to choose:

- **Auto**: default; preserves existing behavior and picks the first available transport.
- **E3**: recommended for E3 users and Linux/Wine setups that already run E3BC.
- **EQBC**: use this if your box crew runs through EQBC.
- **DanNet**: use this if your setup already runs DanNet.

E3/EQBC peer features need AdventureTime running on peer characters because they use request/reply commands. DanNet mode can use DanNet queries directly.

AdventureTime can also pause either E3 or RGMercs while it performs trades, cursor work, ports, invis, and other coordinated actions.

Open **Settings → Bot control** to choose:

- **Auto**: uses RGMercs when `rgmercs` is running, otherwise E3.
- **E3**: forces `/e3p on` and `/e3p off`.
- **RGMercs**: forces `/rgl pause` and `/rgl unpause`.

If RGMercs Chase/Camp While Paused is enabled, AdventureTime warns but does not change your RGMercs settings. Turn it off with:

```txt
/rgl set runmovepaused false
```

## Troubleshooting DanNet Issues

If you use DanNet and only see your driver populating data, DanNet may not be connected correctly.

Sometimes DanNet does not start properly, or it is on a defunct network adapter. You can fix it with the following steps:

1. Find the DanNet config. It is usually in `E3/Config/MQ2DanNet`.
2. Update `Interface` to `1`, then save.
3. Reload DanNet by typing:

```txt
/plugin mq2dannet unload
```

You can broadcast the unload command.

4. On each character, type:

```txt
/plugin mq2dannet load
```

You cannot reliably broadcast the load command.

Alternatively, log off all characters except the driver, reload DanNet, then log the others back in.

If this does not work, type:

```txt
/dnet interface
```

Send a screenshot of the result from the driver and a bot.
