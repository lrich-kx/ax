/ kx.ax.qdocparser -- a qdoc comment parser for KDB-X in plain q: no shared libraries, no regex library, no
/ dependency on another module. It reads the qdoc comments in q source into items and their tags.
/ .
/   .kx.ax.qdocparser:use`kx.ax.qdocparser
/   .kx.ax.qdocparser.getFiles[recursive; paths]    the files under paths, as an items table (name; kind; content)
/   .kx.ax.qdocparser.items[settings; src]          the parse result: one row per item, with its tags
/   .kx.ax.qdocparser.files[settings; src]          the file record: each file's header and parse errors
/   .kx.ax.qdocparser.docItems[settings; src]       the renderer input: readmes, then items, with parameters
/   .kx.ax.qdocparser.parameters[code]              a lambda's parameters, as kx.ax's renderer finds them
/ .
/ The parse follows qdoc's own, which reads a .q file the way q's own script loader does: an indented line
/ or a comment line continues the logical line above it, "/" and "\" alone on a line open and close a block
/ comment, and a bare "\" outside one ends the script.
/ A logical line whose first statement assigns a name (name: or name::) is an item: a function if the
/ value is a lambda or a lambda applied to arguments, data otherwise. Its content is the comment lines
/ before it, then the source after the assignment. \d and system "d ..." lines set the namespace.
/ q's own tokenizer (-4!) decides assignment and function, never native parse; everything else is vector
/ operations on lines.
/ .
/ NB avoid lone-'/' lines in q source -- they start a block comment to EOF.

/ ---------- text helpers ----------
WS:"\t\n\013\014\r ";                                   / the whitespace kx.ax trims
trimL:{[s] (sum mins s in WS) _ s};
trimR:{[s] neg[sum mins reverse s in WS] _ s};
isFq:{[s] "."~first s};                               / a fully qualified name starts with "."
startsWith:{[s;p] p:(),p; (count[p]#s)~p};                    / prefix test, by hand: like was 'nyi in a module on some builds

/ ---------- 1. lines, block comments, logical lines ----------
/ Lines before the first unindented, non-comment line are dropped only up to the last stray indented code
/ line among them; with none (the usual case), nothing is dropped.
/ Per line, computed over the whole file at once: its first raw character (" " for an empty line), its
/ first non-blank character (" " if blank), whether it's blank, and whether it is one non-blank character
/ at column 0 and nothing else but blanks (a block-comment marker, when that character is "/" or "\").
lineInfo:{[lines]
  c:count each lines;
  st:-1_0,sums c+1;
  s:"\n" sv lines;
  nw:where not s in WS;
  k:nw binr st;
  p1:nw k; p2:nw k+1;
  blank:(null p1) or p1>=st+c;
  fc:?[blank; " "; s p1];
  single:(not blank) and (p1=st) and (null p2) or p2>=st+c;
  `col0`fc`blank`single!(?[0<c; s st; " "]; fc; blank; single)};

ignoredLines:{[lines]
  if[0=count lines; :0];
  li:lineInfo lines;
  first0:(count lines)^first where not li[`col0] in "\t /";
  0^1+last where not first0#li[`blank] or "/"=li`fc};

