"""Hintlet promo soundtrack v7, "It comes back": an original numpy synth, 120 BPM, D major, 44 s = 22 bars of 2 s.

The music behaves like Hintlet: it steps out of the way when you switch away or type, and comes back on the
same beat. A three-note motif (A–D–F#) is heard only at the open, when the note comes back, and at the close.

Cues, in seconds of the 44-second silent cut (reference/Hintlet-silent.mp4):
  0–4    brand       felt piano plays the motif; its third note lands on the tagline (1.0)
  4–14   capture     mallets, sub and a soft kick; one bell as the note appears (5.0);
                     10.0 switch away: the music goes behind a wall, only the kick is left;
                     12.0 come back: everything returns at once, with the motif
  14–22  typing      a slow piano line, two notes a bar; at 15.42 the note fades and the band goes translucent,
                     19.0 the return key, 19.85 the note comes back and the band with it
  22–28  contexts    the first chorus, then the lead melody
  28–34  Claude, AI  the note is pressed (31.0) and the music holds its breath;
                     ✨ tapped (32.5): a choir and a turning shimmer while it reads
  34–40  summary     full band, the lead an octave higher
  40–44  brand       the motif again, one note per line of the end card, fading out by 44.0

Usage: python3 music-v7.py out.wav [every-key]   (build.sh masters it; see README)
  writes out.wav (the mix), out-music.wav and out-sfx.wav (stems that add up to it) and out.mid
  every-key  the backup take: every keystroke in the typing scene is a note
"""
import numpy as np, wave, sys
SR=44100; BPM=120; B=60/BPM; BAR=4*B; DUR=44.0; N=int(SR*DUR)
rng=np.random.default_rng(7)
EVERY_KEY=sys.argv[2:3]==['every-key']

def _ff(x,resp):
    X=np.fft.rfft(x,axis=0); f=np.fft.rfftfreq(len(x),1/SR)
    r=resp(f); r=r[:,None] if x.ndim==2 else r
    return np.fft.irfft(X*r,len(x),axis=0)
def lp(x,fc,o=2): return _ff(x,lambda f:1/np.sqrt(1+(f/fc)**(2*o)))
def hp(x,fc,o=2): return _ff(x,lambda f:1/np.sqrt(1+(fc/np.maximum(f,1e-3))**(2*o)))
def bp(x,f1,f2): return lp(hp(x,f1),f2)
def saw(x): return 2*((x/(2*np.pi))%1)-1
def hz(m): return 440*2**((m-69)/12)
def ts(n): return np.arange(n)/SR
def env(n,a,d): t=ts(n); return np.minimum(1,t/max(a,1e-4))*np.exp(-t/d)
def fade_out(n,r=0.01): return np.clip((n-np.arange(n))/(r*SR),0,1)

# buses: 'music' and its send 'msend' step aside with the note; drums and fx (with 'fsend') never do.
# 'sfx' holds the interface sounds (keys, clicks, whooshes) and is written out as its own stem.
bus={k:np.zeros((N,2)) for k in ('music','msend','drums','fx','fsend','sfx')}
# every instrument call leaves its notes here; add() stamps them with a time for the MIDI export
PENDING=[]; NOTES=[]
def played(inst,ms,dur,offset=0.0):
    PENDING.append((inst,ms if isinstance(ms,(list,tuple)) else [ms],dur,offset))
def add(sig,t,gain=1.0,pan=0.0,to='music',send=0.0):
    for inst,ms,dur,off in PENDING:
        if to!='sfx': NOTES.extend((inst,m,t+off,dur,gain) for m in ms)
    PENDING.clear()
    i=int(round(t*SR))
    if i>=N or i+len(sig)<=0: return
    s=sig*gain
    if i<0: s=s[-i:]; i=0
    j=min(N,i+len(s)); s=s[:j-i]
    l,r=np.cos((pan+1)*np.pi/4),np.sin((pan+1)*np.pi/4)
    bus[to][i:j,0]+=s*l*1.414; bus[to][i:j,1]+=s*r*1.414
    if send:
        sb='msend' if to=='music' else 'fsend'
        bus[sb][i:j,0]+=s*send*l; bus[sb][i:j,1]+=s*send*r

