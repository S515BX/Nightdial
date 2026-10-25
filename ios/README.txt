NIGHTDIAL FOR iPHONE AND iPAD
=============================

GET THE APP (no Mac needed)
  Download Nightdial.ipa from the "ios" release on GitHub:
    https://github.com/S515BX/Nightdial/releases/download/ios/Nightdial.ipa

  Install it with Sideloadly (https://sideloadly.io), which signs it with
  your own Apple ID while installing:
    1. Plug in your iPhone, drag Nightdial.ipa into Sideloadly, enter your
       Apple ID and press Start.
    2. On the iPhone: Settings > General > VPN & Device Management > your
       Apple ID > Trust. Turn on Developer Mode if asked and restart.
    3. With a free Apple ID the app lasts 7 days. Sideloadly can refresh it.

BUILD IT YOURSELF (Mac with Xcode 16 or newer)
  Open Nightdial.xcodeproj, pick your team under Signing & Capabilities and
  press Run. make_project.py regenerates the project, icons and theme art.

SIGNING IN
  Xtream Codes (server, username, password) or an M3U playlist link with an
  optional XMLTV guide link. Paste a whole M3U link with username= and
  password= into Server URL and Nightdial fills in the rest.

GOOD TO KNOW
  - Apple's video player plays HLS, so Nightdial asks your provider for
    .m3u8 streams. Movies in .mkv format don't play on iPhone.
  - Settings > Playlist options: name, guide time shift, channel numbers,
    start group, hide adult groups, User-Agent, Movies & Series on or off.
  - Settings > Video player: open full screen in VLC, Infuse or nPlayer.
  - Settings > VPN: shows when your VPN app is on, and can hold playback
    until it is.
  - Nightdial doesn't include any channels. Use it with a service you
    subscribe to.
