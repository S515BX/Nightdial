package app.tuner.tv;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * Fire TV / Android TV shell for Tuner. The guide and player are the same web app as the browser version,
 * served from the APK. Requests to the IPTV provider go through {@link Relay}, so there's no server to run.
 */
public class MainActivity extends Activity {
    private static final String HOST = "appassets.androidplatform.net";
    private static final String START_URL = "https://" + HOST + "/index.html";

    private WebView web;
    private long lastBackPress;

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        web = new WebView(this);
        web.setBackgroundColor(Color.rgb(10, 15, 21));
        setContentView(web);

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

    /** Remote buttons the web page can't see on its own. */
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
                        Toast.makeText(this, "Press Back again to exit Tuner", Toast.LENGTH_SHORT).show();
                    }
                });
            }
            return true;
        }
        String key = null;
        switch (code) {
            case KeyEvent.KEYCODE_MENU:
            case KeyEvent.KEYCODE_INFO:
                key = "i";
                break;
            case KeyEvent.KEYCODE_CHANNEL_UP:
            case KeyEvent.KEYCODE_MEDIA_REWIND:
            case KeyEvent.KEYCODE_PAGE_UP:
                key = "PageUp";
                break;
            case KeyEvent.KEYCODE_CHANNEL_DOWN:
            case KeyEvent.KEYCODE_MEDIA_FAST_FORWARD:
            case KeyEvent.KEYCODE_PAGE_DOWN:
                key = "PageDown";
                break;
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
            case KeyEvent.KEYCODE_MEDIA_PLAY:
                key = "Enter";
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
    protected void onDestroy() {
        web.destroy();
        super.onDestroy();
    }

    private final class Client extends WebViewClient {
        @Override
        public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            Uri url = request.getUrl();
            if (!HOST.equals(url.getHost())) return null;
            String path = url.getPath() == null ? "/" : url.getPath();
            try {
                if (path.equals("/") || path.equals("/index.html")) return page();
                if (path.equals("/proxy")) return toResponse(Relay.handle(url.getQueryParameter("u"), request.getRequestHeaders()));
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

    private static WebResourceResponse toResponse(Relay.Result r) {
        int status = r.status;
        if (status < 100 || (status >= 300 && status < 400) || status > 599) status = 502;
        return new WebResourceResponse(r.mime, r.encoding, status, status < 400 ? "OK" : "Error", r.headers, r.body);
    }

    /** Lets the page open the on-screen keyboard when a text box is selected with the remote. */
    private final class Bridge {
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