# ---------------- instruments ----------------
def piano(m,length=2.5,d=1.2):  # felt piano: slightly stretched partials, a soft hammer
    played('piano',m,min(length,d*1.5))
    n=int(length*SR); t=ts(n); f=hz(m); x=np.zeros(n)
    for k in range(1,9):
        fk=f*k*np.sqrt(1+0.0004*k*k)
        if fk>12000: break
        x+=np.sin(2*np.pi*fk*t+rng.uniform(0,6.28))*k**-1.3*np.exp(-(k-1)*0.3)*np.exp(-t/(d/(1+0.6*(k-1))))
    x+=lp(rng.standard_normal(n),1200)*np.exp(-t/0.012)*0.15
    return lp(x,3200)*np.minimum(1,t/0.003)*fade_out(n,0.05)*0.22
def mallet(m,d=0.22):  # marimba-ish FM
    played('mallet',m,0.25)
    n=int(min(1.2,d*5)*SR); t=ts(n); f=hz(m)
    x=np.sin(2*np.pi*f*t+1.3*np.exp(-t/0.012)*np.sin(2*np.pi*f*t))*np.exp(-t/d)
    x+=0.22*np.sin(2*np.pi*f*3.93*t)*np.exp(-t/0.03)
    return x*np.minimum(1,t/0.0015)*fade_out(n)*0.2
def bell(m,d=0.8):  # glass
    played('bell',m,min(1.0,d))
    n=int(min(3.0,d*4)*SR); t=ts(n); f=hz(m)
    return (np.sin(2*np.pi*f*t)+0.35*np.sin(2*np.pi*f*2.76*t)*np.exp(-t/.18)+0.15*np.sin(2*np.pi*f*5.4*t)*np.exp(-t/.07))\
        *np.exp(-t/d)*np.minimum(1,t/0.002)*fade_out(n,0.05)*0.14
def sub(m,length):
    played('bass',m,length)
    n=int(length*SR); t=ts(n); f=hz(m)
    x=np.sin(2*np.pi*f*t)+0.18*np.sin(4*np.pi*f*t)+0.06*saw(2*np.pi*f*t)
    return lp(x,420)*np.minimum(1,t/0.006)*np.exp(-t/(length*1.5))*fade_out(n,0.03)*0.5
def pad(ms,length,att=0.5,rel=0.6,bright=1800):  # soft detuned triangles
    played('pad',list(ms),length)
    n=int(length*SR); t=ts(n); x=np.zeros(n)
    for m in ms:
        for dt in (-0.18,0.0,0.18):
            ph=2*np.pi*hz(m)*(1+dt/100)*t+rng.uniform(0,6.28)
            x+=(2/np.pi)*np.arcsin(np.sin(ph))+0.15*saw(ph)
    a=np.minimum(1,t/att)*np.clip((length-t)/rel,0,1)
    return lp(x,bright)*a*0.022
def choir(ms,length,att=0.6,rel=0.8):  # "ooh": saws through two vowel formants
    played('choir',list(ms),length)
    n=int(length*SR); t=ts(n); x=np.zeros(n)
    for m in ms:
        for dt in (-0.25,0.25):
            vib=1+0.005*np.sin(2*np.pi*5.2*t+rng.uniform(0,6.28))*np.minimum(1,t/0.6)
            x+=saw(2*np.pi*np.cumsum(hz(m)*(1+dt/100)*vib)/SR)
    y=bp(x,320,560)+0.45*bp(x,700,1000)+0.08*bp(x,2400,3000)
    a=np.minimum(1,t/att)*np.clip((length-t)/rel,0,1)
    return y*a*0.05
