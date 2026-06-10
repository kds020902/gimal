package com.example.gimal.overlayutils;

import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
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
import android.view.inputmethod.EditorInfo;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;

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
  private LinearLayout webOverlayView;
  private WebView webView;
  private EditText addressInput;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), "com.example.gimal/utils");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    closeWebOverlay(false);
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
    } else if (call.method.equals("closeWebOverlay")) {
      closeWebOverlay(false);
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

    webOverlayView = new LinearLayout(webContext);
    webOverlayView.setOrientation(LinearLayout.VERTICAL);
    webOverlayView.setBackgroundColor(Color.WHITE);
    webOverlayView.addView(
        createWebControlBar(),
        new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            dp(58)));

    webView = new WebView(webContext);
    webView.setLayerType(View.LAYER_TYPE_SOFTWARE, null);
    WebSettings settings = webView.getSettings();
    settings.setJavaScriptEnabled(true);
    settings.setDomStorageEnabled(true);
    settings.setUseWideViewPort(true);
    settings.setLoadWithOverviewMode(true);
    webView.setWebViewClient(new WebViewClient() {
      @Override
      public void onPageFinished(WebView view, String url) {
        if (addressInput != null && url != null) {
          addressInput.setText(url);
        }
      }
    });

    webOverlayView.addView(
        webView,
        new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1));

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

  private LinearLayout createWebControlBar() {
    LinearLayout bar = new LinearLayout(webContext);
    bar.setOrientation(LinearLayout.HORIZONTAL);
    bar.setGravity(Gravity.CENTER_VERTICAL);
    bar.setPadding(dp(8), dp(8), dp(8), dp(8));
    bar.setBackgroundColor(Color.rgb(248, 250, 252));

    Button closeButton = smallButton("X");
    closeButton.setOnClickListener(view -> closeWebOverlay(true));
    bar.addView(closeButton, new LinearLayout.LayoutParams(dp(44), dp(42)));

    addressInput = new EditText(webContext);
    addressInput.setSingleLine(true);
    addressInput.setTextSize(14);
    addressInput.setHint("URL or search");
    addressInput.setImeOptions(EditorInfo.IME_ACTION_GO);
    addressInput.setOnEditorActionListener((view, actionId, event) -> {
      if (actionId == EditorInfo.IME_ACTION_GO) {
        loadWebPage(addressInput.getText().toString());
        return true;
      }
      return false;
    });
    LinearLayout.LayoutParams inputParams =
        new LinearLayout.LayoutParams(0, dp(42), 1);
    inputParams.setMargins(dp(6), 0, dp(6), 0);
    bar.addView(addressInput, inputParams);

    Button goButton = smallButton("\uC774\uB3D9");
    goButton.setOnClickListener(view -> loadWebPage(addressInput.getText().toString()));
    bar.addView(goButton, new LinearLayout.LayoutParams(dp(56), dp(42)));

    Button backButton = smallButton("<-");
    backButton.setOnClickListener(view -> webGoBack());
    LinearLayout.LayoutParams backParams =
        new LinearLayout.LayoutParams(dp(44), dp(42));
    backParams.setMargins(dp(6), 0, 0, 0);
    bar.addView(backButton, backParams);

    return bar;
  }

  private Button smallButton(String text) {
    Button button = new Button(webContext);
    button.setAllCaps(false);
    button.setText(text);
    button.setTextSize(12);
    button.setPadding(0, 0, 0, 0);
    return button;
  }

  private void loadWebPage(String value) {
    String url = normalizeUrl(value);
    if (url.isEmpty() || webView == null) return;
    if (addressInput != null) {
      addressInput.setText(url);
    }
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

  private void closeWebOverlay(boolean notifyDart) {
    WindowManager manager = webWindowManager;
    LinearLayout overlay = webOverlayView;
    WebView currentWebView = webView;

    webWindowManager = null;
    webContext = null;
    webOverlayView = null;
    webView = null;
    addressInput = null;

    mainHandler.post(() -> {
      if (overlay != null && manager != null) {
        manager.removeView(overlay);
      }
      if (currentWebView != null) {
        currentWebView.destroy();
      }
      if (notifyDart && channel != null) {
        channel.invokeMethod("webOverlayClosed", null);
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
    int x = dp(numberArgument(call, "x", 12));
    int y = dp(numberArgument(call, "y", 140));
    int width = dp(numberArgument(call, "width", 320));
    int requestedHeight = numberArgument(call, "height", 360);
    int height = requestedHeight <= 0
        ? remainingDisplayHeight(y)
        : dp(requestedHeight);

    WindowManager.LayoutParams params = new WindowManager.LayoutParams(
        width,
        height,
        overlayType(),
        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
        PixelFormat.TRANSLUCENT);
    params.gravity = Gravity.TOP | Gravity.START;
    params.x = x;
    params.y = y;
    params.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE;
    return params;
  }

  private int remainingDisplayHeight(int topPx) {
    int displayHeight = context.getResources().getDisplayMetrics().heightPixels;
    return Math.max(dp(120), displayHeight - topPx);
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
