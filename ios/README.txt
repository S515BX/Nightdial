TUNER FOR iPHONE AND iPAD
Xtream Codes IPTV player with a full TV guide (EPG)
===================================================

There are two ways to get Tuner onto your iPhone. Option A needs no Mac.


OPTION A: GET A Tuner.ipa WITHOUT A MAC (Windows or Mac computer)
------------------------------------------------------------------
Step 1. Build the .ipa on GitHub (free)
  1. Make a free account at https://github.com and create a new repository
     (the + at the top right > New repository). Private is fine.
  2. On the new repository page choose "uploading an existing file" and drag in
     everything inside this Tuner-iOS folder, including the hidden .github
     folder. (If your computer hides it, upload .github/workflows/build-ipa.yml
     separately: "Add file" > "Create new file", type the name
     .github/workflows/build-ipa.yml and paste the file's contents.)
     Click "Commit changes".
  3. Open the "Actions" tab. A run called "Build IPA" starts by itself
     (or press "Run workflow"). It takes about 5-10 minutes.
  4. When it shows a green check, open the run and download "Tuner-ipa" under
     Artifacts. Unzip it: inside is Tuner.ipa.
     A red X means the build failed: open the run, expand "Show build errors"
     and send me the text.

Step 2. Install the .ipa on your iPhone
  Apple only lets an app run on your iPhone if it's signed with an Apple ID.
  These free tools sign Tuner.ipa with yours while installing it:
  - Sideloadly (Windows or Mac): https://sideloadly.io
    Plug in your iPhone, drag Tuner.ipa into Sideloadly, enter your Apple ID,
    press Start.
  - AltStore (Windows or Mac): https://altstore.io
    Can refresh the app automatically over Wi-Fi.
  Then on the iPhone:
  - Settings > General > VPN & Device Management: tap your Apple ID > Trust.
  - Settings > Privacy & Security > Developer Mode: turn it on if asked, restart.

  With a free Apple ID the app has to be refreshed every 7 days (AltStore does
  this for you). A paid Apple Developer account ($99/year) makes it last a year.


OPTION B: BUILD IT WITH XCODE (needs a Mac)
-------------------------------------------
  1. Install Xcode 16 or newer from the Mac App Store.
  2. Double-click Tuner.xcodeproj. Click "Tuner" at the top of the file list,
     open "Signing & Capabilities", and pick your Apple ID under Team.
  3. Plug in your iPhone, choose it at the top of the window, press Run (▶).
  4. Trust the developer and turn on Developer Mode on the iPhone as above.


USING IT
- Enter your server URL, username and password, or tap "Open demo playlist".
  You can paste your whole M3U link into Server URL and Tuner fills in the rest.
- Tap a program to select it. Tap it again to watch full screen, or to see
  details and catch-up for programs that aren't on now.
- Touch and hold a channel to add it to favorites.
- Full screen: swipe up or down to change channel. AirPlay and
  Picture in Picture are at the top right.
- Settings shows your account status, expiry and connections, plus the
  24-hour clock, compact rows and XMLTV guide options.

NOTES
- Needs iOS 16 or newer.
- Apple's video player plays HLS, so Tuner asks your provider for .m3u8 streams.
- Passwords are kept in the iOS Keychain on your device.
- Tuner doesn't include any channels. Use it with a service you subscribe to.