def kick(g=1.0):
    played('drums',36,0.1)
    n=int(.45*SR); t=ts(n); f=47+75*np.exp(-t/0.035)
    return (np.sin(2*np.pi*np.cumsum(f)/SR)*np.exp(-t/0.26)+0.12*np.exp(-t/0.002)*rng.standard_normal(n))*g
def snap():
    played('drums',37,0.1)
    n=int(.2*SR); t=ts(n)
    return (bp(rng.standard_normal(n),1700,5200)*np.exp(-t/0.018)*0.7+np.sin(2*np.pi*2100*t)*np.exp(-t/0.006)*0.3)*0.55
def clap():
    played('drums',39,0.1)
    n=int(.35*SR); x=rng.standard_normal(n); e=np.zeros(n)
    for k,o in enumerate([0,.008,.017]): i=int(o*SR); e[i:]+=np.exp(-ts(n-i)/(0.01 if k<2 else 0.1))
    return bp(x,1000,7000)*e*0.4
def shaker(d=0.035): played('drums',70,0.05); n=int(.12*SR); return lp(hp(rng.standard_normal(n),5000),10000)*env(n,.008,d)*0.09
def crash(length=2.5): played('drums',49,0.5); n=int(length*SR); return lp(hp(rng.standard_normal(n),4000),11000)*env(n,.002,.7)*0.1
def tick(): n=int(.03*SR); t=ts(n); return hp(rng.standard_normal(n),3000)*np.exp(-t/0.004)*0.25
def click(): n=int(.05*SR); t=ts(n); return (np.sin(2*np.pi*1500*t)*0.6+hp(rng.standard_normal(n),2500)*0.4)*np.exp(-t/0.005)*0.35
def thunk(): n=int(.3*SR); t=ts(n); return np.sin(2*np.pi*np.cumsum(140+200*np.exp(-t/0.01))/SR)*np.exp(-t/0.05)*0.5
def whoosh(length=0.6,rev=False,lo=600,hi=8000):
    n=int(length*SR); e=np.sin(np.linspace(0,np.pi,n))**2 if not rev else np.linspace(0,1,n)**2.5
    return bp(rng.standard_normal(n),lo,hi)*e*0.18
def riser(length):
    n=int(length*SR); k=ts(n)/length
    tone=np.sin(2*np.pi*np.cumsum(300*2**(2*k))/SR)*0.15
    return (bp(rng.standard_normal(n),1500,10000)*0.6+tone)*k**3*0.3
def swell(ms,length,d=1.2):  # a reversed bell chord that blooms into the next beat
    x=sum(bell(m,d) for m in ms); x=x[:int(length*SR)]
    PENDING[-len(ms):]=[('bell',[m],0.6,length) for m in ms]   # in MIDI, the bells land where the swell does
    return x[::-1]*np.linspace(0,1,len(x))**0.5

# ---------------- harmony ----------------
CH={'Dadd9':(38,[62,66,69,76]),'Gmaj7':(43,[62,66,67,71]),'D':(38,[62,66,69,74]),'A/C#':(37,[61,64,69,73]),
    'Bm7':(35,[62,66,69,71]),'Asus':(45,[62,64,69,74]),'A':(45,[61,64,69,73]),'F#m7':(42,[61,64,66,69]),
    'Em7':(40,[62,64,67,71]),'G':(43,[62,67,71,74]),'Dmaj9':(38,[66,69,73,76])}
#       0       1       2   3      4     5       6        7       8      9     10       11  12     13
PROG=['Dadd9','Gmaj7','D','A/C#','Bm7','Gmaj7','Asus|A','Gmaj7','F#m7','Em7','Asus|A','D','A/C#','Bm7',
      'Gmaj7','Asus','Em7|A','D','A/C#','Bm7|G','Dmaj9','Dmaj9']
#       14      15     16     17  18     19      20      21
def chord_at(bar,beat=0):
    c=PROG[bar]
    if '|' in c: c=c.split('|')[0 if beat<2 else 1]
    return CH[c]
