import os,sys,tty,termios,time,signal
signal.alarm(90)
fd=sys.stdin.fileno(); old=termios.tcgetattr(fd); tty.setraw(fd)
text='' if len(sys.argv)>2 and sys.argv[2]=='empty' else 'hello'; kind=sys.argv[1]
submits=0
label="Fixture agent"
menu=False
moved=False
def draw():
 cols=os.get_terminal_size().columns
 rule='─'*cols
 rows=[label,rule,'❯ '+text,rule,'  ⏵⏵ auto mode on · 1 shell · esc to interrupt · ← 2 agents · ↓ to manage'] if kind=='claude' else [label,'','› '+text,'','  GPT-6-Astra medium · ~/fixture','  ? for shortcuts']
 if menu: rows[2]='Choose an option'
 if moved: rows.insert(1,'')
 sys.stdout.write('\x1b[?2026h\x1b[H\x1b[2J'+'\r\n'.join(rows)+'\x1b['+str(4 if moved else 3)+';'+str(3+len(text))+'H\x1b[?2026l');sys.stdout.flush()
try:
 if kind=='codex': sys.stdout.write('\x1b[?1049h')
 draw()
 while True:
  c=os.read(fd,1)
  if not c or c==b'\x04': break
  if c==b'\x7f': text=text[:-1]
  elif c==b'\r':
   submits+=1
   if submits==2:
    # Unsynchronized intermediate empty row, then restore before the settle deadline.
    sys.stdout.write('\x1b[3;1H\x1b[2K'+('❯ ' if kind=='claude' else '› '));sys.stdout.flush()
    time.sleep(.02)
    label='Fixture agent restored';draw()
    time.sleep(.5)
   text=''
  elif b' '<=c<=b'~':
   if c==b'~':
    # A renderer visits the header between writes before returning to the same input.
    sys.stdout.write('\x1b[1;1H');sys.stdout.flush()
    time.sleep(.02)
    label='Fixture agent cursor restored';draw()
    time.sleep(.5)
   if c==b'^': moved=True;label='Fixture agent moved'
   if c==b'#': menu=True;label='Fixture agent menu'
   text+=c.decode()
  time.sleep(.07);draw()
finally:
 sys.stdout.write('\x1b[?1049l');sys.stdout.flush();termios.tcsetattr(fd,termios.TCSANOW,old)
