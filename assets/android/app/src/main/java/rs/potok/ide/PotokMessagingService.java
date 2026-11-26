package rs.potok.ide;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.service.notification.StatusBarNotification;
import android.util.Base64;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.app.Person;
import androidx.core.graphics.drawable.IconCompat;

import com.capacitorjs.plugins.pushnotifications.PushNotificationsPlugin;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

/**
 * Draws every Potok notification. The server sends Android its payload as data
 * alone (PotokIde.PushNotifications.FCM), so this runs in the background too:
 *
 * - the title is the conversation (the group, or the person of a direct
 *   conversation), the large icon its picture (`icon`);
 * - messages, mentions and replies of one conversation share a tag and stack
 *   in one MessagingStyle notification, each line with its sender's picture;
 * - a notification with the same tag replaces the one before (Android tells
 *   notifications apart by tag and id together, so a tagged one has a fixed id);
 * - `label` ("Calendar", "Notice") goes in the header, `timestamp` is its time.
 */
public class PotokMessagingService extends FirebaseMessagingService {
    private static final String CHANNEL_NAME = "Potok";
    // The id of every tagged notification: the tag alone tells them apart.
    private static final int TAGGED_NOTIFICATION_ID = 1;
    private static final int MAX_STACKED_MESSAGES = 6;
    private static final int IMAGE_TIMEOUT_MS = 3_000;
    private static final int BRAND_COLOR = 0xFF004599;

    @Override
    public void onMessageReceived(@NonNull RemoteMessage remoteMessage) {
        super.onMessageReceived(remoteMessage);

        PushNotificationsPlugin.sendRemoteMessage(remoteMessage);

        Map<String, String> data = remoteMessage.getData();
        String rawTitle = data.get("title");
        String rawBody = data.get("body");

        if (isBlank(rawTitle) && isBlank(rawBody)) {
            return;
        }

        NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (notificationManager == null) {
            return;
        }

        String title = firstNonBlank(rawTitle, getString(R.string.app_name));
        String body = firstNonBlank(rawBody, "");
        String kind = firstNonBlank(data.get("kind"), "");
        String tag = blankToNull(data.get("tag"));
        String label = blankToNull(data.get("label"));
        long when = parseLong(data.get("timestamp"), System.currentTimeMillis());

        String channelId = firstNonBlank(data.get("android_channel_id"), getString(R.string.default_notification_channel_id));
        ensureNotificationChannel(notificationManager, channelId, label);

        int id = tag != null ? TAGGED_NOTIFICATION_ID : messageHash(remoteMessage);
        int requestCode = tag != null ? tag.hashCode() : messageHash(remoteMessage);

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setColor(BRAND_COLOR)
            .setContentTitle(title)
            .setContentText(body)
            .setWhen(when)
            .setShowWhen(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(category(kind))
            .setAutoCancel(true)
            .setContentIntent(buildContentIntent(remoteMessage, requestCode));

        if (label != null) {
            builder.setSubText(label);
        }

        Bitmap largeIcon = fetchRemoteBitmap(firstNonBlank(data.get("icon"), data.get("badge")));
        if (largeIcon != null) {
            builder.setLargeIcon(largeIcon);
        }

        Bitmap remoteImage = fetchRemoteBitmap(firstNonBlank(data.get("android_image"), data.get("image")));

        if (isChat(kind) && !isBlank(data.get("text")) && tag != null) {
            builder.setStyle(messagingStyle(notificationManager, data, tag, title, when));
        } else if (remoteImage != null) {
            builder.setStyle(
                new NotificationCompat.BigPictureStyle()
                    .bigPicture(remoteImage)
                    .bigLargeIcon((Bitmap) null)
                    .setBigContentTitle(title)
                    .setSummaryText(body)
            );
        } else {
            builder.setStyle(new NotificationCompat.BigTextStyle().bigText(body));
        }

        notificationManager.notify(tag, id, builder.build());
    }

    @Override
    public void onNewToken(@NonNull String token) {
        super.onNewToken(token);
        PushNotificationsPlugin.onNewToken(token);
    }

    // The conversation's notification so far, with this message added: the
    // newest MAX_STACKED_MESSAGES lines, each under its sender's name and picture.
    private NotificationCompat.MessagingStyle messagingStyle(
        NotificationManager notificationManager,
        Map<String, String> data,
        String tag,
        String title,
        long when
    ) {
        boolean direct = "true".equals(data.get("direct"));

        NotificationCompat.MessagingStyle style = activeStyle(notificationManager, tag);
        if (style == null) {
            Person me = new Person.Builder().setKey("me").setName(getString(R.string.notification_you)).build();
            style = new NotificationCompat.MessagingStyle(me);
        }

        style.setGroupConversation(!direct);
        style.setConversationTitle(direct ? null : title);

        String senderName = firstNonBlank(data.get("sender"), title);
        Person.Builder sender = new Person.Builder().setKey("sender:" + senderName).setName(senderName);
        Bitmap senderIcon = fetchRemoteBitmap(data.get("sender_icon"));
        if (senderIcon != null) {
            sender.setIcon(IconCompat.createWithBitmap(senderIcon));
        }

        style.addMessage(new NotificationCompat.MessagingStyle.Message(data.get("text"), when, sender.build()));

        List<NotificationCompat.MessagingStyle.Message> messages = style.getMessages();
        while (messages.size() > MAX_STACKED_MESSAGES) {
            messages.remove(0);
        }

        return style;
    }

    @Nullable
    private NotificationCompat.MessagingStyle activeStyle(NotificationManager notificationManager, String tag) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return null;
        }

