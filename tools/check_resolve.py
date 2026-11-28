"""Run outpost-control's enable() on the exe images: every AOB (unique), operand check and
patch site; dump every asm script with its constants for fasm."""
import sys, os, re, struct
sys.path.insert(0, r'C:\Users\Monsterfish_\AppData\Local\Temp\shcw\tunnelers')
from t import VAN, EXT, CLEANEXT
import lupa.lua54 as l
MOD = os.environ.get('MOD', r'H:\shc-modding\outpost-control\module')
def run(name, exe):
    L = l.LuaRuntime(encoding=None, unpack_returned_tuples=True)
    mem = {}
    heap = [0x30000000]
    def rd(a, n):
        out = b''
        for i in range(n):
            if a+i in mem: out += bytes([mem[a+i]])
            else:
                o = exe.va2off(a+i)
                out += bytes([exe.data[o]]) if o is not None else b'\0'
        return out
    def wr(a, b):
        for i,x in enumerate(b): mem[a+i] = x & 0xFF
    def aob(p, *a):
        hits = [h for h in exe.find(p.decode() if isinstance(p,bytes) else p) if h is not None]
        if len(hits) != 1:
            raise Exception('AOB %d hits: %s' % (len(hits), p))
        return hits[0]
    def alloc(n, z=False):
        a = heap[0]; heap[0] += (int(n) + 15) & ~15; wr(a, b'\0'*int(n)); return a
    scripts = []
    def allocAsm(script, values):
        a = alloc(4096)
        vals = dict(values.items()) if values is not None else {}
        scripts.append((a, script.decode() if isinstance(script, bytes) else script, {k.decode(): v for k,v in vals.items()}))
        return a
    patches = []
    def writeCode(a, b):
        bb = []
        for k in range(1, len(b)+1):
            v = b[k]
            if type(v).__name__ == '_LuaTable':
                for kk in range(1, len(v)+1): bb.append(v[kk])
            else: bb.append(v)
        patches.append((a, bb)); wr(a, bb)
    import lupa
    core = L.table_from({
        b'AOBScan': aob,
        b'readInteger': lambda a: struct.unpack('<i', rd(a,4))[0],
        b'readSmallInteger': lambda a: struct.unpack('<h', rd(a,2))[0],
        b'readByte': lambda a: struct.unpack('<b', rd(a,1))[0],
        b'readBytes': lambda a, n: L.table_from(list(rd(a,n))),
        b'writeInteger': lambda a, v: wr(a, struct.pack('<I', v & 0xFFFFFFFF)),
        b'writeSmallInteger': lambda a, v: wr(a, struct.pack('<H', v & 0xFFFF)),
        b'writeByte': lambda a, v: wr(a, bytes([v & 0xFF])),
        b'writeString': lambda a, s: wr(a, s),
        b'allocate': alloc,
        b'allocateCode': lambda b: alloc(64),
        b'allocateAssembly': allocAsm,
        b'writeCode': writeCode,
        b'writeCodeSmallInteger': lambda a, v: writeCode(a, L.table_from(list(struct.pack('<H', v & 0xFFFF)))),
        b'writeCodeInteger': lambda a, v: writeCode(a, L.table_from(list(struct.pack('<I', v & 0xFFFFFFFF)))),
        b'itob': lambda v: L.table_from(list(struct.pack('<I', v & 0xFFFFFFFF))),
        b'getRelativeAddress': lambda f, t, o: (t - f + o) & 0xFFFFFFFF if (t-f+o)>=0 else (t-f+o),
        b'exposeCode': lambda a, n, c: (lambda *args: 0),
        b'detourCode': lambda f, a, s: None,
        b'setMemory': lambda a, v, n: wr(a, bytes([v])*int(n)),
    })
    L.execute("""local core = ...
      function core.CString(text)
        local address = core.allocate(#text + 1, true)
        core.writeString(address, text)
        return { address = address }
      end""", core)
    g = L.globals()
    g.core = core
    g.package.path = (MOD.replace(os.sep, '/') + '/?.lua;').encode() + g.package.path
    logs = []
    g.log = lambda lvl, msg: logs.append(msg)
    g.INFO, g.WARNING, g.ERROR = 1, 2, 3
    sections = {}
    me = L.table_from({b'registerSection': lambda self, n, cb: sections.__setitem__(n, cb)})
    g.hooks = L.table_from({b'registerHookCallback': lambda n, f: None})
    g.modules = L.table_from({b'map-extensions': me})
    tpl = L.execute(open(os.path.join(MOD,'templates.lua'),'rb').read())
    g.package.loaded[b'templates'] = tpl
    m = L.execute(open(os.path.join(MOD,'init.lua'),'rb').read())
    self = L.table()
    cfg = L.eval(os.environ.get('CFG','{}'))
    m[b'enable'](self, cfg)
    for x in logs: print(name, x.decode() if isinstance(x,bytes) else x)
    return scripts, patches, sections
import lupa
out = r'C:\Users\Monsterfish_\AppData\Local\Temp\shcw\outpost\asm'
os.makedirs(out, exist_ok=True)
for name, exe in [(n,e) for n,e in (('VAN', VAN), ('EXT', EXT), ('CLEAN', CLEANEXT)) if n in os.environ.get('EXES','VAN EXT CLEAN')]:
    scripts, patches, sections = run(name, exe)
    print(name, len(scripts), 'scripts', len(patches), 'patches', list(sections))
    for a, b in patches:
        print('   patch 0x%X %s' % (a, ' '.join('%02X' % (x & 0xFF) for x in b)))
    if name != 'CLEAN':
        for i, (a, s, v) in enumerate(scripts):
            src = 'use32\norg 0x%X\n' % a + ''.join('%s = 0x%X\n' % (k, val & 0xFFFFFFFF) for k, val in v.items()) + s
            open(os.path.join(out, '%s_%02d.asm' % (name, i)), 'w', newline='\n').write(src)