MOTIF=[69,74,78]   # A4 D5 F#5

duck=np.ones(N)
def kick_at(t,g=0.9):
    add(kick(),t,g,to='drums'); i=int(t*SR); j=min(N,i+int(.25*SR))
    if j>i: duck[i:j]=np.minimum(duck[i:j],0.6+0.4*np.linspace(0,1,j-i)**0.7)

def chords(bar,length=BAR,gain=1.0,bright=1800,att=0.5):
    c=PROG[bar]
    if '|' in c:
        a,b=c.split('|'); add(pad(CH[a][1],2*B+0.3,att=min(att,.3),bright=bright),bar*BAR,gain,send=0.3)
        add(pad(CH[b][1],2*B+0.4,att=.2,bright=bright),bar*BAR+2*B,gain,send=0.3)
    else: add(pad(CH[c][1],length+0.4,att=att,bright=bright),bar*BAR,gain,send=0.3)

OST=[0,2,1,3,0,2,1,3]   # mallet ostinato, eighths
def ostinato(bar,gain=0.7,skip_odd=False):
    for e in range(8):
        if skip_odd and e%2: continue
        _,c=chord_at(bar,e/2); m=c[OST[e]]+(12 if e==7 else 0)
        add(mallet(m),bar*BAR+e*B/2,gain*(1 if e%2==0 else .75),pan=-.3 if e%2 else .3,send=0.2)
def bassline(bar,pattern):  # pattern: (beat, octave up?, beats)
    for bt,up,d in pattern:
        r,_=chord_at(bar,bt); add(sub(r+12*up,d*B*0.95),bar*BAR+bt*B,1.0)
BASS_A=[(0,0,1.5),(1.5,0,.5),(2,0,1.5),(3.5,1,.5)]
BASS_B=[(0,0,2),(2,0,2)]
def groove(bar,claps=True,shake=True,kicks=(0,1,2,3)):
    t0=bar*BAR
    for b in kicks: kick_at(t0+b*B,0.85)
    for b in (1,3):
        add(snap(),t0+b*B,0.8,pan=-0.15,to='drums')
        if claps: add(clap(),t0+b*B,0.7,pan=0.1,to='drums')
    if shake:
        for s in range(16): add(shaker(.05 if s%4==2 else .03),t0+s*B/4+(0.012 if s%2 else 0),.8 if s%2 else .5,pan=0.35,to='drums')

def lead(bar,notes,up=0,gain=1.0):
    for bt,m,d in notes:
        add(piano(m+up,max(1.2,d*B+0.6),d=0.9),bar*BAR+bt*B,0.8*gain,pan=0.05,send=0.35)
        add(bell(m+12+up,0.6),bar*BAR+bt*B,0.3*gain,pan=-0.1,send=0.4)
LEAD={12:[(0,78,1),(1,76,.5),(1.5,74,.5),(2,76,1),(3,73,.5),(3.5,69,.5)],
      13:[(0,74,1.5),(1.5,78,.5),(2,81,1),(3,78,.5),(3.5,76,.5)],
      17:[(0,69,.5),(.5,74,.5),(1,78,1.5),(2.5,76,.5),(3,74,1)],
      18:[(0,76,1),(1,73,.5),(1.5,69,.5),(2,76,1),(3,78,.5),(3.5,81,.5)],
      19:[(0,83,1),(1,81,.5),(1.5,78,.5),(2,79,1),(3,81,1)]}

# ---------------- 0–4: brand ----------------
add(pad(CH['Dadd9'][1],4.4,att=0.3,bright=1400),0,1.5,send=0.4)
add(sub(38,4.0),0,0.8); add(piano(50,3.0,d=1.6),0,0.6,send=0.4)
for k,(t,m) in enumerate(zip((0.5,0.75,1.0),MOTIF)):           # the third note on the tagline
    add(piano(m,3.0,d=1.6),t,1.3,pan=-0.2+0.2*k,send=0.5)
