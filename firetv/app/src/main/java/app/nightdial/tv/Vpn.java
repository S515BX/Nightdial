package app.nightdial.tv;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkInfo;
import android.net.VpnService;
import android.os.Build;

import com.wireguard.android.backend.GoBackend;
import com.wireguard.android.backend.Tunnel;
import com.wireguard.config.Config;
import com.wireguard.config.InetEndpoint;
import com.wireguard.config.Peer;

import java.io.BufferedReader;
import java.io.StringReader;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Built-in VPN: a WireGuard tunnel from a config file the viewer gets from their VPN provider.
 * The config (it holds a private key) is kept encrypted in {@link Secrets} and never handed to the page.
 */
final class Vpn {
    interface Listener {
        void onVpnState(String json);
    }

    static final int REQUEST_PERMISSION = 7301;
    private static final String KEY = "vpn.wg";

    private final Context context;
    private final Secrets secrets;
    private final Listener listener;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private GoBackend backend;
    private volatile String state = "off";     // off, connecting, on, error
    private volatile String error = "";

    private final Tunnel tunnel = new Tunnel() {
        @Override
        public String getName() {
            return "nightdial";
        }

        @Override
        public void onStateChange(Tunnel.State s) {
            state = s == Tunnel.State.UP ? "on" : "off";
            publish();
        }
    };

    Vpn(Context context, Secrets secrets, Listener listener) {
        this.context = context.getApplicationContext();
        this.secrets = secrets;
        this.listener = listener;
    }

    static boolean isSecretName(String name) {
        return name != null && name.startsWith("vpn.");
    }

    private static Config parse(String text) throws Exception {
        return Config.parse(new BufferedReader(new StringReader(text)));
    }

    /** Checks and saves a WireGuard config. Returns "" when it's good, otherwise a message for the viewer. */
    String setConfig(String text) {
        if (text == null || text.trim().isEmpty()) return "That's empty. Paste the whole WireGuard config.";
        if (text.length() > 16000) return "That's too long for a WireGuard config.";
        try {
            Config c = parse(text.trim());
            if (c.getPeers().isEmpty()) return "That config has no [Peer] section.";
        } catch (Exception e) {
            return "That isn't a WireGuard config Nightdial can read. It should start with [Interface] and have a PrivateKey line.";
        }
        boolean wasOn = "on".equals(state);
        secrets.set(KEY, text.trim());
        error = "";
        if (wasOn) up();
        publish();
        return "";
    }

    boolean hasConfig() {
        String c = secrets.get(KEY);
        return c != null && !c.isEmpty();
    }

    void clear() {
        down();
        secrets.delete(KEY);
        publish();
    }

    private String endpoint() {
        try {
            String c = secrets.get(KEY);
            if (c == null) return "";
            for (Peer p : parse(c).getPeers()) {
                if (p.getEndpoint().isPresent()) {
                    InetEndpoint ep = p.getEndpoint().get();
                    return ep.getHost();
                }
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    /** Starts the tunnel; the first time Android asks the viewer to allow it. */
    void connect(Activity activity) {
        if (!hasConfig()) {
            error = "Add a WireGuard config first.";
            state = "error";
            publish();
            return;
        }
        Intent ask;
        try {
            ask = VpnService.prepare(context);
        } catch (RuntimeException e) {
            ask = null;
        }
        if (ask != null) {
            state = "connecting";
            publish();
            try {
                activity.startActivityForResult(ask, REQUEST_PERMISSION);
            } catch (RuntimeException e) {
                state = "error";
                error = "This device didn't let Nightdial ask for VPN permission.";
                publish();
            }
            return;
        }
        up();
    }

    void onPermissionResult(boolean granted) {
        if (granted) up();
        else {
            state = "error";
            error = "VPN permission was declined.";
            publish();
        }
    }

    private void up() {
        state = "connecting";
        error = "";
        publish();
        worker.execute(() -> {
            try {
                Config c = parse(secrets.get(KEY));
                if (backend == null) backend = new GoBackend(context);
                Tunnel.State s = backend.setState(tunnel, Tunnel.State.UP, c);
                state = s == Tunnel.State.UP ? "on" : "off";
            } catch (Throwable e) {
                state = "error";
                error = "Couldn't connect the VPN. Check the config, or ask your VPN provider for a new one.";
            }
            publish();
        });
    }

    void down() {
        if ("off".equals(state) && backend == null) return;
        worker.execute(() -> {
            try {
                if (backend != null) backend.setState(tunnel, Tunnel.State.DOWN, null);
            } catch (Throwable ignored) {
            }
            state = "off";
            publish();
        });
    }

    /** Another VPN app (not Nightdial's) is carrying the traffic. */
    boolean otherVpnOn() {
        if ("on".equals(state)) return false;
        try {
            ConnectivityManager cm = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return false;
            if (Build.VERSION.SDK_INT >= 23) {
                Network n = cm.getActiveNetwork();
                NetworkCapabilities nc = n == null ? null : cm.getNetworkCapabilities(n);
                return nc != null && nc.hasTransport(NetworkCapabilities.TRANSPORT_VPN);
            }
            @SuppressWarnings("deprecation")
            NetworkInfo vpn = cm.getNetworkInfo(ConnectivityManager.TYPE_VPN);
            return vpn != null && vpn.isConnected();
        } catch (RuntimeException e) {
            return false;
        }
    }

    String stateJson() {
        return "{\"state\":\"" + state + "\",\"configured\":" + hasConfig() + ",\"other\":" + otherVpnOn()
                + ",\"endpoint\":\"" + clean(endpoint()) + "\",\"error\":\"" + clean(error) + "\"}";
    }

    private static String clean(String s) {
        return s == null ? "" : s.replaceAll("[\"\\\\\\p{Cntrl}]", "");
    }

    private void publish() {
        listener.onVpnState(stateJson());
    }

    void shutdown() {
        down();
        worker.shutdown();
    }
}
