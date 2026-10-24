package app.tuner.tv;

import java.io.BufferedInputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.UnsupportedEncodingException;
import java.net.HttpURLConnection;
import java.net.MalformedURLException;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.GZIPInputStream;

/**
 * Fetches from the IPTV provider on behalf of the app's web page, the same job server.js does on a computer.
 * Web pages can't call most IPTV servers directly, so the page asks for /proxy?u=... and this class answers.
 * HLS playlists are rewritten so every segment and key also comes through here.
 * Plain Java (no Android classes) so it can be tested off-device.
 */
public final class Relay {
    private Relay() {}

    public static final class Result {
        public final int status;
        public final String mime;
        public final String encoding;
        public final Map<String, String> headers;
        public final InputStream body;

        Result(int status, String mime, String encoding, Map<String, String> headers, InputStream body) {
            this.status = status;
            this.mime = mime;
            this.encoding = encoding;
            this.headers = headers;
            this.body = body;
        }
    }

    static String userAgent = "Tuner/1.0";
    private static final Pattern URI_ATTR = Pattern.compile("URI=\"([^\"]+)\"");
    private static final Pattern PLAYLIST_PATH = Pattern.compile("\\.m3u8?(\\?|$)", Pattern.CASE_INSENSITIVE);

    public static Result handle(String target, Map<String, String> requestHeaders) throws IOException {
        if (target == null || !(target.startsWith("http://") || target.startsWith("https://"))) {
            return text(400, "Bad address");
        }
        HttpURLConnection c = open(target, requestHeaders);
        int code = c.getResponseCode();
        String type = c.getContentType();
        String finalUrl = c.getURL().toString();
        InputStream in = code >= 400 ? c.getErrorStream() : c.getInputStream();
        if (in == null) in = new ByteArrayInputStream(new byte[0]);

        Map<String, String> headers = new HashMap<>();
        headers.put("Cache-Control", "no-store");
        // Provider content is data, never a page: it can't run script inside the app.
        headers.put("Content-Security-Policy", "sandbox");
        headers.put("X-Content-Type-Options", "nosniff");

        if (isPlaylist(type, finalUrl) || isPlaylist(null, target)) {
            String body = rewrite(readAll(in), finalUrl);
            return new Result(code, "application/vnd.apple.mpegurl", "utf-8", headers,
                    new ByteArrayInputStream(body.getBytes(StandardCharsets.UTF_8)));
        }

        String mime = "application/octet-stream";
        String encoding = null;
        if (type != null) {
            String[] parts = type.split(";");
            if (!parts[0].trim().isEmpty()) mime = parts[0].trim();
            for (int i = 1; i < parts.length; i++) {
                String p = parts[i].trim();
                if (p.toLowerCase(Locale.ROOT).startsWith("charset=")) encoding = p.substring(8).trim();
            }
        }
        String range = c.getHeaderField("Content-Range");
        if (range != null) headers.put("Content-Range", range);
        String acceptRanges = c.getHeaderField("Accept-Ranges");
        if (acceptRanges != null) headers.put("Accept-Ranges", acceptRanges);
        // TV guide files are often shared compressed (.xml.gz); unpack them here so any Fire TV can read them.
        if (range == null && code < 400) {
            BufferedInputStream peek = new BufferedInputStream(in);
            peek.mark(4);
            int b0 = peek.read(), b1 = peek.read();
            peek.reset();
            in = peek;
            if (b0 == 0x1f && b1 == 0x8b) {
                in = new GZIPInputStream(peek, 64 * 1024);
                if (mime.contains("gzip") || mime.equals("application/octet-stream")) mime = "text/xml";
            }
        }
        return new Result(code, mime, encoding, headers, in);
    }

    /** Opens the address, following redirects by hand (Java won't follow http to https on its own). */
    static HttpURLConnection open(String target, Map<String, String> requestHeaders) throws IOException {
        URL url = new URL(target);
        for (int hop = 0; hop < 6; hop++) {
            HttpURLConnection c = (HttpURLConnection) url.openConnection();
            c.setInstanceFollowRedirects(false);
            c.setConnectTimeout(15000);
            c.setReadTimeout(30000);
            c.setRequestProperty("User-Agent", userAgent);
            c.setRequestProperty("Accept", "*/*");
            String range = header(requestHeaders, "Range");
            if (range != null) c.setRequestProperty("Range", range);
            int code = c.getResponseCode();
            if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                String location = c.getHeaderField("Location");
                c.disconnect();
                if (location == null) throw new IOException("Redirect without a location");
                url = new URL(url, location);
                continue;
            }
            return c;
        }
        throw new IOException("Too many redirects");
    }

    static boolean isPlaylist(String contentType, String url) {
        if (contentType != null && contentType.toLowerCase(Locale.ROOT).contains("mpegurl")) return true;
        if (url == null) return false;
        String path = url;
        try { path = new URL(url).getPath(); } catch (MalformedURLException ignored) { }
        return PLAYLIST_PATH.matcher(path).find();
    }

    static String rewrite(String text, String base) throws MalformedURLException {
        URL baseUrl = new URL(base);
        StringBuilder out = new StringBuilder(text.length() + 256);
        for (String line : text.split("\r?\n")) {
            String l = line.trim();
            if (l.isEmpty()) {
                out.append(line);
            } else if (l.startsWith("#")) {
                Matcher m = URI_ATTR.matcher(line);
                StringBuffer sb = new StringBuffer();
                while (m.find()) {
                    m.appendReplacement(sb, Matcher.quoteReplacement("URI=\"" + proxied(baseUrl, m.group(1)) + "\""));
                }
                m.appendTail(sb);
                out.append(sb);
            } else {
                out.append(proxied(baseUrl, l));
            }
            out.append('\n');
        }
        return out.toString();
    }

    static String proxied(URL base, String ref) {
        String absolute;
        try { absolute = new URL(base, ref).toString(); } catch (MalformedURLException e) { absolute = ref; }
        try { return "/proxy?u=" + URLEncoder.encode(absolute, "UTF-8"); } catch (UnsupportedEncodingException e) { return ref; }
    }

    static String header(Map<String, String> headers, String name) {
        if (headers == null) return null;
        for (Map.Entry<String, String> e : headers.entrySet()) {
            if (e.getKey() != null && e.getKey().equalsIgnoreCase(name)) return e.getValue();
        }
        return null;
    }

    public static Result text(int status, String message) {
        Map<String, String> headers = new HashMap<>();
        headers.put("Cache-Control", "no-store");
        return new Result(status, "text/plain", "utf-8", headers,
                new ByteArrayInputStream(message.getBytes(StandardCharsets.UTF_8)));
    }

    public static String readAll(InputStream in) throws IOException {
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        } finally {
            in.close();
        }
    }
}
