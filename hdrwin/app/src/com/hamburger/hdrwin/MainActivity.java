package com.hamburger.hdrwin;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.TypedArray;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.View;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.TextView;

/**
 * 极简控制界面：授权、开、关，外加一个深色模式选择。
 *
 * 深色模式走的是换主题（{@link #applyTheme()}），不是一个个 View 刷颜色 ——
 * 这样按钮、文字、窗口背景、状态栏图标会一起变。
 */
public class MainActivity extends Activity {

    private static final String PREFS = "hdrwin";
    private static final String KEY_THEME = "theme";

    /** 跟随系统（默认） */
    private static final int THEME_SYSTEM = 0;
    /** 强制深色 */
    private static final int THEME_DARK = 1;
    /** 强制浅色 */
    private static final int THEME_LIGHT = 2;

    private static final String[] THEME_NAMES = {"跟随系统", "深色", "浅色"};

    private TextView mState;
    private int mPad;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // 必须赶在 super.onCreate() / setContentView() 之前换主题
        applyTheme();
        super.onCreate(savedInstanceState);

        mPad = dp(20);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(mPad, mPad, mPad, mPad);
        // targetSdk 35 起系统强制全面屏（edge-to-edge），得自己给状态栏/导航栏让位，
        // 不然标题会顶到状态栏底下。
        root.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override
            public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                Insets b = insets.getInsets(
                        WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                v.setPadding(mPad + b.left, mPad + b.top, mPad + b.right, mPad + b.bottom);
                return insets;
            }
        });

        TextView title = new TextView(this);
        title.setText("HDR 小窗");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        root.addView(title);

        TextView hint = new TextView(this);
        hint.setText("在屏幕角落放一个看不见的 UltraHDR 图片，让系统认为屏幕上有 HDR 内容，"
                + "从而把面板亮度上限从 500nit 放开到 1300nit。\n\n"
                + "先授予「显示在其他应用上层」权限，然后点开启即可。开启后可以关掉这个界面。");
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        hint.setTextColor(themeColor(android.R.attr.textColorSecondary, 0xFF808080));
        hint.setPadding(0, mPad / 2, 0, mPad);
        root.addView(hint);

        Button perm = new Button(this);
        perm.setText("1. 授予悬浮窗权限");
        perm.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (!Settings.canDrawOverlays(MainActivity.this)) {
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

        // ---------------------------------------------------------- 深色模式
        TextView themeTitle = new TextView(this);
        themeTitle.setText("深色模式");
        themeTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        themeTitle.setPadding(0, mPad * 3 / 2, 0, 0);
        root.addView(themeTitle);

        final int current = themePref();
        final RadioButton[] opts = new RadioButton[THEME_NAMES.length];
        RadioGroup group = new RadioGroup(this);
        for (int i = 0; i < THEME_NAMES.length; i++) {
            RadioButton rb = new RadioButton(this);
            rb.setText(THEME_NAMES[i]);
            rb.setId(View.generateViewId());
            rb.setTag(Integer.valueOf(i));
            opts[i] = rb;
            group.addView(rb);
        }
        // 先勾好再加监听，免得初始化时被当成用户点击
        group.check(opts[current].getId());
        group.setOnCheckedChangeListener(new RadioGroup.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(RadioGroup g, int checkedId) {
                for (RadioButton rb : opts) {
                    if (rb.getId() == checkedId) {
                        setThemePref(((Integer) rb.getTag()).intValue());
                        return;
                    }
                }
            }
        });
        root.addView(group);

        mState = new TextView(this);
        mState.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        mState.setPadding(0, mPad, 0, 0);
        root.addView(mState);

        setContentView(root);
        refresh();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    // ------------------------------------------------------------------ 主题

    /** 必须在 super.onCreate() 之前调用。 */
    private void applyTheme() {
        switch (themePref()) {
            case THEME_DARK:
                setTheme(R.style.AppTheme_Dark);
                break;
            case THEME_LIGHT:
                setTheme(R.style.AppTheme_Light);
                break;
            default:
                // AppTheme 在 values/ 是浅色、在 values-night/ 是深色，系统自己挑
                setTheme(R.style.AppTheme);
                break;
        }
    }

    private int themePref() {
        SharedPreferences sp = getSharedPreferences(PREFS, MODE_PRIVATE);
        int v = sp.getInt(KEY_THEME, THEME_SYSTEM);
        return (v >= 0 && v < THEME_NAMES.length) ? v : THEME_SYSTEM;
    }

    private void setThemePref(int mode) {
        if (mode == themePref()) {
            return;
        }
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putInt(KEY_THEME, mode).apply();
        recreate();   // onCreate 里会重新 applyTheme()
    }

    /** 取当前主题里的一个颜色属性，取不到就用 fallback。 */
    private int themeColor(int attr, int fallback) {
        TypedArray a = getTheme().obtainStyledAttributes(new int[]{attr});
        try {
            return a.getColor(0, fallback);
        } catch (Throwable t) {
            return fallback;
        } finally {
            a.recycle();
        }
    }

    private boolean isLightTheme() {
        TypedArray a = getTheme().obtainStyledAttributes(new int[]{android.R.attr.isLightTheme});
        try {
            return a.getBoolean(0, true);
        } catch (Throwable t) {
            return true;
        } finally {
            a.recycle();
        }
    }

    // ------------------------------------------------------------------ 状态

    private void refresh() {
        if (mState == null) {
            return;
        }
        boolean canOverlay = Settings.canDrawOverlays(this);
        mState.setText("悬浮窗权限: " + (canOverlay ? "已授予" : "未授予（必须先授予）") + '\n'
                + "HDR 状态: " + (HdrWindowService.isRunning() ? "已开启" : "已关闭"));
        // 深色底上用亮一点的红，浅色底上用深一点的红，两边都看得清
        mState.setTextColor(canOverlay
                ? themeColor(android.R.attr.textColorPrimary, 0xFF000000)
                : (isLightTheme() ? 0xFFD32F2F : 0xFFFF6B6B));
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
