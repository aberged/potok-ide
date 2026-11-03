package rs.potok.ide;

import android.content.ClipData;
import android.content.ContentResolver;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Parcelable;
import android.provider.OpenableColumns;
import android.util.Base64;
import android.webkit.MimeTypeMap;

import androidx.core.content.IntentCompat;

import com.getcapacitor.JSObject;
import com.getcapacitor.Logger;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

/**
 * Content shared to Potok from other apps (ACTION_SEND and ACTION_SEND_MULTIPLE on
 * MainActivity). Shared files are copied into the cache, next to a share.json, so the
 * web app (assets/js/share_inbox.js) can read them once a group is picked, even after
 * the process was killed. Only the newest share is kept, and none past a day.
 *
 * Everything runs on one thread in order: a getPending sent while a share is being
 * copied answers once the copy is done.
 */
@CapacitorPlugin(name = "ShareInbox")
public class ShareInboxPlugin extends Plugin {
    private static final String INBOX_DIR = "share_inbox";
    private static final String MANIFEST = "share.json";
    // Marks an intent as taken, so the activity's same intent is not shared twice.
    private static final String HANDLED_EXTRA = "rs.potok.ide.SHARE_HANDLED";
    private static final Pattern SHARE_ID = Pattern.compile("[A-Za-z0-9]{1,64}");
    private static final long MAX_AGE_MS = 24L * 60 * 60 * 1000;
    private static final int MAX_FILES = 50;
    private static final int MAX_CHUNK = 4 * 1024 * 1024;
    // Larger files are listed but not copied: no composer accepts them.
    private static final long MAX_COPY_BYTES = 1024L * 1024 * 1024;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    @Override
    public void load() {
        executor.execute(this::removeStaleShares);
        receive(getActivity().getIntent());
    }

    @Override
    protected void handleOnNewIntent(Intent intent) {
        super.handleOnNewIntent(intent);
        receive(intent);
    }

    @PluginMethod
    public void getPending(PluginCall call) {
        executor.execute(() -> {
            JSObject result = new JSObject();
            JSObject share = readPendingShare();

            if (share != null) {
                result.put("share", share);
            }

            call.resolve(result);
        });
    }

    @PluginMethod
    public void readChunk(PluginCall call) {
        String shareId = call.getString("shareId");
        String fileId = call.getString("fileId");
        // org.json reads small numbers as Integer, which `call.getLong` would ignore.
        long offset = Math.max(0L, call.getData().optLong("offset", 0L));
        int length = Math.max(1, Math.min(call.getData().optInt("length", MAX_CHUNK), MAX_CHUNK));

        executor.execute(() -> {
            File file = sharedFile(shareId, fileId);

            if (file == null) {
                call.reject("Shared file not found");
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
                call.reject("Could not read the shared file", exception);
            }
        });
    }

    @PluginMethod
    public void clear(PluginCall call) {
        String shareId = call.getString("shareId");

        executor.execute(() -> {
            if (shareId != null && SHARE_ID.matcher(shareId).matches()) {
                deleteRecursively(new File(inbox(), shareId));
            }

            call.resolve();
        });
    }