        try {
            for (StatusBarNotification active : notificationManager.getActiveNotifications()) {
                if (tag.equals(active.getTag()) && active.getId() == TAGGED_NOTIFICATION_ID) {
                    Notification notification = active.getNotification();
                    return NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(notification);
                }
            }
        } catch (RuntimeException e) {
            return null;
        }

        return null;
    }

    private boolean isChat(String kind) {
        return "message".equals(kind) || "mention".equals(kind) || "reply".equals(kind);
    }

    private String category(String kind) {
        switch (kind) {
            case "message":
            case "mention":
            case "reply":
            case "reaction":
                return NotificationCompat.CATEGORY_MESSAGE;
            case "event":
                return NotificationCompat.CATEGORY_EVENT;
            case "event_reminder":
            case "process":
                return NotificationCompat.CATEGORY_REMINDER;
            case "test":
                return NotificationCompat.CATEGORY_STATUS;
            default:
                return NotificationCompat.CATEGORY_SOCIAL;
        }
    }

    private PendingIntent buildContentIntent(RemoteMessage remoteMessage, int requestCode) {
        Intent intent = new Intent(this, MainActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);

        if (remoteMessage.getMessageId() != null) {
            intent.putExtra("google.message_id", remoteMessage.getMessageId());
        }

        for (Map.Entry<String, String> entry : remoteMessage.getData().entrySet()) {
            intent.putExtra(entry.getKey(), entry.getValue());
        }

        return PendingIntent.getActivity(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT | pendingIntentImmutableFlag()
        );
    }

    // The page creates the channels with names in its language
    // (PotokIdeWeb.PushChannels); this one covers a push that comes first.
    private void ensureNotificationChannel(NotificationManager notificationManager, String channelId, @Nullable String label) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }

        if (notificationManager.getNotificationChannel(channelId) != null) {
            return;
        }

        NotificationChannel channel = new NotificationChannel(
            channelId,
            firstNonBlank(label, CHANNEL_NAME),
            NotificationManager.IMPORTANCE_HIGH
        );

        channel.enableVibration(true);
        notificationManager.createNotificationChannel(channel);
    }

    private int messageHash(RemoteMessage remoteMessage) {
        if (remoteMessage.getMessageId() != null) {
            return remoteMessage.getMessageId().hashCode();
        }

        return (int) System.currentTimeMillis();
    }

    private int pendingIntentImmutableFlag() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return PendingIntent.FLAG_IMMUTABLE;
        }

        return 0;
    }

    @Nullable
    private Bitmap fetchRemoteBitmap(String rawUrl) {
        String sanitizedUrl = sanitizeUrl(rawUrl);
        if (sanitizedUrl == null) {
            return null;
        }

        if (sanitizedUrl.startsWith("data:")) {
            return decodeDataUrl(sanitizedUrl);
        }

        HttpURLConnection connection = null;

        try {
            URL url = URI.create(sanitizedUrl).toURL();
            connection = (HttpURLConnection) url.openConnection();
            connection.setConnectTimeout(IMAGE_TIMEOUT_MS);
            connection.setReadTimeout(IMAGE_TIMEOUT_MS);
            connection.setInstanceFollowRedirects(true);
            connection.connect();

            if (connection.getResponseCode() >= 400) {
                return null;
            }

            try (InputStream stream = connection.getInputStream()) {
                return BitmapFactory.decodeStream(stream);
            }
        } catch (IOException | IllegalArgumentException e) {
            return null;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    @Nullable
    private String sanitizeUrl(String rawUrl) {
        if (isBlank(rawUrl)) {
            return null;
        }

        String trimmedUrl = rawUrl.trim();

        if (trimmedUrl.startsWith("data:")) {
            return trimmedUrl;
        }

        try {
            URI uri = URI.create(trimmedUrl);
            if (!uri.isAbsolute()) {
                return null;
            }

            String scheme = uri.getScheme();
            if (!"http".equalsIgnoreCase(scheme) && !"https".equalsIgnoreCase(scheme)) {
                return null;
            }

            return uri.toString();
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    @Nullable
    private Bitmap decodeDataUrl(String rawUrl) {
        int commaIndex = rawUrl.indexOf(',');
        if (commaIndex < 0 || commaIndex == rawUrl.length() - 1) {
            return null;
        }

        String metadata = rawUrl.substring(5, commaIndex);
        String payload = rawUrl.substring(commaIndex + 1);

        try {
            if (metadata.endsWith(";base64")) {
                byte[] bytes = Base64.decode(payload, Base64.DEFAULT);
                return BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            }

            String decoded = URLDecoder.decode(payload, StandardCharsets.UTF_8.name());
            byte[] bytes = decoded.getBytes(StandardCharsets.UTF_8);
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        } catch (IllegalArgumentException | IOException e) {
            return null;
        }
    }

    private long parseLong(String value, long fallback) {
        if (isBlank(value)) {
            return fallback;
        }

        try {
            return Long.parseLong(value.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }

    @Nullable
    private String blankToNull(String value) {
        return isBlank(value) ? null : value.trim();
    }

    private String firstNonBlank(String primary, String fallback) {
        return isBlank(primary) ? fallback : primary.trim();
    }
}
