# Nightdial

IPTV player with Xtream Codes sign-in and a full TV guide (EPG), for iPhone/iPad, Fire TV and the web.

GitHub builds the apps automatically every time something in `ios/` or `firetv/` changes. Only builds from the `main` branch are published; builds from `dev` are for testing (their files and iPhone screenshots are attached to the workflow run).
The newest builds are always on the **Releases** page (right-hand side of this page).

| App | Download | Install with |
| --- | --- | --- |
| iPhone and iPad | [Nightdial.ipa](https://github.com/S515BX/turner/releases/download/ios/Nightdial.ipa) | [Sideloadly](https://sideloadly.io) (signs it with your Apple ID) |
| Fire TV | [Nightdial-FireTV.apk](https://github.com/S515BX/turner/releases/download/firetv/Nightdial-FireTV.apk) | Downloader app or adb |
| Web | `web/` folder | `node server.js`, then open http://localhost:8080 |

To build again without changing anything: **Actions** tab → pick the workflow → **Run workflow**.

## iPhone and iPad (Sideloadly)

1. Download `Nightdial.ipa` from Releases on your computer.
2. Install [Sideloadly](https://sideloadly.io). On Windows it needs iTunes and iCloud from Apple's website, not the Microsoft Store versions.
3. Plug in your iPhone, drag `Nightdial.ipa` into Sideloadly, enter your Apple ID and press **Start**.
4. On the iPhone: Settings → General → VPN & Device Management → your Apple ID → **Trust**. Turn on Developer Mode if asked (Settings → Privacy & Security) and restart.
5. With a free Apple ID the app lasts 7 days. Turn on Sideloadly's automatic refresh, or press Start again before then.

## Fire TV

1. On the Fire Stick: Settings → My Fire TV → About, select the device name 7 times. Then in **Developer options** turn on **Apps from Unknown Sources** (or allow the Downloader app to install apps).
2. Install the free **Downloader** app from the Amazon Appstore.
3. In Downloader, enter the APK link from the **firetv** release:
   `https://github.com/S515BX/turner/releases/download/firetv/Nightdial-FireTV.apk`
   (This works because the repository is public. Alternatively, install from a computer with
   `adb connect <fire-stick-ip>` then `adb install -r Nightdial-FireTV.apk`.)

New builds install over the old one and keep your playlists and favorites.

On the remote: **Back** or **Left** (from what's on now) opens the menu, **◀◀ / ▶▶** step through earlier and later programs, and **OK** watches. In full screen, **OK** opens the channel options (favorite, hide, audio track, stream format) and **Left** shows the channel list. **Exit Nightdial** is at the bottom of the menu.

The old `Tuner-FireTV.apk` and `Tuner.ipa` links still get the newest build.


## Look and channels

- **Themes & look** (menu → Themes): everyday themes plus holiday themes (New Year, Valentine's, St. Patrick's, Easter, 4th of July, Halloween, Thanksgiving, Christmas) that can switch on by themselves in season, highlight and menu colors, six fonts, interface size, and holiday decorations.
- **Edit channels** (menu → Edit channels): put favorites in your own order, hide channels or whole groups, and sort channels by provider order, number or A–Z.

## What's inside

- `ios/` – SwiftUI app (iOS 16+). Open `Tuner.xcodeproj` in Xcode 16+ if you have a Mac.
- `firetv/` – Android TV app for Fire TV (Fire OS 5+). Opens in Android Studio.
- `web/` – browser version with a small Node.js relay for your provider.

Tuner doesn't include any channels. Use it with a service you subscribe to.
