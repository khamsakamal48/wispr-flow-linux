#!/usr/bin/env bash
#===============================================================================
# patch-linux-tray-glyph.sh -- give the Linux tray a monochrome glyph tinted to
# the desktop theme, instead of the full-colour app logo.
#
# WHY THIS PATCH EXISTS
# ---------------------
# The tray picks its image with
#   const e=isMac?"TrayIconMac@2x.png":"TrayIconWindows.png",
#         t=nativeImage.createFromPath(<root>+<dir>+e);
#   t.setTemplateImage(!0);const n=new Tray(t);
# so Linux gets TrayIconWindows.png: the logo on a dark rounded square, which
# clashes with every symbolic glyph around it in a Linux panel. The macOS file
# is the right shape (a white waveform template), but setTemplateImage() is a
# no-op off macOS, so nothing tints it: white vanishes on a light panel. And
# StatusNotifierItem hosts draw Electron's IconPixmap as-is (quickshell bars
# like Ryoku's do not recolour pixmaps). The glyph is also 30px of ink on a
# 32px canvas, so hosts that fill a 16px slot draw it larger than its
# neighbours, whose symbolic icons carry their own margin.
#
# THE PATCH
# ---------
# Right after `const n=new Tray(t);`, on Linux only:
#   * load TrayIconMac@2x.png and recolour its ink. The colour is the panel's
#     own icon colour when the shell publishes one: Ryoku writes its live
#     wallpaper palette to ~/.cache/ryoku/colors.json and draws bar glyphs in
#     `onSurface`. Otherwise white (dark theme) or dark grey (light theme)
#     from nativeTheme.shouldUseDarkColors (the XDG portal color-scheme).
#     Ryoku's palette can disagree with the portal (a light wallpaper palette
#     under a dark system theme), which is why the file wins;
#   * re-centre it on a 1.375x canvas (32 -> 44px, the ratio that matched the
#     neighbouring glyphs on a quickshell bar) -- padding only, no resampling;
#   * n.setImage() it, and again on nativeTheme "updated" and whenever
#     colors.json is rewritten (fs.watch on its directory, since the file is
#     replaced rather than edited).
# The bitmap is premultiplied BGRA, so each channel is colour*alpha/255.
#
# Anchor: the createFromPath -> setTemplateImage(!0) -> new Tray sequence,
# with the image/electron/tray identifiers captured, exactly one match. The
# macOS and Windows paths are untouched.
#
# Usage: linux-tray-glyph.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "usage: $0 <.webpack/main/index.js>" >&2
  exit 2
fi

python3 - "$BUNDLE" <<'PY'
import re, shutil, sys

path = sys.argv[1]
src = open(path, 'r', encoding='utf-8', errors='surrogateescape').read()

MARKER = 'WISPR_LINUX_TRAY_GLYPH'
if MARKER in src:
    print("Already patched (marker %s present). Nothing to do." % MARKER)
    sys.exit(0)

anchor = re.compile(
    r'(?P<img>[\w$]+)=(?P<el>[\w$]+)\.nativeImage\.createFromPath'
    r'\((?P<path>[^()]+)\);(?P=img)\.setTemplateImage\(!0\);'
    r'const (?P<tray>[\w$]+)=new (?P=el)\.Tray\((?P=img)\);'
)
ms = list(anchor.finditer(src))
if len(ms) != 1:
    sys.exit("ERROR: expected exactly 1 tray-creation anchor, found %d."
             % len(ms))
m = ms[0]
tray = m.group('tray')

inject = (
    'if("linux"===process.platform){/*' + MARKER + '*/'
    'const{nativeImage:_wI,nativeTheme:_wT}=require("electron"),'
    '_wfs=require("fs"),_wpa=require("path"),'
    '_wP=(' + m.group('path') + ')'
    '.replace("TrayIconWindows.png","TrayIconMac@2x.png"),'
    '_wF=_wpa.join(process.env.XDG_CACHE_HOME||'
    '_wpa.join(require("os").homedir(),".cache"),"ryoku","colors.json"),'
    '_wC=()=>{try{const h=JSON.parse(_wfs.readFileSync(_wF,"utf8")).onSurface;'
    'if(/^#[0-9a-f]{6}$/i.test(h))return[1,3,5].map(i=>parseInt(h.substr(i,2),16))}'
    'catch(e){}const v=_wT.shouldUseDarkColors?255:48;return[v,v,v]},'
    '_wG=()=>{const b=_wI.createFromPath(_wP).toBitmap({scaleFactor:2}),'
    'w=Math.round(Math.sqrt(b.length/4));if(!w)return null;'
    'const C=Math.round(1.375*w),o=Buffer.alloc(C*C*4),d=C-w>>1,[R,G,B]=_wC();'
    'for(let y=0;y<w;y++)for(let x=0;x<w;x++){'
    'const i=4*(y*w+x),j=4*((y+d)*C+x+d),a=b[i+3];'
    'o[j]=B*a/255|0;o[j+1]=G*a/255|0;o[j+2]=R*a/255|0;o[j+3]=a}'
    'return _wI.createFromBitmap(o,{width:C,height:C})},'
    '_wS=()=>{const g=_wG();g&&!' + tray + '.isDestroyed()&&'
    + tray + '.setImage(g)};'
    '_wS();_wT.on("updated",_wS);'
    'try{_wfs.watch(_wpa.dirname(_wF),(e,f)=>{"colors.json"===f&&setTimeout(_wS,300)})}'
    'catch(e){}}'
)
patched = src[:m.end()] + inject + src[m.end():]

shutil.copyfile(path, path + ".trayglyph.orig")
print("Backup written:", path + ".trayglyph.orig")
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(patched)
print("OK: Linux tray glyph inserted after `new Tray(...)` (tray var %r)."
      % tray)
PY

if command -v node >/dev/null; then
  if ! node --check "$BUNDLE"; then
    echo "ERROR: node --check failed. Restoring backup." >&2
    cp -p "$BUNDLE.trayglyph.orig" "$BUNDLE"
    exit 1
  fi
  echo "node --check OK"
fi