add(bell(90,1.5),1.0,0.35,pan=0.3,send=0.6)
add(swell([74,78,81],1.0),3.0,0.8,send=0.3)
add(riser(1.6),2.4,0.7,to='fx')

# ---------------- 4–14: capture, follow, switch away, come back ----------------
for bar in range(2,7):
    t0=bar*BAR
    if bar==5:  # 10–12 switched away: the band is behind the wall (see step_aside), the kick keeps the time
        chords(bar); ostinato(bar); bassline(bar,BASS_B)
        for b in range(4): kick_at(t0+b*B,0.7)
        continue
    chords(bar,bright=1400 if bar<4 else 2200)
    ostinato(bar,skip_odd=(bar==2))
    bassline(bar,BASS_B if bar==2 else BASS_A)
    groove(bar,claps=bar>=4,shake=bar>=4,kicks=(0,2) if bar==2 else (0,1,2,3))
add(crash(2),4.0,0.6,to='drums'); kick_at(4.0,1.0)
add(bell(MOTIF[2]+12,1.0),5.0,0.45,to='fx',send=0.5)                                                   # the note sticks
for k in range(30): add(tick(),5.35+k*0.05,0.25+0.1*rng.random(),pan=0.2,to='sfx')                       # typing into it
add(whoosh(1.4,lo=400,hi=5000),8.0,0.6,pan=-0.3,to='sfx')                                               # dragged along
add(whoosh(0.3,lo=300,hi=3000),9.95,0.6,to='sfx')                                                       # switch away
add(click(),11.92,0.8,to='sfx')                                                                         # click back
add(crash(2),12.0,0.5,to='drums')
for k,m in enumerate(MOTIF): add(bell(m+12,1.0),12.0+k*0.08,0.45,pan=-0.3+0.3*k,to='fx',send=0.5)     # it comes back
add(whoosh(0.8,rev=True,lo=500,hi=6000),13.2,0.6,to='sfx'); add(whoosh(0.5,lo=500,hi=6000),14.0,0.4,to='sfx')

# ---------------- 14–22: typing ----------------
for bar in range(7,11): chords(bar,bright=1600,att=0.4)
for bar in (7,8,9): bassline(bar,BASS_B)
bassline(10,BASS_A)
for bar in (7,8,9):
    for b in (1,3): add(snap(),bar*BAR+b*B,0.7,pan=-0.15,to='drums')
    for b in (0,2): kick_at(bar*BAR+b*B,0.6)
    for e in range(8): add(shaker(.03),bar*BAR+e*B/2+B/4,0.5,pan=0.35,to='drums')
