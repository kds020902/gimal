package com.example.gimal

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 메인 앱의 안드로이드 진입점(Activity). Flutter가 여기 위에서 돌아간다.
// 하는 일은 하나뿐: Flutter가 "홈으로 가라(goHome)"고 하면 앱을 백그라운드로 보내,
//   띄워둔 오버레이가 다른 앱(홈/게임) 위에 떠 보이게 한다.
class MainActivity : FlutterActivity() {
    // Dart 쪽 _homeChannel과 똑같은 이름이어야 통신이 돼서 문자열을 맞춘다.
    private val homeChannel = "com.example.gimal/home"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 이 엔진(메인 앱)에 goHome 명령을 처리할 핸들러를 등록한다.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, homeChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "goHome") {
                    goHome()
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    // 홈 화면을 띄우고(=앱을 가림) 이 앱 태스크를 뒤로 보낸다.
    // 그래야 사용자 눈에는 오버레이만 남아, "오버레이 전환"이 자연스럽게 보인다.
    private fun goHome() {
        val intent = android.content.Intent(android.content.Intent.ACTION_MAIN).apply {
            addCategory(android.content.Intent.CATEGORY_HOME)
            flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK
        }

        startActivity(intent)
        moveTaskToBack(true)
    }
}
