package app.nightdial.tv;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Typing a VPN config with a TV remote is no fun, so the TV briefly serves a one-page form on the home network:
 * open the address on a phone or computer, enter the code shown on the TV and paste the config (or pick the file).
 * It only runs while that screen is open, closes after 10 minutes or 5 wrong codes, and accepts one config.
 */
final class ShareServer {
    interface Receiver {
        /** Returns "" if the text was accepted, otherwise a message to show on the phone. */
        String onText(String text);
    }

    private final Receiver receiver;
    private final String code;
    private ServerSocket server;
    private volatile boolean running;
    private int wrong;

    ShareServer(Receiver receiver) {
        this.receiver = receiver;
        this.code = String.format(Locale.ROOT, "%06d", new SecureRandom().nextInt(1_000_000));
    }

    String code() {
        return code;
    }

    /** Starts listening; returns the address to open, or null when the TV isn't on a home network. */
    String start() {
        String ip = lanAddress();
        if (ip == null) return null;
        try {
            server = new ServerSocket(0, 8);
            server.setSoTimeout(1000);
        } catch (IOException e) {
            return null;
        }
        running = true;
        final long until = System.currentTimeMillis() + 10 * 60 * 1000;
        Thread t = new Thread(() -> {
            while (running && System.currentTimeMillis() < until) {
                try (Socket s = server.accept()) {
                    s.setSoTimeout(8000);
                    handle(s);
                } catch (java.net.SocketTimeoutException ignored) {
                } catch (IOException e) {
                    if (!running) break;
                }
            }
            stop();
        }, "nightdial-share");
        t.setDaemon(true);
        t.start();
        return "http://" + ip + ":" + server.getLocalPort();
    }

    void stop() {
        running = false;
        try {
            if (server != null) server.close();
        } catch (IOException ignored) {
        }
    }

    private void handle(Socket s) throws IOException {
        InputStream in = s.getInputStream();
        String head = readHead(in);
        if (head == null) return;
        String[] lines = head.split("\r\n");
        String[] req = lines[0].split(" ");
        if (req.length < 2) return;
        Map<String, String> headers = new HashMap<>();
        for (int i = 1; i < lines.length; i++) {
            int c = lines[i].indexOf(':');
            if (c > 0) headers.put(lines[i].substring(0, c).trim().toLowerCase(Locale.ROOT), lines[i].substring(c + 1).trim());
        }
        OutputStream out = s.getOutputStream();
        if ("GET".equals(req[0]) && ("/".equals(req[1]) || req[1].startsWith("/?"))) {
            send(out, 200, page(""));
            return;
        }
        if (!"POST".equals(req[0]) || !"/send".equals(req[1])) {
            send(out, 404, page("Not found."));
            return;
        }
        int len;
        try {
            len = Integer.parseInt(headers.getOrDefault("content-length", "0"));
        } catch (NumberFormatException e) {
            len = 0;
        }
        if (len <= 0 || len > 64 * 1024) {
            send(out, 413, page("That's too big."));
            return;
        }
        byte[] body = new byte[len];
        int got = 0;
        while (got < len) {
            int n = in.read(body, got, len - got);
            if (n < 0) break;
            got += n;
        }
        Map<String, String> form = parseForm(new String(body, 0, got, StandardCharsets.UTF_8));
        if (!code.equals(form.getOrDefault("code", "").trim())) {
            wrong++;
            if (wrong >= 5) {
                send(out, 403, page("Too many wrong codes. Start again on the TV."));
                running = false;
            } else send(out, 403, page("That code doesn't match the one on the TV."));
            return;
        }
        String problem = receiver.onText(form.getOrDefault("text", ""));
        if (problem.isEmpty()) {
            send(out, 200, done());
            running = false;
        } else send(out, 400, page(problem));
    }

    private static String readHead(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int prev3 = 0, prev2 = 0, prev1 = 0, c;
        while ((c = in.read()) >= 0) {
            b.write(c);
            if (prev3 == '\r' && prev2 == '\n' && prev1 == '\r' && c == '\n') return b.toString("UTF-8");
            if (b.size() > 8192) return null;
            prev3 = prev2;
            prev2 = prev1;
            prev1 = c;
        }
        return null;
    }

