program nc(output);

{ NC -- a Norton Commander style file manager for P/OS

  Port of NC for RSX-11M-PLUS to the DEC Professional 350/380 under
  P/OS V3.2.  Compiled with Oregon Software Pascal-2 V2.1 on RSX-11M-PLUS;
  the task image runs unchanged under P/OS.  Uses the P/OS terminal
  (VT102 with LK201 function keys).
  Terminal, Files-11 and spawn primitives are in NCIO.MAC.

  Build (on RSX-11M-PLUS):
    PAS NC=NC/NOWALKBACK/NOCHECK
    MAC NCIO=NCIO
    TKB @NCBLD
  or @NCMAKE

  Keys (Pro LK201):
    Up Down  Prev/Next Screen  Find Select   move the cursor
    Left Right                   page up / page down
    Tab                          switch panels
    Return or Do                 enter directory, run .TSK, view
                                 other files, or execute the
                                 command line if one has been typed
    Insert Here or ^T            select / deselect file
    + - *                        select all, deselect all, invert
    ^F                           copy file name to the command line
    ^R reread   ^L redraw   ^U swap panels   Esc Esc clear command
    F1 help   F2 devices / go to   F3 view   F4 edit   F5 copy
    F6 ren/move   F7 mkdir  F8 delete  F9 sort/options  F10 quit
    (numbered as on a PC keyboard under Xhomer; on the Pro's LK201
    F1 is Help and F2-F5 are F17-F20)
  Common DCL verbs are translated for MMV or PIP; any other verb runs
  the installed task ...xxx it names.  @file is not supported.
}

const
  maxent = 250;         { directory entries per panel }
  maxcol = 96;          { longest string }
  maxscr = 132;         { widest screen }
  obsize = 1024;        { terminal output buffer }
  recsize = 512;        { viewer record buffer }

  { key codes above the character range }
  kup = 256; kdown = 257; kleft = 258; kright = 259;
  khome = 260; kend = 261; kpgup = 262; kpgdn = 263;
  kins = 264; kdel = 265; kesc = 266; knone = 267;
  kf1 = 271; kf2 = 272; kf3 = 273; kf4 = 274; kf5 = 275;
  kf6 = 276; kf7 = 277; kf8 = 278; kf9 = 279; kf10 = 280;

  { RSX }
  iofna = 2304;         { IO.FNA  find file in directory }
  iorat = 5632;         { IO.RAT  read attributes }
  ieeof = -10;          { IE.EOF }
  iensf = -26;          { IE.NSF }
  mfdnum = 4;           { file ID of the master file directory }
  maxdev = 24;          { devices in the F2 menu }
  maxunit = 7;          { highest unit number tried for each device }

  { screen attributes }
  anorm = 0; acur = 1; asel = 2; acursel = 3; adir = 4; aframe = 5;
  atitle = 6; akeyn = 7; akeyl = 8; acmd = 9; adlg = 10; afield = 11;
  ahead = 12; aview = 13;

  { sort orders }
  sname = 0; sext = 1; ssize = 2; sdate = 3; sunsort = 4;

type
  fileid = array [1..3] of integer;
  timbuf = array [1..8] of integer;
  fnblock = array [0..31] of integer;
  block = record
            case integer of
              0: (w: array [0..255] of integer);
              1: (c: packed array [0..511] of char)
          end;
  str3 = packed array [1..3] of char;
  line = packed array [1..maxcol] of char;
  str = record
          len: integer;
          s: line
        end;
  recbuf = packed array [1..recsize] of char;
  outbuf = packed array [1..obsize] of char;

  entry = packed record
            fnum, fseq: integer;        { file ID; fnum = -1 for ".." }
            nam: array [1..3] of integer;       { name keys }
            typ, ver: integer;
            size: integer;              { blocks used, or -Kblocks }
            fdate, ftime: integer;      { packed creation date/time }
            info, sel, isdir, contig: boolean
          end;

  panel = record
            dev, unit: integer;         { device, e.g. "DB" 0 }
            dnum, dseq: integer;        { directory file ID }
            dname: str;                 { "[1,54]" }
            n, top, cur, nsel: integer;
            sort: integer;
            e: array [1..maxent] of entry
          end;

  { just enough of the task's low core and FCS impure area to find the
    default directory string }
  fsrblk = record
             head1, head2, bfsr, efsr, owui, fipr: integer;
             dpb: array [1..12] of integer;
             iost, ioln: integer;
             dfdr: array [1..13] of integer;
             dfbc, dfui: integer;
             exds: packed array [1..80] of char
           end;
  lowcore = record
              w: array [0..19] of integer;
              fsr: ^fsrblk
            end;

var
  low origin 0: lowcore;
  pan: array [0..1] of panel;
  act: integer;                 { active panel }
  scrw, scrh: integer;          { screen size }
  pw, iw, nw: integer;          { panel, inner and name column widths }
  listh: integer;               { file rows per panel }
  showtime: boolean;
  obuf: outbuf;
  olen: integer;
  curattr: integer;
  ingfx: boolean;
  color: boolean;
  quit: boolean;
  cmd: str;                     { command line }
  lastdef: str;                 { last directory given to SET /DEF }
  startdef: str;                { default directory when NC started }
  exitst: integer;
  precmd: str;                  { run before a translated command }
  curdev, curunit: integer;     { device the FS LUNs are assigned to }
  hdr: block;
  fnb: fnblock;
  vrec: recbuf;
  vlen: integer;
  months: packed array [1..36] of char;
  oldnbr: integer;              { broadcast setting to restore }
  keychars: packed array [1..40] of char;
  devnames: packed array [1..32] of char;       { disk devices tried }
  ndev: integer;                { mounted devices found by scandevs }
  ddev, dunit: array [1..maxdev] of integer;
  sydev, syunit, lbdev, lbunit: integer;        { SY: and LB: }

{ ---- NCIO.MAC ---- }

procedure ttinit; external;
function ttgetc: integer; external;
procedure ttput(var b: outbuf; len: integer); external;
procedure ttsize(var w, h: integer); external;
function ttnbr(val: integer): integer; external;
function fsalun(dev, unit: integer): integer; external;
procedure fsglun(var dev, unit: integer); external;
function fsqio(fn: integer; var f: fnblock; code, size: integer;
               var b: block; p3, p4, p5, p6: integer): integer; external;
function vopen(var f: fileid): integer; external;
function vget(var b: recbuf; size: integer; var len: integer): integer;
  external;
procedure vclose; external;
procedure gtime(var b: timbuf); external;
procedure r50asc(w: integer; var s: str3); external;
function spawn(var c: line; len, tsk: integer): integer; external;

{ ---- strings ---- }

procedure sclr(var s: str);
begin
  s.len := 0
end;

procedure saddc(var s: str; c: char);
begin
  if s.len < maxcol then
    begin
    s.len := s.len + 1;
    s.s[s.len] := c
    end
end;

procedure sadd(var s: str; t: packed array [lo..hi: integer] of char);
var
  i: integer;
begin
  for i := lo to hi do saddc(s, t[i])
end;

procedure sadds(var s: str; var t: str);
var
  i: integer;
begin
  for i := 1 to t.len do saddc(s, t.s[i])
end;

procedure sset(var s: str; t: packed array [lo..hi: integer] of char);
var
  i: integer;
begin
  s.len := 0;
  for i := lo to hi do saddc(s, t[i])
end;

procedure saddnum(var s: str; n, base: integer);
var
  d: array [1..6] of char;
  k: integer;
begin
  if n < 0 then
    begin
    saddc(s, '-');
    n := -n
    end;
  k := 0;
  repeat
    k := k + 1;
    d[k] := chr(ord('0') + n mod base);
    n := n div base
  until n = 0;
  while k > 0 do
    begin
    saddc(s, d[k]);
    k := k - 1
    end
end;

procedure saddpad(var s: str; n, width: integer);
{ decimal, right justified with blanks }
var
  t: str;
  i: integer;
begin
  sclr(t);
  saddnum(t, n, 10);
  for i := t.len + 1 to width do saddc(s, ' ');
  sadds(s, t)
end;

procedure sadd2(var s: str; n: integer);
{ two digits with leading zero }
begin
  saddc(s, chr(ord('0') + (n div 10) mod 10));
  saddc(s, chr(ord('0') + n mod 10))
end;

function seq(var a, b: str): boolean;
var
  i: integer;
  same: boolean;
begin
  same := a.len = b.len;
  i := 1;
  while same and (i <= a.len) do
    begin
    same := a.s[i] = b.s[i];
    i := i + 1
    end;
  seq := same
end;

function upc(c: char): char;
begin
  if (c >= 'a') and (c <= 'z') then upc := chr(ord(c) - 32)
  else upc := c
end;

procedure supper(var s: str);
var
  i: integer;
begin
  for i := 1 to s.len do s.s[i] := upc(s.s[i])
end;

function spos(var s: str; c: char): integer;
{ index of the first c in s, or 0 }
var
  i, p: integer;
begin
  p := 0;
  i := s.len;
  while i > 0 do
    begin
    if s.s[i] = c then p := i;
    i := i - 1
    end;
  spos := p
end;

{ ---- terminal output ---- }

procedure flush;
begin
  if olen > 0 then ttput(obuf, olen);
  olen := 0
end;

procedure putc(c: char);
begin
  if olen >= obsize then flush;
  olen := olen + 1;
  obuf[olen] := c
end;

procedure puts(t: packed array [lo..hi: integer] of char);
var
  i: integer;
begin
  for i := lo to hi do putc(t[i])
end;

procedure putstr(var s: str);
var
  i: integer;
begin
  for i := 1 to s.len do putc(s.s[i])
end;

procedure putnum(n: integer);
var
  t: str;
begin
  sclr(t);
  saddnum(t, n, 10);
  putstr(t)
end;

procedure csi;
begin
  putc(chr(27));
  putc('[')
end;

procedure gotoxy(row, col: integer);
begin
  csi;
  putnum(row);
  putc(';');
  putnum(col);
  putc('H')
end;

procedure clreol;
begin
  csi;
  putc('K')
end;

procedure crlf;
begin
  putc(chr(13));
  putc(chr(10))
end;

procedure spaces(n: integer);
begin
  while n > 0 do
    begin
    putc(' ');
    n := n - 1
    end
end;

