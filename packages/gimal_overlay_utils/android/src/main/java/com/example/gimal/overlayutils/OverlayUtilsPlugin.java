package com.example.gimal.overlayutils;

import android.content.Context;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.WindowManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

// 오버레이는 Activity가 아닌 Service 위에서 도는 별도 Flutter 엔진이라, 그 안에서는
// Flutter WebView(플랫폼 뷰)가 동작하지 않는다(flutter/platform_views 채널 부재).
// 그래서 네이티브 android.webkit.WebView를 별도의 시스템 오버레이 창으로 직접 띄우고,
// Flutter 쪽 컨트롤바에서 메서드 채널로 URL 열기/뒤로/닫기/접기/위치·크기를 제어한다.
public final class OverlayUtilsPlugin
    implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private Context context;
  private MethodChannel channel;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());

  private WebView webView;
  private WindowManager windowManager;
  private WindowManager.LayoutParams webParams;
  // 웹뷰 창이 현재 WindowManager에 붙어 있는지(접기 시 떼되 인스턴스는 유지).
  private boolean webAttached = false;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), "com.example.gimal/utils");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (channel != null) {
      channel.setMethodCallHandler(null);
    }
    channel = null;
    // 오버레이 엔진이 내려갈 때 네이티브 웹뷰 창이 남지 않도록 정리한다.
    mainHandler.post(this::hideWebOverlay);
    context = null;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "bringToFront":
        bringToFront();
        result.success(null);
        return;
      case "getScreenSize": {
        // 회전을 반영한 실제 화면 크기(physical px)를 돌려준다.
        final DisplayMetrics dm = new DisplayMetrics();
        final WindowManager w = wm();
        if (w != null) {
          w.getDefaultDisplay().getRealMetrics(dm);
        }
        final Map<String, Integer> size = new HashMap<>();
        size.put("width", dm.widthPixels);
        size.put("height", dm.heightPixels);
        result.success(size);
        return;
      }
      case "showWebOverlay": {
        final String url = call.argument("url");
        final int x = intArg(call, "x");
        final int y = intArg(call, "y");
        final int w = intArg(call, "width");
        final int h = intArg(call, "height");
        mainHandler.post(() -> showWebOverlay(url, x, y, w, h));
        result.success(null);
        return;
      }
      case "setWebOverlayBounds": {
        final int x = intArg(call, "x");
        final int y = intArg(call, "y");
        final int w = intArg(call, "width");
        final int h = intArg(call, "height");
        mainHandler.post(() -> setWebOverlayBounds(x, y, w, h));
        result.success(null);
        return;
      }
      case "detachWebOverlay":
        mainHandler.post(this::detachWebOverlay);
        result.success(null);
        return;
      case "reattachWebOverlay": {
        final int x = intArg(call, "x");
        final int y = intArg(call, "y");
        final int w = intArg(call, "width");
        final int h = intArg(call, "height");
        mainHandler.post(() -> reattachWebOverlay(x, y, w, h));
        result.success(null);
        return;
      }
      case "webOverlayGoBack":
        mainHandler.post(this::webOverlayGoBack);
        result.success(null);
        return;
      case "hideWebOverlay":
        mainHandler.post(this::hideWebOverlay);
        result.success(null);
        return;
      default:
        result.notImplemented();
    }
  }

  private int intArg(MethodCall call, String key) {
    final Object value = call.argument(key);
    return value instanceof Number ? ((Number) value).intValue() : 0;
  }

  private WindowManager wm() {
    if (windowManager == null && context != null) {
      windowManager = (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
    }
    return windowManager;
  }

  private WindowManager.LayoutParams buildParams(int x, int y, int w, int h) {
    final int type = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        : WindowManager.LayoutParams.TYPE_PHONE;
    // 포커스 가능(FLAG_NOT_FOCUSABLE 제거)으로 둬서 하드웨어 뒤로가기 키를 받아
    // 웹뷰 자체의 뒤로가기로 쓴다. FLAG_NOT_TOUCH_MODAL을 줘서 창 바깥(상단 컨트롤
    // 스트립) 터치는 그쪽으로 통과시킨다.
    final int flags = WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED;
    final WindowManager.LayoutParams params =
        new WindowManager.LayoutParams(w, h, x, y, type, flags, PixelFormat.TRANSLUCENT);
    params.gravity = Gravity.TOP | Gravity.START;
    return params;
  }

  // 네이티브 웹뷰 창을 만들고(없으면) 주어진 위치/크기에 띄운 뒤 url을 로드한다.
  private void showWebOverlay(String url, int x, int y, int w, int h) {
    if (context == null || wm() == null) {
      return;
    }
    try {
      if (webView == null) {
        webView = new WebView(context);
        final WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setUseWideViewPort(true);
        settings.setLoadWithOverviewMode(true);
        settings.setMediaPlaybackRequiresUserGesture(true);
        // 링크 클릭이 외부 브라우저로 새지 않고 이 창 안에서 열리도록 한다.
        webView.setWebViewClient(new WebViewClient());
        // 하드웨어 뒤로가기를 웹뷰의 이전 페이지 이동으로 처리한다(소비해서 오버레이가
        // 닫히지 않게 한다).
        webView.setFocusableInTouchMode(true);
        webView.setOnKeyListener((v, keyCode, event) -> {
          if (keyCode == KeyEvent.KEYCODE_BACK) {
            if (event.getAction() == KeyEvent.ACTION_UP && webView.canGoBack()) {
              webView.goBack();
            }
            return true;
          }
          return false;
        });
        webParams = buildParams(x, y, w, h);
        wm().addView(webView, webParams);
        webAttached = true;
      } else {
        if (!webAttached) {
          reattachWebOverlay(x, y, w, h);
        } else {
          setWebOverlayBounds(x, y, w, h);
        }
      }
      if (url != null && !url.isEmpty()) {
        webView.loadUrl(url);
      }
    } catch (Exception error) {
      // 창 추가 실패 시 조용히 무시한다(권한 회수 등).
    }
  }

  private void setWebOverlayBounds(int x, int y, int w, int h) {
    if (webView == null || webParams == null || wm() == null || !webAttached) {
      return;
    }
    try {
      webParams.x = x;
      webParams.y = y;
      webParams.width = w;
      webParams.height = h;
      wm().updateViewLayout(webView, webParams);
    } catch (Exception error) {
      // ignore
    }
  }

  // 접기: 웹뷰 인스턴스는 유지한 채 창에서만 떼어 화면에서 사라지게 한다.
  private void detachWebOverlay() {
    if (webView != null && webAttached && wm() != null) {
      try {
        wm().removeView(webView);
      } catch (Exception error) {
        // ignore
      }
      webAttached = false;
    }
  }

  // 펼치기: 접어둔(떼어둔) 웹뷰를 같은 인스턴스 그대로 다시 띄운다(로딩 상태 유지).
  private void reattachWebOverlay(int x, int y, int w, int h) {
    if (webView == null || wm() == null || webAttached) {
      return;
    }
    try {
      webParams = buildParams(x, y, w, h);
      wm().addView(webView, webParams);
      webAttached = true;
    } catch (Exception error) {
      // ignore
    }
  }

  private void webOverlayGoBack() {
    if (webView != null && webView.canGoBack()) {
      webView.goBack();
    }
  }

  private void hideWebOverlay() {
    if (webView != null) {
      try {
        if (webAttached && wm() != null) {
          wm().removeView(webView);
        }
      } catch (Exception error) {
        // ignore
      }
      try {
        webView.destroy();
      } catch (Exception error) {
        // ignore
      }
    }
    webView = null;
    webParams = null;
    webAttached = false;
  }

  private void bringToFront() {
    if (context == null) {
      return;
    }

    Intent intent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
    if (intent == null) {
      return;
    }

    intent.addFlags(
        Intent.FLAG_ACTIVITY_NEW_TASK
            | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            | Intent.FLAG_ACTIVITY_CLEAR_TOP
            | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    context.startActivity(intent);
  }
}
