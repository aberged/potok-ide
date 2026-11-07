package rs.potok.ide;

import android.content.ClipData;
import android.content.ContentResolver;
import android.net.Uri;
import android.util.Base64;
import android.util.Pair;
import android.view.View;
import android.view.inputmethod.InputMethodManager;
import android.webkit.MimeTypeMap;
import android.webkit.WebView;

import androidx.core.view.ContentInfoCompat;
import androidx.core.view.OnReceiveContentListener;
import androidx.core.view.ViewCompat;

import com.getcapacitor.JSObject;
import com.getcapacitor.Logger;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

/**
 * GIFs, stickers and pictures sent from the keyboard (InputConnection#commitContent,
 * see PotokWebView). The web app (assets/js/keyboard_media.js) calls start while a
 * composer is on the page, so keyboards behave as before everywhere else. Each file
 * is copied into the cache and read from there, as the keyboard's permission to read
 * it ends with the keyboard's request.
 */
@CapacitorPlugin(name = "KeyboardContent")
public class KeyboardContentPlugin extends Plugin {
    private static final String EVENT = "contentReceived";
    private static final String INBOX_DIR = "keyboard_inbox";
    private static final String[] MIME_TYPES = {"image/*"};
    private static final Pattern FILE_ID = Pattern.compile("[A-Za-z0-9]{1,64}");
    private static final int MAX_CHUNK = 4 * 1024 * 1024;
    private static final long MAX_BYTES = 100L * 1024 * 1024;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    @Override
    public void load() {
        executor.execute(() -> deleteRecursively(inbox()));
    }

    @PluginMethod
    public void start(PluginCall call) {
        listen(MIME_TYPES, this::receive);
        call.resolve();
    }

    @PluginMethod
    public void stop(PluginCall call) {
        listen(null, null);
        call.resolve();
    }

    @PluginMethod
    public void readChunk(PluginCall call) {
        String id = call.getString("id");
        // org.json reads small numbers as Integer, which `call.getLong` would ignore.
        long offset = Math.max(0L, call.getData().optLong("offset", 0L));
        int length = Math.max(1, Math.min(call.getData().optInt("length", MAX_CHUNK), MAX_CHUNK));

        executor.execute(() -> {
            File file = storedFile(id);

            if (file == null) {
                call.reject("Keyboard content not found");
                return;
            }

            try (RandomAccessFile input = new RandomAccessFile(file, "r")) {
                int size = (int) Math.max(0L, Math.min(length, input.length() - offset));
                byte[] buffer = new byte[size];

                input.seek(offset);
                input.readFully(buffer);

                JSObject result = new JSObject();
                result.put("data", Base64.encodeToString(buffer, Base64.NO_WRAP));
                call.resolve(result);
            } catch (IOException exception) {
                call.reject("Could not read the keyboard content", exception);
            }
        });
    }

    @PluginMethod
    public void clear(PluginCall call) {
        String id = call.getString("id");

        executor.execute(() -> {
            File file = storedFile(id);

            if (file != null) {
                file.delete();
            }

            call.resolve();
        });
    }

    private void listen(String[] mimeTypes, OnReceiveContentListener listener) {
        getBridge().executeOnMainThread(() -> {
            WebView webView = getBridge().getWebView();
            ViewCompat.setOnReceiveContentListener(webView, mimeTypes, listener);

            // A field already in focus learns what the WebView takes only from a new connection.
            if (webView.hasFocus()) {
                InputMethodManager keyboard = getContext().getSystemService(InputMethodManager.class);

                if (keyboard != null) {
                    keyboard.restartInput(webView);
                }
            }
        });
    }

    // Runs on the WebView's keyboard thread. What is returned goes back to the keyboard
    // as refused, like a full page load that took the web app's listener away.
    private ContentInfoCompat receive(View view, ContentInfoCompat payload) {
        if (!hasListeners(EVENT)) {
            return payload;
        }

        Pair<ContentInfoCompat, ContentInfoCompat> parts = payload.partition(item -> readable(item.getUri()));
        ContentInfoCompat accepted = parts.first;

        if (accepted != null) {
            // The payload holds the permission to read the URI: it has to live until the copy is done.
            executor.execute(() -> store(accepted));
        }

        return parts.second;
    }

    // Only other apps' content: a file:// URI or one of our own provider could make
    // the app post its private files.
    private boolean readable(Uri uri) {
        String ownAuthority = getContext().getPackageName() + ".fileprovider";

        return uri != null
            && ContentResolver.SCHEME_CONTENT.equals(uri.getScheme())
            && !ownAuthority.equals(uri.getAuthority());
    }

    private void store(ContentInfoCompat payload) {
        ClipData clip = payload.getClip();

        for (int index = 0; index < clip.getItemCount(); index++) {
            Uri uri = clip.getItemAt(index).getUri();
            String mimeType = mimeType(uri, clip);
            String id = UUID.randomUUID().toString().replace("-", "");
            File target = new File(inbox(), id);

            try {
                if (!mimeType.startsWith("image/")) {
                    throw new IOException("Not an image: " + mimeType);
                }

                copy(uri, target);

                JSObject event = new JSObject();
                event.put("id", id);
                event.put("name", fileName(mimeType, index));
                event.put("mimeType", mimeType);
                event.put("size", target.length());
                notifyListeners(EVENT, event);
            } catch (IOException | RuntimeException exception) {
                Logger.error("KeyboardContent", "Could not store keyboard content", exception);
                target.delete();

                JSObject event = new JSObject();
                event.put("failed", true);
                notifyListeners(EVENT, event);
            }
        }
    }

    private void copy(Uri uri, File target) throws IOException {
        File inbox = inbox();

        if (!inbox.isDirectory() && !inbox.mkdirs()) {
            throw new IOException("Could not create " + inbox);
        }

        try (InputStream input = getContext().getContentResolver().openInputStream(uri);
             OutputStream output = new FileOutputStream(target)) {
            if (input == null) {
                throw new IOException("No stream for " + uri);
            }

            byte[] buffer = new byte[64 * 1024];
            long copied = 0L;
            int read;

            while ((read = input.read(buffer)) != -1) {
                copied += read;

                if (copied > MAX_BYTES) {
                    throw new IOException("Keyboard content is too large");
                }

                output.write(buffer, 0, read);
            }
        }
    }

    private String mimeType(Uri uri, ClipData clip) {
        String type = getContext().getContentResolver().getType(uri);

        if (type == null && clip.getDescription().getMimeTypeCount() > 0) {
            type = clip.getDescription().getMimeType(0);
        }

        return type == null ? "" : type.toLowerCase(Locale.ROOT);
    }

    private String fileName(String mimeType, int index) {
        String extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType);
        String suffix = index == 0 ? "" : "-" + index;

        return "keyboard-" + System.currentTimeMillis() + suffix + "." + (extension == null ? "img" : extension);
    }

    private File storedFile(String id) {
        if (id == null || !FILE_ID.matcher(id).matches()) {
            return null;
        }

        File file = new File(inbox(), id);
        return file.isFile() ? file : null;
    }

    private File inbox() {
        return new File(getContext().getCacheDir(), INBOX_DIR);
    }

    private void deleteRecursively(File file) {
        File[] children = file.listFiles();

        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }

        file.delete();
    }
}