procedure gfx(on: boolean);
{ DEC special graphics (line drawing) on or off }
begin
  if on <> ingfx then
    begin
    putc(chr(27));
    putc('(');
    if on then putc('0') else putc('B');
    ingfx := on
    end
end;

procedure hline(n: integer);
begin
  gfx(true);
  while n > 0 do
    begin
    putc('q');
    n := n - 1
    end
end;

procedure setattr(a: integer);
begin
  if a <> curattr then
    begin
    curattr := a;
    csi;
    if color then
      case a of
        anorm, aframe: puts('0;36;44');
        acur, atitle, akeyl: puts('0;30;46');
        asel, ahead: puts('0;1;33;44');
        acursel: puts('0;1;33;46');
        adir, afield: puts('0;1;37;44');
        akeyn, acmd, aview: puts('0;37;40');
        adlg: puts('0;30;47')
      end
    else
      case a of
        anorm, adir, aframe, akeyn, acmd, afield, aview: putc('0');
        acur, atitle, akeyl, adlg: puts('0;7');
        asel, ahead: puts('0;1');
        acursel: puts('0;1;7')
      end;
    putc('m')
    end
end;

procedure putfield(var s: str; width: integer);
{ s left justified in width columns, truncated if too long }
var
  i: integer;
begin
  gfx(false);
  for i := 1 to width do
    if i <= s.len then putc(s.s[i]) else putc(' ')
end;

procedure putrfield(var s: str; width: integer);
{ s right justified in width columns }
var
  i: integer;
begin
  gfx(false);
  for i := s.len + 1 to width do putc(' ');
  for i := 1 to s.len do
    if i <= width then putc(s.s[i])
end;

procedure putcenter(t: packed array [lo..hi: integer] of char;
                    width: integer);
var
  l, i: integer;
begin
  gfx(false);
  l := (width - (hi - lo + 1)) div 2;
  spaces(l);
  for i := lo to hi do putc(t[i]);
  spaces(width - l - (hi - lo + 1))
end;

procedure termreset;
{ forget what we think the terminal state is }
begin
  curattr := -1;
  ingfx := true;
  gfx(false);
  csi;
  puts('0m')
end;

procedure clrscr(a: integer);
begin
  setattr(a);
  csi;
  puts('2J')
end;

{ ---- keyboard ---- }

function getkey: integer;
var
  c, k, n: integer;
begin
  flush;
  repeat
    c := ttgetc
  until (c <> 0) and (c <> 10);
  k := c;
  if c = 27 then
    begin
    c := ttgetc;
    k := knone;
    if (c = ord('[')) or (c = ord('O')) then
      begin
      c := ttgetc;
      if (c >= ord('0')) and (c <= ord('9')) then
        begin
        n := 0;
        while (c >= ord('0')) and (c <= ord('9')) do
          begin
          if n < 100 then n := n * 10 + c - ord('0');
          c := ttgetc
          end;
        while (c = ord(';')) or ((c >= ord('0')) and (c <= ord('9'))) do
          c := ttgetc;
        if (n = 1) or (n = 7) then k := khome
        else if n = 2 then k := kins
        else if n = 3 then k := kdel
        else if (n = 4) or (n = 8) then k := kend
        else if n = 5 then k := kpgup
        else if n = 6 then k := kpgdn
        else if (n >= 11) and (n <= 15) then k := kf1 + n - 11
        else if (n >= 17) and (n <= 21) then k := kf6 + n - 17
        else if n = 23 then k := kesc           { F11 (ESC) }
        else if n = 28 then k := kf1            { Help }
        else if n = 29 then k := 13             { Do }
        else if (n >= 31) and (n <= 34) then k := kf2 + n - 31 { F17-F20 }
        end
      else if c = ord('A') then k := kup
      else if c = ord('B') then k := kdown
      else if c = ord('C') then k := kright
      else if c = ord('D') then k := kleft
      else if c = ord('H') then k := khome
      else if c = ord('F') then k := kend
      else if (c >= ord('P')) and (c <= ord('S')) then
        k := kf1 + c - ord('P')
      end
    else if (c >= ord('1')) and (c <= ord('9')) then
      k := kf1 + c - ord('1')
    else if c = ord('0') then k := kf10
    else if c = 27 then k := kesc
    end;
  getkey := k
end;

{ ---- names, dates and sizes ---- }

procedure devname(dv, un: integer; var s: str);
{ append "DB0:" }
begin
  saddc(s, chr(dv mod 256));
  saddc(s, chr(dv div 256));
  saddnum(s, un, 8);
  saddc(s, ':')
end;

procedure devstr(p: integer; var s: str);
{ "DB0:" }
begin
  sclr(s);
  devname(pan[p].dev, pan[p].unit, s)
end;

procedure pathstr(p: integer; var s: str);
{ "DB0:[1,54]" }
begin
  devstr(p, s);
  sadds(s, pan[p].dname)
end;

{ File names are kept as "keys": RAD50 words re-coded so that the
  characters are in ASCII order (blank $ . % 0-9 A-Z).  Unsigned
  comparison of keys then sorts names the way a user expects. }

function r50key(w: integer): integer;
var
  t: str3;
  i, k1, k2, k3, r: integer;
  kk: array [1..3] of integer;
begin
  r50asc(w, t);
  for i := 1 to 3 do
    begin
    kk[i] := 0;
    for r := 1 to 40 do
      if keychars[r] = t[i] then kk[i] := r - 1
    end;
  k1 := kk[1];
  k2 := kk[2];
  k3 := kk[3];
  r := k2 * 40 + k3;
  if (k1 < 20) or ((k1 = 20) and (r < 768)) then r50key := k1 * 1600 + r
  else r50key := -32767 - 1 + ((k1 - 20) * 1600 + r - 768)
end;

procedure keychr(w: integer; var t: str3);
{ decode a key into three characters }
var
  q, r, u: integer;
begin
  if w >= 0 then
    begin
    q := w div 1600;
    r := w mod 1600
    end
  else
    begin
    u := w + 32767 + 1;
    q := u div 1600;
    r := u mod 1600 + 768;
    if r >= 1600 then
      begin
      q := q + 1;
      r := r - 1600
      end;
    q := q + 20
    end;
  if q > 39 then q := 39;
  t[1] := keychars[q + 1];
  t[2] := keychars[r div 40 + 1];
  t[3] := keychars[r mod 40 + 1]
end;

procedure r50str(w: integer; var s: str);
{ append a name key, dropping blanks }
var
  t: str3;
  i: integer;
begin
  keychr(w, t);
  for i := 1 to 3 do
    if t[i] <> ' ' then saddc(s, t[i])
end;

procedure entnam(var e: entry; var s: str);
{ file name without type }
begin
  sclr(s);
  r50str(e.nam[1], s);
  r50str(e.nam[2], s);
  r50str(e.nam[3], s)
end;

procedure dirform(var nm: str; var s: str);
{ directory file name to "[g,m]" or "[NAME]" }
var
  i, g, m: integer;
  num: boolean;
begin
  num := nm.len = 6;
  for i := 1 to nm.len do
    if (nm.s[i] < '0') or (nm.s[i] > '7') then num := false;
  sclr(s);
  saddc(s, '[');
  if num then
    begin
    g := 0;
    m := 0;
    for i := 1 to 3 do
      begin
      g := g * 8 + ord(nm.s[i]) - ord('0');
      m := m * 8 + ord(nm.s[i + 3]) - ord('0')
      end;
    saddnum(s, g, 8);
    saddc(s, ',');
    saddnum(s, m, 8)
    end
  else sadds(s, nm);
  saddc(s, ']')
end;

procedure filename(var e: entry; var s: str);
{ "NAME.TYP;V" }
var
  t: str;
begin
  entnam(e, s);
  saddc(s, '.');
  sclr(t);
  r50str(e.typ, t);
  sadds(s, t);
  saddc(s, ';');
  saddnum(s, e.ver, 10)
end;

procedure filespec(p, i: integer; var s: str);
{ "DB0:[1,54]NAME.TYP;V" }
var
  t: str;
begin
  pathstr(p, s);
  filename(pan[p].e[i], t);
  sadds(s, t)
end;

procedure listname(var e: entry; var s: str);
{ name as shown in the panel }
var
  t: str;
  i: integer;
begin
  if e.fnum = -1 then sset(s, '..')
  else
    begin
    entnam(e, t);
    if e.isdir then dirform(t, s)
    else
      begin
      s := t;
      for i := t.len + 1 to 9 do saddc(s, ' ');
      saddc(s, ' ');
      r50str(e.typ, s);
      while s.len < 13 do saddc(s, ' ');
      saddc(s, ';');
      saddnum(s, e.ver, 10)
      end
    end
end;

procedure datestr(d: integer; var s: str);
{ "17-SEP-26" }
var
  y, m, dd, i: integer;
begin
  y := d div 416 + 70;
  m := (d mod 416) div 32;
  dd := d mod 32;
  if (m < 1) or (m > 12) then m := 1;
  sadd2(s, dd);
  saddc(s, '-');
  for i := 1 to 3 do saddc(s, months[(m - 1) * 3 + i]);
  saddc(s, '-');
  sadd2(s, y mod 100)
end;

procedure timestr(t: integer; var s: str);
{ "16:43" }
begin
  sadd2(s, t div 60);
  saddc(s, ':');
  sadd2(s, t mod 60)
end;

function ulo1k(lo: integer): integer;
{ unsigned lo div 1024 }
begin
  if lo >= 0 then ulo1k := lo div 1024
  else ulo1k := (lo + 32767 + 1) div 1024 + 32
end;

procedure sizestr(size: integer; var s: str);
begin
  if size >= 0 then saddnum(s, size, 10)
  else
    begin
    saddnum(s, -size, 10);
    saddc(s, 'K')
    end
end;

{ ---- directories ---- }

procedure setdev(p: integer);
var
  st: integer;
begin
  with pan[p] do
    if (dev <> curdev) or (unit <> curunit) then
      begin
      st := fsalun(dev, unit);
      curdev := dev;
      curunit := unit
      end
end;

function digit(c: char): integer;
begin
  digit := ord(c) - ord('0')
end;

procedure loadinfo(p, i: integer);
{ read the file header for size and date }
var
  st, ib, d, m, y, k, hi, lo: integer;
  mon: str3;
