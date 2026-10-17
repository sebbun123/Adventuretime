AdventureTime development tools (not part of a release; the updater never touches this folder).
  tools/check_globals.py   every global the code reads must be set somewhere (init.lua or modules/) or come from
                           Lua/MacroQuest; also flags a module reading one of init.lua's top-level locals.
                           python3 dev/tools/check_globals.py . --baseline dev/tools/globals_baseline.txt
  tests/run.lua            offline tests: each module loaded with a fake mq.   luajit dev/tests/run.lua
