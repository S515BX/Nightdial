package app.tuner.tv;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Passwords and playlist links, encrypted with AES-256-GCM. The key lives in Android's keystore and never leaves it,
 * so the stored values are useless if the app's files are copied off the device. (Fire OS 5 / Android 5.1 has no
 * keystore AES; there the values fall back to the app's private storage.)
 */
final class Secrets {
    private static final String ALIAS = "nightdial-secrets";
    private final SharedPreferences prefs;

    Secrets(Context context) {
        prefs = context.getSharedPreferences("secrets", Context.MODE_PRIVATE);
    }

    static boolean validName(String name) {
        return name != null && name.length() > 0 && name.length() <= 64 && name.matches("[A-Za-z0-9_.:-]+");
    }

    synchronized String get(String name) {
        if (!validName(name)) return null;
        String stored = prefs.getString(name, null);
        if (stored == null) return null;
        try {
            if (stored.startsWith("1:") && Build.VERSION.SDK_INT >= 23) return Keystore.decrypt(stored.substring(2));
            if (stored.startsWith("0:")) return stored.substring(2);
        } catch (Exception e) {
            return null;
        }
        return null;
    }

    synchronized void set(String name, String value) {
        if (!validName(name) || value == null || value.length() > 16384) return;
        String stored;
        try {
            stored = Build.VERSION.SDK_INT >= 23 ? "1:" + Keystore.encrypt(value) : "0:" + value;
        } catch (Exception e) {
            stored = "0:" + value;
        }
        prefs.edit().putString(name, stored).apply();
    }

    synchronized void delete(String name) {
        if (validName(name)) prefs.edit().remove(name).apply();
    }

    /** Keystore code lives in its own class so Android 5.1 never loads it. */
    private static final class Keystore {
        private static SecretKey key() throws Exception {
            KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
            ks.load(null);
            if (ks.containsAlias(ALIAS)) {
                return ((KeyStore.SecretKeyEntry) ks.getEntry(ALIAS, null)).getSecretKey();
            }
            KeyGenerator kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            kg.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build());
            return kg.generateKey();
        }

        static String encrypt(String plain) throws Exception {
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, key());
            byte[] iv = c.getIV();
            byte[] body = c.doFinal(plain.getBytes(StandardCharsets.UTF_8));
            byte[] all = new byte[iv.length + body.length];
            System.arraycopy(iv, 0, all, 0, iv.length);
            System.arraycopy(body, 0, all, iv.length, body.length);
            return Base64.encodeToString(all, Base64.NO_WRAP);
        }

        static String decrypt(String encoded) throws Exception {
            byte[] all = Base64.decode(encoded, Base64.NO_WRAP);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, all, 0, 12));
            return new String(c.doFinal(all, 12, all.length - 12), StandardCharsets.UTF_8);
        }
    }
}