begin
  with pan[p].e[i] do
    if not info then
      begin
      info := true;
      size := 0;
      fdate := 0;
      ftime := -1;
      if fnum > 0 then
        begin
        setdev(p);
        fnb[0] := fnum;
        fnb[1] := fseq;
        fnb[2] := 0;
        st := fsqio(iorat, fnb, -10, 0, hdr, 0, 0, 0, 0);
        if st = 1 then
          begin
          contig := ord(hdr.c[12]) >= 128;
          { end of file block, less one if the first free byte is 0 }
          hi := hdr.w[11];
          lo := hdr.w[12];
          if hdr.w[13] = 0 then
            if lo = 0 then
              begin
              hi := hi - 1;
              lo := -1
              end
            else if lo = -32767 - 1 then lo := 32767
            else lo := lo - 1;
          if hi < 0 then
            begin
            hi := 0;
            lo := 0
            end;
          if (hi = 0) and (lo >= 0) then size := lo
          else size := -(hi * 64 + ulo1k(lo));
          { creation date "DDMMMYY" and time "HHMMSS" }
          ib := ord(hdr.c[0]) * 2 + 25;
          if (ib > 0) and (ib < 500) then
            begin
            d := digit(hdr.c[ib]) * 10 + digit(hdr.c[ib + 1]);
            mon[1] := hdr.c[ib + 2];
            mon[2] := hdr.c[ib + 3];
            mon[3] := hdr.c[ib + 4];
            y := digit(hdr.c[ib + 5]) * 10 + digit(hdr.c[ib + 6]);
            m := 0;
            for k := 1 to 12 do
              if (months[k * 3 - 2] = mon[1]) and
                 (months[k * 3 - 1] = mon[2]) and
                 (months[k * 3] = mon[3]) then m := k;
            if (m > 0) and (d >= 1) and (d <= 31) and (y >= 70) and
               (y <= 147) then
              begin
              fdate := (y - 70) * 416 + m * 32 + d;
              ftime := (digit(hdr.c[ib + 7]) * 10 +
                        digit(hdr.c[ib + 8])) * 60 +
                       digit(hdr.c[ib + 9]) * 10 + digit(hdr.c[ib + 10]);
              if (ftime < 0) or (ftime >= 1440) then ftime := -1
              end
            end
          end
        end
      end
end;

function ucmp(a, b: integer): integer;
{ compare as unsigned 16 bit numbers }
begin
  if a = b then ucmp := 0
  else if (a < 0) = (b < 0) then
    begin
    if a < b then ucmp := -1 else ucmp := 1
    end
  else if a < 0 then ucmp := 1
  else ucmp := -1
end;

function cmpname(var a, b: entry): integer;
var
  c: integer;
begin
  c := ucmp(a.nam[1], b.nam[1]);
  if c = 0 then c := ucmp(a.nam[2], b.nam[2]);
  if c = 0 then c := ucmp(a.nam[3], b.nam[3]);
  cmpname := c
end;

function cmpent(var a, b: entry; mode: integer): integer;
var
  c: integer;
begin
  c := 0;
  if a.fnum = -1 then c := -1
  else if b.fnum = -1 then c := 1
  else if a.isdir <> b.isdir then
    begin
    if a.isdir then c := -1 else c := 1
    end
  else
    begin
    if mode = sext then c := ucmp(a.typ, b.typ)
    else if mode = ssize then
      begin
      { bigger first; negative sizes are in K blocks }
      if (a.size < 0) and (b.size < 0) then c := ucmp(a.size, b.size)
      else if a.size < 0 then c := -1
      else if b.size < 0 then c := 1
      else if a.size > b.size then c := -1
      else if a.size < b.size then c := 1
      end
    else if mode = sdate then
      begin
      if a.fdate <> b.fdate then c := ucmp(b.fdate, a.fdate)
      else c := ucmp(b.ftime, a.ftime)
      end;
    if c = 0 then c := cmpname(a, b);
    if c = 0 then c := ucmp(a.typ, b.typ);
    if c = 0 then c := ucmp(b.ver, a.ver)
    end;
  cmpent := c
end;

procedure sortpanel(p: integer);
var
  gap, i, j: integer;
  t: entry;
  done: boolean;
begin
  with pan[p] do
    if sort <> sunsort then
      begin
      if (sort = ssize) or (sort = sdate) then
        for i := 1 to n do loadinfo(p, i);
      gap := n div 2;
      while gap > 0 do
        begin
        for i := gap + 1 to n do
          begin
          t := e[i];
          j := i;
          done := false;
          while not done do
            if j <= gap then done := true
            else if cmpent(e[j - gap], t, sort) <= 0 then done := true
            else
              begin
              e[j] := e[j - gap];
              j := j - gap
              end;
          e[j] := t
          end;
        gap := gap div 2
        end
      end
end;

function ismfd(p: integer): boolean;
begin
  ismfd := pan[p].dnum = mfdnum
end;

