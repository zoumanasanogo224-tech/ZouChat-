package com.zouchat.app;

import android.Manifest;
import android.app.Activity;
import android.media.AudioManager;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.app.DownloadManager;
import android.os.Environment;
import android.database.Cursor;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Build;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import android.view.WindowManager;
import java.net.HttpURLConnection;
import java.net.URL;
import com.google.firebase.messaging.FirebaseMessaging;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {
    private static final String APP_URL = "https://zoumanasanogo224-tech.github.io/ZouChat-/";
    private static final String APP_HOST = "zoumanasanogo224-tech.github.io";
    private static final int FILE_CHOOSER_REQUEST = 4102;
    private static final int MEDIA_PERMISSION_REQUEST = 4103;
    private WebView webView;
    private ValueCallback<Uri[]> filePathCallback;
    private PermissionRequest pendingWebPermissionRequest;
    private AudioManager audioManager;
    private int previousAudioMode = AudioManager.MODE_NORMAL;
    private boolean audioModeChanged = false;
    private volatile boolean updateCheckInProgress = false;
    private boolean updateDialogVisible = false;
    private String lastPromptedVersion = "";
    private boolean downloadReceiverRegistered = false;
    private boolean activityResumed = false;
    private final BroadcastReceiver updateDownloadReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (intent == null || !DownloadManager.ACTION_DOWNLOAD_COMPLETE.equals(intent.getAction())) return;
            long completedId = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L);
            long expectedId = getPreferences(MODE_PRIVATE).getLong("zouchat_update_download_id", -2L);
            if (completedId == expectedId) handleUpdateDownloadCompleted(completedId);
        }
    };

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 4104);
        }
        audioManager = (AudioManager) getSystemService(AUDIO_SERVICE);
        registerUpdateDownloadReceiver();
        webView = new WebView(this);
        setContentView(webView);
        webView.addJavascriptInterface(new ZouChatAndroidBridge(), "ZouChatAndroid");
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setCacheMode(WebSettings.LOAD_NO_CACHE);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(true);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, false);
        webView.setWebViewClient(new WebViewClient() {
            @Override public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                if (isTrustedAppUrl(Uri.parse(url))) requestFcmToken();
            }
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                if (isTrustedAppUrl(uri)) return false;
                try { startActivity(new Intent(Intent.ACTION_VIEW, uri)); }
                catch (ActivityNotFoundException ignored) {
                    Toast.makeText(MainActivity.this, "Impossible d’ouvrir ce lien.", Toast.LENGTH_SHORT).show();
                }
                return true;
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) Toast.makeText(MainActivity.this,
                    "ZouChat ne peut pas se connecter. Vérifie Internet puis réessaie.", Toast.LENGTH_LONG).show();
            }
        });
        webView.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (filePathCallback != null) filePathCallback.onReceiveValue(null);
                filePathCallback = callback;
                try {
                    Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                    intent.addCategory(Intent.CATEGORY_OPENABLE);
                    intent.setType("*/*");
                    intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"image/*", "video/*"});
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    startActivityForResult(intent, FILE_CHOOSER_REQUEST);
                } catch (ActivityNotFoundException e) {
                    filePathCallback = null;
                    callback.onReceiveValue(null);
                    Toast.makeText(MainActivity.this, "Impossible d’ouvrir la galerie ou les fichiers.", Toast.LENGTH_LONG).show();
                    return false;
                }
                return true;
            }
            @Override public void onPermissionRequest(PermissionRequest request) {
                runOnUiThread(() -> handleWebPermissionRequest(request));
            }
            @Override public void onPermissionRequestCanceled(PermissionRequest request) {
                if (pendingWebPermissionRequest == request) pendingWebPermissionRequest = null;
            }
        });
        webView.loadUrl(APP_URL + "?app_refresh=" + System.currentTimeMillis());
    }

    @Override protected void onResume() {
        super.onResume();
        activityResumed = true;
        // Reprend le contrôle d'un téléchargement même si Android a recréé l'activité.
        resumePendingUpdateInstall();
        // Vérifie aussi les mises à jour lorsque l'utilisateur revient dans ZouChat.
        checkForAppUpdate();
    }

    @Override protected void onPause() {
        activityResumed = false;
        super.onPause();
    }

    private boolean isTrustedAppUrl(Uri uri) {
        return uri != null && "https".equalsIgnoreCase(uri.getScheme()) && APP_HOST.equalsIgnoreCase(uri.getHost()) && (uri.getPort() == -1 || uri.getPort() == 443);
    }

    private void handleWebPermissionRequest(PermissionRequest request) {
        if (request.getOrigin() == null || !isTrustedAppUrl(request.getOrigin())) { request.deny(); return; }
        List<String> androidPermissions = new ArrayList<>();
        for (String resource : request.getResources()) {
            if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(resource)) androidPermissions.add(Manifest.permission.RECORD_AUDIO);
            else if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(resource)) androidPermissions.add(Manifest.permission.CAMERA);
            else { request.deny(); return; }
        }
        List<String> missing = new ArrayList<>();
        for (String permission : androidPermissions) {
            if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED && !missing.contains(permission)) missing.add(permission);
        }
        if (missing.isEmpty()) { prepareCallAudio(); request.grant(request.getResources()); return; }
        if (pendingWebPermissionRequest != null) pendingWebPermissionRequest.deny();
        pendingWebPermissionRequest = request;
        requestPermissions(missing.toArray(new String[0]), MEDIA_PERMISSION_REQUEST);
    }

    private void prepareCallAudio() {
        // WebRTC sur Android WebView fonctionne mieux en mode communication.
        if (audioManager == null) return;
        try {
            if (!audioModeChanged) previousAudioMode = audioManager.getMode();
            audioManager.setMode(AudioManager.MODE_IN_COMMUNICATION);
            audioModeChanged = true;
        } catch (SecurityException ignored) {
            // Ne bloque pas les appels si le système refuse le changement de mode audio.
        }
    }

    private void restoreAudioMode() {
        if (audioManager == null || !audioModeChanged) return;
        try { audioManager.setMode(previousAudioMode); } catch (SecurityException ignored) { }
        audioModeChanged = false;
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != MEDIA_PERMISSION_REQUEST) return;
        PermissionRequest request = pendingWebPermissionRequest;
        pendingWebPermissionRequest = null;
        if (request == null) return;
        boolean allGranted = true;
        for (int result : grantResults) if (result != PackageManager.PERMISSION_GRANTED) { allGranted = false; break; }
        if (allGranted) { prepareCallAudio(); request.grant(request.getResources()); }
        else {
            request.deny();
            Toast.makeText(this, "Autorise le micro ou la caméra pour utiliser cette fonction.", Toast.LENGTH_LONG).show();
        }
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == FILE_CHOOSER_REQUEST && filePathCallback != null) {
            Uri[] results = null;
            if (resultCode == Activity.RESULT_OK && data != null) {
                if (data.getClipData() != null) {
                    int count = data.getClipData().getItemCount();
                    results = new Uri[count];
                    for (int i = 0; i < count; i++) results[i] = data.getClipData().getItemAt(i).getUri();
                } else if (data.getData() != null) results = new Uri[]{data.getData()};
            }
            filePathCallback.onReceiveValue(results);
            filePathCallback = null;
        }
    }


    // Vérifie les nouvelles versions Android publiées dans les Releases GitHub.
    // Android exige toujours une confirmation de l'utilisateur pour installer un APK.
    private void checkForAppUpdate() {
        if (updateCheckInProgress || isFinishing()) return;
        updateCheckInProgress = true;
        new Thread(() -> {
            HttpURLConnection connection = null;
            try {
                URL url = new URL("https://api.github.com/repos/zoumanasanogo224-tech/ZouChat-/releases/latest");
                connection = (HttpURLConnection) url.openConnection();
                connection.setRequestMethod("GET");
                connection.setConnectTimeout(7000);
                connection.setReadTimeout(7000);
                connection.setRequestProperty("Accept", "application/vnd.github+json");
                connection.setRequestProperty("User-Agent", "ZouChat-Android");
                if (connection.getResponseCode() != HttpURLConnection.HTTP_OK) return;
                java.io.InputStream stream = connection.getInputStream();
                java.io.ByteArrayOutputStream buffer = new java.io.ByteArrayOutputStream();
                byte[] chunk = new byte[4096];
                int read;
                while ((read = stream.read(chunk)) != -1) buffer.write(chunk, 0, read);
                stream.close();
                JSONObject release = new JSONObject(buffer.toString("UTF-8"));
                String latestTag = release.optString("tag_name", "");
                String latestVersion = latestTag.replaceFirst("^android-v", "");
                String installedVersion = getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
                String apkUrl = "";
                JSONArray assets = release.optJSONArray("assets");
                if (assets != null) {
                    for (int i = 0; i < assets.length(); i++) {
                        JSONObject asset = assets.optJSONObject(i);
                        if (asset != null && asset.optString("name", "").toLowerCase().endsWith(".apk") && !asset.optString("name", "").toLowerCase().contains("debug")) {
                            apkUrl = asset.optString("browser_download_url", "");
                            if (!apkUrl.isEmpty()) break;
                        }
                    }
                }
                if (!apkUrl.isEmpty() && compareVersions(latestVersion, installedVersion) > 0) {
                    final String versionToInstall = latestVersion;
                    final String downloadUrl = apkUrl;
                    runOnUiThread(() -> {
                        if (isFinishing() || (Build.VERSION.SDK_INT >= 17 && isDestroyed()) ||
                            updateDialogVisible || versionToInstall.equals(lastPromptedVersion)) return;
                        lastPromptedVersion = versionToInstall;
                        updateDialogVisible = true;
                        AlertDialog dialog = new AlertDialog.Builder(MainActivity.this)
                            .setTitle("Nouvelle version de ZouChat")
                            .setMessage("La version " + versionToInstall + " est disponible. Veux-tu mettre à jour l’application maintenant ?")
                            .setPositiveButton("Télécharger et installer", (d, which) -> {
                                enqueueUpdateDownload(downloadUrl, versionToInstall);
                            })
                            .setNegativeButton("Plus tard", null)
                            .create();
                        dialog.setOnDismissListener(d -> updateDialogVisible = false);
                        dialog.show();
                    });
                }
            } catch (Exception ignored) {
                // La messagerie reste utilisable même si la vérification échoue.
            } finally {
                if (connection != null) connection.disconnect();
                updateCheckInProgress = false;
            }
        }).start();
    }


    private void registerUpdateDownloadReceiver() {
        IntentFilter filter = new IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(updateDownloadReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(updateDownloadReceiver, filter);
        }
        downloadReceiverRegistered = true;
    }

    private void enqueueUpdateDownload(String downloadUrl, String version) {
        try {
            Uri uri = Uri.parse(downloadUrl);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || !"github.com".equalsIgnoreCase(uri.getHost()) &&
                !"objects.githubusercontent.com".equalsIgnoreCase(uri.getHost()) &&
                !"release-assets.githubusercontent.com".equalsIgnoreCase(uri.getHost())) {
                Toast.makeText(this, "Adresse de téléchargement non sécurisée.", Toast.LENGTH_LONG).show();
                return;
            }
            DownloadManager manager = (DownloadManager) getSystemService(DOWNLOAD_SERVICE);
            if (manager == null) throw new IllegalStateException("DownloadManager indisponible");
            DownloadManager.Request request = new DownloadManager.Request(uri);
            request.setTitle("Mise à jour de ZouChat");
            request.setDescription("Téléchargement de la version " + version);
            request.setMimeType("application/vnd.android.package-archive");
            request.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
            request.setAllowedOverMetered(true);
            request.setAllowedOverRoaming(false);
            request.setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, "ZouChat-update-" + version + ".apk");
            long id = manager.enqueue(request);
            getPreferences(MODE_PRIVATE).edit()
                .putLong("zouchat_update_download_id", id)
                .putString("zouchat_update_download_version", version)
                .putBoolean("zouchat_update_install_launched", false)
                .apply();
            Toast.makeText(this, "Téléchargement de la mise à jour commencé.", Toast.LENGTH_LONG).show();
        } catch (Exception e) {
            Toast.makeText(this, "Impossible de télécharger la mise à jour. Réessaie plus tard.", Toast.LENGTH_LONG).show();
        }
    }

    private void resumePendingUpdateInstall() {
        long id = getPreferences(MODE_PRIVATE).getLong("zouchat_update_download_id", -1L);
        if (id >= 0) handleUpdateDownloadCompleted(id);
    }

    private void handleUpdateDownloadCompleted(long id) {
        // Ne lance jamais l'installateur depuis un écran en arrière-plan.
        if (!activityResumed || isFinishing()) return;
        DownloadManager manager = (DownloadManager) getSystemService(DOWNLOAD_SERVICE);
        if (manager == null) return;
        DownloadManager.Query query = new DownloadManager.Query().setFilterById(id);
        try (Cursor cursor = manager.query(query)) {
            if (cursor == null || !cursor.moveToFirst()) return;
            int statusIndex = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS);
            if (statusIndex < 0) return;
            int status = cursor.getInt(statusIndex);
            if (status == DownloadManager.STATUS_FAILED) {
                int reasonIndex = cursor.getColumnIndex(DownloadManager.COLUMN_REASON);
                String reason = reasonIndex >= 0 ? String.valueOf(cursor.getInt(reasonIndex)) : "inconnu";
                Toast.makeText(this, "Échec du téléchargement de la mise à jour (" + reason + ").", Toast.LENGTH_LONG).show();
                getPreferences(MODE_PRIVATE).edit().remove("zouchat_update_download_id").apply();
                return;
            }
            if (status != DownloadManager.STATUS_SUCCESSFUL) return;
            boolean alreadyLaunched = getPreferences(MODE_PRIVATE).getBoolean("zouchat_update_install_launched", false);
            if (alreadyLaunched) return;
            Uri apkUri = manager.getUriForDownloadedFile(id);
            if (apkUri == null) return;
            if (Build.VERSION.SDK_INT >= 26 && !getPackageManager().canRequestPackageInstalls()) {
                Toast.makeText(this, "Autorise ZouChat à installer cette mise à jour dans les paramètres Android.", Toast.LENGTH_LONG).show();
                Intent settings = new Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + getPackageName()));
                try { startActivity(settings); } catch (ActivityNotFoundException ignored) { }
                return;
            }
            try {
                Intent install = new Intent(Intent.ACTION_INSTALL_PACKAGE);
                install.setDataAndType(apkUri, "application/vnd.android.package-archive");
                install.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                install.putExtra(Intent.EXTRA_RETURN_RESULT, true);
                startActivity(install);
                getPreferences(MODE_PRIVATE).edit().putBoolean("zouchat_update_install_launched", true).apply();
            } catch (ActivityNotFoundException e) {
                Toast.makeText(this, "Aucun installateur Android disponible.", Toast.LENGTH_LONG).show();
            }
        } catch (Exception ignored) {
            // Un contrôle ultérieur reprendra le traitement sans interrompre la messagerie.
        }
    }

    private int compareVersions(String first, String second) {
        try {
            String[] a = first.split("\\.");
            String[] b = (second == null ? "0" : second).split("\\.");
            int length = Math.max(a.length, b.length);
            for (int i = 0; i < length; i++) {
                int av = i < a.length ? Integer.parseInt(a[i].replaceAll("[^0-9].*$", "")) : 0;
                int bv = i < b.length ? Integer.parseInt(b[i].replaceAll("[^0-9].*$", "")) : 0;
                if (av != bv) return Integer.compare(av, bv);
            }
        } catch (Exception ignored) { return first.compareTo(second == null ? "" : second); }
        return 0;
    }

    private void requestFcmToken() {
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
            if (!task.isSuccessful() || task.getResult() == null || webView == null) return;
            String token = task.getResult();
            runOnUiThread(() -> {
                if (webView == null) return;
                String script = "window.ZouChatNativeOnToken && window.ZouChatNativeOnToken(" + JSONObject.quote(token) + ")";
                webView.evaluateJavascript(script, null);
            });
        });
    }

    private final class ZouChatAndroidBridge {
        @JavascriptInterface
        public void requestFcmToken() {
            MainActivity.this.requestFcmToken();
        }

        @JavascriptInterface
        public void setSecureWindow(boolean enabled) {
            runOnUiThread(() -> {
                if (webView == null || !isTrustedAppUrl(Uri.parse(webView.getUrl()))) return;
                if (enabled) getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
                else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
            });
        }

        @JavascriptInterface
        public void setCallAudioMode(boolean enabled) {
            runOnUiThread(() -> {
                if (webView == null || !isTrustedAppUrl(Uri.parse(webView.getUrl()))) return;
                if (enabled) prepareCallAudio(); else restoreAudioMode();
            });
        }

        @JavascriptInterface
        public void enableNotifications() {
            runOnUiThread(() -> {
                if (Build.VERSION.SDK_INT >= 33 &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 4104);
                }
                MainActivity.this.requestFcmToken();
            });
        }
    }

    @Override public void onBackPressed() {
        if (webView != null && webView.canGoBack()) webView.goBack(); else super.onBackPressed();
    }
    @Override protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        if (webView != null) webView.saveState(outState);
    }
    @Override protected void onDestroy() {
        if (filePathCallback != null) filePathCallback.onReceiveValue(null);
        if (pendingWebPermissionRequest != null) { pendingWebPermissionRequest.deny(); pendingWebPermissionRequest = null; }
        restoreAudioMode();
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
        if (downloadReceiverRegistered) {
            try { unregisterReceiver(updateDownloadReceiver); } catch (IllegalArgumentException ignored) { }
            downloadReceiverRegistered = false;
        }
        if (webView != null) { webView.stopLoading(); webView.setWebChromeClient(null); webView.setWebViewClient(null); webView.destroy(); }
        super.onDestroy();
    }
}