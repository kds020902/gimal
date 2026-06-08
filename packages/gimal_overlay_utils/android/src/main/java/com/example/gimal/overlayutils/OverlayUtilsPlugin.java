package com.example.gimal.overlayutils;

import android.content.Context;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.hardware.display.DisplayManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;
import android.view.Display;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public final class OverlayUtilsPlugin
    implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private static final String TAG = "GimalOverlayUtils";

  private Context context;
  private MethodChannel channel;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  private WindowManager webWindowManager;
  private Context webContext;
  private FrameLayout webOverlayView;
  private WebView webView;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), "com.example.gimal/utils");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    closeWebOverlay();
    if (channel != null) {
      channel.setMethodCallHandler(null);
    }
    channel = null;
    context = null;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    if (call.method.equals("bringToFront")) {
      bringToFront();
      result.success(null);
    } else if (call.method.equals("openWebOverlay")) {
      String url = call.argument("url");
      openWebOverlay(url == null ? "" : url, call, result);
    } else if (call.method.equals("updateWebOverlayBounds")) {
      updateWebOverlayBounds(call);
      result.success(null);
    } else if (call.method.equals("webGoBack")) {
      webGoBack();
      result.success(null);
    } else if (call.method.equals("closeWebOverlay")) {
      closeWebOverlay();
      result.success(null);
    } else {
      result.notImplemented();
    }
  }

  private void bringToFront() {
    Intent intent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
    if (intent == null) return;

    intent.addFlags(
        Intent.FLAG_ACTIVITY_NEW_TASK
            | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            | Intent.FLAG_ACTIVITY_CLEAR_TOP
            | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    context.startActivity(intent);
  }

  private void openWebOverlay(
      String startUrl, MethodCall call, MethodChannel.Result result) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(context)) {
      result.error("NO_OVERLAY_PERMISSION", "Overlay permission is required.", null);
      return;
    }

    mainHandler.post(() -> {
      try {
        if (webOverlayView == null) {
          createWebOverlay(call);
        }
        applyWebOverlayBounds(call);
        loadWebPage(startUrl);
        result.success(null);
      } catch (Exception error) {
        Log.e(TAG, "openWebOverlay failed", error);
        result.error("WEB_OVERLAY_ERROR", error.getMessage(), null);
      }
    });
  }

  private void createWebOverlay(MethodCall call) {
    webContext = createOverlayContext();
    webWindowManager = (WindowManager) webContext.getSystemService(Context.WINDOW_SERVICE);
    if (webWindowManager == null) {
      throw new IllegalStateException("WindowManager is not available.");
    }

    webOverlayView = new FrameLayout(webContext);

    webView = new WebView(webContext);
    webView.setLayerType(View.LAYER_TYPE_SOFTWARE, null);
    WebSettings settings = webView.getSettings();
    settings.setJavaScriptEnabled(true);
    settings.setDomStorageEnabled(true);
    settings.setUseWideViewPort(true);
    settings.setLoadWithOverviewMode(true);
    webView.setWebViewClient(new WebViewClient());

    webOverlayView.addView(
        webView,
        new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT));

    WindowManager.LayoutParams params = webOverlayParams(call);
    webWindowManager.addView(webOverlayView, params);
  }

  private void webGoBack() {
    mainHandler.post(() -> {
      if (webView != null && webView.canGoBack()) {
        webView.goBack();
      }
    });
  }

  private void loadWebPage(String value) {
    String url = normalizeUrl(value);
    if (url.isEmpty() || webView == null) return;
    webView.loadUrl(url);
  }

  private String normalizeUrl(String value) {
    String trimmed = value == null ? "" : value.trim();
    if (trimmed.isEmpty()) return "";
    if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
      return trimmed;
    }
    if (trimmed.contains(".") && !trimmed.contains(" ")) {
      return "https://" + trimmed;
    }
    return "https://www.google.com/search?q=" + Uri.encode(trimmed);
  }

  private void closeWebOverlay() {
    WindowManager manager = webWindowManager;
    FrameLayout overlay = webOverlayView;
    WebView currentWebView = webView;

    webWindowManager = null;
    webContext = null;
    webOverlayView = null;
    webView = null;

    mainHandler.post(() -> {
      if (overlay == null || manager == null) return;
      manager.removeView(overlay);
      if (currentWebView != null) {
        currentWebView.destroy();
      }
    });
  }

  private void updateWebOverlayBounds(MethodCall call) {
    mainHandler.post(() -> applyWebOverlayBounds(call));
  }

  private void applyWebOverlayBounds(MethodCall call) {
    if (webOverlayView == null || webWindowManager == null) return;
    webWindowManager.updateViewLayout(webOverlayView, webOverlayParams(call));
  }

  private WindowManager.LayoutParams webOverlayParams(MethodCall call) {
    WindowManager.LayoutParams params = new WindowManager.LayoutParams(
        dp(numberArgument(call, "width", 320)),
        dp(numberArgument(call, "height", 360)),
        overlayType(),
        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
        PixelFormat.TRANSLUCENT);
    params.gravity = Gravity.TOP | Gravity.START;
    params.x = dp(numberArgument(call, "x", 12));
    params.y = dp(numberArgument(call, "y", 140));
    params.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE;
    return params;
  }

  private int overlayType() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      return WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY;
    }
    return WindowManager.LayoutParams.TYPE_PHONE;
  }

  private Context createOverlayContext() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      DisplayManager displayManager =
          (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
      Display display = displayManager == null
          ? null
          : displayManager.getDisplay(Display.DEFAULT_DISPLAY);
      if (display != null) {
        return context.createWindowContext(display, overlayType(), null);
      }
    }
    return context;
  }

  private int dp(int value) {
    Context targetContext = webContext == null ? context : webContext;
    return (int) (value * targetContext.getResources().getDisplayMetrics().density + 0.5f);
  }

  private int numberArgument(MethodCall call, String name, int defaultValue) {
    Number value = call.argument(name);
    return value == null ? defaultValue : value.intValue();
  }
}
