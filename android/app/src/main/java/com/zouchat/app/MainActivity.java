package com.zouchat.app;

import android.Manifest;
import android.app.Activity;
import android.media.AudioManager;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.CookieManager;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import java.net.HttpURLConnection;
import java.net.URL;
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

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        audioManager = (AudioManager) getSystemService(AUDIO_SERVICE);
        webView = new WebView(this);
        setContentView(webView);
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
        checkForAppUpdate();
    }

    private boolean isTrustedAppUrl(Uri uri) {
        return uri != null && "https".equalsIgnoreCase(uri.getScheme()) && APP_HOST.equalsIgnoreCase(uri.getHost());
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
                        if (asset != null && asset.optString("name", "").endsWith(".apk")) {
                            apkUrl = asset.optString("browser_download_url", "");
                            if (!apkUrl.isEmpty()) break;
                        }
                    }
                }
                if (!apkUrl.isEmpty() && compareVersions(latestVersion, installedVersion) > 0) {
                    final String versionToInstall = latestVersion;
                    final String downloadUrl = apkUrl;
                    runOnUiThread(() -> new AlertDialog.Builder(MainActivity.this)
                        .setTitle("Mise à jour ZouChat disponible")
                        .setMessage("La version " + versionToInstall + " est disponible. Télécharge-la pour profiter des améliorations.")
                        .setPositiveButton("Télécharger", (dialog, which) -> {
                            try {
                                startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(downloadUrl)));
                            } catch (ActivityNotFoundException e) {
                                Toast.makeText(MainActivity.this, "Impossible d’ouvrir le téléchargement.", Toast.LENGTH_LONG).show();
                            }
                        })
                        .setNegativeButton("Plus tard", null)
                        .show());
                }
            } catch (Exception ignored) {
                // La messagerie reste utilisable même si la vérification échoue.
            } finally {
                if (connection != null) connection.disconnect();
            }
        }).start();
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
        if (webView != null) webView.destroy();
        super.onDestroy();
    }
}