/ "/" alone opens a block comment, "\" alone closes it, and "\" alone outside one ends the script. Lines
/ inside become "// " comments; the marker lines go.
blockComments:{[lines]
  n:count lines;
  if[0=n; :lines];
  li:lineInfo lines;
  isOpen:li[`single] and "/"=li`fc; isClose:li[`single] and "\\"=li`fc;
  marks:where isOpen or isClose;
  if[0=count marks; :lines];
  commented:n#0b; drop:`long$(); inBlock:0b; start:0N; i:0;
  while[i<count marks;
    m:marks i;
    $[inBlock;
      if[isClose m; inBlock:0b; drop,:m; commented[start+til m-start]:1b];
      isOpen m; [inBlock:1b; drop,:m; start:m+1];
      [drop,:m; commented[(m+1)+til n-m+1]:1b; i:count marks]];
    i+:1];
  if[inBlock; commented[start+til n-start]:1b];
  lines:@[lines; where commented; "// ",];
  lines where not (til n) in drop};

/ An indented line, a blank line or a comment line continues the logical line above it; a run of comment
/ and blank lines at the end of a logical line is split off, one line each.
logicalLines:{[lines]
  if[0=count lines; :()];
  li:lineInfo lines;
  blank:li`blank; comment:"/"=li`fc;
  cont:comment or li[`col0] in "\t ";
  starts:distinct 0,where not cont;
  g:-1+sums (til count lines) in starts;               / logical line of each line
  v:comment or blank;
  lastFirm:@[count[starts]#-1; g where not v; :; where not v];
  trailing:v and (til count lines)>lastFirm g;
  breaks:asc distinct 0,starts,where trailing;
  "\n" sv/: breaks cut lines};

/ ---------- 2. statements: comments, code, name ----------
/ Drop everything before the line holding the first "/", keeping that line's indent.
trimComment:{[c]
  s:first where c="/";
  if[null s; :""];
  (0^1+last where "\n"=s#c) _ c};

/ One logical line of code -> (name; code; codeType). An assignment to a name as the first statement makes
/ an item; its code is the source after the ":" or "::". Decided from -4!'s tokens alone: native parse is
/ stricter than kx.ax's parser about names (a reserved word as a column name) and resolves builtins written
/ in q (use, each) to their lambdas, so it answers kx.ax's question differently.
classify:{[text]
  if["\\"=first text; :(""; text; `command)];
  if["k)"~2#text; :(""; text; `k)];
  t:@[-4!; text; {()}];
  if[not (0h=type t) and 0<count t; :(""; text; `unparsed)];
  / brackets are always one-character tokens: ch holds each token's character, or a blank if it is longer
  ch:@[count[t]#" "; w; :; raze t w:where 1=count each t];
  / a statement kx.ax's parser couldn't parse is no item: unbalanced brackets are the sign of one
  if[not (sum each ch=/:"([{")~sum each ch=/:")]}"; :(""; text; `unparsed)];
  / nor is a lambda that starts with an adverb: "{/ c" has no blank before the "/", so q reads it as over,
  / not a comment, and refuses the lambda
  if[any (ch="{") and (1_ch,"x") in "/\\"; :(""; text; `unparsed)];
  i0:skipTok[t; 0; 0b]; i1:skipTok[t; i0+1; 0b];
  if[i1>=count t; :(""; text; `data)];
  if[not isName t i0; :(""; text; `data)];
  if[not any (t i1)~/:(enlist ":";"::"); :(""; text; `data)];
  j:skipTok[t; i1+1; 1b];
  if[j>=count t; :(""; text; `data)];
  start:(sum count each (i1+1)#t);
  (t i0; trimL start _ text; $[fnTokens[j _ t; j _ ch]; `function; `data])};

/ The index of the first token from i on that isn't blank (nor a comment, when comments is true).
skipTok:{[t; i; comments]
  while[i<count t;
    x:t i;
    if[not isBlankTok[x] or comments and isCommentTok x; :i];
    i+:1];
  i};

isBlankTok:{[x] all x in WS};
isCommentTok:{[x] ("/"=first trimL x) and not any x~/:(enlist"/";"/:")};
isName:{[x] ((first x) in .Q.a,.Q.A,".") and (all x in .Q.an,".") and not (`$x) in .Q.res};
/ The q keywords written between their two arguments. After a value, one of these is the root of the
/ expression (so a lambda before it is an argument, not the value); any other name is applied to. Written
/ out rather than computed from .q, so that the parse doesn't move with the q release.
INFIX:`mod`xbar`xlog`and`or`each`scan`over`prior`mmu`lsq`scov`msum`mcount`mavg`mdev`xrank`mmin`mmax`xprev,
  `rotate`ema`cut`set`inter`except`cross`sv`vs`sublist`peach`xcols`xkey`xcol`xasc`xdesc`ij`ijf`pj`asof,
  `uj`ujf`fby`xgroup`bin`binr`cor`cov`div`in`insert`like`ss`wavg`within`wsum`xexp`union`upsert`lj`ljf,
  `aj`aj0`ajf`ajf0`ej`ww`wj`wj1`setenv;

/ A noun can follow a value and be applied to it: a name that isn't an infix keyword, a number (negative
/ too), a string, a symbol or an opening parenthesis.
isNoun:{[f]
  c:first f;
  $[c in .Q.a,.Q.A; not (`$f) in INFIX;
    c in "0123456789`\"("; 1b;
    c="."; (1<count f) and (f 1) in .Q.a,.Q.A;
    c="-"; (1<count f) and (f 1) in "0123456789";
    0b]};

/ kx.ax calls a value a function when the root of its parse tree is a lambda, or a lambda applied to
/ arguments. In tokens: a lambda, then only bracketed arguments, then the end of the first statement or a
/ noun it is applied to (q reads right to left, so a verb, adverb or keyword there is the root instead).
fnTokens:{[r; ch]
  if[not "{"=first ch; :0b];
  if[null c:first where 0=sums (ch="{")-ch="}"; :0b];
  k:skipTok[r; c+1; 1b];
  while["["=ch k;
    if[null c:first where 0=sums ((k _ ch)="[")-(k _ ch)="]"; :0b];
    k:skipTok[r; k+c+1; 1b]];
  if[k>=count r; :1b];
  f:r k;
  if[(enlist";")~f; :1b];
  isNoun f};

/ The namespace a statement switches to, or "": kx.ax's \d and system "d ..." rules, which look at every
/ line start of the statement. system "d ..." wins over \d. The system form keeps kx.ax's arithmetic: it
/ drops ten characters from the match, so only `system "d .ns"` with single spaces reads cleanly.
contextOf:{[s]
  ls0:lower s;
  if[(0=count ls0 ss "\\d") and 0=count ls0 ss "system"; :""];
  ls:"\n" vs s;
  sl:{[i;l]
    if[not startsWith[lower l; "system"]; :""];
    r:trimL 6_l; off:count[l]-count r;
    if[not startsWith[lower r; "\"d"]; :""];
    rest:2_r; c:rest?"\"";
    if[(c<2) or (c=count rest) or not (first rest) in WS; :""];
    m:$[i>0; "\n"; ""],(off+3+c)#l;
    trimL -1_10_m}'[til count ls; ls];
  if[count w:where 0<count each sl; :sl first w];
  dl:{[l] $[(2<count l) and ("\\"=l 0) and ("d"=lower l 1) and (l 2) in WS;
      [r:trimL 2_l; $[(0<count r) and not (first r) in "\t /"; (min r?"\t ")#r; ""]]; ""]} each ls;
  if[count w:where 0<count each dl; :dl first w];
  ""};

/ A file's text -> its statements: (context; name; code; codeType; switch), in source order. Namespace
/ switches are rows too (switch), so the file record can report the comments kx.ax drops with them.
statementsAll:{[text]
  lines:"\n" vs ssr[text; "\r\n"; "\n"];
  lines:ignoredLines[lines] _ lines;
  lines:logicalLines blockComments lines;
  if[0=count lines; :([] context:(); name:(); code:(); codeType:`$(); switch:`boolean$())];
  li:lineInfo lines;
  isCode:not ("/"=li`fc) or li`blank;
  breaks:distinct 0,-1_1+where isCode;
  comments:{[lines;isCode;g] "\n" sv lines g where not isCode g}[lines;isCode] each breaks cut til count lines;
  comments:trimComment each comments,\:"\n";
  code:lines where isCode;
  tab:$[0=count code;
    ([] name:enlist ""; code:comments; codeType:enlist `data);
    [c:classify each code; ([] name:c[;0]; code:comments,'c[;1]; codeType:c[;2])]];
  / only a file that mentions \d or system can switch namespace
  lt:lower text;
  ctx:$[(0<count lt ss "\\d") or 0<count lt ss "system"; contextOf each tab`code; count[tab]#enlist ""];
  sw:0<count each ctx;
  cs:fills @[count[ctx]#`; where sw; :; `$ctx where sw];
  cs:@[string cs; where null cs; :; count[where null cs]#enlist enlist "."];
  `context xcols update context:cs, switch:sw from tab};
/ The statements kx.ax reads for items: namespace switches set the context and are gone.
noSwitch:{[t] (cols[t] except `switch)#t where not t`switch};

/ ---------- 3. embedded docs: @kind blocks ----------
/ A comment line holding @kind and one of its values (kx.ax's TAG_KIND), case-insensitive: the value, or "".
commentRest:{[l] r:(sum mins l in "\t ") _ l; $["/"=first r; [r:(sum mins r in "/*") _ r; (sum mins r in "\t ") _ r]; ""]};
KINDS:("function";"data";"readme";"file");
/ kx.ax's TAG_KIND match on one line: blanks, "/" then any run of "/" and "*", blanks, "@kind" (any case),
/ at least one blank, then one of the kinds (any case, with no word boundary after it).
/ -> (kind; index just past the match), or ("";0).
kindAt:{[l]
  sk:{[l;i;cs] i+sum mins (i _ l) in cs};
  i:sk[l;0;"\t "];
  if[not "/"=l i; :("";0)];
  i:sk[l;i;"/*"]; i:sk[l;i;"\t "];
  if[not "@kind"~lower 5#i _ l; :("";0)];
  i+:5;
  if[not (l i) in "\t "; :("";0)];
  i:sk[l;i;"\t "];
  m:KINDS where startsWith[lower i _ l] each KINDS;
  $[count m; (first m; i+count first m); ("";0)]};
kindWord:{[l] first kindAt l};
isKindLine:{[l] 0<count kindWord l};
isEndLine:{[l] startsWith[lower commentRest l; "@end"]};
/ The kind kx.ax gives an embedded block: the last space-separated word of its first line's @kind match,
/ so a tab before the kind gives no kind at all.
blockKind:{[s] k:kindAt first "\n" vs s; $[0=count k 0; `; `$last " " vs k[1]#first "\n" vs s]};

/ Split a header from what follows: at the first line starting (after blanks) with "{", else at the first
/ line not starting with "/" (a blank or indented line counts), else nothing follows. -> (header; rest)
splitHeader:{[s]
  if[0=count s; s:"{[]}"];
  ls:"\n" vs s;
  starts:-1_0,sums 1+count each ls;
  t:{(sum mins x in "\t ") _ x} each ls;
  i:first where "{"=t[;0];
  / a final empty line (the text ends with a newline) is no line to kx.ax
  / a line that starts with a blank also ends the header, comment or not: kx.ax's ^\h*[^/] lets [^/]
  / match the blank
  if[null i; i:first where not ("/"=first each ls) or ((til count ls)=count[ls]-1) and 0=count each ls];
  $[null i; (s; s); (starts[i] # s; starts[i] _ s)]};

/ Re-cut a file's statements at embedded @kind lines, as kx.ax does when any statement in the file has one.
embedded:{[st]
  st:select from st where codeType in `function`data;
  if[0=count st; :st];
  / most files have no @kind at all: then nothing is re-cut
  if[all 0=count each (lower each st`code) ss\: "@kind"; :st];
  codeLines:{x where not ""~/:x} each "\n" vs/: st`code;
  kinds:{where isKindLine each x} each codeLines;
  if[all 0=count each kinds; :st];
  none:0=count each kinds;
  codeLines:@[codeLines; where none; {[x;t] enlist["// @kind ",string t],x}; st[`codeType] where none];
  kinds:@[kinds; where none; :; count[where none]#enlist enlist 0];
  blocks:kinds _' codeLines;
  pieces:{[nm;b] ("\n" sv/: -1_b),splitBlock[nm; last b]}'[st`name; blocks];
  new:c where not ""~/:c:raze -1_/:pieces;
  newKind:blockKind each new;
  ([] context:count[new]#enlist enlist "."; name:count[new]#enlist "README"; code:new; codeType:newKind),
    update code:last each pieces from st};

splitBlock:{[nm; block]
  s:"\n" sv block;
  k:kindWord first block;
  if[any k~/:("function";"data");
    :$[""~nm; splitHeader s; enlist s]];
  if[count e:where isEndLine each block; :"\n" sv/: (0,1+e) _ block];
  splitHeader s};

/ ---------- 4. names, modules, categories ----------
modName:{[m; nm] $[(0<count m) and startsWith[nm; m,"."]; m; ".",first "." vs 1_nm]};
moduleOf:{[fileMod; ctx; nm]
  noCtx:(enlist ".")~ctx;
  $[isFq nm; $[noCtx; modName[fileMod; nm]; modName[ctx; nm]]; $[noCtx; fileMod; ctx]]};

toCat:{[md]
  m:1_` vs md;
  $[isFq string md; (first m; $[0=count 1_m; `; ` sv 1_m]); (`Global; md)]};

/ A file (its root-relative name and text) -> its items, in kx.ax's order.
fileItems:{[tmap; path; text] itemsOf[tmap; path; statementsAll text]};
/ The same, from the file's statementsAll, which the file record's errors share.
itemsOf:{[tmap; path; st] r:itemRows[path; st]; r,'([] tags:tagBlock[tmap] each r`content)};
/ The items without their tags, which the file record's errors need no more than.
itemRows:{[path; st]
  / kx.ax's file module: the file's directory, root-relative ("" at the root)
  fileMod:$[count w:where path="/"; (last w)#path; ""];
  st:embedded noSwitch st;
  st:select from st where 0<count each name, codeType in `function`data`readme;
  if[0=count st; :(cols[ITEMS] except `tags)#ITEMS];
  mods:moduleOf[fileMod]'[st`context; st`name];
  rel:not isFq each st`name;
  glob:not isFq each mods;
  ref:?[rel and not glob; "." sv/: flip (mods; st`name); st`name];
  nm:?[rel; st`name; {last (x,".") vs y}'[mods; st`name]];
  cat:toCat each `$mods;
  ([] ref:`$ref; name:`$nm; kind:st`codeType; module:`$mods; category:cat[;0]; subcategory:cat[;1];
    content:st`code)};

/ ---------- 5. tags ----------
/ The comment lines of a header, with the comment marker cut off (kx.ax keeps the space after it).
headerComments:{[h]
  ls:"\n" vs h;
  ls:ls where {"/"=first (sum mins x in "\t ") _ x} each ls;
  {r:(sum mins x in "\t ") _ x; (sum mins r in "/*") _ r} each ls};

/ A line's tag: "@" then [a-zA-Z:-]*, ending at a word boundary, after optional blanks. -> (tag; rest), or ().
WORD:.Q.an;
TAGCH:.Q.a,.Q.A,":-";
tagOf:{[l]
  i:sum mins l in "\t ";
  if[not "@"=l i; :()];
  n:count l;
  j:i+1+sum mins (i+1) _ l in TAGCH;
  / back off to the last position that is a word boundary (regex \b, which a tag at line end also has)
  wb:{[l;n;p] a:$[p>0; (l p-1) in WORD; 0b]; b:$[p<n; (l p) in WORD; 0b]; a<>b}[l;n];
  while[(j>i) and not wb j; j-:1];
  if[j<=i; :()];
  (lower i _ j#l; j _ l)};

/ kx.ax's default tag map: the identity over qdoc's vocabulary, as kx.ax builds it ({x!x} distinct raze
/ data.TAGS). kx.ax writes @public with a leading space; q's symbol cast drops it, so @public is mapped.
VOCAB:`$("@fileoverview";"@overview";"@kind";"@name";"@end";"@category";"@default-category";"@subcategory";
  "@default-subcategory";"@author";"@private";"@deprecated";"@ignore";"@param";"@throws";"@returns";"@return";
  "@type";"@typedef";"@typedef:private";"@req";"@desc";"@default";"@example";"@format";"@doctest";"@see";
  "@todo";"@atype";" @public";"@connection";"@alias";"@typ";"@datatype";"@datatype:private";"@extends";
  "@field";"@mutable";"@inject");
/ A consumer's tagmap -> the map tags go through (kx.ax's addTagmap): the default extended by it, keys and
/ values lower-cased with "@". With no tagmap, tags keep their names: the map is the identity, ::.
tagMap:{[settings]
  if[not `tagmap in key settings; :(::)];
  m:settings`tagmap;
  if[not 99h=type m; '"tagmap: invalid type, expecting a dictionary"];
  norm:{lower `${$["@"=first x; x; "@",x]} each {$[10h=type x; x; -11h=type x; string x; -10h=type x; enlist x; string x]} each x};
  m:(norm key m)!norm value m;
  (VOCAB!VOCAB),m};

tagBlock:{[tmap; content]
  ls:headerComments first splitHeader content;
  if[0=count ls; :([] lines:(); tagType:`$())];
  tg:tagOf each ls;
  isTag:0<count each tg;
  blk:sums isTag;
  b:distinct blk;
  rows:{[tmap;ls;tg;isTag;blk;k]
    w:where blk=k;
    $[isTag first w;
      (enlist[last tg first w],ls 1_w; $[(enlist"@")~first tg first w; `; tmap `$first tg first w]);
      (ls w; `)]}[tmap;ls;tg;isTag;blk] each b;
  t:([] lines:rows[;0]; tagType:rows[;1]);
  t:mutable t;
  / a @desc before the first @param, @returns, @return or @type becomes @overview
  io:first where t[`tagType] in `$("@param";"@returns";"@return";"@type");
  d:where t[`tagType]=`$"@desc";
  if[count d:d where d<0W^io; t:update tagType:`$"@overview" from t where i in d];
  t};

/ After a multi-line @mutable with no {type} on its first line, only that first line is kept (kx.ax KXAX-10002).
mutable:{[t]
  w:where (t[`tagType]=`$"@mutable") and 1<count each t`lines;
  if[0=count w; :t];
  t[`lines;w]:{$[2<>count x[0] ss "[{}]"; enlist first x; x]} each t[`lines] w;
  t};

/ ---------- 6. files ----------
endsWith:{[s;x] x:(),x; (neg[count x]#s)~x};
/ kx.ax's file filter: names ending .q, README or README.md, case-insensitively.
isDocFile:{[p] s:lower string p; any endsWith[s] each (".q";"readme";"readme.md")};

walk:{[recursive; path]
  k:key path;
  $[11h=type k;
    [ps:` sv/: path,/:k;
     $[recursive; raze .z.s[recursive] each ps; ps where isDocFile each ps]];
    -11h=type k; $[isDocFile path; enlist path; `$()];
    `$()]};

relName:{[root; f]
  r:string f; p:string root;
  r:$[11h=type key root; last (1_p) vs 1_r; 1_r];
  $[startsWith[r; "./"]; 2_r; startsWith[r; "/"]; 1_r; r]};

ITEMS:([] ref:`$(); name:`$(); kind:`$(); module:`$(); category:`$(); subcategory:`$(); content:(); tags:());

/ A file's text as kx.ax reads it ("\n" sv read0): read1, less one trailing newline.
readText:{[f] s:"c"$read1 f; $["\n"=last s; -1_s; s]};

/ kx.ax names a readme after its directory alone: "<dir>/README" (README at the root), whatever its case
/ and whether or not it ends .md. Its pattern is (.|/)?README(\.md)?$, caseless: the text before that match,
/ in the name's last two parts, is the directory.
isReadme:{[r] l:lower r; endsWith[l; "readme"] or endsWith[l; "readme.md"]};
readmeRef:{[r]
  p:"/" vs r; s:"/" sv neg[2&count p]#p;              / -2# would wrap a one-part name
  k:$[endsWith[lower s; "readme.md"]; 9; 6];
  m:neg[k+k<count s]#s;
  i:first where m~/:(count m)#/:(til count s)_\:s;
  d:i#s;
  $[startsWith[d,"/README"; "/"]; 1_d,"/README"; d,"/README"]};
getFiles:{[recursive; paths]
  paths:(),paths;
  rows:raze {[recursive; p] f:walk[recursive; p]; ([] name:`${$[isReadme x; readmeRef x; x]} each relName[p] each f; kind:`file; content:readText each f)}[recursive] each hsym paths;
  rows};

/ kx.ax's settings keys, and its renderers' flags, which it also accepts: anything else is refused by name.
SETTINGS:`out`errFile`preprocessors`exclude`group`idstyle`docprivate`docempty`doctodo`doctest`doctypedef,
  `recursive`write`sanitizeURL`checkParams`resolve`mdDir`htmlDir`tagmap`defaults`preMarkdownHook,
  `jsscripts`config`index`assets`sitename;

/ settings: a dictionary, or an empty or null one for the defaults (as kx.ax's sanitize.settings has it).
checkSettings:{[settings]
  if[(settings~(::)) or 0=count settings; :()!()];
  if[not 99h=type settings; '"settings: invalid type, expecting a dictionary"];
  settings:(enlist `)_settings;
  if[count bad:(key settings) except SETTINGS; '"settings: invalid flag(s): ",", " sv string bad];
  settings};

/ kx.ax's exclude: a like pattern, or (`like; pattern), matched against file paths and item refs. -> the
/ pattern, or "" for none. (`regex; pattern) needs a regex library, which kx.ax.qdocparser doesn't use.
excludeOf:{[settings]
  if[not `exclude in key settings; :""];
  e:settings`exclude;
  if[(e~"") or e~(::); :""];
  if[10h=type e; :e];
  if[`like~first e; :e 1];
  if[`regex~first e; '"exclude: a regex pattern needs a regex library, which kx.ax.qdocparser doesn't use; give a like pattern"];
  '"exclude: invalid option, expecting like or regex"};

/ src: a path symbol or string, a list of them, or an items table (name; kind; content).
toFiles:{[settings; src]
  if[98h=type src;
    if[not all `name`kind`content in cols src; '"src: an items table needs the columns name, kind and content"];
    :select from src where kind=`file];
  ps:$[10h=type src; enlist `$src; -11h=type src; enlist src;
    (0h=type src) and all 10h=type each src; `$src; 11h=type src; src;
    '"src: expecting a symbolic file/directory path or a table of items"];
  if[count missing:ps where {()~key hsym x} each ps; '"src: no such file or directory: ",", " sv string missing];
  r:$[`recursive in key settings; settings`recursive; 1b];
  getFiles[r; ps]};

items:{[settings; src]
  settings:checkSettings settings;
  f:toFiles[settings; src];
  / .q files only, as aimeta reads them; the suffix is case-sensitive, as in kx.ax
  f:`name xasc select from f where {".q"~-2#string x} each name;
  ex:excludeOf settings;
  if[count ex; f:select from f where not name like ex];
  if[0=count f; :ITEMS];
  r:raze fileItems[tagMap settings]'[string f`name; f`content];
  $[count ex; select from r where not ref like ex; r]};

/ ---------- 7. file records ----------
/ A file's header: the comment block it starts with (after any blank lines), when a blank line, a
/ statement that defines nothing, or the end of the file follows it. Directly above a definition the
/ block is the definition's, and there is no header. -> the header's text, or "".
headerText:{[text]
  lines:blockComments "\n" vs ssr[text; "\r\n"; "\n"];
  if[0=count lines; :""];
  li:lineInfo lines;
  s:first where not li`blank;
  if[null s; :""];
  if[not "/"=li[`fc] s; :""];
  e:s+sum mins (s _ "/"=li`fc) and not s _ li`blank;
  h:"\n" sv s _ e#lines;
  if[e=count lines; :h];
  if[li[`blank] e; :h];
  $[0=count first classify first logicalLines e _ lines; h; ""]};

FILES:([] file:`$(); module:`$(); header:(); error:());
ERRORS:([] ref:`$(); qdType:`$(); errorType:`$(); error:());

/ A statement's first line of code: the line that names it in an error.
codeLine:{[x] l:"\n" vs x; first l where not "/"=first each trimL each l};
hasTag:{[code] any 0<count each tagOf each headerComments first splitHeader code};
isMalformed:{[l] ("@"=first trimL l) and {(0=count x) or (enlist"@")~first x} tagOf l};
/ Whether kx.ax re-cuts the file at embedded @kind lines (see embedded).
reCut:{[st] c:st[`code] where st[`codeType] in `function`data;
  c:c where 0<count each (lower each c) ss\: "@kind";
  any {any isKindLine each "\n" vs x} each c};

/ The problems in one file that kx.ax passes over silently, in kx.ax's error shape:
/ - PARSE_ERROR: a statement kx.ax's parser can't parse, and so skips;
/ - UNBOUND_TAGS: a tag block, other than the file header, above a statement that is no definition (an
/   indexed assignment such as f[`k]:{..} included) or a namespace switch, which kx.ax drops (in a file re-cut at @kind lines, only above a namespace switch);
/ - MALFORMED_TAG: a line of an item's documentation that starts with @ but names no tag, which kx.ax
/   reads as text, against the item.
fileErrors:{[tm; path; text]
  st:statementsAll text;
  u:select from st where not switch, codeType=`unparsed;
  pe:([] ref:count[u]#`$path; qdType:`statement; errorType:`PARSE_ERROR;
    error:{"kx.ax's parser can't parse this statement (q doesn't accept it), so it is skipped: ",80 sublist codeLine x} each u`code);
  item:(0<count each st`name) and st[`codeType] in `function`data;
  cand:st[`switch] or $[reCut noSwitch st; 0b; not item or st[`codeType]=`unparsed];
  cand:cand and not st[`codeType]=`unparsed;
  if[0<count headerText text; cand[0]:0b];
  b:st where cand and "@" in/: st`code;
  b:b where hasTag each b`code;
  ub:([] ref:count[b]#`$path; qdType:`block; errorType:`UNBOUND_TAGS;
    error:{"A tag block above a statement that is no definition (an assignment to a name) is bound to no item, and kx.ax drops it: ",80 sublist codeLine x} each b`code);
  its:itemRows[path; st];
  / only an item with an "@" not followed by a letter can hold a malformed tag
  its:its where {w:where x="@"; any not x[w+1] in .Q.a,.Q.A} each its`content;
  bad:{headerComments first splitHeader x} each its`content;
  bad:bad@'where each isMalformed each' bad;
  n:count each bad;
  mt:([] ref:raze n#'its`ref; qdType:`tag; errorType:`MALFORMED_TAG;
    error:{"This line starts with @ but names no tag (a tag name is letters, ':' and '-'), so it is read as text: ",80 sublist trimL x} each raze bad);
  ERRORS,pe,ub,mt};

/ The documentation generator's input: what kx.ax's qd.doc hands its renderer (i.doc), so that kx.ax can
/ render from this parse. kx.ax's order: the readme files first, by name, as rows of kind file, then the
/ items, without tags (the renderer reads them from content), and last each row's parameters (paramsOf).
/ exclude isn't applied: the renderer applies it.
DOCCOLS:`ref`name`kind`module`category`subcategory`content;
/ The parameters kx.ax's getParams finds in a piece of code (an item's content, or a whole file's): in its
/ body, the code after its header, the names in the parameter list of the lambda the body starts with
/ (blanks, newlines and comments may come between the brace and the list),
/ blanks trimmed and empty names dropped. A list of strings; () when the body doesn't start, at its first
/ character, with a lambda that has a non-empty list.
/ Past blanks, newlines and comments: a comment is a "/" after a blank, to the end of its line (q's rule;
/ a "/" straight after the brace is q's over, and the lambda no item).
skipBlanks:{[b] w:sum mins b in WS; r:w _ b; $[(w>0) and "/"=first r; .z.s (r?"\n") _ r; r]};
parameters:{[code]
  / no trim: a body that starts with a blank (an indented lambda in a whole file, say) has none in kx.ax
  b:last splitHeader code;
  if[not "{"=first b; :()];
  b:skipBlanks 1_b;
  if[not "["=first b; :()];
  e:b?"]";
  if[e=count b; :()];
  n:trimL each trimR each ";" vs 1_e#b;
  $[count n:n where 0<count each n; n; ()]};
/ An item's parameters: a function's, as above; () for data and readmes.
paramsOf:{[kind; content] $[kind=`function; parameters content; ()]};
docItems:{[settings; src]
  settings:checkSettings settings;
  f:toFiles[settings; src];
  rd:`name xasc select from f where not {".q"~-2#string x} each name;
  r:string rd`name;
  mods:{$[count w:where x="/"; (last w)#x; ""]} each r;
  cat:toCat each `$mods;
  rd:([] ref:rd`name; name:`${$[count x; 1_(count x)_y; y]}'[mods; r]; kind:rd`kind; module:`$mods;
    category:cat[;0]; subcategory:cat[;1]; content:rd`content);
  it:DOCCOLS#items[(key[settings] except `exclude)#settings; f];
  r:rd,it;
  r,'([] parameters:paramsOf'[r`kind; r`content])};

/ The file record: one row per .q file of src, in path order (the parse result's second table).
files:{[settings; src]
  settings:checkSettings settings;
  f:toFiles[settings; src];
  f:`name xasc select from f where {".q"~-2#string x} each name;
  ex:excludeOf settings;
  if[count ex; f:select from f where not name like ex];
  if[0=count f; :FILES];
  tm:tagMap settings;
  p:string f`name;
  ([] file:f`name; module:`${$[count w:where x="/"; (last w)#x; ""]} each p;
    header:{[tm;t] h:headerText t; $[0=count h; ([] lines:(); tagType:`$()); tagBlock[tm; h]]}[tm] each f`content;
    error:fileErrors[tm]'[p; f`content])};

/ APPEND new exports: consumers may key this dict positionally.
export:`getFiles`items`files`docItems`parameters!(getFiles; items; files; docItems; parameters);
