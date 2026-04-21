package com.potok.ide;

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

    private Bitmap fetchRemoteBitmap(String urlString) {
        return fetchRemoteBitmap(urlString, true);
    }

    private Bitmap fetchRemoteBitmap(String urlString, boolean allowFallback) {
        if (isBlank(urlString)) {
            return fallbackBitmap(allowFallback);
        }

        String normalizedSource = normalizeBitmapSource(urlString);
        if (isBlank(normalizedSource)) {
            return fallbackBitmap(allowFallback);
        }

        // Check if it's a base64 data URL
        if (normalizedSource.startsWith("data:")) {
            Bitmap decoded = decodeBase64DataUrl(normalizedSource);
            if (decoded != null) {
                return decoded;
            }

            return fallbackBitmap(allowFallback);
        }

        // Otherwise handle as HTTP(S) URL
        HttpURLConnection connection = null;
        InputStream inputStream = null;

        try {
            URL url = URI.create(normalizedSource).toURL();
            String protocol = url.getProtocol();
            if (!"https".equalsIgnoreCase(protocol) && !"http".equalsIgnoreCase(protocol)) {
                return fallbackBitmap(allowFallback);
            }

            connection = (HttpURLConnection) url.openConnection();
            connection.setConnectTimeout(5_000);
            connection.setReadTimeout(5_000);
            connection.setInstanceFollowRedirects(true);
            connection.connect();

            int responseCode = connection.getResponseCode();
            if (responseCode < 200 || responseCode >= 300) {
                return fallbackBitmap(allowFallback);
            }

            inputStream = connection.getInputStream();
            return BitmapFactory.decodeStream(inputStream);
        } catch (IOException | RuntimeException ignored) {
            return fallbackBitmap(allowFallback);
        } finally {
            if (inputStream != null) {
                try {
                    inputStream.close();
                } catch (IOException ignored) {
                }
            }

            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private Bitmap decodeBase64DataUrl(String dataUrl) {
        try {
            // Supports data:image/*;base64,[data] and data:image/*;base64/[data]
            String trimmed = dataUrl == null ? null : dataUrl.trim();
            if (isBlank(trimmed) || !trimmed.startsWith("data:")) {
                return fallbackBitmap(true);
            }

            int base64MarkerIndex = trimmed.indexOf(";base64");
            if (base64MarkerIndex == -1) {
                return fallbackBitmap(true);
            }

            int payloadStartIndex = base64MarkerIndex + ";base64".length();
            while (payloadStartIndex < trimmed.length()) {
                char separator = trimmed.charAt(payloadStartIndex);
                if (separator == ',' || separator == '/' || separator == ';') {
                    payloadStartIndex++;
                    continue;
                }

                break;
            }

            if (payloadStartIndex >= trimmed.length()) {
                return fallbackBitmap(true);
            }

            String base64String = trimmed.substring(payloadStartIndex).trim();
            if (base64String.startsWith("\"") && base64String.endsWith("\"") && base64String.length() >= 2) {
                base64String = base64String.substring(1, base64String.length() - 1);
            }

            base64String = base64String.replaceAll("\\s", "");
            if (base64String.contains("%")) {
                base64String = URLDecoder.decode(base64String, StandardCharsets.UTF_8);
                base64String = base64String.replace(" ", "+").replaceAll("\\s", "");
            }

            byte[] decodedBytes;
            try {
                decodedBytes = Base64.decode(base64String, Base64.DEFAULT);
            } catch (IllegalArgumentException ignored) {
                decodedBytes = Base64.decode(base64String, Base64.URL_SAFE | Base64.NO_WRAP);
            }

            return BitmapFactory.decodeByteArray(decodedBytes, 0, decodedBytes.length);
        } catch (Exception ignored) {
            return fallbackBitmap(true);
        }
    }

    private Bitmap fallbackBitmap(boolean allowFallback) {
        if (!allowFallback) {
            return null;
        }

        return fetchRemoteBitmap(FALLBACK_BADGE_URL, false);
    }

    private String normalizeBitmapSource(String source) {
        if (isBlank(source)) {
            return null;
        }

        String trimmed = source.trim();

        if (trimmed.startsWith("data:")) {
            return trimmed;
        }

        if (trimmed.startsWith("//")) {
            return "https:" + trimmed;
        }

        if (trimmed.startsWith("/")) {
            return FALLBACK_BASE_URL + trimmed;
        }

        return trimmed;
    }

    private String firstNonBlank(String value, String fallback) {
        if (isBlank(value)) {
            return fallback;
        }

        return value;
    }

    private boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }
}