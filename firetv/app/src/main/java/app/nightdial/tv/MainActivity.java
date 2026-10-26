package app.nightdial.tv;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.Toast;

import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.TrackSelectionOverride;
import androidx.media3.common.Tracks;
import androidx.media3.common.VideoSize;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter;
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy;
import androidx.media3.ui.AspectRatioFrameLayout;
import androidx.media3.ui.PlayerView;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Fire TV / Android TV shell for Nightdial.
 * The guide is the same web app as the browser version, served from the APK and drawn on a see-through WebView.
 * Video plays in Android's own player (Media3 ExoPlayer) underneath it, so Dolby audio, H.265 and raw MPEG-TS work.
 * Guide requests to the IPTV provider go through {@link Relay}.
 */
public class MainActivity extends Activity {
    private static final String HOST = "appassets.androidplatform.net";
    private static final String START_URL = "https://" + HOST + "/index.html";

    private WebView web;
    private PlayerView playerView;
    private ExoPlayer player;
    private Secrets secrets;
    private Vpn vpn;
    /** What's playing, for the page's resolution / frame rate / codec / audio badges. */
    private volatile String streamInfoJson = "";
    private ShareServer share;
    private long lastBackPress;
    private int retries;
    /** What's playing, so a dropped stream can be opened again: providers often cut connections or hand out links that expire. */
    private String currentUrl;
    private boolean currentLive;
    private boolean hasPlayed;
    /** Waits between reconnect attempts once a stream has been playing (about a minute in all), like TiviMate. */
    private static final long[] RECONNECT_DELAYS = {1000, 2000, 3000, 5000, 8000, 10000, 12000, 15000};
    private final Runnable reconnectNow = this::reconnect;
    /** A stream that played for half a minute counts as healthy again. */
    private final Runnable playingSteady = () -> retries = 0;
    /** A live stream that stops sending without closing (it just freezes) is reopened after 20 s. */
    private final Runnable stallCheck = () -> {
        if (player != null && hasPlayed && player.getPlayWhenReady() && player.getPlaybackState() == Player.STATE_BUFFERING) dropped("network", "STREAM_STALLED");
    };
    /** Player position for the page ("pos;duration;paused;seekable;behindLive", ms), refreshed on the main thread. */
    private volatile String playerState = "0;-1;0;0;-1";
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Runnable stateTicker = new Runnable() {
        @Override
        public void run() {
            updatePlayerState();
            ui.postDelayed(this, 500);
        }
    };
    private volatile String audioTracksJson = "[]";
    /** Where the page wants the video (device pixels) and how to fit the picture into it. */
    private int rectX, rectY, rectW = 1, rectH = 1;
    private String aspect = "16:9";
    private final List<int[]> audioTrackIndex = new ArrayList<>();

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        secrets = new Secrets(this);
        vpn = new Vpn(this, secrets, json -> runOnUiThread(() -> {
            if (web != null) web.evaluateJavascript("window.nightdialVpnEvent&&window.nightdialVpnEvent(" + json + ")", null);
        }));

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);   // shows as black bars around 4:3 / 16:9 pictures

        playerView = new PlayerView(this);
        playerView.setUseController(false);
        playerView.setResizeMode(AspectRatioFrameLayout.RESIZE_MODE_FIT);
        playerView.setShutterBackgroundColor(Color.BLACK);
        playerView.setFocusable(false);
        playerView.setVisibility(View.GONE);
        root.addView(playerView, new FrameLayout.LayoutParams(1, 1));

        web = new WebView(this);
        web.setBackgroundColor(Color.TRANSPARENT);
        root.addView(web, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        setContentView(root);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        // Only channel logos load over plain http; scripts and data never do.
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setGeolocationEnabled(false);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setSupportMultipleWindows(false);
        s.setUserAgentString(s.getUserAgentString() + " Nightdial/1.0");

        web.setWebViewClient(new Client());
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "NightdialNative");
        web.setFocusable(true);
        web.setFocusableInTouchMode(true);
        web.requestFocus(View.FOCUS_DOWN);
        web.loadUrl(START_URL);
    }

    // ---------------------------------------------------------------- remote

    /** Remote buttons the web page can't see on its own, including the center (select) button. */
    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        int code = event.getKeyCode();
        if (code == KeyEvent.KEYCODE_BACK) {
            if (event.getAction() == KeyEvent.ACTION_UP) {
                web.evaluateJavascript("(window.nightdialBack ? window.nightdialBack() : false)", value -> {
                    if ("true".equals(value)) return;
                    long now = System.currentTimeMillis();
                    if (now - lastBackPress < 2000) {
                        finish();
                    } else {
                        lastBackPress = now;
                        Toast.makeText(this, "Press Back again to exit Nightdial", Toast.LENGTH_SHORT).show();
                    }
                });
            }
            return true;
        }
        // The page must hold Android's focus, or arrows and OK go nowhere.
        if (!web.hasFocus()) web.requestFocus();
        String key = null;
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_NUMPAD_ENTER:
            case KeyEvent.KEYCODE_BUTTON_A: {
                // OK is timed here: a short press reaches the page as a real Enter key when it ends (so every button,
                // switch and option responds as with a keyboard); holding it for half a second asks the page for the
                // channel options instead (window.nightdialLongPress), and a held key never repeats into the page.
                if (event.getAction() == KeyEvent.ACTION_DOWN) {
                    if (event.getRepeatCount() == 0) {
                        okDownEvent = event;
                        okDown = true;
                        okLongFired = false;
                        okLongHandled = false;
                        okUpWhileAsking = false;
                        ui.removeCallbacks(okLong);
                        ui.postDelayed(okLong, 550);
                    }
                    return true;
                }
                if (event.getAction() == KeyEvent.ACTION_UP) {
                    okDown = false;
                    okLastUp = event;
                    ui.removeCallbacks(okLong);
                    if (!okLongFired) sendEnter(event);
                    else if (okAsking) okUpWhileAsking = true;
                    else if (!okLongHandled) sendEnter(event);
                }
                return true;
            }
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
            case KeyEvent.KEYCODE_MEDIA_PLAY:
            case KeyEvent.KEYCODE_MEDIA_PAUSE:
                key = "MediaPlayPause";
                break;
            case KeyEvent.KEYCODE_MENU:
            case KeyEvent.KEYCODE_INFO:
                key = "i";
                break;
            case KeyEvent.KEYCODE_CHANNEL_UP:
            case KeyEvent.KEYCODE_PAGE_UP:
                key = "PageUp";
                break;
            case KeyEvent.KEYCODE_CHANNEL_DOWN:
            case KeyEvent.KEYCODE_PAGE_DOWN:
                key = "PageDown";
                break;
            case KeyEvent.KEYCODE_MEDIA_REWIND:
                key = "MediaRewind";
                break;
            case KeyEvent.KEYCODE_MEDIA_FAST_FORWARD:
                key = "MediaFastForward";
                break;
            default:
                break;
        }
        if (key != null) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                web.evaluateJavascript("(window.nightdialKey ? window.nightdialKey('" + key + "') : document.dispatchEvent(new KeyboardEvent('keydown',{key:'" + key + "',bubbles:true})))", null);
            }
            return true;
        }
        return super.dispatchKeyEvent(event);
    }

    // ---- OK button timing (short press = Enter, hold = channel options)
    private KeyEvent okDownEvent;
    private boolean okDown, okLongFired, okLongHandled, okAsking, okUpWhileAsking;
    private KeyEvent okLastUp;

    private final Runnable okLong = () -> {
        if (!okDown) return;
        okLongFired = true;
        okAsking = true;
        web.evaluateJavascript("(window.nightdialLongPress ? window.nightdialLongPress() : false)", value -> {
            okAsking = false;
            okLongHandled = "true".equals(value);
            // nothing to open here: the press counts as a normal OK once it ends
            if (!okLongHandled && okUpWhileAsking) {
                okUpWhileAsking = false;
                sendEnter(okLastUp);
            }
        });
    };

    /** A whole Enter press (down + up) for the page, made from the remote's own key so the WebView treats it as real. */
    private void sendEnter(KeyEvent up) {
        okLastUp = up;
        KeyEvent d = okDownEvent != null ? okDownEvent : up;
        if (d == null) return;
        long upTime = up != null ? up.getEventTime() : d.getEventTime();
        web.dispatchKeyEvent(new KeyEvent(d.getDownTime(), d.getEventTime(), KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER, 0,
                d.getMetaState(), d.getDeviceId(), d.getScanCode(), d.getFlags(), d.getSource()));
        web.dispatchKeyEvent(new KeyEvent(d.getDownTime(), upTime, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER, 0,
                d.getMetaState(), d.getDeviceId(), d.getScanCode(), d.getFlags(), d.getSource()));
    }

    // ---------------------------------------------------------------- player

    private void ensurePlayer() {
        if (player != null) return;
        DefaultHttpDataSource.Factory http = new DefaultHttpDataSource.Factory()
                .setUserAgent(Relay.userAgent)
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(15000)
                .setReadTimeoutMs(30000);
        DefaultMediaSourceFactory sources = new DefaultMediaSourceFactory(new DefaultDataSource.Factory(this, http))
                // more retries of a failed download before giving up; playback carries on from the buffer meanwhile
                .setLoadErrorHandlingPolicy(new DefaultLoadErrorHandlingPolicy(8));
        DefaultRenderersFactory renderers = new DefaultRenderersFactory(this).setEnableDecoderFallback(true);
        // Start by assuming a fast connection, so streams with several qualities open at the best one instead of working up to it.
        DefaultBandwidthMeter meter = new DefaultBandwidthMeter.Builder(this).setInitialBitrateEstimate(40_000_000L).build();
        player = new ExoPlayer.Builder(this, renderers).setMediaSourceFactory(sources).setBandwidthMeter(meter).build();
        // Always the highest quality the Fire TV can decode; never capped to the size of the small preview window.
        player.setTrackSelectionParameters(player.getTrackSelectionParameters().buildUpon()
                .setForceHighestSupportedBitrate(true)
                .clearVideoSizeConstraints()
                .clearViewportSizeConstraints()
                .build());
        // keeps Wi-Fi in full-speed mode while something plays, so the Fire TV's power saving doesn't starve the stream
        player.setWakeMode(C.WAKE_MODE_NETWORK);
        player.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(), true);
        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int state) {
                ui.removeCallbacks(stallCheck);
                if (state == Player.STATE_BUFFERING) {
                    send("buffering", "");
                    if (hasPlayed && currentLive) ui.postDelayed(stallCheck, 20000);
                } else if (state == Player.STATE_ENDED) {
                    // a live channel never ends: the provider closed the connection, so open it again
                    if (currentLive && hasPlayed) dropped("network", "STREAM_ENDED");
                    else send("ended", "");
                }
            }

            @Override
            public void onIsPlayingChanged(boolean isPlaying) {
                if (isPlaying) {
                    hasPlayed = true;
                    ui.removeCallbacks(playingSteady);
                    ui.postDelayed(playingSteady, 30000);
                    updateStreamInfo();
                    send("playing", "");
                }
            }

            @Override
            public void onPlayerError(PlaybackException error) {
                if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
                    player.seekToDefaultPosition();
                    player.prepare();
                    return;
                }
                String kind = classify(error);
                if ("media".equals(kind)) {
                    send("error", kind + "|" + error.getErrorCodeName());
                    return;
                }
                // timeouts, refused or cut connections, and streams broken off mid-packet: reconnect
                dropped(kind, error.getErrorCodeName());
            }

            @Override
            public void onTracksChanged(Tracks tracks) {
                updateAudioTracks(tracks);
                updateStreamInfo();
                send("tracks", "");
            }

            @Override
            public void onVideoSizeChanged(VideoSize size) {
                updateStreamInfo();
                send("info", "");
            }
        });
        playerView.setPlayer(player);
        ui.removeCallbacks(stateTicker);
        ui.post(stateTicker);
    }

    /** Sizes the player inside the page's video box for the chosen aspect ratio. */
    private void layoutVideo() {
        int x = rectX, y = rectY, w = rectW, h = rectH;
        int mode;
        float ratio = 0f;
        switch (aspect) {
            case "4:3": ratio = 4f / 3f; mode = AspectRatioFrameLayout.RESIZE_MODE_FILL; break;
            case "fit": mode = AspectRatioFrameLayout.RESIZE_MODE_FIT; break;
            case "zoom": mode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM; break;
            case "stretch": mode = AspectRatioFrameLayout.RESIZE_MODE_FILL; break;
            default: ratio = 16f / 9f; mode = AspectRatioFrameLayout.RESIZE_MODE_FILL; break;
        }
        if (ratio > 0f) {
            if ((float) w / h > ratio) { int nw = Math.round(h * ratio); x += (w - nw) / 2; w = nw; }
            else { int nh = Math.round(w / ratio); y += (h - nh) / 2; h = nh; }
        }
        playerView.setResizeMode(mode);
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) playerView.getLayoutParams();
        lp.leftMargin = x;
        lp.topMargin = y;
        lp.width = Math.max(1, w);
        lp.height = Math.max(1, h);
        playerView.setLayoutParams(lp);
    }

    private void updatePlayerState() {
        if (player == null) {
            playerState = "0;-1;0;0;-1";
            return;
        }
        long dur = player.getDuration();
        long behind = player.isCurrentMediaItemLive() ? player.getCurrentLiveOffset() : C.TIME_UNSET;
        playerState = Math.max(0, player.getCurrentPosition()) + ";" + (dur == C.TIME_UNSET ? -1 : dur) + ";"
                + (player.getPlayWhenReady() ? "0" : "1") + ";" + (player.isCurrentMediaItemSeekable() ? "1" : "0") + ";"
                + (behind == C.TIME_UNSET ? -1 : behind);
    }

    private void startPlayback(String url, long startMs, boolean live) {
        ensurePlayer();
        cancelReconnect();
        retries = 0;
        hasPlayed = false;
        currentUrl = url;
        currentLive = live;
        load(url, startMs, true);
    }

    private void load(String url, long startMs, boolean playWhenReady) {
        MediaItem.Builder item = new MediaItem.Builder().setUri(url);
        String path = Uri.parse(url).getPath();
        if (path != null && path.toLowerCase(Locale.ROOT).endsWith(".m3u8")) item.setMimeType(MimeTypes.APPLICATION_M3U8);
        if (startMs > 0) player.setMediaItem(item.build(), startMs); else player.setMediaItem(item.build());
        player.prepare();
        player.setPlayWhenReady(playWhenReady);
        playerView.setVisibility(View.VISIBLE);
    }

    /**
     * The stream failed. One that never started gets two quick tries before the page shows why; one that was playing
     * is opened again from the original link (a fresh connection and token from the provider) for about a minute,
     * keeping the last picture on screen, before giving up.
     */
    private void dropped(String kind, String code) {
        ui.removeCallbacks(stallCheck);
        ui.removeCallbacks(playingSteady);
        int max = hasPlayed ? RECONNECT_DELAYS.length : 2;
        if (currentUrl == null || retries >= max) {
            retries = 0;
            send("error", kind + "|" + code);
            return;
        }
        long delay = hasPlayed ? RECONNECT_DELAYS[retries] : 600;
        retries++;
        if (hasPlayed) send("reconnecting", String.valueOf(retries));
        ui.removeCallbacks(reconnectNow);
        ui.postDelayed(reconnectNow, delay);
    }

    private void reconnect() {
        if (player == null || currentUrl == null) return;
        // live: back to the live edge; movies, episodes and catch-up: where it stopped
        long at = currentLive ? 0 : Math.max(0, player.getCurrentPosition());
        load(currentUrl, at, player.getPlayWhenReady());
    }

    private void cancelReconnect() {
        ui.removeCallbacks(reconnectNow);
        ui.removeCallbacks(stallCheck);
        ui.removeCallbacks(playingSteady);
    }

    private static boolean webUrl(String url) {
        return url != null && (url.startsWith("http://") || url.startsWith("https://"));
    }

    private static String classify(PlaybackException e) {
        switch (e.errorCode) {
            case PlaybackException.ERROR_CODE_DECODER_INIT_FAILED:
            case PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED:
            case PlaybackException.ERROR_CODE_DECODING_FAILED:
            case PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES:
            case PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED:
            case PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED:
                return "media";
            case PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS:
                return "http";
            case PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED:
            case PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED:
            case PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED:
            case PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED:
                return "format";
            default:
                return "network";
        }
    }

    private void updateAudioTracks(Tracks tracks) {
        StringBuilder json = new StringBuilder("[");
        audioTrackIndex.clear();
        List<Tracks.Group> groups = tracks.getGroups();
        for (int g = 0; g < groups.size(); g++) {
            Tracks.Group group = groups.get(g);
            if (group.getType() != C.TRACK_TYPE_AUDIO) continue;
            for (int t = 0; t < group.length; t++) {
                if (!group.isTrackSupported(t)) continue;
                Format f = group.getTrackFormat(t);
                String label = f.label != null ? f.label : f.language != null ? new Locale(f.language).getDisplayLanguage() : "Track " + (audioTrackIndex.size() + 1);
                if (f.channelCount > 2) label += " " + (f.channelCount == 6 ? "5.1" : f.channelCount + "ch");
                if (audioTrackIndex.size() > 0) json.append(',');
                json.append("{\"label\":\"").append(label.replace("\\", "").replace("\"", "'"))
                        .append("\",\"selected\":").append(group.isTrackSelected(t)).append('}');
                audioTrackIndex.add(new int[]{g, t});
            }
        }
        audioTracksJson = json.append(']').toString();
    }

    private void send(String type, String detail) {
        web.evaluateJavascript("window.nightdialPlayerEvent&&window.nightdialPlayerEvent('" + type + "','" + detail.replace("'", "") + "')", null);
    }

    private void updateStreamInfo() {
        if (player == null) {
            streamInfoJson = "";
            return;
        }
        Format v = player.getVideoFormat(), a = player.getAudioFormat();
        VideoSize vs = player.getVideoSize();
        int w = vs.width > 0 ? vs.width : (v != null && v.width > 0 ? v.width : 0);
        int h = vs.height > 0 ? vs.height : (v != null && v.height > 0 ? v.height : 0);
        StringBuilder j = new StringBuilder("{\"w\":").append(w).append(",\"h\":").append(h);
        if (v != null) {
            if (v.frameRate > 0) j.append(",\"fps\":").append(v.frameRate);
            if (v.sampleMimeType != null) j.append(",\"vcodec\":\"").append(jsonText(v.sampleMimeType)).append('"');
            if (v.bitrate > 0) j.append(",\"vbitrate\":").append(v.bitrate);
            if (v.colorInfo != null) {
                int t = v.colorInfo.colorTransfer;
                String hdr = t == C.COLOR_TRANSFER_ST2084 ? "HDR10" : t == C.COLOR_TRANSFER_HLG ? "HLG" : "";
                if (!hdr.isEmpty()) j.append(",\"hdr\":\"").append(hdr).append('"');
            }
        }
        if (a != null) {
            if (a.sampleMimeType != null) j.append(",\"acodec\":\"").append(jsonText(a.sampleMimeType)).append('"');
            if (a.channelCount > 0) j.append(",\"ach\":").append(a.channelCount);
            if (a.sampleRate > 0) j.append(",\"arate\":").append(a.sampleRate);
            if (a.language != null) j.append(",\"alang\":\"").append(jsonText(a.language)).append('"');
        }
        streamInfoJson = w > 0 || v != null || a != null ? j.append('}').toString() : "";
    }

    private void stopPlayer() {
        cancelReconnect();
        currentUrl = null;
        hasPlayed = false;
        streamInfoJson = "";
        if (player != null) {
            player.stop();
            player.clearMediaItems();
        }
        playerView.setVisibility(View.GONE);
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
    }

    @Override
    protected void onPause() {
        web.onPause();
        super.onPause();
    }

    @Override
    protected void onStop() {
        stopPlayer();
        super.onStop();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == Vpn.REQUEST_PERMISSION) vpn.onPermissionResult(resultCode == RESULT_OK);
    }

    @Override
    protected void onDestroy() {
        ui.removeCallbacks(stateTicker);
        cancelReconnect();
        if (share != null) share.stop();
        vpn.shutdown();
        if (player != null) {
            player.release();
            player = null;
        }
        web.destroy();
        super.onDestroy();
    }

    // ---------------------------------------------------------------- page + relay

    private final class Client extends WebViewClient {
        /** The page never navigates; anything that tries to leave the app's own page is blocked. */
        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            return !HOST.equals(request.getUrl().getHost());
        }

        @Override
        public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            Uri url = request.getUrl();
            if (!HOST.equals(url.getHost())) return null;
            String path = url.getPath() == null ? "/" : url.getPath();
            try {
                if (path.equals("/") || path.equals("/index.html")) return page();
                if (path.equals("/proxy")) return toResponse(Relay.handle(url.getQueryParameter("u"), request.getRequestHeaders()));
                if (path.startsWith("/fonts/") && path.endsWith(".ttf") && !path.contains("..")) return font(path.substring(1));
                return toResponse(Relay.text(404, "Not found"));
            } catch (Exception e) {
                return toResponse(Relay.text(502, "Could not reach the provider: " + e.getMessage()));
            }
        }
    }

    private WebResourceResponse page() throws IOException {
        String html = Relay.readAll(getAssets().open("index.html"));
        // Keep this script identical to TV_FLAG in build.js: its hash is in the page's Content-Security-Policy.
        html = html.replace("<!--NIGHTDIAL_PROXY-->", "<script>window.NIGHTDIAL_PROXY=true;window.NIGHTDIAL_TV=true;</script>");
        Map<String, String> headers = new HashMap<>();
        headers.put("Cache-Control", "no-store");
        headers.put("X-Content-Type-Options", "nosniff");
        headers.put("Referrer-Policy", "no-referrer");
        return new WebResourceResponse("text/html", "utf-8", 200, "OK", headers,
                new ByteArrayInputStream(html.getBytes(StandardCharsets.UTF_8)));
    }

    /** Fonts bundled in the APK, so the guide never waits on Google Fonts. */
    private WebResourceResponse font(String assetPath) throws IOException {
        Map<String, String> headers = new HashMap<>();
        headers.put("Cache-Control", "max-age=31536000");
        headers.put("Access-Control-Allow-Origin", "*");
        return new WebResourceResponse("font/ttf", null, 200, "OK", headers, getAssets().open(assetPath));
    }

    private static WebResourceResponse toResponse(Relay.Result r) {
        int status = r.status;
        if (status < 100 || (status >= 300 && status < 400) || status > 599) status = 502;
        return new WebResourceResponse(r.mime, r.encoding, status, status < 400 ? "OK" : "Error", r.headers, r.body);
    }

    // ---------------------------------------------------------------- bridge for the page

    private final class Bridge {
        @JavascriptInterface
        public boolean hasPlayer() {
            return true;
        }

        @JavascriptInterface
        public void play(String url, boolean live) {
            if (!webUrl(url)) return;
            runOnUiThread(() -> startPlayback(url, 0, live));
        }

        /** Movies and episodes: start at a saved position. */
        @JavascriptInterface
        public void playFrom(String url, double startMs) {
            if (!webUrl(url)) return;
            runOnUiThread(() -> startPlayback(url, (long) Math.max(0, startMs), false));
        }

        @JavascriptInterface
        public void setPaused(boolean paused) {
            runOnUiThread(() -> {
                if (player != null) player.setPlayWhenReady(!paused);
                updatePlayerState();
            });
        }

        /** Skip back or forward; on live streams only within what the stream keeps (its DVR window). */
        @JavascriptInterface
        public void seekBy(double ms) {
            runOnUiThread(() -> {
                if (player == null || !player.isCurrentMediaItemSeekable()) return;
                long target = Math.max(0, player.getCurrentPosition() + (long) ms);
                long dur = player.getDuration();
                if (dur != C.TIME_UNSET) target = Math.min(target, Math.max(0, dur - 1000));
                player.seekTo(target);
                updatePlayerState();
            });
        }

        @JavascriptInterface
        public void seekToLive() {
            runOnUiThread(() -> {
                if (player != null) player.seekToDefaultPosition();
            });
        }

        @JavascriptInterface
        public String position() {
            return playerState;
        }

        @JavascriptInterface
        public String secretGet(String name) {
            if (Vpn.isSecretName(name)) return null;   // the VPN key never goes to the page
            return secrets.get(name);
        }

        @JavascriptInterface
        public void secretSet(String name, String value) {
            if (Vpn.isSecretName(name)) return;
            secrets.set(name, value);
        }

        @JavascriptInterface
        public void secretDel(String name) {
            if (Vpn.isSecretName(name)) return;
            secrets.delete(name);
        }

        @JavascriptInterface
        public void stop() {
            runOnUiThread(MainActivity.this::stopPlayer);
        }

        @JavascriptInterface
        public void setMuted(boolean muted) {
            runOnUiThread(() -> {
                if (player != null) player.setVolume(muted ? 0f : 1f);
            });
        }

        /** Position of the video box on the page, in CSS pixels. */
        @JavascriptInterface
        public void setVideoRect(double x, double y, double w, double h) {
            runOnUiThread(() -> {
                float d = getResources().getDisplayMetrics().density;
                rectX = (int) Math.round(x * d);
                rectY = (int) Math.round(y * d);
                rectW = Math.max(1, (int) Math.round(w * d));
                rectH = Math.max(1, (int) Math.round(h * d));
                layoutVideo();
            });
        }

        /** Picture shape: "16:9", "4:3" (forced shapes), "fit" (original shape), "zoom" (fill, cropping), "stretch". */
        @JavascriptInterface
        public void setAspect(String mode) {
            runOnUiThread(() -> {
                aspect = mode == null ? "16:9" : mode;
                layoutVideo();
            });
        }

        /** Resolution, frame rate, codecs and audio of what's playing, as JSON (empty when nothing is). */
        @JavascriptInterface
        public String streamInfo() {
            return streamInfoJson;
        }

        @JavascriptInterface
        public String audioTracks() {
            return audioTracksJson;
        }

        @JavascriptInterface
        public void setAudioTrack(int index) {
            runOnUiThread(() -> {
                if (player == null || index < 0 || index >= audioTrackIndex.size()) return;
                int[] gt = audioTrackIndex.get(index);
                List<Tracks.Group> groups = player.getCurrentTracks().getGroups();
                if (gt[0] >= groups.size()) return;
                TrackSelectionOverride override = new TrackSelectionOverride(groups.get(gt[0]).getMediaTrackGroup(), gt[1]);
                player.setTrackSelectionParameters(player.getTrackSelectionParameters().buildUpon().setOverrideForType(override).build());
            });
        }

        /** Lets the page open the on-screen keyboard when a text box is selected with the remote. */
        @JavascriptInterface
        public void showKeyboard() {
            runOnUiThread(() -> {
                web.requestFocus();
                InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                if (imm != null) imm.showSoftInput(web, InputMethodManager.SHOW_FORCED);
            });
        }

        @JavascriptInterface
        public void exit() {
            runOnUiThread(MainActivity.this::finish);
        }

        /** Video players installed on the device (VLC, MX Player, Kodi…) as JSON: [{"pkg":"…","name":"…"}]. */
        @JavascriptInterface
        public String externalPlayers() {
            Intent probe = new Intent(Intent.ACTION_VIEW);
            probe.setDataAndType(Uri.parse("http://example.com/live/stream.ts"), "video/*");
            PackageManager pm = getPackageManager();
            Map<String, String> found = new LinkedHashMap<>();
            try {
                for (ResolveInfo ri : pm.queryIntentActivities(probe, 0)) {
                    if (ri.activityInfo == null) continue;
                    String pkg = ri.activityInfo.packageName;
                    if (pkg.equals(getPackageName()) || found.containsKey(pkg)) continue;
                    found.put(pkg, String.valueOf(ri.loadLabel(pm)));
                }
            } catch (RuntimeException ignored) {
            }
            StringBuilder json = new StringBuilder("[");
            for (Map.Entry<String, String> e : found.entrySet()) {
                if (json.length() > 1) json.append(',');
                json.append("{\"pkg\":\"").append(jsonText(e.getKey())).append("\",\"name\":\"").append(jsonText(e.getValue())).append("\"}");
            }
            return json.append(']').toString();
        }

        /** Hands a stream to another player: a package name, or empty to let the viewer pick each time. */
        @JavascriptInterface
        public boolean openExternal(String url, String pkg, String title, double positionMs) {
            if (!webUrl(url)) return false;
            Intent i = new Intent(Intent.ACTION_VIEW);
            i.setDataAndType(Uri.parse(url), "video/*");
            if (title != null && !title.isEmpty()) {
                i.putExtra("title", title);                     // VLC, MX Player
                i.putExtra(Intent.EXTRA_TITLE, title);
            }
            if (positionMs > 0) {
                i.putExtra("position", (int) Math.min(Integer.MAX_VALUE, positionMs));   // MX Player (ms)
                i.putExtra("from_start", false);
            }
            boolean ask = pkg == null || pkg.isEmpty();
            if (!ask) i.setPackage(pkg);
            if (i.resolveActivity(getPackageManager()) == null) return false;
            runOnUiThread(() -> {
                stopPlayer();
                try {
                    startActivity(ask ? Intent.createChooser(i, "Play with") : i);
                } catch (ActivityNotFoundException | SecurityException e) {
                    Toast.makeText(MainActivity.this, "Couldn't open that player", Toast.LENGTH_SHORT).show();
                }
            });
            return true;
        }

        // ---- VPN (WireGuard)

        @JavascriptInterface
        public String vpnState() {
            return vpn.stateJson();
        }

        @JavascriptInterface
        public void vpnConnect() {
            runOnUiThread(() -> vpn.connect(MainActivity.this));
        }

        @JavascriptInterface
        public void vpnDisconnect() {
            vpn.down();
        }

        /** Saves a WireGuard config; returns "" or a message saying what's wrong with it. */
        @JavascriptInterface
        public String vpnSetConfig(String text) {
            return vpn.setConfig(text);
        }

        @JavascriptInterface
        public void vpnClear() {
            vpn.clear();
        }

        /** Opens the one-page form for sending a config from a phone or computer: {"url":"…","code":"123456"} or "". */
        @JavascriptInterface
        public String vpnShareStart() {
            if (share != null) share.stop();
            share = new ShareServer(text -> vpn.setConfig(text));
            String url = share.start();
            if (url == null) {
                share = null;
                return "";
            }
            return "{\"url\":\"" + url + "\",\"code\":\"" + share.code() + "\"}";
        }

        @JavascriptInterface
        public void vpnShareStop() {
            if (share != null) share.stop();
            share = null;
        }

        /** The User-Agent sent to the provider by the player and the app's own requests (Playlist options); empty for the default. */
        @JavascriptInterface
        public void setUserAgent(String ua) {
            String clean = ua == null ? "" : ua.replaceAll("[^\\x20-\\x7e]", "").trim();
            if (clean.length() > 200) clean = clean.substring(0, 200);
            String next = clean.isEmpty() ? Relay.DEFAULT_UA : clean;
            if (next.equals(Relay.userAgent)) return;
            Relay.userAgent = next;
            runOnUiThread(() -> {
                // the player keeps the User-Agent it was made with: make a new one for the next channel
                if (player != null) {
                    playerView.setPlayer(null);
                    player.release();
                    player = null;
                }
            });
        }
    }

    private static String jsonText(String s) {
        StringBuilder b = new StringBuilder();
        for (char c : s.toCharArray()) {
            if (c == '"' || c == '\\') b.append('\\').append(c);
            else if (c < 0x20) b.append(' ');
            else b.append(c);
        }
        return b.toString();
    }
}
