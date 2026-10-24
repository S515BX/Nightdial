TUNER
IPTV player with Xtream Codes sign-in and a full TV guide (EPG)
=================================================================

START IT
1. Install Node.js 18 or newer from https://nodejs.org
2. Open a terminal in this folder and run:

       node server.js

3. Open http://localhost:8080 in Chrome, Edge, Firefox or Safari.
4. Enter the server URL, username and password from your IPTV provider.
   You can also paste your full M3U link (the one with username= and
   password= in it) into the Server URL box. Tuner fills in the rest.

WATCH ON A TV, TABLET OR PHONE (same Wi-Fi)
   Mac / Linux:          HOST=0.0.0.0 node server.js
   Windows PowerShell:   $env:HOST="0.0.0.0"; node server.js
   Then open http://<this computer's IP address>:8080 on the other device.

WHY THERE'S A SERVER
   Browsers block web pages from talking to most IPTV servers directly.
   server.js runs on your own computer and passes the app's requests to
   your provider. It talks to nothing else.

WHAT'S IN IT
   - Xtream Codes sign-in, several saved playlists, account status/expiry
   - TV guide grid with live "now" line, channel groups, favorites, recently watched
   - Guide data per channel from your provider, or a full XMLTV file
   - Catch-up (watch from start) on channels your provider archives
   - Full-screen player with channel banner, channel up/down, number entry
   - HLS (.m3u8) or MPEG-TS (.ts) stream format
   - Remote-friendly: arrow keys, OK, Back, 0-9, F (favorite), G (groups), / (search)

NOTES
   - Saved playlists and favorites live in this browser only.
   - If a channel won't start, switch Stream format in Settings.
   - Tuner doesn't include any channels. Use it with a service you subscribe to.
