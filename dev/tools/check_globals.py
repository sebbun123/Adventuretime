#!/usr/bin/env python3
"""AdventureTime safety net: every global the code READS must be WRITTEN somewhere (init.lua or a module) or be
provided by Lua/MacroQuest. A name that is read but never set is nil at run time - the classic way moving code
out of init.lua breaks (a local in init.lua is not visible from another file).

usage: check_globals.py <dir> [--baseline FILE] [--write-baseline FILE]
Reads <dir>/init.lua and every module in <dir>/modules/."""
import os, re, subprocess, sys

ENV = set('''assert error ipairs pairs next pcall xpcall print select tonumber tostring type unpack rawget rawset rawequal
setmetatable getmetatable require loadfile loadstring load dofile string table math os io debug coroutine bit jit _G
collectgarbage package arg gcinfo newproxy module setfenv getfenv _VERSION printf'''.split())
# MacroQuest / ImGui globals (provided by the host, never assigned by the script)
ENV_PREFIX = ('ImGui', 'ImDraw', 'ImVec', 'IM_COL32', 'ImFont', 'ImTexture')

def scan(path):
    out = subprocess.run(['luajit', '-bl', path], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit('compile failed: %s\n%s' % (path, out.stderr))
    reads, writes, where = {}, set(), None
    for line in out.stdout.splitlines():
        m = re.match(r'-- BYTECODE -- (\S+)', line)
        if m: where = m.group(1); continue
        m = re.search(r'\b(GGET|GSET)\s+\d+\s+\d+\s+; "([^"]+)"', line)
        if not m: continue
        if m.group(1) == 'GSET': writes.add(m.group(2))
        else: reads.setdefault(m.group(2), set()).add(where)
    return reads, writes

def main():
    d = sys.argv[1]
    files = [os.path.join(d, 'init.lua')]
    md = os.path.join(d, 'modules')
    if os.path.isdir(md): files += sorted(os.path.join(md, f) for f in os.listdir(md) if f.endswith('.lua'))
    reads, writes = {}, set()
    for f in files:
        r, w = scan(f)
        writes |= w
        for k, v in r.items(): reads.setdefault(k, set()).update(v)
    bad = {k: v for k, v in reads.items() if k not in writes and k not in ENV and not (k.startswith(ENV_PREFIX) and k != 'ImGui')}
    base = set()
    if '--baseline' in sys.argv:
        bf = sys.argv[sys.argv.index('--baseline') + 1]
        if os.path.exists(bf): base = set(l.strip() for l in open(bf) if l.strip() and not l.startswith('#'))
    if '--write-baseline' in sys.argv:
        bf = sys.argv[sys.argv.index('--write-baseline') + 1]
        with open(bf, 'w') as fh:
            fh.write('# globals read but never set when the baseline was taken (host-provided or known)\n')
            for k in sorted(bad): fh.write(k + '\n')
        print('baseline written: %d names' % len(bad)); return
    # a module reading a name init.lua declares as a top-level LOCAL sees a different (global) variable - never
    # the local - even when some global of that name is set elsewhere
    tl = set()
    for line in open(files[0], encoding='latin-1'):
        m = re.match(r'local\s+function\s+([A-Za-z_]\w*)', line) or None
        if m: tl.add(m.group(1)); continue
        m = re.match(r'local\s+([A-Za-z_][\w\s,]*?)\s*(=|$)', line)
        if m:
            for n in m.group(1).split(','): tl.add(n.strip())
    shadow = {}
    for f in files[1:]:
        r, _ = scan(f)
        for k, v in r.items():
            if k in tl: shadow.setdefault(k, set()).update(v)
    for k in sorted(shadow):
        print('  LOCAL-IN-INIT  %-20s read in %s - a local in init.lua is not visible from a module' % (k, ', '.join(sorted(shadow[k])[:4])))
    # debug.getinfo in a module names the MODULE's file, not the AdventureTime folder: use AT_SRC_DIR
    gi = [f for f in files[1:] if 'debug.getinfo' in open(f, encoding='latin-1').read()]
    for f in gi: print('  GETINFO  %s uses debug.getinfo - in a module it names the module file; use AT_SRC_DIR' % f)
    new = {k: v for k, v in bad.items() if k not in base}
    if (shadow or gi) and not new: sys.exit(1)
    print('%d file(s), %d globals read, %d written; %d read-never-set (%d in the baseline)' %
          (len(files), len(reads), len(writes), len(bad), len(bad) - len(new)))
    for k in sorted(new):
        print('  NEW  %-28s read in %s' % (k, ', '.join(sorted(new[k])[:4])))
    sys.exit(1 if new else 0)

main()
