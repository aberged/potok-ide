package rs.potok.ide;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.util.Base64;

import androidx.annotation.NonNull;
import androidx.core.app.NotificationCompat;

import com.capacitorjs.plugins.pushnotifications.PushNotificationsPlugin;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.net.URLDecoder;
import java.util.Map;

public class PotokMessagingService extends FirebaseMessagingService {
    private static final String CHANNEL_NAME = "Potok";
    private static final String CHANNEL_DESCRIPTION = "Activity and invitation updates";
    private static final String FALLBACK_BASE_URL = "https://potok-ide.fly.dev";
    private static final String FALLBACK_BADGE_URL = FALLBACK_BASE_URL + "/images/pwa/icon-192.png";

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

        String title = firstNonBlank(rawTitle, getString(R.string.app_name));
        String body = firstNonBlank(rawBody, "");

        String channelId = firstNonBlank(data.get("android_channel_id"), getString(R.string.default_notification_channel_id));
        ensureNotificationChannel(channelId);

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(buildContentIntent(remoteMessage));

        String badge = data.get("badge");
        Bitmap largeIcon = fetchRemoteBitmap(badge);
        if (largeIcon != null) {
            builder.setLargeIcon(largeIcon);
        }

        String remoteImageURL = firstNonBlank(data.get("android_image"), data.get("image"));
        Bitmap remoteImage = fetchRemoteBitmap(remoteImageURL, false);
        if (remoteImage != null) {
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

        NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (notificationManager == null) {
            return;
        }

        String tag = data.get("tag");
        notificationManager.notify(tag, notificationId(remoteMessage), builder.build());
    }

    @Override
    public void onNewToken(@NonNull String token) {
        super.onNewToken(token);
        PushNotificationsPlugin.onNewToken(token);
    }

    private PendingIntent buildContentIntent(RemoteMessage remoteMessage) {
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
            notificationId(remoteMessage),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT | pendingIntentImmutableFlag()
        );
    }

    private void ensureNotificationChannel(String channelId) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }

        NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (notificationManager == null) {
            return;
        }

        NotificationChannel existingChannel = notificationManager.getNotificationChannel(channelId);
        if (existingChannel != null) {
            return;
        }

        NotificationChannel channel = new NotificationChannel(
            channelId,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH
        );

        channel.setDescription(CHANNEL_DESCRIPTION);
        channel.enableVibration(true);
        notificationManager.createNotificationChannel(channel);
    }

    private int notificationId(RemoteMessage remoteMessage) {
        if (remoteMessage.getMessageId() != null) {
            return remoteMessage.getMessageId().hashCode();
        }

        String tag = remoteMessage.getData().get("tag");
        if (!isBlank(tag)) {
            return tag.hashCode();
        }

        return (int) System.currentTimeMillis();
    }

    private int pendingIntentImmutableFlag() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return PendingIntent.FLAG_IMMUTABLE;
        }

        return 0;
    }

    private Bitmap fetchRemoteBitmap(String rawUrl) {
        return fetchRemoteBitmap(rawUrl, true);
    }

    private Bitmap fetchRemoteBitmap(String rawUrl, boolean allowFallback) {
        String sanitizedUrl = sanitizeUrl(rawUrl, allowFallback);
        if (sanitizedUrl == null) {
            return null;
        }

        HttpURLConnection connection = null;

        try {
            URL url = URI.create(sanitizedUrl).toURL();
            connection = (HttpURLConnection) url.openConnection();
            connection.setConnectTimeout(5_000);
            connection.setReadTimeout(5_000);
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

    private String sanitizeUrl(String rawUrl, boolean allowFallback) {
        if (isBlank(rawUrl)) {
            return allowFallback ? FALLBACK_BADGE_URL : null;
        }

        String trimmedUrl = rawUrl.trim();

        if (trimmedUrl.startsWith("data:")) {
            return decodeDataUrl(trimmedUrl) != null ? trimmedUrl : null;
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

    private boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }

    private String firstNonBlank(String primary, String fallback) {
        return isBlank(primary) ? fallback : primary.trim();
    }
}