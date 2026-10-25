NIGHTDIAL FOR THE WEB
IPTV player with Xtream Codes or M3U sign-in and a full TV guide (EPG)
=====================================================================

START IT
1. Install Node.js 18 or newer from https://nodejs.org
2. Open a terminal in this folder and run:

       node server.js

3. Open http://localhost:8080 in Chrome, Edge, Firefox or Safari.
4. Sign in with Xtream Codes (server address, username, password) or an
   M3U playlist link. You can also paste your full M3U link (the one with
   username= and password= in it) into the Server URL box and Nightdial
   fills in the rest.

WATCH ON A TV, TABLET OR PHONE (same Wi-Fi)
   Mac / Linux:          HOST=0.0.0.0 node server.js
   Windows PowerShell:   $env:HOST="0.0.0.0"; node server.js
   Then open http://<this computer's IP address>:8080 on the other device.

WHY THERE'S A SERVER
   Browsers block web pages from talking to most IPTV servers directly.
   server.js runs on your own computer and passes the app's requests to
   your provider. It talks to nothing else.

WHAT'S IN IT
   - Xtream Codes and M3U sign-in, several saved playlists, account status
   - TV guide grid with a live "now" line, channel groups and favorites;
     scroll back through what already aired and catch up where your
     provider keeps recordings
   - Playlist options for each playlist: name, login, guide source and
     time shift, channel numbers, sorting, start group, stream format,
     User-Agent, Movies & Series on or off, hide adult groups
   - Movies & Series, pause and rewind live TV, picture shape
   - Themes, holiday themes, highlight and menu colors, fonts
   - Keyboard: arrow keys, Enter, Esc, 0-9, F (favorite), G (groups), / (search)

NOTES
   - Saved playlists and favorites live in this browser only.
   - If a channel won't start, change Stream format in Playlist options.
   - Nightdial doesn't include any channels. Use it with a service you subscribe to.