    private void receive(Intent intent) {
        if (intent == null || intent.getBooleanExtra(HANDLED_EXTRA, false)) {
            return;
        }

        // Opening the app from recent apps hands back the intent that started it.
        if ((intent.getFlags() & Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
            return;
        }

        String action = intent.getAction();

        if (!Intent.ACTION_SEND.equals(action) && !Intent.ACTION_SEND_MULTIPLE.equals(action)) {
            return;
        }

        intent.putExtra(HANDLED_EXTRA, true);

        String title = firstNonEmpty(
            intent.getStringExtra(Intent.EXTRA_SUBJECT),
            intent.getStringExtra(Intent.EXTRA_TITLE)
        );
        List<String> texts = sharedTexts(intent);
        List<Uri> uris = sharedUris(intent);
        String intentType = intent.getType();

        executor.execute(() -> {
            try {
                String id = store(title, texts, uris, intentType);

                if (id != null) {
                    JSObject event = new JSObject();
                    event.put("id", id);
                    notifyListeners("shareReceived", event, true);
                }
            } catch (IOException | JSONException exception) {
                Logger.error("ShareInbox", "Could not store a share", exception);
            }
        });
    }

    private List<String> sharedTexts(Intent intent) {
        List<String> texts = new ArrayList<>();
        ArrayList<CharSequence> many = intent.getCharSequenceArrayListExtra(Intent.EXTRA_TEXT);

        if (many != null) {
            for (CharSequence text : many) {
                addText(texts, text);
            }
        } else {
            addText(texts, intent.getCharSequenceExtra(Intent.EXTRA_TEXT));
        }

        // Some apps put the text only in the clip.
        ClipData clip = intent.getClipData();

        if (texts.isEmpty() && clip != null) {
            for (int index = 0; index < clip.getItemCount(); index++) {
                addText(texts, clip.getItemAt(index).getText());
            }
        }

        return texts;
    }

    private void addText(List<String> texts, CharSequence text) {
        if (text != null && text.toString().trim().length() > 0) {
            texts.add(text.toString().trim());
        }
    }

    private List<Uri> sharedUris(Intent intent) {
        LinkedHashSet<Uri> uris = new LinkedHashSet<>();

        if (Intent.ACTION_SEND_MULTIPLE.equals(intent.getAction())) {
            ArrayList<Uri> streams =
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri.class);

            if (streams != null) {
                uris.addAll(streams);
            } else {
                // The documented type is an ArrayList, but some apps send an array.
                Parcelable[] array =
                    IntentCompat.getParcelableArrayExtra(intent, Intent.EXTRA_STREAM, Uri.class);

                if (array != null) {
                    for (Parcelable item : array) {
                        uris.add((Uri) item);
                    }
                }
            }
        } else {
            Uri stream = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri.class);

            if (stream != null) {
                uris.add(stream);
            }
        }

        ClipData clip = intent.getClipData();

        if (clip != null) {
            for (int index = 0; index < clip.getItemCount(); index++) {
                Uri uri = clip.getItemAt(index).getUri();

                if (uri != null) {
                    uris.add(uri);
                }
            }
        }

        List<Uri> readable = new ArrayList<>();

        for (Uri uri : uris) {
            if (shareable(uri)) {
                readable.add(uri);
            }
        }

