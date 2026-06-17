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
// Flutter WebView(플랫폼 뷰)가 동작하지 않는다(flutter/platform_views 채널 부재 → create 실패).
// 그래서 네이티브 android.webkit.WebView를 별도의 시스템 오버레이 창으로 직접 띄우고,
// Flutter 쪽 컨트롤바에서 메서드 채널로 URL 열기/뒤로/닫기/접기/위치·크기를 제어한다.
public final class OverlayUtilsPlugin
    implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private Context context;
  private MethodChannel channel;
  // WebView·WindowManager 작업은 반드시 메인(UI) 스레드에서 해야 하는데, 채널 콜은 다른
  // 스레드로 올 수 있어, 메인 스레드로 넘기려고 핸들러를 둔다.
  private final Handler mainHandler = new Handler(Looper.getMainLooper());

  private WebView webView; // 웹뷰 인스턴스. 접어도(detach) 살려둬서 펼칠 때 그대로 복귀.
  private WindowManager windowManager;
  private WindowManager.LayoutParams webParams;
  // 웹뷰 창이 지금 화면(WindowManager)에 붙어 있는지. "끄지 않고 접기"를 위해 인스턴스 유지와
  // 화면 표시 여부를 따로 추적하려고 둔다.
  private boolean webAttached = false;

  // 엔진에 붙을 때: Dart 쪽과 똑같은 채널 이름으로 연결해야 통신이 돼서 문자열을 맞춘다.
  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), "com.example.gimal/utils");
    channel.setMethodCallHandler(this);
  }

  // 엔진이 내려갈 때: 웹뷰 창은 엔진과 별개라 안 닫으면 화면에 남는다. 그래서 같이 정리한다.
  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (channel != null) {
      channel.setMethodCallHandler(null);
    }
    channel = null;
    mainHandler.post(this::hideWebOverlay);
    context = null;
  }

  // Dart에서 온 명령을 분기한다. WebView/창 조작은 전부 메인 스레드로 post해서 실행한다.
  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "bringToFront":
        bringToFront();
        result.success(null);
        return;
      case "getScreenSize": {
        // ui.Display.size는 회전을 반영하지 않아서, 회전 반영 실제 화면 크기를
        // getRealMetrics로 구해 돌려준다(가로모드 폭 틀어짐 방지의 핵심).
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
      case "hideWebOverlay":
        mainHandler.post(this::hideWebOverlay);
        result.success(null);
        return;
      default:
        result.notImplemented();
    }
  }

  // 채널 인자(숫자)를 안전하게 int로 꺼내려고 둔다. 값이 없거나 숫자가 아니면 0.
  private int intArg(MethodCall call, String key) {
    final Object value = call.argument(key);
    return value instanceof Number ? ((Number) value).intValue() : 0;
  }

  // WindowManager를 처음 쓸 때 한 번만 가져와 캐시하려고 둔다(앱 컨텍스트 기준).
  private WindowManager wm() {
    if (windowManager == null && context != null) {
      windowManager = (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
    }
    return windowManager;
  }

  // 웹뷰 창의 LayoutParams를 만들려고 둔다. 띄울 때와 다시 붙일 때 같은 규칙을 쓰려고 한곳에 모음.
  private WindowManager.LayoutParams buildParams(int x, int y, int w, int h) {
    // TYPE_APPLICATION_OVERLAY: 다른 앱 위에 뜨는 시스템 창(구버전은 TYPE_PHONE).
    final int type = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        : WindowManager.LayoutParams.TYPE_PHONE;
    // 포커스 가능(FLAG_NOT_FOCUSABLE을 안 줌)으로 둬서 하드웨어 뒤로가기 키를 받아 웹뷰의
    //   이전 페이지 이동으로 쓴다. FLAG_NOT_TOUCH_MODAL: 창 바깥(상단 컨트롤 스트립) 터치는
    //   그쪽으로 통과시킨다. FLAG_HARDWARE_ACCELERATED: 웹뷰가 제대로 그려지게.
    final int flags = WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED;
    final WindowManager.LayoutParams params =
        new WindowManager.LayoutParams(w, h, x, y, type, flags, PixelFormat.TRANSLUCENT);
    // 좌상단 기준 + (x,y) 오프셋으로 위치를 잡으려고 gravity를 고정.
    params.gravity = Gravity.TOP | Gravity.START;
    return params;
  }

  // 웹뷰를 처음 띄울 때: 인스턴스를 만들고(없으면) 창에 붙인 뒤 url을 로드한다.
  private void showWebOverlay(String url, int x, int y, int w, int h) {
    if (context == null || wm() == null) {
      return;
    }
    try {
      if (webView == null) {
        webView = new WebView(context);
        final WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true); // 요즘 사이트는 JS 없으면 깨져서 켬.
        settings.setDomStorageEnabled(true); // 로그인/상태 저장하는 사이트 위해.
        settings.setUseWideViewPort(true); // 모바일 페이지가 폭에 맞게 보이도록.
        settings.setLoadWithOverviewMode(true);
        settings.setMediaPlaybackRequiresUserGesture(true); // 자동재생 막아 갑자기 소리 안 나게.
        // 링크 클릭이 외부 브라우저로 새지 않고 이 창 안에서 열리게 하려고 기본 클라이언트 지정.
        webView.setWebViewClient(new WebViewClient());
        // 하드웨어 뒤로가기 → 웹뷰 이전 페이지로. 항상 소비(return true)해서 그 키로 오버레이가
        //   닫히지 않게 한다(끝까지 가면 그냥 아무 일 안 함).
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
        // 이미 인스턴스가 있으면: 접혀 있었으면 다시 붙이고, 떠 있으면 위치만 갱신.
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
      // 창 추가 실패(권한 회수 등) 시 앱이 죽지 않게 조용히 무시.
    }
  }

  // 스트립 높이가 바뀌면 웹뷰 위치/크기를 갱신하려고 둔다(붙어 있을 때만).
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

  // 접기: 인스턴스(로딩 상태)는 유지한 채 창에서만 떼어 화면에서 사라지게 한다.
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

  // 펼치기: 접어둔 그 웹뷰를 같은 인스턴스로 다시 붙인다(다시 로딩하지 않고 보던 페이지 그대로).
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

  // 완전히 닫기(X/앱으로/엔진 종료): 창을 떼고 인스턴스까지 없애 메모리를 정리한다.
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

  // "앱으로" 버튼용: 메인 앱(MainActivity)을 다시 앞으로 가져온다.
  // REORDER_TO_FRONT 등 플래그로 새 화면을 쌓지 않고 기존 액티비티를 끌어올린다.
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