function loaddir(p: integer): integer;
{ read the panel's directory; returns 1 or an error code }
var
  st, i: integer;
  t: str3;
begin
  setdev(p);
  with pan[p] do
    begin
    n := 0;
    nsel := 0;
    top := 1;
    cur := 1;
    if not ismfd(p) then
      begin
      n := 1;
      with e[1] do
        begin
        fnum := -1;
        fseq := 0;
        typ := 0;
        ver := 0;
        info := true;
        sel := false;
        isdir := true;
        contig := false;
        size := 0;
        fdate := 0;
        ftime := -1
        end
      end;
    for i := 0 to 31 do fnb[i] := 0;
    fnb[8] := 56;       { wildcard name, type and version }
    fnb[10] := dnum;
    fnb[11] := dseq;
    repeat
      st := fsqio(iofna, fnb, 0, 0, hdr, 0, 0, 0, 2);
      if st = 1 then
        begin
        n := n + 1;
        with e[n] do
          begin
          fnum := fnb[0];
          fseq := fnb[1];
          nam[1] := r50key(fnb[3]);
          nam[2] := r50key(fnb[4]);
          nam[3] := r50key(fnb[5]);
          r50asc(fnb[6], t);
          typ := r50key(fnb[6]);
          ver := fnb[7];
          info := false;
          sel := false;
          contig := false;
          isdir := t = 'DIR'
          end
        end
    until (st <> 1) or (n >= maxent);
    if st = iensf then st := 1;
    loaddir := st
    end;
  sortpanel(p)
end;

function finddir(p: integer; var want: str; var num, sq: integer): boolean;
{ look up "[g,m]" or "[NAME]" in the MFD of the panel's device }
var
  st, i: integer;
  found: boolean;
  e: entry;
  nm, d: str;
  t: str3;
begin
  found := false;
  if seq(want, pan[p].dname) then
    begin
    num := pan[p].dnum;
    sq := pan[p].dseq;
    found := true
    end;
  sset(d, '[0,0]');
  if seq(want, d) then
    begin
    num := mfdnum;
    sq := mfdnum;
    found := true
    end;
  if not found then
    begin
    setdev(p);
    for i := 0 to 31 do fnb[i] := 0;
    fnb[8] := 56;
    fnb[10] := mfdnum;
    fnb[11] := mfdnum;
    repeat
      st := fsqio(iofna, fnb, 0, 0, hdr, 0, 0, 0, 2);
      if st = 1 then
        begin
        r50asc(fnb[6], t);
        if t = 'DIR' then
          begin
          e.nam[1] := r50key(fnb[3]);
          e.nam[2] := r50key(fnb[4]);
          e.nam[3] := r50key(fnb[5]);
          entnam(e, nm);
          dirform(nm, d);
          if seq(d, want) then
            begin
            found := true;
            num := fnb[0];
            sq := fnb[1]
            end
          end
        end
    until found or (st <> 1)
    end;
  finddir := found
end;

function mfdok: boolean;
{ true if the device the FS LUN is assigned to holds a mounted
  Files-11 volume, i.e. the MFD's header can be read }
begin
  fnb[0] := mfdnum;
  fnb[1] := mfdnum;
  fnb[2] := 0;
  mfdok := fsqio(iorat, fnb, -10, 0, hdr, 0, 0, 0, 0) = 1
end;

procedure adddev(dv, un: integer);
{ add a device to the list, unless it is there already }
var
  k: integer;
  dup: boolean;
begin
  dup := false;
  for k := 1 to ndev do
    if (ddev[k] = dv) and (dunit[k] = un) then dup := true;
  if not dup and (ndev < maxdev) then
    begin
    ndev := ndev + 1;
    ddev[ndev] := dv;
    dunit[ndev] := un
    end
end;

procedure scandevs;
{ list the mounted Files-11 volumes: try units 0 to maxunit of each
  disk device name and keep those whose MFD can be read }
var
  i, u, dv, un: integer;
begin
  ndev := 0;
  curdev := -1;
  sydev := -1;
  lbdev := -1;
  if fsalun(ord('S') + 256 * ord('Y'), 0) >= 0 then fsglun(sydev, syunit);
  if fsalun(ord('L') + 256 * ord('B'), 0) >= 0 then fsglun(lbdev, lbunit);
  i := 1;
  while i < 32 do
    begin
    for u := 0 to maxunit do
      begin
      dv := ord(devnames[i]) + 256 * ord(devnames[i + 1]);
      un := u;
      if fsalun(dv, un) >= 0 then
        begin
        { a redirected device resolves to its target }
        fsglun(dv, un);
        if mfdok then adddev(dv, un)
        end
      end;
    i := i + 2
    end;
  { the panels' devices, in case their unit numbers are higher }
  adddev(pan[0].dev, pan[0].unit);
  adddev(pan[1].dev, pan[1].unit);
  curdev := -1
end;

{ ---- screen layout ---- }

function x0(p: integer): integer;
begin
  x0 := p * pw + 1
end;

procedure drawtitle(p: integer);
var
  t: str;
  x: integer;
begin
  pathstr(p, t);
  if t.len > pw - 4 then t.len := pw - 4;
  x := x0(p) + (pw - t.len - 2) div 2;
  gotoxy(1, x);
  gfx(false);
  if p = act then setattr(atitle) else setattr(aframe);
  putc(' ');
  putstr(t);
  putc(' ')
end;

procedure rowattr(p, i: integer);
begin
  with pan[p] do
    if (i = cur) and (p = act) then
      begin
      if e[i].sel then setattr(acursel) else setattr(acur)
      end
    else if e[i].sel then setattr(asel)
    else if e[i].isdir then setattr(adir)
    else setattr(anorm)
end;

procedure bar;
begin
  gfx(true);
  putc('x')
end;

procedure drawrow(p, i: integer);
var
  t: str;
begin
  with pan[p] do
    if (i >= top) and (i < top + listh) then
      begin
      gotoxy(3 + i - top, x0(p));
      setattr(aframe);
      bar;
      if i <= n then
        begin
        loadinfo(p, i);
        rowattr(p, i);
        listname(e[i], t);
        putfield(t, nw);
        bar;
        sclr(t);
        if e[i].fnum = -1 then sset(t, '<UP>')
        else if e[i].isdir then sset(t, '<DIR>')
        else sizestr(e[i].size, t);
        putrfield(t, 7);
        bar;
        sclr(t);
        if e[i].ftime >= 0 then datestr(e[i].fdate, t);
        putfield(t, 9);
        if showtime then
          begin
          bar;
          sclr(t);
          if e[i].ftime >= 0 then timestr(e[i].ftime, t);
          putfield(t, 5)
          end
        end
      else
        begin
        setattr(anorm);
        gfx(false);
        spaces(nw);
        bar;
        gfx(false);
        spaces(7);
        bar;
        gfx(false);
        spaces(9);
        if showtime then
          begin
          bar;
          gfx(false);
          spaces(5)
          end
        end;
      setattr(aframe);
      bar;
      gfx(false)
      end
end;

procedure drawinfo(p: integer);
var
  t, u: str;
  i, tk, tu, v: integer;
begin
  sclr(t);
  with pan[p] do
    if nsel > 0 then
      begin
      { total blocks, kept as thousands and units }
      tk := 0;
      tu := 0;
      for i := 1 to n do
        if e[i].sel then
          with e[i] do
            begin
            if size >= 0 then
              begin
              tk := tk + size div 1000;
              tu := tu + size mod 1000
              end
            else
              begin
              v := -size;
              tk := tk + v + v div 40
              end;
            while tu >= 1000 do
              begin
              tu := tu - 1000;
              tk := tk + 1
              end
            end;
      saddnum(t, nsel, 10);
      sadd(t, ' selected, ');
      if tk > 0 then
        begin
        saddnum(t, tk, 10);
        saddc(t, ',');
        saddc(t, chr(ord('0') + tu div 100));
        sadd2(t, tu mod 100)
        end
      else saddnum(t, tu, 10);
      sadd(t, ' blocks')
      end
    else if (cur >= 1) and (cur <= n) then
      begin
      if e[cur].fnum = -1 then sset(t, '.. (up to [0,0])')
      else if e[cur].isdir then
        begin
        entnam(e[cur], u);
        dirform(u, t);
        sadd(t, '  directory')
        end
      else
        begin
        filename(e[cur], t);
        loadinfo(p, cur);
        if not showtime and (e[cur].ftime >= 0) then
          begin
          while t.len < iw - 7 do saddc(t, ' ');
          saddc(t, ' ');
          timestr(e[cur].ftime, t)
          end;
        if e[cur].contig then
          begin
          while t.len < iw - 2 do saddc(t, ' ');
          sadd(t, ' C')
          end
        end
      end;
  gotoxy(listh + 4, x0(p));
  setattr(aframe);
  bar;
  setattr(anorm);
  putfield(t, iw);
  setattr(aframe);
  bar;
  gfx(false)
end;

procedure drawframe(p: integer);
var
  x: integer;
begin
  x := x0(p);
  setattr(aframe);
  gotoxy(1, x);
  gfx(true);
  putc('l');
  hline(nw);
  putc('w');
  hline(7);
  putc('w');
  hline(9);
  if showtime then
    begin
    putc('w');
    hline(5)
    end;
  putc('k');
  gotoxy(2, x);
  bar;
  setattr(ahead);
  putcenter('Name', nw);
  setattr(aframe);
  bar;
  setattr(ahead);
  putcenter('Size', 7);
  setattr(aframe);
  bar;
  setattr(ahead);
  putcenter('Date', 9);
  setattr(aframe);
  if showtime then
    begin
    bar;
    setattr(ahead);
    putcenter('Time', 5);
    setattr(aframe)
    end;
  bar;
  gotoxy(listh + 3, x);
  gfx(true);
  putc('t');
  hline(nw);
  putc('v');
  hline(7);
  putc('v');
  hline(9);
  if showtime then
    begin
    putc('v');
    hline(5)
    end;
  putc('u');
  gotoxy(listh + 5, x);
  putc('m');
  hline(pw - 2);
  putc('j');
  gfx(false);
  drawtitle(p)
end;

procedure drawrows(p: integer);
var
  i: integer;
begin
  for i := pan[p].top to pan[p].top + listh - 1 do drawrow(p, i)
end;

procedure drawpanel(p: integer);
begin
  drawframe(p);
  drawrows(p);
  drawinfo(p)
end;

procedure drawkeys;
{ key legend, numbered as on a PC keyboard under Xhomer; on the Pro's
  LK201, F1 is Help and F2-F5 are F17-F20 }
var
  k, w, i, n: integer;
  t: str;
begin
  w := scrw div 10;
  gotoxy(scrh, 1);
  for k := 1 to 10 do
    begin
    setattr(akeyn);
    sclr(t);
    saddnum(t, k, 10);
    putstr(t);
    n := t.len;
    setattr(akeyl);
    case k of
      1: sset(t, 'Help');
      2: sset(t, 'Go To');
      3: sset(t, 'View');
      4: sset(t, 'Edit');
      5: sset(t, 'Copy');
      6: sset(t, 'RenMov');
      7: sset(t, 'Mkdir');
      8: sset(t, 'Delete');
      9: sset(t, 'Sort');
      10: sset(t, 'Quit')
    end;
    i := w - n;
    if k = 10 then i := i - 1;
    putfield(t, i)
    end;
  setattr(acmd)
end;

procedure drawclock;
{ HH:MM at the top right, as Norton Commander shows it }
var
  tb: timbuf;
  t: str;
begin
  gtime(tb);
  sclr(t);
  saddc(t, ' ');
  sadd2(t, tb[4]);
  saddc(t, ':');
  sadd2(t, tb[5]);
  saddc(t, ' ');
  gotoxy(1, scrw - 7);
  setattr(atitle);
  putstr(t)
end;

procedure drawcmd;
var
  t: str;
  room, i: integer;
begin
  drawclock;
  pathstr(act, t);
  saddc(t, '>');
  gotoxy(scrh - 1, 1);
  setattr(acmd);
  room := scrw - 1 - t.len;
  putstr(t);
  if cmd.len <= room then putstr(cmd)
  else
    for i := cmd.len - room + 1 to cmd.len do putc(cmd.s[i]);
  clreol
end;

procedure redraw;
begin
  termreset;
  csi;
  puts('?7l');          { no autowrap }
  clrscr(anorm);
  drawpanel(0);
  drawpanel(1);
  setattr(acmd);
  gotoxy(scrh - 1, 1);
  clreol;
  drawkeys;
  drawcmd
end;

procedure setcur(p, c: integer);
{ move the cursor of panel p to entry c, scrolling if needed }
var
  old, oldtop: integer;
begin
  with pan[p] do
    begin
    if c > n then c := n;
    if c < 1 then c := 1;
    old := cur;
    oldtop := top;
    cur := c;
    { stepping off the bottom or top of the window turns a whole page:
      the cursor lands on the first or last line of the new page }
    if cur < top then
      begin
      if cur = old - 1 then top := cur - listh + 1 else top := cur
      end;
    if cur >= top + listh then
      begin
      if cur = old + 1 then top := cur else top := cur - listh + 1
      end;
    if top < 1 then top := 1;
    if top <> oldtop then drawrows(p)
    else if old <> cur then
      begin
      drawrow(p, old);
      drawrow(p, cur)
      end;
    drawinfo(p)
    end
end;

procedure fixtop(p: integer);
{ keep the cursor visible and the list window full }
begin
  with pan[p] do
    begin
    if cur > n then cur := n;
    if cur < 1 then cur := 1;
    if top > n - listh + 1 then top := n - listh + 1;
    if cur >= top + listh then top := cur - listh + 1;
    if cur < top then top := cur;
    if top < 1 then top := 1
    end
end;

procedure findcur(p: integer; var want: entry);
{ put the cursor back on the entry named like want }
var
  i, c: integer;
begin
  c := 1;
  with pan[p] do
    for i := 1 to n do
      if (e[i].fnum = want.fnum) and (e[i].fseq = want.fseq) then c := i;
  pan[p].cur := c;
  if c >= listh then pan[p].top := c - listh div 2;
  fixtop(p)
end;

procedure reload(p: integer);
var
  keep: entry;
  st, c: integer;
begin
  with pan[p] do
    begin
    c := cur;
    if (cur >= 1) and (cur <= n) then keep := e[cur]
    else keep.fnum := 0;
    st := loaddir(p);
    findcur(p, keep);
    if (cur = 1) and (c > 1) and (keep.fnum > 0) then
      if c <= n then cur := c else cur := n;
    fixtop(p)
    end
end;

{ ---- dialogs ---- }

procedure box(r1, c1, r2, c2: integer; var title: str);
var
  r: integer;
begin
  setattr(adlg);
  gotoxy(r1, c1);
  gfx(true);
  putc('l');
  hline(c2 - c1 - 1);
  putc('k');
  for r := r1 + 1 to r2 - 1 do
    begin
    gotoxy(r, c1);
    bar;
    gfx(false);
    spaces(c2 - c1 - 1);
    bar
    end;
  gotoxy(r2, c1);
  putc('m');
  hline(c2 - c1 - 1);
  putc('j');
  gfx(false);
  if title.len > 0 then
    begin
    gotoxy(r1, c1 + (c2 - c1 - title.len) div 2);
    putc(' ');
    putstr(title);
    putc(' ')
    end
end;

procedure msgbox(title, text: str);
var
  w, c1, r1, k: integer;
begin
  w := text.len + 6;
  if w < 30 then w := 30;
  if w > scrw - 2 then w := scrw - 2;
  if text.len > w - 4 then text.len := w - 4;
  c1 := (scrw - w) div 2 + 1;
  r1 := scrh div 2 - 3;
  box(r1, c1, r1 + 5, c1 + w - 1, title);
  gotoxy(r1 + 2, c1 + (w - text.len) div 2);
  putstr(text);
  gotoxy(r1 + 4, c1 + (w - 20) div 2);
  puts('[ Press any key ]');
  k := getkey;
  redraw
end;

function confirm(title, text: str): boolean;
var
  w, c1, r1, k: integer;
  yes, done: boolean;

  procedure buttons;
  begin
    gotoxy(r1 + 4, c1 + (w - 16) div 2);
    if yes then setattr(afield) else setattr(adlg);
    puts('[ Yes ]');
    setattr(adlg);
    puts('  ');
    if yes then setattr(adlg) else setattr(afield);
    puts('[ No ]');
    setattr(adlg);
    if yes then gotoxy(r1 + 4, c1 + (w - 16) div 2 + 2)
    else gotoxy(r1 + 4, c1 + (w - 16) div 2 + 11)
  end;

begin
  w := text.len + 6;
  if w < 30 then w := 30;
  if w > scrw - 2 then w := scrw - 2;
  if text.len > w - 4 then text.len := w - 4;
  c1 := (scrw - w) div 2 + 1;
  r1 := scrh div 2 - 3;
  box(r1, c1, r1 + 5, c1 + w - 1, title);
  gotoxy(r1 + 2, c1 + (w - text.len) div 2);
  putstr(text);
  yes := true;
  done := false;
  repeat
    buttons;
    k := getkey;
    if (k = kleft) or (k = kright) or (k = 9) or (k = kup) or
       (k = kdown) then yes := not yes
    else if (k = ord('y')) or (k = ord('Y')) then
      begin
      yes := true;
      done := true
      end
    else if (k = ord('n')) or (k = ord('N')) or (k = kesc) or
            (k = kf10) or (k = 3) then
      begin
      yes := false;
      done := true
      end
    else if (k = 13) or (k = ord(' ')) then done := true
  until done;
  confirm := yes;
  redraw
end;

function inputbox(title, prompt: str; var val: str): boolean;
var
  w, c1, r1, fw, k, i, first: integer;
  done, ok: boolean;
begin
  w := scrw - 10;
  c1 := 6;
  r1 := scrh div 2 - 3;
  fw := w - 4;
  box(r1, c1, r1 + 5, c1 + w - 1, title);
  gotoxy(r1 + 2, c1 + 2);
  if prompt.len > fw then prompt.len := fw;
  putstr(prompt);
  done := false;
  ok := false;
  repeat
    gotoxy(r1 + 3, c1 + 2);
    setattr(afield);
    first := 1;
    if val.len >= fw then first := val.len - fw + 2;
    for i := first to first + fw - 1 do
      if i <= val.len then putc(val.s[i]) else putc(' ');
    gotoxy(r1 + 3, c1 + 2 + val.len - first + 1);
    setattr(adlg);
    k := getkey;
    if k = 13 then
      begin
      done := true;
      ok := true
      end
    else if (k = kesc) or (k = kf10) or (k = 3) then done := true
    else if (k = 8) or (k = 127) or (k = kdel) then
      begin
      if val.len > 0 then val.len := val.len - 1
      end
    else if k = 21 then val.len := 0
    else if (k >= 32) and (k < 127) then saddc(val, chr(k))
  until done;
  inputbox := ok;
  redraw
end;

{ ---- running commands ---- }

procedure cmdscreen;
{ plain screen for command output }
begin
  termreset;
  csi;
  puts('?7h');          { autowrap on for other programs }
  clrscr(acmd);
  gotoxy(1, 1)
end;

function r50ch(c: char): integer;
{ RAD50 code of one character (0 for anything else) }
begin
  if (c >= 'A') and (c <= 'Z') then r50ch := ord(c) - ord('A') + 1
  else if (c >= 'a') and (c <= 'z') then r50ch := ord(c) - ord('a') + 1
  else if (c >= '0') and (c <= '9') then r50ch := ord(c) - ord('0') + 30
  else if c = '$' then r50ch := 27
  else if c = '.' then r50ch := 28
  else r50ch := 0
end;

function cmdtask(var c: str): integer;
{ RAD50 name xxx of the task ...xxx that runs command line c, chosen
  as MCR would: the first three characters of the verb, or AT. for an
  indirect command file. }
var
  i, n, k1, r: integer;
  v: array [1..3] of integer;
begin
  i := 1;
  while (i < c.len) and (c.s[i] = ' ') do i := i + 1;
  for n := 1 to 3 do v[n] := 0;
  if c.s[i] = '@' then
    begin
    v[1] := 1; v[2] := 20; v[3] := 28          { AT. }
    end
  else
    begin
    n := 0;
    while (i <= c.len) and (n < 3) and (r50ch(c.s[i]) > 0) do
      begin
      n := n + 1;
      v[n] := r50ch(c.s[i]);
      i := i + 1
      end
    end;
  { v[1]*1600 + v[2]*40 + v[3] as a 16-bit word }
  k1 := v[1];
  r := v[2] * 40 + v[3];
  if (k1 < 20) or ((k1 = 20) and (r < 768)) then cmdtask := k1 * 1600 + r
  else cmdtask := -32767 - 1 + ((k1 - 20) * 1600 + r - 768)
end;

function runline(var c: str): integer;
{ run one command line, showing it first }
var
  st: integer;
begin
  putstr(c);
  crlf;
  flush;
  st := spawn(c.s, c.len, cmdtask(c));
  curattr := -1;
  runline := st
end;

procedure setdefault;
{ make the terminal's default directory follow the active panel.  P/OS
  has no MCR SET /DEF; its MMV task (which DCL itself uses) takes
  SET DEFAULT. }
var
  t, c: str;
  st: integer;
begin
  pathstr(act, t);
  if not seq(t, lastdef) then
    begin
    sset(c, 'MMV SET DEFAULT ');
    sadds(c, t);
    st := spawn(c.s, c.len, cmdtask(c));
    lastdef := t
    end
end;

{ ---- DCL style commands ----

  P/OS has no MCR, and its DCL cannot be given a command by another
  task.  DCL does much of its work by passing commands to the installed
  tasks MMV and PIP, so NC translates the common DCL verbs the same way:

    RUN file              MMV INSTALL/RUN file
    SET ASSIGN DEASSIGN DISMOUNT INSTALL REMOVE CREATE BAD
    SHOW DEFAULT/LOGICAL  MMV <the command line>
    MOUNT dev: label      MMV MOUNT dev:label
    INITIALIZE dev: label MMV BAD dev:, then MMV INITIALIZE dev:label
    DIRECTORY [spec]      PIP [spec]/LI
    TYPE spec             PIP TI:=spec
    COPY from to          PIP to=from
    RENAME from to        PIP to/RE=from
    DELETE spec           PIP spec/DE
    PURGE spec            PIP spec/PU
    PRINT spec            MMV PRINT spec

  Any other verb names the installed task ...xxx, as with MCR. }

function abbrev(var v: str; full: packed array [lo..hi: integer] of char;
                min: integer): boolean;
{ v is full, or an abbreviation of it at least min characters long }
var
  i: integer;
  ok: boolean;
begin
  ok := (v.len >= min) and (v.len <= hi - lo + 1);
  i := 1;
  while ok and (i <= v.len) do
    begin
    ok := v.s[i] = full[lo + i - 1];
    i := i + 1
    end;
  abbrev := ok
end;

procedure nextword(var c: str; var i: integer; var w: str);
{ the next blank-separated word of c from position i }
begin
  sclr(w);
  while (i <= c.len) and (c.s[i] = ' ') do i := i + 1;
  while (i <= c.len) and (c.s[i] <> ' ') do
    begin
    saddc(w, c.s[i]);
    i := i + 1
    end
end;

function translate(var c: str): boolean;
{ rewrite a DCL style command line c for MMV or PIP; false if the verb
  is not one of those handled here.  precmd is set to a command to run
  first, if any. }
var
  v, a, b, t, w: str;
  i, j: integer;
  done: boolean;
begin
  i := 1;
  sclr(v);
  while (i <= c.len) and (c.s[i] = ' ') do i := i + 1;
  while (i <= c.len) and (((c.s[i] >= 'A') and (c.s[i] <= 'Z')) or
                          ((c.s[i] >= 'a') and (c.s[i] <= 'z'))) do
    begin
    saddc(v, c.s[i]);
    i := i + 1
    end;
  supper(v);
  j := i;
  nextword(c, j, a);
  nextword(c, j, b);
  done := true;
  sclr(precmd);
  sclr(w);
  for j := 1 to a.len do
    if (a.s[j] >= 'a') and (a.s[j] <= 'z') then saddc(w, chr(ord(a.s[j]) - 32))
    else saddc(w, a.s[j]);
  if abbrev(v, 'RUN', 3) then
    begin
    sset(t, 'MMV INSTALL/RUN ');
    sadds(t, a)
    end
  else if abbrev(v, 'DIRECTORY', 3) then
    begin
    sset(t, 'PIP ');
    sadds(t, a);
    sadd(t, '/LI')
    end
  else if abbrev(v, 'TYPE', 3) then
    begin
    sset(t, 'PIP TI:=');
    sadds(t, a)
    end
  else if abbrev(v, 'COPY', 3) and (b.len > 0) then
    begin
    sset(t, 'PIP ');
    sadds(t, b);
    saddc(t, '=');
    sadds(t, a)
    end
  else if abbrev(v, 'RENAME', 3) and (b.len > 0) then
    begin
    sset(t, 'PIP ');
    sadds(t, b);
    sadd(t, '/RE=');
    sadds(t, a)
    end
  else if abbrev(v, 'DELETE', 3) and (c.s[i] <> '/') then
    begin
    sset(t, 'PIP ');
    sadds(t, a);
    sadd(t, '/DE')
    end
  else if abbrev(v, 'PURGE', 2) then
    begin
    sset(t, 'PIP ');
    sadds(t, a);
    sadd(t, '/PU')
    end
  else if abbrev(v, 'MOUNT', 3) or abbrev(v, 'INITIALIZE', 3) then
    begin
    { MMV wants the label joined to the device: DZ2:LABEL }
    if abbrev(v, 'MOUNT', 3) then sset(t, 'MMV MOUNT ')
    else
      begin
      sset(precmd, 'MMV BAD ');         { as DCL does: new diskettes }
      sadds(precmd, a);                 { need a bad block file }
      sset(t, 'MMV INITIALIZE ')
      end;
    sadds(t, a);
    sadds(t, b)
    end
  else if abbrev(v, 'SHOW', 2) and not (abbrev(w, 'DEFAULT', 3) or
          abbrev(w, 'LOGICALS', 3)) then
    done := false                       { MMV cannot; only DCL can }
  else if abbrev(v, 'PRINT', 2) then
    begin
    sset(t, 'MMV PRINT ');
    sadds(t, a)
    end
  else if abbrev(v, 'SET', 3) or abbrev(v, 'SHOW', 2) or
          abbrev(v, 'ASSIGN', 2) or abbrev(v, 'DEASSIGN', 3) or
          abbrev(v, 'DISMOUNT', 3) or abbrev(v, 'BAD', 3) or
          abbrev(v, 'INSTALL', 3) or
          abbrev(v, 'REMOVE', 3) or abbrev(v, 'CREATE', 2) or
          abbrev(v, 'DELETE', 3) then
    begin
    sset(t, 'MMV ');
    sadds(t, c)
    end
  else done := false;
  if done then c := t;
  translate := done
end;

procedure waitkey(st: integer);
var
  k: integer;
begin
  crlf;
  setattr(adlg);
  if st = 1 then puts(' Press any key to return ')
  else
    begin
    puts(' Exit status ');
    putnum(st);
    puts(' -- press any key to return ')
    end;
  setattr(acmd);
  k := getkey
end;

procedure execute(var c: str; pause: boolean);
{ run c through MMV or PIP (DCL style verbs) or the task named by its
  verb.  Commands that only DCL itself can run (@ files, most SHOW
  commands) are not available: DCL cannot be given a command by
  another task. }
var
  st: integer;
begin
  sclr(cmd);
  cmdscreen;
  setdefault;
  pathstr(act, cmd);
  saddc(cmd, '>');
  putstr(cmd);
  sclr(cmd);
  if (c.len > 0) and (c.s[1] = '@') then st := -2
  else
    begin
    if translate(c) then ;
    st := 1;
    if precmd.len > 0 then st := runline(precmd);
    if st = 1 then st := runline(c)
    end;
  if st = -2 then
    begin
    crlf;
    puts('Not available from NC: no installed task takes this command,');
    crlf;
    puts('and only DCL itself can run it.')
    end;
  if pause or (st = -2) then waitkey(st);
  reload(0);
  reload(1);
  redraw
end;

function okstatus(st: integer): boolean;
begin
  okstatus := st = 1
end;

{ ---- file viewer ---- }

procedure doview(p, i: integer);
var
  fid: fileid;
  st, top, pos, hs, rows, k, r: integer;
  atend, done: boolean;
  name, t: str;

  procedure showline(row: integer);
  var
    j, col, out: integer;
    ch: char;
  begin
    gotoxy(row, 1);
    setattr(aview);
    col := 0;
    out := 0;
    for j := 1 to vlen do
      begin
      ch := vrec[j];
      if ch = chr(9) then
        repeat
          col := col + 1;
          if (col > hs) and (col <= hs + scrw) then
            begin
            putc(' ');
            out := out + 1
            end
        until col mod 8 = 0
      else
        begin
        col := col + 1;
        if (col > hs) and (col <= hs + scrw) then
          begin
          if (ch < ' ') or (ch > '~') then ch := '.';
          putc(ch);
          out := out + 1
          end
        end
      end;
    if out < scrw then clreol
  end;

  function nextline: boolean;
  begin
    if atend then nextline := false
    else
      begin
      st := vget(vrec, recsize, vlen);
      if st = 1 then
        begin
        if vlen > recsize then vlen := recsize;
        if vlen < 0 then vlen := 0;
        pos := pos + 1;
        nextline := true
        end
      else
        begin
        atend := true;
        nextline := false
        end
      end
  end;

  procedure reopen;
  begin
    vclose;
    setdev(p);
    st := vopen(fid);
    pos := 0;
    atend := st <> 1
  end;

  procedure seekto(ln: integer);
  { position so that the next line read is line ln (0 based) }
  begin
    if ln < pos then reopen;
    while (pos < ln) and nextline do ;
  end;

  procedure vstatus;
  begin
    gotoxy(1, 1);
    setattr(atitle);
    sset(t, ' View: ');
    sadds(t, name);
    sadd(t, '   Line ');
    saddnum(t, top + 1, 10);
    if hs > 0 then
      begin
      sadd(t, '  Col ');
      saddnum(t, hs + 1, 10)
      end;
    putfield(t, scrw)
  end;

  procedure showpage(haveone: boolean);
  { draw the page starting at top; if haveone, line top is in vrec }
  var
    row: integer;
    more: boolean;
  begin
    if not haveone then seekto(top);
    more := true;
    for row := 2 to scrh - 1 do
      begin
      if more then
        if (row > 2) or not haveone then more := nextline;
      if more then showline(row)
      else
        begin
        gotoxy(row, 1);
        setattr(aview);
        clreol
        end
      end;
    vstatus
  end;

begin
  with pan[p].e[i] do
    begin
    fid[1] := fnum;
    fid[2] := fseq;
    fid[3] := 0
    end;
  filespec(p, i, name);
  setdev(p);
  st := vopen(fid);
  if st <> 1 then
    begin
    sset(t, 'Cannot open file, error ');
    saddnum(t, st, 10);
    sset(name, 'View');
    msgbox(name, t)
    end
  else
    begin
    rows := scrh - 2;
    top := 0;
    pos := 0;
    hs := 0;
    atend := false;
    termreset;
    clrscr(aview);
    csi;
    putnum(2);
    putc(';');
    putnum(scrh - 1);
    putc('r');          { scrolling region }
    gotoxy(scrh, 1);
    setattr(akeyl);
    sset(t, ' Up Down Prev Next Find Select Left Right ');
    sadd(t, 'Esc F3 F10 Q = quit');
    putfield(t, scrw - 1);
    showpage(false);
    done := false;
    repeat
      k := getkey;
      if (k = kdown) or (k = 13) then
        begin
        seekto(top + rows);
        if nextline then
          begin
          top := top + 1;
          gotoxy(scrh - 1, 1);
          putc(chr(10));
          showline(scrh - 1);
          vstatus
          end
        end
      else if k = kup then
        begin
        if top > 0 then
          begin
          top := top - 1;
          seekto(top);
          if nextline then
            begin
            gotoxy(2, 1);
            putc(chr(27));
            putc('M');
            showline(2)
            end;
          vstatus
          end
        end
      else if (k = kpgdn) or (k = ord(' ')) then
        begin
        seekto(top + rows);
        if nextline then
          begin
          top := top + rows;
          showpage(true)
          end
        end
      else if k = kpgup then
        begin
        if top > 0 then
          begin
          top := top - rows;
          if top < 0 then top := 0;
          showpage(false)
          end
        end
      else if k = khome then
        begin
        top := 0;
        showpage(false)
        end
      else if k = kend then
        begin
        while nextline do ;
        top := pos - rows;
        if top < 0 then top := 0;
        showpage(false)
        end
      else if k = kright then
        begin
        hs := hs + 20;
        showpage(false)
        end
      else if k = kleft then
        begin
        if hs > 0 then
          begin
          hs := hs - 20;
          if hs < 0 then hs := 0;
          showpage(false)
          end
        end
      else if (k = kesc) or (k = kf3) or (k = kf10) or (k = ord('q')) or
              (k = ord('Q')) or (k = 3) then done := true
    until done;
    vclose;
    csi;
    putc('r');
    redraw
    end
end;

{ ---- file operations ---- }

function selcount(p: integer): integer;
{ number of files an operation works on: the selection, or the
  file under the cursor }
begin
  with pan[p] do
    if nsel > 0 then selcount := nsel
    else if (cur >= 1) and (cur <= n) then
      begin
      if e[cur].fnum = -1 then selcount := 0 else selcount := 1
      end
    else selcount := 0
end;

function inset(p, i: integer): boolean;
begin
  with pan[p] do
    if nsel > 0 then inset := e[i].sel
    else inset := (i = cur) and (e[i].fnum <> -1)
end;

procedure oneline(p: integer; var s: str);
{ "3 files" or the name of the single file }
var
  i: integer;
begin
  with pan[p] do
    if selcount(p) = 1 then
      begin
      for i := 1 to n do
        if inset(p, i) then filename(e[i], s)
      end
    else
      begin
      sclr(s);
      saddnum(s, selcount(p), 10);
      sadd(s, ' files')
      end
end;

procedure endops(fail: boolean);
var
  k: integer;
begin
  if fail then
    begin
    crlf;
    setattr(adlg);
    puts(' Some operations failed -- press any key ');
    setattr(acmd);
    k := getkey
    end;
  reload(0);
  reload(1);
  redraw
end;

procedure skipdir(var fail: boolean; var name: str);
begin
  puts('Skipping directory ');
  putstr(name);
  crlf;
  fail := true
end;

procedure docopy(move: boolean);
var
  dest, t, c, spec, nm: str;
  i, st, q: integer;
  fail, samedev, isdirdest, ok: boolean;
begin
  if selcount(act) > 0 then
    begin
    pathstr(1 - act, dest);
    oneline(act, t);
    if move then
      begin
      sset(c, 'Rename/Move');
      sset(nm, 'Move ')
      end
    else
      begin
      sset(c, 'Copy');
      sset(nm, 'Copy ')
      end;
    sadds(nm, t);
    sadd(nm, ' to:');
    if inputbox(c, nm, dest) then
      if dest.len > 0 then
        begin
        supper(dest);
        { a destination without device or directory is relative to
          the active panel }
        if spos(dest, ':') = 0 then
          begin
          if spos(dest, '[') = 0 then pathstr(act, t)
          else devstr(act, t);
          sadds(t, dest);
          dest := t
          end;
        isdirdest := (dest.s[dest.len] = ']') or (dest.s[dest.len] = ':');
        devstr(act, t);
        samedev := true;
        q := spos(dest, ':');
        if q > 0 then
          begin
          samedev := q = t.len;
          for i := 1 to q do
            if i <= t.len then
              if dest.s[i] <> t.s[i] then samedev := false
          end;
        cmdscreen;
        fail := false;
        with pan[act] do
          for i := 1 to n do
            if inset(act, i) then
              begin
              filespec(act, i, spec);
              if e[i].isdir then skipdir(fail, spec)
              else
                begin
                filename(e[i], nm);
                sset(c, 'PIP ');
                sadds(c, dest);
                if move and samedev then
                  begin
                  if isdirdest then sadds(c, nm);
                  sadd(c, '/RE=')
                  end
                else sadd(c, '/NV=');
                sadds(c, spec);
                st := runline(c);
                ok := okstatus(st);
                if ok and move and not samedev then
                  begin
                  sset(c, 'PIP ');
                  sadds(c, spec);
                  sadd(c, '/DE');
                  st := runline(c);
                  ok := okstatus(st)
                  end;
                if not ok then fail := true
                end
              end;
        endops(fail)
        end
    end
end;

procedure dodelete;
var
  t, c, spec: str;
  i, st: integer;
  fail: boolean;
begin
  if selcount(act) > 0 then
    begin
    oneline(act, t);
    sset(c, 'Delete ');
    sadds(c, t);
    saddc(c, '?');
    sset(t, 'Delete');
    if confirm(t, c) then
      begin
      cmdscreen;
      fail := false;
      with pan[act] do
        for i := 1 to n do
          if inset(act, i) then
            begin
            filespec(act, i, spec);
            if e[i].isdir then skipdir(fail, spec)
            else
              begin
              sset(c, 'PIP ');
              sadds(c, spec);
              sadd(c, '/DE');
              st := runline(c);
              if not okstatus(st) then fail := true
              end
            end;
      endops(fail)
      end
    end
end;

procedure domkdir;
var
  t, p, v, c: str;
  st: integer;
begin
  sset(t, 'Make directory');
  sset(p, 'Create directory, e.g. [200,1] or [NAME]:');
  sclr(v);
  if inputbox(t, p, v) then
    if v.len > 0 then
      begin
      supper(v);
      sset(c, 'MMV CREATE/DIR ');
      if spos(v, ':') = 0 then
        begin
        devstr(act, t);
        sadds(c, t)
        end;
      sadds(c, v);
      cmdscreen;
      st := runline(c);
      endops(not okstatus(st))
      end
end;

procedure doedit(p, i: integer);
var
  c, t: str;
begin
  sset(c, 'EDT ');
  filespec(p, i, t);
  sadds(c, t);
  execute(c, false)
end;

{ ---- navigation ---- }

function chdir(p, num, sq: integer; var name: str): integer;
{ show another directory in panel p; on failure the panel is left
  as it was and the error code is returned }
var
  st, i: integer;
  olddn, u, v: str;
  oldnum, oldseq: integer;
begin
  with pan[p] do
    begin
    olddn := dname;
    oldnum := dnum;
    oldseq := dseq;
    dnum := num;
    dseq := sq;
    dname := name;
    st := loaddir(p);
    chdir := st;
    if st <> 1 then
      begin
      dnum := oldnum;
      dseq := oldseq;
      dname := olddn;
      i := loaddir(p)
      end
    else
      begin
      { going up: put the cursor on the directory we came from }
      if num = mfdnum then
        for i := 1 to n do
          if e[i].isdir then
            begin
            entnam(e[i], u);
            dirform(u, v);
            if seq(v, olddn) then cur := i
            end;
      if cur >= listh then top := cur - listh div 2;
      fixtop(p);
      drawpanel(p)
      end
    end
end;

procedure direrror(var name: str; st: integer);
var
  t, u: str;
begin
  if st = 0 then sset(t, 'Directory not found: ')
  else sset(t, 'Cannot read ');
  sadds(t, name);
  if st <> 0 then
    begin
    sadd(t, ', error ');
    saddnum(t, st, 10)
    end;
  sset(u, 'Error');
  msgbox(u, t)
end;

procedure goto_path(p: integer; var path: str);
{ path is "DDn:", "DDn:[dir]" or "[dir]" }
var
  dv, un, i, q, olddev, oldunit, oldnum, oldseq, num, sq, st: integer;
  d, olddn: str;
  ok: boolean;
begin
  supper(path);
  ok := true;
  st := 0;
  with pan[p] do
    begin
    olddev := dev;
    oldunit := unit;
    oldnum := dnum;
    oldseq := dseq;
    olddn := dname;
    q := spos(path, ':');
    if q > 0 then
      begin
      if q < 3 then ok := false
      else
        begin
        dv := ord(path.s[1]) + 256 * ord(path.s[2]);
        un := 0;
        for i := 3 to q - 1 do
          if (path.s[i] >= '0') and (path.s[i] <= '7') then
            un := un * 8 + digit(path.s[i])
          else ok := false;
        if ok then
          begin
          curdev := -1;
          st := fsalun(dv, un);
          if st < 0 then ok := false
          else
            begin
            dev := dv;
            unit := un;
            fsglun(dev, unit);
            curdev := dev;
            curunit := unit;
            if (dev <> olddev) or (unit <> oldunit) then
              begin
              { another device: start from its MFD }
              dnum := mfdnum;
              dseq := mfdnum;
              sset(dname, '[0,0]')
              end
            end
          end
        end
      end;
    sclr(d);
    for i := q + 1 to path.len do saddc(d, path.s[i]);
    if d.len = 0 then sset(d, '[0,0]');
    if ok then ok := finddir(p, d, num, sq);
    if ok then
      begin
      st := chdir(p, num, sq, d);
      ok := st = 1
      end;
    if not ok then
      begin
      dev := olddev;
      unit := oldunit;
      dnum := oldnum;
      dseq := oldseq;
      dname := olddn;
      curdev := -1;
      i := loaddir(p);
      direrror(path, st)
      end
    end
end;

procedure enter;
var
  c, t, u: str;
  st: integer;
begin
  with pan[act] do
    if (cur >= 1) and (cur <= n) then
      begin
      if e[cur].fnum = -1 then
        begin
        sset(t, '[0,0]');
        st := chdir(act, mfdnum, mfdnum, t);
        if st <> 1 then direrror(t, st)
        end
      else if e[cur].isdir then
        begin
        entnam(e[cur], u);
        dirform(u, t);
        st := chdir(act, e[cur].fnum, e[cur].fseq, t);
        if st <> 1 then direrror(t, st)
        end
      else
        begin
        sclr(u);
        r50str(e[cur].typ, u);
        filespec(act, cur, t);
        sset(c, 'TSK');
        if seq(u, c) then
          begin
          sset(c, 'RUN ');
          sadds(c, t);
          execute(c, true)
          end
        else
          begin
          doview(act, cur)
          end
        end
      end
end;

procedure togglesel(p, i: integer);
begin
  with pan[p] do
    if (i >= 1) and (i <= n) then
      if not e[i].isdir then
        begin
        e[i].sel := not e[i].sel;
        if e[i].sel then nsel := nsel + 1 else nsel := nsel - 1
        end
end;

procedure selectall(mode: integer);
{ 1 select all, 0 deselect all, 2 invert }
var
  i: integer;
begin
  with pan[act] do
    begin
    for i := 1 to n do
      if not e[i].isdir then
        if (mode = 2) or (e[i].sel <> (mode = 1)) then togglesel(act, i);
    drawrows(act);
    drawinfo(act)
    end
end;

procedure help;
var
  k: integer;

  procedure l(r: integer; t: packed array [lo..hi: integer] of char);
  var
    i: integer;
  begin
    gotoxy(r, 3);
    for i := lo to hi do putc(t[i])
  end;

begin
  termreset;
  clrscr(adlg);
  l(1, 'NC -- Norton Commander for P/OS (Pascal-2)');
  l(3, 'Up Down  Prev Next Screen  Find Select   move  Left Right  page');
  l(4, 'Tab       switch panels           ^U  swap panels');
  l(5, 'Return/Do enter directory / run .TSK / view file');
  l(6, '          or execute the typed command line');
  l(7, 'Insert ^T select file        + - *  select all/none/invert');
  l(8, '^F        put file name on the command line');
  l(9, '^R        reread directory   ^L  redraw   Esc Esc  clear line');
  l(11, 'F1 Help     F2 Device/dir   F3 View    F4 Edit (EDT)');
  l(12, 'F5 Copy     F6 Rename/Move  F7 Mkdir   F8 Delete');
  l(13, 'F9 Sort / colour options    F10 Quit');
  l(15, 'On the Pro''s LK201: Help = F1, F17-F20 = F2-F5; F11 is ESC.');
  l(16, 'ESC followed by a digit also works: ESC 1 = F1 ... ESC 0 = F10.');
  l(18, 'RUN SET SHOW DIR TYPE COPY RENAME DELETE PURGE ... go through MMV');
  l(19, 'or PIP (also PRINT); other verbs name a task (PIP, EDT, DMP...).');
  l(21, 'Press any key.');
  k := getkey;
  redraw
end;

procedure options;
var
  w, c1, r1: integer;
  c: char;
  t: str;
begin
  w := 34;
  c1 := (scrw - w) div 2 + 1;
  r1 := scrh div 2 - 5;
  sset(t, 'Sort / Options');
  box(r1, c1, r1 + 9, c1 + w - 1, t);
  gotoxy(r1 + 2, c1 + 3);
  puts('N  sort by Name');
  gotoxy(r1 + 3, c1 + 3);
  puts('E  sort by Extension');
  gotoxy(r1 + 4, c1 + 3);
  puts('S  sort by Size');
  gotoxy(r1 + 5, c1 + 3);
  puts('D  sort by Date');
  gotoxy(r1 + 6, c1 + 3);
  puts('U  Unsorted (directory order)');
  gotoxy(r1 + 7, c1 + 3);
  puts('C  Colour on/off');
  c := upc(chr(getkey mod 128));
  if c = 'C' then color := not color
  else
    with pan[act] do
      begin
      if c = 'N' then sort := sname
      else if c = 'E' then sort := sext
      else if c = 'S' then sort := ssize
      else if c = 'D' then sort := sdate
      else if c = 'U' then sort := sunsort;
      if (c = 'N') or (c = 'E') or (c = 'S') or (c = 'D') or (c = 'U') then
        reload(act)
      end;
  redraw
end;

{ ---- main ---- }

procedure initpanels;
var
  t, d: str;
  i, num, sq, st, g, m: integer;
  found: boolean;
begin
  { default device and directory }
  curdev := -1;
  st := fsalun(ord('S') + 256 * ord('Y'), 0);
  fsglun(pan[0].dev, pan[0].unit);
  curdev := pan[0].dev;
  curunit := pan[0].unit;
  sclr(d);
  with low.fsr^ do
    if dfdr[1] > 0 then
      begin
      i := 1;
      while (i < 80) and (exds[i] <> '[') do i := i + 1;
      while (i <= 80) and (d.len < dfdr[1]) do
        begin
        saddc(d, exds[i]);
        i := i + 1
        end
      end;
  if (d.len < 3) or (d.s[1] <> '[') or (d.s[d.len] <> ']') then
    begin
    g := low.fsr^.dfui div 256;
    m := low.fsr^.dfui mod 256;
    sclr(d);
    saddc(d, '[');
    saddnum(d, g, 8);
    saddc(d, ',');
    saddnum(d, m, 8);
    saddc(d, ']')
    end;
  supper(d);
  for i := 0 to 1 do
    with pan[i] do
      begin
      dev := pan[0].dev;
      unit := pan[0].unit;
      dnum := mfdnum;
      dseq := mfdnum;
      sset(dname, '[0,0]');
      sort := sname;
      n := 0;
      top := 1;
      cur := 1;
      nsel := 0
      end;
  found := finddir(0, d, num, sq);
  if found then
    begin
    pan[0].dnum := num;
    pan[0].dseq := sq;
    pan[0].dname := d
    end;
  st := loaddir(0);
  st := loaddir(1);
  pathstr(0, lastdef);
  startdef := lastdef
end;

procedure setsize;
begin
  ttsize(scrw, scrh);
  if (scrw < 80) or (scrw > maxscr) then scrw := 80;
  if (scrh < 16) or (scrh > 66) then scrh := 24;
  pw := scrw div 2;
  iw := pw - 2;
  showtime := iw >= 46;
  nw := iw - 7 - 9 - 2;
  if showtime then nw := nw - 6;
  listh := scrh - 7
end;

procedure swappanels;
var
  t: str;
  i: integer;
begin
  t := pan[0].dname;
  pan[0].dname := pan[1].dname;
  pan[1].dname := t;
  i := pan[0].dev;
  pan[0].dev := pan[1].dev;
  pan[1].dev := i;
  i := pan[0].unit;
  pan[0].unit := pan[1].unit;
  pan[1].unit := i;
  i := pan[0].dnum;
  pan[0].dnum := pan[1].dnum;
  pan[1].dnum := i;
  i := pan[0].dseq;
  pan[0].dseq := pan[1].dseq;
  pan[1].dseq := i;
  curdev := -1;
  i := loaddir(0);
  i := loaddir(1);
  redraw
end;

procedure switchpanel;
var
  old: integer;
begin
  old := act;
  act := 1 - act;
  drawtitle(old);
  drawrow(old, pan[old].cur);
  drawtitle(act);
  drawrow(act, pan[act].cur)
end;

procedure nametocmd;
{ ^F: append the current file name to the command line }
var
  t: str;
begin
  with pan[act] do
    if (cur >= 1) and (cur <= n) then
      if e[cur].fnum <> -1 then
        begin
        filename(e[cur], t);
        if (cmd.len > 0) and (cmd.s[cmd.len] <> ' ') then saddc(cmd, ' ');
        sadds(cmd, t)
        end
end;

procedure devline(i, r, c, w: integer; hi: boolean);
{ entry i of the device menu, at row r, column c, w columns wide }
var
  t: str;
  p: integer;
begin
  sclr(t);
  saddc(t, ' ');
  if i > ndev then sadd(t, 'Type a path...')
  else
    begin
    devname(ddev[i], dunit[i], t);
    while t.len < 8 do saddc(t, ' ');
    if (ddev[i] = sydev) and (dunit[i] = syunit) then sadd(t, 'SY: ');
    if (ddev[i] = lbdev) and (dunit[i] = lbunit) then sadd(t, 'LB: ');
    while t.len < 17 do saddc(t, ' ');
    for p := 0 to 1 do
      if (ddev[i] = pan[p].dev) and (dunit[i] = pan[p].unit) then
        if p = 0 then sadd(t, 'Left ') else sadd(t, 'Right')
    end;
  gotoxy(r, c);
  if hi then setattr(afield) else setattr(adlg);
  putfield(t, w)
end;

function devmenu(var first: str): integer;
{ F2 menu of the mounted devices.  Returns the device chosen, 0 to
  type a path (first holds the text to start with), or -1 }
var
  ni, vis, top, cur, w, c1, r1, k, i, res: integer;
  t: str;
begin
  scandevs;
  ni := ndev + 1;
  vis := ni;
  if vis > scrh - 6 then vis := scrh - 6;
  w := 34;
  c1 := (scrw - w) div 2 + 1;
  r1 := (scrh - vis - 2) div 2;
  sset(t, 'Go To');
  box(r1, c1, r1 + vis + 1, c1 + w - 1, t);
  cur := ni;
  for i := ndev downto 1 do
    if (ddev[i] = pan[act].dev) and (dunit[i] = pan[act].unit) then
      cur := i;
  top := 1;
  if cur > vis then top := cur - vis + 1;
  sclr(first);
  res := -2;
  repeat
    for i := top to top + vis - 1 do
      devline(i, r1 + 1 + i - top, c1 + 1, w - 2, i = cur);
    gotoxy(r1 + 1 + cur - top, c1 + 1);
    k := getkey;
    if k = kup then cur := cur - 1
    else if k = kdown then cur := cur + 1
    else if (k = kpgup) or (k = kleft) then cur := cur - vis + 1
    else if (k = kpgdn) or (k = kright) then cur := cur + vis - 1
    else if k = khome then cur := 1
    else if k = kend then cur := ni
    else if k = 13 then
      begin
      if cur > ndev then
        begin
        pathstr(act, first);
        res := 0
        end
      else res := cur
      end
    else if (k = kesc) or (k = kf2) or (k = kf10) or (k = 3) then res := -1
    else if (k > 32) and (k < 127) then
      begin
      { typing starts a path }
      saddc(first, chr(k));
      res := 0
      end;
    if cur > ni then cur := ni;
    if cur < 1 then cur := 1;
    if cur < top then top := cur;
    if cur >= top + vis then top := cur - vis + 1
  until res > -2;
  devmenu := res;
  redraw
end;

procedure gotodir;
var
  t, u, v: str;
  i: integer;
begin
  i := devmenu(t);
  if i > 0 then
    begin
    sclr(t);
    devname(ddev[i], dunit[i], t);
    goto_path(act, t)
    end
  else if i = 0 then
    begin
    sset(u, 'Go to directory (DDn:[dir]):');
    sset(v, 'Go To');
    if inputbox(v, u, t) then goto_path(act, t)
    end
end;

procedure askquit;
var
  t, u: str;
begin
  sset(t, 'Quit');
  sset(u, 'Do you want to quit NC?');
  quit := confirm(t, u)
end;

function curfile: boolean;
{ true if the cursor is on a plain file }
begin
  curfile := false;
  with pan[act] do
    if (cur >= 1) and (cur <= n) then curfile := not e[cur].isdir
end;

procedure movekey(k: integer);
begin
  with pan[act] do
    if k = kup then setcur(act, cur - 1)
    else if k = kdown then setcur(act, cur + 1)
    else if (k = kpgup) or (k = kleft) then setcur(act, cur - listh + 1)
    else if (k = kpgdn) or (k = kright) then setcur(act, cur + listh - 1)
    else if k = khome then setcur(act, 1)
    else if k = kend then setcur(act, n)
end;

procedure fkey(k: integer);
begin
  if k = kf1 then help
  else if k = kf2 then gotodir
  else if k = kf3 then
    begin
    if curfile then doview(act, pan[act].cur)
    end
  else if k = kf4 then
    begin
    if curfile then doedit(act, pan[act].cur)
    end
  else if k = kf5 then docopy(false)
  else if k = kf6 then docopy(true)
  else if k = kf7 then domkdir
  else if k = kf8 then dodelete
  else if k = kf9 then options
  else if k = kf10 then askquit
end;

procedure ctrlkey(k: integer);
var
  t: str;
begin
  if k = 9 then switchpanel
  else if k = 13 then
    begin
    if cmd.len > 0 then
      begin
      t := cmd;
      execute(t, true)
      end
    else enter
    end
  else if (k = 8) or (k = 127) then
    begin
    if cmd.len > 0 then cmd.len := cmd.len - 1
    end
  else if (k = kesc) or (k = 3) then sclr(cmd)
  else if k = 6 then nametocmd
  else if k = 18 then
    begin
    reload(act);
    drawpanel(act)
    end
  else if k = 12 then redraw
  else if k = 21 then swappanels
  else if (k = kins) or (k = 20) then
    begin
    togglesel(act, pan[act].cur);
    drawrow(act, pan[act].cur);
    setcur(act, pan[act].cur + 1)
    end
end;

procedure mainloop;
var
  k: integer;
begin
  repeat
    drawcmd;
    k := getkey;
    if (k >= kup) and (k <= kpgdn) then movekey(k)
    else if (k >= kf1) and (k <= kf10) then fkey(k)
    else if (k = ord('+')) and (cmd.len = 0) then selectall(1)
    else if (k = ord('-')) and (cmd.len = 0) then selectall(0)
    else if (k = ord('*')) and (cmd.len = 0) then selectall(2)
    else if (k >= 32) and (k < 127) then
      begin
      if cmd.len < maxcol - 20 then saddc(cmd, chr(k))
      end
    else ctrlkey(k)
  until quit
end;

begin
  months := 'JANFEBMARAPRMAYJUNJULAUGSEPOCTNOVDEC';
  keychars := ' $.%0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  devnames := 'DBDDDFDKDLDMDPDRDSDTDUDWDXDYDZVD';
  olen := 0;
  color := false;
  quit := false;
  act := 0;
  sclr(cmd);
  ttinit;
  oldnbr := ttnbr(1);           { no broadcast messages while we run }
  setsize;
  initpanels;
  redraw;
  mainloop;
  { leave the terminal tidy }
  oldnbr := ttnbr(oldnbr);
  if not seq(lastdef, startdef) then
    begin                       { put the default back, for P/OS's menus }
    sset(cmd, 'MMV SET DEFAULT ');
    sadds(cmd, startdef);
    exitst := spawn(cmd.s, cmd.len, cmdtask(cmd))
    end;
  termreset;
  csi;
  puts('?7h');
  csi;
  puts('2J');
  gotoxy(1, 1);
  flush
end.
