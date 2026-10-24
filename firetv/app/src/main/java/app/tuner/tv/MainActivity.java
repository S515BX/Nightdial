package app.tuner.tv;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
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
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.ui.AspectRatioFrameLayout;
import androidx.media3.ui.PlayerView;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
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
    private long lastBackPress;
    private int retries;
    private volatile String audioTracksJson = "[]";
    private final List<int[]> audioTrackIndex = new ArrayList<>();

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.rgb(10, 15, 21));

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
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        s.setAllowFileAccess(false);
        s.setUserAgentString(s.getUserAgentString() + " TunerTV/1.0");

        web.setWebViewClient(new Client());
        web.setWebChromeClient(new WebChromeClient());
        web.addJavascriptInterface(new Bridge(), "TunerNative");
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
                web.evaluateJavascript("(window.tunerBack ? window.tunerBack() : false)", value -> {
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
        String key = null;
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_NUMPAD_ENTER:
            case KeyEvent.KEYCODE_BUTTON_A:
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
            case KeyEvent.KEYCODE_MEDIA_PLAY:
                key = "Enter";
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
                web.evaluateJavascript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'" + key + "',bubbles:true}))", null);
            }
            return true;
        }
        return super.dispatchKeyEvent(event);
    }

    // ---------------------------------------------------------------- player

    private void ensurePlayer() {
        if (player != null) return;
        DefaultHttpDataSource.Factory http = new DefaultHttpDataSource.Factory()
                .setUserAgent(Relay.userAgent)
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(15000)
                .setReadTimeoutMs(30000);
        DefaultMediaSourceFactory sources = new DefaultMediaSourceFactory(new DefaultDataSource.Factory(this, http));
        DefaultRenderersFactory renderers = new DefaultRenderersFactory(this).setEnableDecoderFallback(true);
        player = new ExoPlayer.Builder(this, renderers).setMediaSourceFactory(sources).build();
        player.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(), true);
        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int state) {
                if (state == Player.STATE_BUFFERING) send("buffering", "");
                else if (state == Player.STATE_ENDED) send("error", "stopped|ENDED");
            }

            @Override
            public void onIsPlayingChanged(boolean isPlaying) {
                if (isPlaying) {
                    retries = 0;
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
                if ("network".equals(kind) && retries < 2) {
                    retries++;
                    player.prepare();
                    return;
                }
                send("error", kind + "|" + error.getErrorCodeName());
            }

            @Override
            public void onTracksChanged(Tracks tracks) {
                updateAudioTracks(tracks);
                send("tracks", "");
            }
        });
        playerView.setPlayer(player);
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
        web.evaluateJavascript("window.tunerPlayerEvent&&window.tunerPlayerEvent('" + type + "','" + detail.replace("'", "") + "')", null);
    }

    private void stopPlayer() {
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
    protected void onDestroy() {
        if (player != null) {
            player.release();
            player = null;
        }
        web.destroy();
        super.onDestroy();
    }

    // ---------------------------------------------------------------- page + relay

    private final class Client extends WebViewClient {
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
        html = html.replace("<!--TUNER_PROXY-->", "<script>window.TUNER_PROXY=true;window.TUNER_TV=true;</script>");
        Map<String, String> headers = new HashMap<>();
        headers.put("Cache-Control", "no-store");
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
            runOnUiThread(() -> {
                ensurePlayer();
                retries = 0;
                MediaItem.Builder item = new MediaItem.Builder().setUri(url);
                String path = Uri.parse(url).getPath();
                if (path != null && path.toLowerCase(Locale.ROOT).endsWith(".m3u8")) item.setMimeType(MimeTypes.APPLICATION_M3U8);
                player.setMediaItem(item.build());
                player.prepare();
                player.setPlayWhenReady(true);
                playerView.setVisibility(View.VISIBLE);
            });
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
                FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) playerView.getLayoutParams();
                lp.leftMargin = (int) Math.round(x * d);
                lp.topMargin = (int) Math.round(y * d);
                lp.width = Math.max(1, (int) Math.round(w * d));
                lp.height = Math.max(1, (int) Math.round(h * d));
                playerView.setLayoutParams(lp);
            });
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
    }
}