    private static Map<String, String> parseForm(String body) {
        Map<String, String> m = new HashMap<>();
        for (String part : body.split("&")) {
            int eq = part.indexOf('=');
            if (eq <= 0) continue;
            try {
                m.put(URLDecoder.decode(part.substring(0, eq), "UTF-8"), URLDecoder.decode(part.substring(eq + 1), "UTF-8"));
            } catch (Exception ignored) {
            }
        }
        return m;
    }

    private static void send(OutputStream out, int status, String html) throws IOException {
        byte[] b = html.getBytes(StandardCharsets.UTF_8);
        String h = "HTTP/1.1 " + status + " " + (status == 200 ? "OK" : "Error") + "\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: " + b.length + "\r\n"
                + "Cache-Control: no-store\r\n"
                + "X-Frame-Options: DENY\r\n"
                + "X-Content-Type-Options: nosniff\r\n"
                + "Referrer-Policy: no-referrer\r\n"
                + "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'\r\n"
                + "Connection: close\r\n\r\n";
        out.write(h.getBytes(StandardCharsets.US_ASCII));
        out.write(b);
        out.flush();
    }

    private static final String STYLE = "<meta name=viewport content='width=device-width,initial-scale=1'><style>body{margin:0;background:#0f1220;color:#f2f4fa;font:16px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}"
            + "main{max-width:560px;margin:0 auto;padding:28px 18px}h1{font-size:24px;margin:0 0 6px}p{color:#b6bdd0}label{display:block;margin:16px 0 6px;font-weight:600}"
            + "input,textarea{width:100%;box-sizing:border-box;border:1px solid #2a3350;background:#151a2c;color:#f2f4fa;border-radius:12px;padding:12px;font:15px ui-monospace,Menlo,Consolas,monospace}"
            + "textarea{height:220px}button{margin-top:18px;width:100%;height:50px;border:0;border-radius:14px;background:linear-gradient(100deg,#5ee6c4,#58a6ff);color:#0b1020;font-weight:700;font-size:16px}"
            + ".err{padding:12px 14px;border-radius:12px;background:rgba(255,107,107,.12);color:#ffb3b3}</style>";

    private static String page(String message) {
        return "<!doctype html><html lang=en><head><meta charset=utf-8><title>Nightdial</title>" + STYLE + "</head><body><main>"
                + "<h1>Send a VPN config to Nightdial</h1><p>Enter the code shown on your TV, then paste your WireGuard config or pick the .conf file from your VPN provider.</p>"
                + (message.isEmpty() ? "" : "<p class=err>" + escape(message) + "</p>")
                + "<form method=post action=/send><label for=c>Code on the TV</label><input id=c name=code inputmode=numeric autocomplete=off maxlength=6 required>"
                + "<label for=f>Config file (optional)</label><input id=f type=file accept='.conf,.txt,text/plain'>"
                + "<label for=t>WireGuard config</label><textarea id=t name=text placeholder='[Interface]&#10;PrivateKey = …' required></textarea>"
                + "<button>Send to TV</button></form></main>"
                + "<script>document.getElementById('f').addEventListener('change',function(e){var x=e.target.files[0];if(!x)return;var r=new FileReader();r.onload=function(){document.getElementById('t').value=r.result};r.readAsText(x)})</script>"
                + "</body></html>";
    }

    private static String done() {
        return "<!doctype html><html lang=en><head><meta charset=utf-8><title>Nightdial</title>" + STYLE + "</head><body><main><h1>Sent</h1><p>Your TV has the config. You can close this page.</p></main></body></html>";
    }

    private static String escape(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    }

    /** The TV's address on the home network (Wi-Fi or Ethernet). */
    private static String lanAddress() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback() || ni.isVirtual() || ni.getName().startsWith("tun")) continue;
                for (InetAddress a : Collections.list(ni.getInetAddresses())) {
                    if (a instanceof Inet4Address && a.isSiteLocalAddress()) return a.getHostAddress();
                }
            }
        } catch (Exception ignored) {
        }
        return null;
    }
}
