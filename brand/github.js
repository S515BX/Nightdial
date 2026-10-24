// GitHub page art: a wide banner for the README (also usable as the repo's social preview image).
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
const DIR = __dirname, OUT = path.join(DIR, '..', 'docs');
fs.mkdirSync(OUT, { recursive: true });
const svg = fs.readFileSync(path.join(DIR, 'icon.svg'), 'utf8');
const font = f => 'data:font/ttf;base64,' + fs.readFileSync('/home/claude/fonts/subset/' + f).toString('base64');
const html = (w, h) => `<!doctype html><html><head><style>
@font-face{font-family:P;font-weight:600;src:url(${font('Poppins-SemiBold.ttf')})}
@font-face{font-family:P;font-weight:400;src:url(${font('Poppins-Regular.ttf')})}
body{margin:0}
.b{position:relative;width:${w}px;height:${h}px;overflow:hidden;font-family:P;color:#fff;box-sizing:border-box;
  background:radial-gradient(ellipse at 8% 0%,rgba(76,201,240,.42),transparent 50%),radial-gradient(ellipse at 100% 115%,rgba(255,107,139,.40),transparent 55%),linear-gradient(135deg,#20253a,#121521 58%,#0d0f17)}
.stars i{position:absolute;width:3px;height:3px;border-radius:50%;background:#fff;opacity:.5}
.row{position:absolute;left:${w * .07}px;top:50%;transform:translateY(-50%);display:flex;align-items:center;gap:${w * .04}px}
.ic{width:${h * .5}px;height:${h * .5}px;border-radius:${h * .12}px;overflow:hidden;flex:none;box-shadow:0 ${h * .04}px ${h * .12}px rgba(0,0,0,.5),0 0 0 2px rgba(255,255,255,.08)}
.ic svg{width:100%;height:100%;display:block}
h1{margin:0;font-weight:600;font-size:${h * .17}px;line-height:1;letter-spacing:-.015em}
.tag{margin-top:${h * .035}px;font-weight:600;font-size:${h * .052}px;letter-spacing:.2em;text-transform:uppercase;color:#9fe9d6}
.sub{margin-top:${h * .045}px;font-weight:400;font-size:${h * .045}px;color:rgba(255,255,255,.72)}
.chips{margin-top:${h * .05}px;display:flex;gap:${h * .02}px}
.chips span{padding:${h * .014}px ${h * .03}px;border-radius:99px;background:rgba(255,255,255,.09);box-shadow:inset 0 0 0 1px rgba(255,255,255,.1);font-size:${h * .036}px;color:rgba(255,255,255,.85)}
</style></head><body><div class="b">
<div class="stars">${Array.from({ length: 40 }, (_, i) => `<i style="left:${(i * 37 % 100)}%;top:${(i * 53 % 100)}%;opacity:${(.15 + (i * 7 % 10) / 25).toFixed(2)};transform:scale(${(.5 + (i * 3 % 5) / 5).toFixed(2)})"></i>`).join('')}</div>
<div class="row"><div class="ic">${svg}</div><div>
<h1>Nightdial</h1><div class="tag">Live TV guide</div>
<div class="sub">Xtream Codes &amp; M3U · full TV guide · movies &amp; series · pause &amp; rewind</div>
<div class="chips"><span>Fire TV</span><span>iPhone</span><span>iPad</span><span>Web</span></div>
</div></div></div></body></html>`;
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ deviceScaleFactor: 1 });
  await p.setViewportSize({ width: 1280, height: 640 });
  await p.setContent(html(1280, 640), { waitUntil: 'load' });
  await p.evaluate(() => document.fonts.ready);
  await p.screenshot({ path: path.join(OUT, 'banner.png') });
  await b.close();
  console.log('docs/banner.png');
})();
