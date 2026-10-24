// Renders the Nightdial icon + Fire TV banner to PNGs at every size the apps need.
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
const DIR = __dirname, OUT = path.join(DIR, 'out'); fs.mkdirSync(OUT, { recursive: true });
const svg = fs.readFileSync(path.join(DIR, 'icon.svg'), 'utf8');
const poppins = 'data:font/ttf;base64,' + fs.readFileSync('/home/claude/fonts/subset/Poppins-SemiBold.ttf').toString('base64');
const iconPage = (size, radius) => `<!doctype html><html><body style="margin:0;background:transparent">
<div style="width:${size}px;height:${size}px;border-radius:${radius}px;overflow:hidden">${svg.replace('width="1024" height="1024"', `width="${size}" height="${size}"`)}</div></body></html>`;
const banner = (w, h) => `<!doctype html><html><head><style>
@font-face{font-family:P;src:url(${poppins})}
body{margin:0}
.b{position:relative;width:${w}px;height:${h}px;overflow:hidden;background:radial-gradient(circle at 0 0,rgba(76,201,240,.45),transparent 55%),radial-gradient(circle at 100% 110%,rgba(255,107,139,.42),transparent 55%),linear-gradient(135deg,#20253a,#121521 60%,#0d0f17);display:flex;align-items:center;gap:${w * .045}px;padding-left:${w * .07}px;box-sizing:border-box;font-family:P}
.ic{width:${h * .58}px;height:${h * .58}px;border-radius:${h * .14}px;overflow:hidden;box-shadow:0 ${h * .03}px ${h * .1}px rgba(0,0,0,.45),0 0 0 ${Math.max(1, h / 180)}px rgba(255,255,255,.08);flex:none}
.ic svg{width:100%;height:100%;display:block}
.t{font-size:${h * .2}px;color:#fff;letter-spacing:-.01em;line-height:1}
.t small{display:block;margin-top:${h * .05}px;font-size:${h * .075}px;letter-spacing:.18em;color:#9fe9d6;text-transform:uppercase}
</style></head><body><div class="b"><div class="ic">${svg}</div><div class="t">Nightdial<small>Live TV guide</small></div></div></body></html>`;
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage();
  async function shot(html, w, h, file, transparent) {
    await p.setViewportSize({ width: w, height: h });
    await p.setContent(html, { waitUntil: 'load' });
    await p.evaluate(() => document.fonts.ready);
    await p.screenshot({ path: path.join(OUT, file), omitBackground: !!transparent, clip: { x: 0, y: 0, width: w, height: h } });
  }
  await shot(iconPage(1024, 0), 1024, 1024, 'icon-1024-square.png');          // iOS (no transparency, iOS rounds it)
  for (const [d, s] of [['mdpi', 48], ['hdpi', 72], ['xhdpi', 96], ['xxhdpi', 144], ['xxxhdpi', 192]])
    await shot(iconPage(s, Math.round(s * .22)), s, s, `ic_launcher-${d}.png`, true);   // Android launcher (rounded square)
  await shot(iconPage(512, 112), 512, 512, 'icon-512-rounded.png', true);
  await shot(banner(320, 180), 320, 180, 'banner-xhdpi.png');
  await shot(banner(640, 360), 640, 360, 'banner-640.png');
  await shot(iconPage(180, 0), 180, 180, 'apple-touch-180.png');
  await b.close();
  console.log(fs.readdirSync(OUT).join('\n'));
})();
