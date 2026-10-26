#!/usr/bin/env node
/*
  Nightdial local server
  ------------------
  Serves the Nightdial app and relays its requests to your IPTV provider.

  Why: browsers don't let a web page talk to most IPTV servers directly
  (they don't send CORS headers, and many only speak plain http). This
  server runs on your own computer, fetches from your provider for the app,
  and rewrites HLS playlists so every segment also goes through it.
  Nothing is sent anywhere except to the provider you sign in to.

  Run:      node server.js            (needs Node.js 18 or newer)
  Open:     http://localhost:8080

  Options (environment variables):
    PORT=8080          port to listen on
    HOST=127.0.0.1     use 0.0.0.0 to watch from a TV or phone on your Wi-Fi
    UA="Nightdial/1.0" User-Agent sent to your provider
*/
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { Readable } = require('stream');

const PORT = Number(process.env.PORT) || 8080;
const HOST = process.env.HOST || '127.0.0.1';
const UA = process.env.UA || 'Nightdial/1.0';

if (typeof fetch !== 'function') {
  console.error('Nightdial needs Node.js 18 or newer. Download it from https://nodejs.org');
  process.exit(1);
}

function page() {
  const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
  return html.replace('<!--NIGHTDIAL_PROXY-->', '<script>window.NIGHTDIAL_PROXY=true</script>');   // its hash is in the page's CSP (build.js)
}

const isPlaylist = (contentType, url) => /mpegurl/i.test(contentType || '') || /\.m3u8?(\?|$)/i.test(url || '');

function rewritePlaylist(text, baseUrl, ua) {
  const abs = u => { try { return new URL(u, baseUrl).href; } catch (e) { return u; } };
  const prox = u => '/proxy?u=' + encodeURIComponent(abs(u)) + (ua ? '&ua=' + encodeURIComponent(ua) : '');
  return text.split(/\r?\n/).map(line => {
    const l = line.trim();
    if (!l) return line;
    if (l.startsWith('#')) return line.replace(/URI="([^"]+)"/g, (_, u) => `URI="${prox(u)}"`);
    return prox(l);
  }).join('\n');
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');

  if (url.pathname === '/' || url.pathname === '/index.html') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', 'x-frame-options': 'DENY' });
    return res.end(page());
  }
  const method = req.method;
  if (url.pathname !== '/proxy' || !['GET', 'HEAD', 'POST', 'DELETE'].includes(method)) { res.writeHead(404, { 'content-type': 'text/plain' }); return res.end('Not found'); }
  // POST and DELETE (Emby sign-in and playback reports) only from the app itself: other web pages can't add this
  // header to a request without this server agreeing first, and it never does.
  if ((method === 'POST' || method === 'DELETE') && req.headers['x-nightdial'] !== '1') { res.writeHead(403, { 'content-type': 'text/plain' }); return res.end('Forbidden'); }

  let target;
  try { target = new URL(url.searchParams.get('u') || ''); } catch (e) { target = null; }
  if (!target || !/^https?:$/.test(target.protocol)) { res.writeHead(400, { 'content-type': 'text/plain' }); return res.end('Bad address'); }

  const ctl = new AbortController();
  res.on('close', () => ctl.abort());
  try {
    // a playlist can ask for its own User-Agent (Playlist options); plain text only
    const ua = (url.searchParams.get('ua') || '').replace(/[^\x20-\x7e]/g, '').slice(0, 200);
    const headers = { 'user-agent': ua || UA, accept: req.headers.accept === 'application/json' ? 'application/json' : '*/*' };
    if (req.headers.range) headers.range = req.headers.range;
    // Emby's sign-in header (with its access token) goes to the Emby server and nowhere else
    if (req.headers['x-emby-authorization']) headers['x-emby-authorization'] = String(req.headers['x-emby-authorization']).slice(0, 2000);
    let body;
    if (method === 'POST') {
      const chunks = []; let size = 0;
      for await (const c of req) { size += c.length; if (size > 1e6) { res.writeHead(413, { 'content-type': 'text/plain' }); return res.end('Too large'); } chunks.push(c); }
      body = Buffer.concat(chunks);
      headers['content-type'] = 'application/json';
    }
    const up = await fetch(target, { method, headers, body, redirect: 'follow', signal: ctl.signal });
    const type = up.headers.get('content-type') || '';

    if (isPlaylist(type, up.url) || isPlaylist('', target.pathname)) {
      const body = rewritePlaylist(await up.text(), up.url, ua);
      res.writeHead(up.status, { 'content-type': 'application/vnd.apple.mpegurl', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'content-security-policy': 'sandbox' });
      return res.end(body);
    }

    // Provider content is data, never a page: sandboxed and not sniffed, so it can't run script on this origin.
    const out = { 'content-type': type || 'application/octet-stream', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'content-security-policy': 'sandbox' };
    for (const h of ['content-range', 'accept-ranges']) { const v = up.headers.get(h); if (v) out[h] = v; }
    if (!up.headers.get('content-encoding') && up.headers.get('content-length')) out['content-length'] = up.headers.get('content-length');
    res.writeHead(up.status, out);
    if (!up.body) return res.end();
    Readable.fromWeb(up.body).on('error', () => res.destroy()).pipe(res);
  } catch (e) {
    if (ctl.signal.aborted) return;
    if (!res.headersSent) { res.writeHead(502, { 'content-type': 'text/plain' }); res.end('Could not reach the provider: ' + e.message); }
    else res.destroy();
  }
});

server.listen(PORT, HOST, () => {
  const shown = HOST === '0.0.0.0' ? 'localhost' : HOST;
  console.log(`\n  Nightdial is running → http://${shown}:${PORT}\n`);
  if (HOST === '0.0.0.0') console.log('  Open it from other devices on your network with this computer\'s IP address.\n');
  console.log('  Press Ctrl+C to stop.\n');
});
