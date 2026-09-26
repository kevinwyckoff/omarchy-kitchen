#!/usr/bin/env python3
# Usage: keys.py <host:port> <item>...   item = "text:<literal>" or a key/combo like ret, tab, down, esc, ctrl-c, spc
import json, socket, sys, time
h, p = sys.argv[1].rsplit(":", 1)
s = socket.create_connection((h, int(p))); f = s.makefile("rw"); f.readline()
def cmd(c):
    f.write(json.dumps(c) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            if "error" in r: sys.exit(r)
            return r
cmd({"execute": "qmp_capabilities"})
SHIFT = {'!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8','(':'9',')':'0','_':'minus','+':'equal',
         '{':'bracket_left','}':'bracket_right','|':'backslash',':':'semicolon','"':'apostrophe','<':'comma','>':'dot','?':'slash','~':'grave_accent'}
PLAIN = {' ':'spc','-':'minus','=':'equal','[':'bracket_left',']':'bracket_right','\\':'backslash',';':'semicolon',
         "'":'apostrophe',',':'comma','.':'dot','/':'slash','`':'grave_accent'}
def send(keys):
    cmd({"execute": "send-key", "arguments": {"keys": [{"type": "qcode", "data": k} for k in keys]}}); time.sleep(0.06)
for item in sys.argv[2:]:
    if item.startswith("text:"):
        for ch in item[5:]:
            if ch.isalpha(): send(["shift", ch.lower()] if ch.isupper() else [ch])
            elif ch.isdigit(): send([ch])
            elif ch in SHIFT: send(["shift", SHIFT[ch]])
            elif ch in PLAIN: send([PLAIN[ch]])
            else: sys.exit(f"unmapped char {ch!r}")
    else:
        send(item.split("-")); time.sleep(0.25)
