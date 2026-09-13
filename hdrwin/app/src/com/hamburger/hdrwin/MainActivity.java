package com.hamburger.hdrwin;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 极简控制界面：授权、开、关。
 * 主用法还是通过 adb 起服务，这个界面只是给你手动操作和看状态用。
 */
public class MainActivity extends Activity {

    private TextView mState;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("HDR 小窗");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        root.addView(title);

        TextView hint = new TextView(this);
        hint.setText("在屏幕角落放一个看不见的 UltraHDR 图片，让系统认为屏幕上有 HDR 内容，"
                + "从而把面板亮度上限从 500nit 放开到 1300nit。\n\n"
                + "先授予「显示在其他应用上层」权限，然后点开启即可。开启后可以关掉这个界面。");
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        hint.setPadding(0, pad / 2, 0, pad);
        root.addView(hint);

        Button perm = new Button(this);
        perm.setText("1. 授予悬浮窗权限");
        perm.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                        && !Settings.canDrawOverlays(MainActivity.this)) {
                    startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:" + getPackageName())));
                } else {
                    refresh();
                }
            }
        });
        root.addView(perm);

        Button start = new Button(this);
        start.setText("2. 开启");
        start.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                Intent i = new Intent(MainActivity.this, HdrWindowService.class);
                i.setAction(HdrWindowService.ACTION_START);
                startForegroundService(i);
                refresh();
            }
        });
        root.addView(start);

        Button stop = new Button(this);
        stop.setText("3. 关闭");
        stop.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                Intent i = new Intent(MainActivity.this, HdrWindowService.class);
                i.setAction(HdrWindowService.ACTION_STOP);
                startService(i);
                refresh();
            }
        });
        root.addView(stop);

        mState = new TextView(this);
        mState.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        mState.setPadding(0, pad, 0, 0);
        root.addView(mState);

        setContentView(root);
        refresh();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    private void refresh() {
        if (mState == null) {
            return;
        }
        boolean canOverlay = Build.VERSION.SDK_INT < Build.VERSION_CODES.M
                || Settings.canDrawOverlays(this);
        StringBuilder sb = new StringBuilder();
        sb.append("悬浮窗权限: ").append(canOverlay ? "已授予" : "未授予（必须先授予）").append('\n');
        sb.append("HDR 状态: ").append(HdrWindowService.isRunning() ? "已开启" : "已关闭").append('\n');
        mState.setText(sb.toString());
        mState.setTextColor(canOverlay ? Color.DKGRAY : Color.RED);
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