        return readable;
    }

    // Only other apps' content: a file:// URI or one of our own provider could make
    // the app post its private files.
    private boolean shareable(Uri uri) {
        String ownAuthority = getContext().getPackageName() + ".fileprovider";

        return ContentResolver.SCHEME_CONTENT.equals(uri.getScheme())
            && !ownAuthority.equals(uri.getAuthority());
    }

    // Copies the share into a new folder of the inbox and drops the older ones.
    // Returns the share's id, or null when nothing came.
    private String store(String title, List<String> texts, List<Uri> uris, String intentType)
        throws IOException, JSONException {
        File inbox = inbox();
        String id = UUID.randomUUID().toString().replace("-", "");
        File dir = new File(inbox, id);

        if (!dir.mkdirs()) {
            throw new IOException("Could not create " + dir);
        }

        ContentResolver resolver = getContext().getContentResolver();
        JSONArray files = new JSONArray();

        for (Uri uri : uris) {
            if (files.length() >= MAX_FILES) {
                break;
            }

            String fileId = String.valueOf(files.length());
            String[] details = openableDetails(resolver, uri);
            String name = cleanName(details[0], fileId);
            long reportedSize = details[1] == null ? -1L : Long.parseLong(details[1]);
            JSONObject file = new JSONObject()
                .put("id", fileId)
                .put("name", name)
                .put("mimeType", mimeType(resolver, uri, name, intentType));

            if (reportedSize > MAX_COPY_BYTES) {
                files.put(file.put("size", reportedSize));
                continue;
            }

            File target = new File(dir, fileId + "-" + storedName(name));

            try (InputStream input = resolver.openInputStream(uri);
                 OutputStream output = new FileOutputStream(target)) {
                if (input == null) {
                    throw new IOException("No stream for " + uri);
                }

                byte[] buffer = new byte[64 * 1024];
                int read;

                while ((read = input.read(buffer)) != -1) {
                    output.write(buffer, 0, read);
                }
            } catch (IOException | SecurityException exception) {
                Logger.error("ShareInbox", "Could not copy a shared file", exception);
                target.delete();
                continue;
            }

            files.put(file.put("size", target.length()).put("path", target.getName()));
        }

        if (title == null && texts.isEmpty() && files.length() == 0) {
            deleteRecursively(dir);
            return null;
        }

        JSONObject manifest = new JSONObject()
            .put("id", id)
            .put("title", title == null ? "" : title)
            .put("texts", new JSONArray(texts))
            .put("files", files);

        try (OutputStream output = new FileOutputStream(new File(dir, MANIFEST))) {
            output.write(manifest.toString().getBytes(StandardCharsets.UTF_8));
        }

        File[] others = inbox.listFiles();

        if (others != null) {
            for (File other : others) {
                if (!other.getName().equals(id)) {
                    deleteRecursively(other);
                }
            }
        }

        return id;
    }

    // The newest share, without where its files lie.
    private JSObject readPendingShare() {
        File[] dirs = inbox().listFiles(File::isDirectory);
        File newest = null;

        if (dirs != null) {
            for (File dir : dirs) {
                if (new File(dir, MANIFEST).isFile()
                    && (newest == null || dir.lastModified() > newest.lastModified())) {
                    newest = dir;
                }
            }
        }

        if (newest == null) {
            return null;
        }

        try {
            JSObject share = JSObject.fromJSONObject(readManifest(newest));
            JSONArray files = share.getJSONArray("files");

            for (int index = 0; index < files.length(); index++) {
                files.getJSONObject(index).remove("path");
            }

            return share;
        } catch (IOException | JSONException exception) {
            Logger.error("ShareInbox", "Could not read a share", exception);
            return null;
        }
    }

    private File sharedFile(String shareId, String fileId) {
        if (shareId == null || fileId == null || !SHARE_ID.matcher(shareId).matches()) {
            return null;
        }

        File dir = new File(inbox(), shareId);

        try {
            JSONArray files = readManifest(dir).getJSONArray("files");

            for (int index = 0; index < files.length(); index++) {
                JSONObject file = files.getJSONObject(index);

                if (fileId.equals(file.optString("id")) && file.has("path")) {
                    File path = new File(dir, file.getString("path"));
                    return dir.getCanonicalPath().equals(path.getParentFile().getCanonicalPath())
                        ? path
                        : null;
                }
            }
        } catch (IOException | JSONException exception) {
            return null;
        }

        return null;
    }

    private JSONObject readManifest(File dir) throws IOException, JSONException {
        File manifest = new File(dir, MANIFEST);
        byte[] bytes = new byte[(int) manifest.length()];

        try (RandomAccessFile input = new RandomAccessFile(manifest, "r")) {
            input.readFully(bytes);
        }

        return new JSONObject(new String(bytes, StandardCharsets.UTF_8));
    }

    // { display name, size } as the providing app reports them, either may be null.
    private String[] openableDetails(ContentResolver resolver, Uri uri) {
        String[] details = new String[2];
        String[] columns = {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE};

        try (Cursor cursor = resolver.query(uri, columns, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                int sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE);

                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    details[0] = cursor.getString(nameIndex);
                }

                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    details[1] = String.valueOf(cursor.getLong(sizeIndex));
                }
            }
        } catch (RuntimeException exception) {
            // Some providers refuse queries; the name falls back to the URI's last segment.
        }

        if (details[0] == null) {
            details[0] = uri.getLastPathSegment();
        }

        return details;
    }

    private String mimeType(ContentResolver resolver, Uri uri, String name, String intentType) {
        String type = resolver.getType(uri);

        if (type == null && intentType != null && !intentType.contains("*")) {
            type = intentType;
        }

        if (type == null) {
            int dot = name.lastIndexOf('.');

            if (dot >= 0) {
                String extension = name.substring(dot + 1).toLowerCase(Locale.ROOT);
                type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension);
            }
        }

        return type == null ? "" : type;
    }

    private String cleanName(String name, String fileId) {
        String cleaned = name == null ? "" : name.replaceAll("[/\\\\\\p{Cntrl}]", "_").trim();

        if (cleaned.isEmpty()) {
            cleaned = "file-" + fileId;
        }

        return cleaned.length() > 255 ? cleaned.substring(0, 255) : cleaned;
    }

    private String storedName(String name) {
        String stored = name.replaceAll("[^A-Za-z0-9._-]", "_");
        return stored.length() > 80 ? stored.substring(stored.length() - 80) : stored;
    }

    private String firstNonEmpty(String first, String second) {
        if (first != null && !first.trim().isEmpty()) {
            return first.trim();
        }

        return second != null && !second.trim().isEmpty() ? second.trim() : null;
    }

    private File inbox() {
        return new File(getContext().getCacheDir(), INBOX_DIR);
    }

    private void removeStaleShares() {
        File[] dirs = inbox().listFiles();
        long now = System.currentTimeMillis();

        if (dirs != null) {
            for (File dir : dirs) {
                if (now - dir.lastModified() > MAX_AGE_MS) {
                    deleteRecursively(dir);
                }
            }
        }
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