groove(10,claps=True,shake=True,kicks=(0,1,2,3))
for k in range(8): add(clap(),21.0+k*B/4,0.15+0.07*k,pan=0.1,to='drums')                              # into 22
add(riser(1.5),20.5,0.8,to='fx')
if EVERY_KEY:  # the backup: every keystroke is a mallet note, spaces are rests
    PENTA=[62,64,66,69,71,74,76,78,81,83,86]
    line='Keep the words flowing, right where ideas happen.'
    word=0; step=0
    for k in range(1,26):
        ch=line[23+k]; t=14.75+k/6
        if ch in ' .,': word+=1; step=0; continue
        m=PENTA[min(len(PENTA)-1,(word*2)%5+step)]; step+=1
        add(mallet(m+12,0.2),t,0.9,pan=-0.25+0.1*(k%5),to='fx',send=0.35)
        add(tick(),t,0.15,to='sfx')
    nxt='Then keep going.'
    for j in range(1,17):
        if nxt[j-1] in ' .': continue
        add(mallet(PENTA[min(10,3+j//2)]+12,0.2),19.0+1.2*j/16,0.8,pan=0.25,to='fx',send=0.35)
else:  # a slow piano line, two notes a bar, that stays clear while the band steps aside
    for t,m in [(14.0,74),(15.0,71),(16.0,73),(17.0,69),(18.0,71)]:
        add(piano(m,2.2,d=1.4),t,0.75,pan=0.1,to='fx',send=0.45)
    for k in range(1,26): add(tick(),14.75+k/6,0.25+0.1*rng.random(),pan=0.2,to='sfx')     # typing, as in the other scenes
    for j in range(1,17): add(tick(),19.0+1.2*j/16,0.25+0.1*rng.random(),pan=0.2,to='sfx')
add(thunk(),19.0,0.7,to='sfx'); add(piano(50,2.0,d=1.0),19.0,0.6,send=0.3)                              # return key
if not EVERY_KEY: add(piano(67,2.0,d=1.4),19.0,0.65,pan=0.1,to='fx',send=0.45)
add(swell([74,78,81,86],0.35),19.85,0.9,to='fx',send=0.3)                                                          # and returns

# ---------------- 22–28: windows, folders, Safari pages, Claude chats ----------------
kick_at(22.0,1.0); add(crash(2.5),22.0,0.7,to='drums')
for bar in (11,12,13):
    chords(bar,bright=2600); ostinato(bar,gain=0.6); bassline(bar,BASS_A); groove(bar)
    for e in (1,3,5,7):  # piano stabs on the off-beats
        _,c=chord_at(bar,e/2); add(sum(piano(m,0.8,d=0.25) for m in c[1:]),bar*BAR+e*B/2,0.35,pan=-0.2,send=0.2)
for bar in (12,13): lead(bar,LEAD[bar])
add(whoosh(0.6,rev=True),27.4,0.6,to='sfx')

# ---------------- 28–34: a Claude conversation, and its AI note ----------------
chords(14,bright=2000); ostinato(14,gain=0.55); bassline(14,BASS_B); groove(14,claps=False,shake=True,kicks=(0,2))
add(crash(2),28.0,0.4,to='drums')
for k in range(25): add(tick(),29.6+k*0.028,0.22,pan=0.25,to='sfx')
# 30–31 builds, 31.0 the island is pressed and everything holds its breath
add(pad(CH['Asus'][1],1.3,att=.2,bright=2200),30.0,1.0,send=0.3); ostinato(15,gain=0.55)
r,_=chord_at(15); add(sub(r,0.95),30.0,1.0); add(sub(r+12,0.45),30.5,0.8)
for b in (0,1): kick_at(30.0+b*B,0.85)
for s in range(8): add(shaker(),30.0+s*B/4,0.6,pan=0.35,to='drums')
add(snap(),30.5,0.8,to='drums')
add(click(),31.0,0.8,to='sfx')
n=int(0.42*SR); tt=ts(n); add(np.sin(2*np.pi*np.cumsum(hz(57)*(1+0.06*tt/0.42))/SR)*np.minimum(1,tt/0.05)*0.18,31.0,1.0,to='sfx')  # held
add(pad(CH['Asus'][1],1.6,att=.3,bright=1200),31.0,1.1,send=0.4)
add(swell([81,86,90,93],0.6),31.9,1.0,to='fx',send=0.4)
# 32.5 ✨ tapped: the note starts reading
add(crash(2.5),32.5,0.5,to='drums'); add(bell(98,1.5),32.5,0.4,to='fx',send=0.6)
add(pad(CH['Em7'][1],1.0,att=.1,bright=2400),32.0,0.8,send=0.3)
add(choir([64,67,71,74],1.8,att=.4,rel=.3),32.5,1.0,send=0.5)
add(choir([64,69,73,76],0.4,att=.05,rel=.2),33.6,0.7)
add(pad(CH['A'][1],0.6,att=.1,bright=2400),33.5,0.9,send=0.3)
add(sub(45,1.4),32.5,0.9)
for s in range(12):  # a shimmer that turns with the glow
    t=32.5+s*B/4; _,c=chord_at(16,(t-32)/B)
    add(bell(c[s%4]+12+(12 if s%8>=4 else 0),0.35),t,0.22+0.02*s,pan=np.sin(2*np.pi*(t-32.5)/2),to='fx',send=0.5)
for k in range(4): kick_at(32.5+k*B/2*0.999 if k<3 else 33.75,0.45+0.1*k)
add(riser(1.4),32.6,0.9,to='fx')

# ---------------- 34–40: goal, key point, what's next ----------------
kick_at(34.0,1.0); add(crash(3),34.0,0.8,to='drums'); add(bell(90,1.5),34.0,0.4,to='fx',send=0.6)
for bar in (17,18,19):
    chords(bar,bright=2800); ostinato(bar,gain=0.6); bassline(bar,BASS_A); groove(bar)
    lead(bar,LEAD[bar],up=12 if bar==17 else 0,gain=1.0)
    c=PROG[bar].split('|'); add(choir(CH[c[0]][1],BAR+0.3 if len(c)==1 else 2*B+.3,att=.5),bar*BAR,0.55,send=0.4)
    if len(c)>1: add(choir(CH[c[1]][1],2*B+.3,att=.3),bar*BAR+2*B,0.55,send=0.4)
for k in range(4): add(clap(),39.5+k*B/4*0.999,0.2+0.15*k,to='drums')
add(whoosh(0.5,rev=True,lo=800,hi=9000),39.5,0.7,to='sfx')

# ---------------- 40–44: brand ----------------
kick_at(40.0,1.0); add(crash(3.5),40.0,0.6,to='drums')
add(pad(CH['Dmaj9'][1],4.0,att=0.05,rel=2.2,bright=1800),40.0,1.2,send=0.5)
add(sub(38,3.5),40.0,0.8); add(piano(38,4.0,d=2.0),40.0,0.5,send=0.3)
for k,(t,m) in enumerate(zip((40.0,40.25,40.5),MOTIF)):     # hero, tagline, closing line
    add(piano(m,3.5,d=1.8),t,0.95,pan=-0.2+0.2*k,send=0.5); add(bell(m+24,1.2),t,0.25,pan=0.2-0.2*k,send=0.6)
for k,m in enumerate([81,86,90,93]): add(bell(m,1.4),41.5+k*0.25,0.18,pan=0.4-0.27*k,send=0.7,to='fx')

# ---------------- mix ----------------
def delay(x,dt=0.75*B,fb=0.35,taps=6):
    y=np.zeros_like(x); d=int(dt*SR); g=1.0
    for k in range(1,taps+1):
        g*=fb; o=d*k
        if o>=len(x): break
        sh=x[:-o]*g
        if k%2: sh=sh[:,::-1]
        y[o:]+=sh
    return lp(hp(y,300),5000)
def reverb(x,length=2.4,decay=0.55):
    n=int(length*SR); t=ts(n); ir=np.stack([rng.standard_normal(n),rng.standard_normal(n)],1)*np.exp(-t/decay)[:,None]
    ir=lp(ir,6500); ir[:int(.02*SR)]=0; ir/=np.sqrt((ir**2).sum(0))
    L=1<<int(np.ceil(np.log2(len(x)+n)))
    y=np.fft.irfft(np.fft.rfft(x,L,axis=0)*np.fft.rfft(ir,L,axis=0),L,axis=0)[:len(x)]
    return hp(y,200)

def ramp(t,t0,dur,a,b):  # a→b from t0 over dur
    return a+(b-a)*np.clip((t-t0)/max(dur,1e-4),0,1)
t=ts(N)
# how far the band has stepped aside: 'away' (switched to another app) and 'clear' (typing near the note)
away=np.where(t<11,ramp(t,10.0,0.1,0,1),ramp(t,12.0,0.15,1,0))
clear=np.where(t<17,ramp(t,15.4167,0.128,0,1),ramp(t,19.8533,0.32,1,0))
music=bus['music']*duck[:,None]+delay(bus['msend'])*0.6+reverb(bus['msend'])*0.9
behind=lp(music,320)*0.55            # through a wall
faint=hp(lp(music,1100),70)*0.55     # see-through, like the 12% note
music=music*(1-away-clear)[:,None]+behind*away[:,None]+faint*clear[:,None]
music=hp(bus['drums']*0.9+music+bus['fx']+reverb(bus['fsend'])*0.9+delay(bus['fsend'])*0.3,30)
peak=np.max(np.abs(music)); music=np.tanh(music/peak*1.4)/np.tanh(1.4)*0.7   # gentle saturation, on the music only
sfx=hp(bus['sfx'],30)*0.7/peak                                                # the interface sounds stay clean
shape=np.clip((DUR-t)/1.6,0,1)**1.6; shape[:int(0.01*SR)]*=np.linspace(0,1,int(0.01*SR))   # gone by 44.0
music*=shape[:,None]; sfx*=shape[:,None]

def write(path,x):
    w=wave.open(path,'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((np.clip(x,-1,1)*32767).astype('<i2').tobytes()); w.close()
stem=sys.argv[1].removesuffix('.wav')
write(sys.argv[1],music+sfx); write(stem+'-music.wav',music); write(stem+'-sfx.wav',sfx)

# MIDI: one track per instrument, for re-voicing the arrangement with real instruments in a DAW
GM={'piano':(0,0),'mallet':(1,12),'bell':(2,8),'bass':(3,38),'pad':(4,89),'choir':(5,52),'drums':(9,0)}
NAME={'piano':'Felt piano (lead, motif)','mallet':'Marimba','bell':'Glass bells / celesta','bass':'Sub bass',
      'pad':'Pad','choir':'Choir "ooh"','drums':'Drums (36 kick, 37 snap, 39 clap, 49 crash, 70 shaker)'}
PPQ=480
def vlq(n):
    b=[n&0x7f]; n>>=7
    while n: b.append(0x80|(n&0x7f)); n>>=7
    return bytes(reversed(b))
def chunk(evs):  # evs: (tick, order, bytes)
    out=b''; last=0
    for tk,_,data in sorted(evs,key=lambda e:(e[0],e[1])): out+=vlq(tk-last)+data; last=tk
    out+=vlq(0)+b'\xff\x2f\x00'; return b'MTrk'+len(out).to_bytes(4,'big')+out
def tick_of(sec): return int(round(sec/B*PPQ))
tracks=[chunk([(0,0,b'\xff\x51\x03'+int(B*1e6).to_bytes(3,'big')),(0,0,b'\xff\x58\x04\x04\x02\x18\x08'),
               (0,0,b'\xff\x03'+bytes([len(b'Hintlet v7')])+b'Hintlet v7')])]
for inst,(chn,prog) in GM.items():
    nm=NAME[inst].encode(); evs=[(0,0,b'\xff\x03'+vlq(len(nm))+nm)]
    if chn!=9: evs.append((0,0,bytes([0xC0|chn,prog])))
    for i,m,t0,dur,g in NOTES:
        if i!=inst or t0>=DUR: continue
        v=int(np.clip(30+70*g,20,120)); a=tick_of(t0); e=max(a+1,tick_of(min(DUR,t0+dur)))
        evs+=[(a,1,bytes([0x90|chn,int(m),v])),(e,0,bytes([0x80|chn,int(m),0]))]
    tracks.append(chunk(evs))
with open(stem+'.mid','wb') as f:
    f.write(b'MThd'+(6).to_bytes(4,'big')+(1).to_bytes(2,'big')+len(tracks).to_bytes(2,'big')+PPQ.to_bytes(2,'big')+b''.join(tracks))
print('wrote',sys.argv[1],stem+'-music.wav',stem+'-sfx.wav',stem+'.mid',f'{N/SR:.3f}s',len(NOTES),'notes')
