package com.hamburger.hdrwin;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Gainmap;
import android.graphics.ImageDecoder;

import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.WindowManager;

import java.io.File;
import java.io.FileOutputStream;

/**
 * HdrWindowService —— 在屏幕角落放一个很小的、**完全透明**的 UltraHDR 图片。
 *
 * 思路（也是 Google 相册 / 酷安能触发 HDR 亮度的那条路）：
 *   1. 造一张带 gain map 的 UltraHDR JPEG，主图**全透明**
 *   2. 解码成 Bitmap（保留 gain map）
 *   3. 放进一个小 SurfaceView 悬浮窗
 *   4. SurfaceView 用公开 API setDesiredHdrHeadroom 声明 HDR 余量
 *      —— 这是关键，光有 gain map 不够（我实测 root 造图层时 numHdrLayers 一直是 0）
 *
 * 图层本身透明，所以你看不到任何东西，但系统会认为屏幕上有 HDR 内容，
 * 从而把面板亮度上限放开。
 *
 * 之前用 root + SurfaceControl 硬造图层走不通：那样拿不到 SurfaceView，
 * 就没法调 setDesiredHdrHeadroom。
 */
public class HdrWindowService extends Service {

    public static final String TAG = "HDRWin";
    public static final String ACTION_START = "com.hamburger.hdrwin.START";
    public static final String ACTION_STOP = "com.hamburger.hdrwin.STOP";

    /** 窗口尺寸（dp）：小到看不见，但足够让系统认它是可见图层 */
    private static final int SIZE_DP = 40;
    /** 位图本身几像素就够，窗口尺寸另算 */
    private static final int SIZE = 8;
    /** HDR 余量：Google 相册/酷安的 desiredRatio 都在 4~5 附近 */
    private static final float HEADROOM = 4.99f;

    private static final String IMG_PATH_NAME = "hdr_blank.jpg";

    private WindowManager mWm;
    private SurfaceView mView;
    private Bitmap mBitmap;
    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private static volatile boolean sRunning = false;
    private volatile boolean mDrewOnce = false;
    private android.graphics.HardwareRenderer mRenderer;

    public static boolean isRunning() {
        return sRunning;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        sRunning = true;
        startForegroundNotif();
        try {
            showOverlay();
        } catch (Throwable t) {
            Log.e(TAG, "showOverlay failed", t);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        sRunning = false;
        mHandler.removeCallbacksAndMessages(null);
        try {
            if (mView != null && mWm != null) {
                mWm.removeView(mView);
            }
        } catch (Throwable ignored) {
        }
        if (mRenderer != null) {
            try { mRenderer.destroy(); } catch (Throwable ignored) {}
            mRenderer = null;
        }
        mView = null;
        if (mBitmap != null) {
            mBitmap.recycle();
            mBitmap = null;
        }
        Log.i(TAG, "service destroyed");
        super.onDestroy();
    }

    // ------------------------------------------------------------------ overlay

    private void showOverlay() throws Exception {
        mWm = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        if (mWm == null) {
            Log.e(TAG, "no WindowManager");
            return;
        }

        mBitmap = buildTransparentUltraHdr();
        Log.i(TAG, "bitmap " + mBitmap.getWidth() + "x" + mBitmap.getHeight()
                + " hasGainmap=" + mBitmap.hasGainmap());

        final int size = Math.max(8, Math.round(SIZE_DP
                * getResources().getDisplayMetrics().density));

        mView = new SurfaceView(this);
        mView.getHolder().setFormat(PixelFormat.TRANSLUCENT);

        // 关键：声明 HDR 余量。这是 SurfaceView 的公开 API，
        // 也是普通 App（Google 相册）能触发 HDR 亮度的原因。
        try {
            mView.setDesiredHdrHeadroom(HEADROOM);
            Log.i(TAG, "setDesiredHdrHeadroom(" + HEADROOM + ") ok");
        } catch (Throwable t) {
            Log.w(TAG, "setDesiredHdrHeadroom failed: " + t);
        }

        mView.getHolder().addCallback(new SurfaceHolder.Callback() {
            @Override
            public void surfaceCreated(SurfaceHolder holder) {
                bindHardwareBuffer((SurfaceView) mView);
            }

            @Override
            public void surfaceChanged(SurfaceHolder holder, int f, int w, int h) {
                bindHardwareBuffer((SurfaceView) mView);
            }

            @Override
            public void surfaceDestroyed(SurfaceHolder holder) {
            }
        });

        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                size, size,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.BOTTOM | Gravity.START;
        lp.x = 0;
        lp.y = 0;
        // 窗口整体几乎全透明（alpha 0.01），只有 1/100，肉眼不可见；
        // 但图层仍是「可见」的（alpha 刚好 0 才会被判为不可见而排除在 HDR 统计外）。
        lp.alpha = 0.01f;
        lp.setTitle("hdrwin");

        mWm.addView(mView, lp);
        Log.i(TAG, "overlay added " + size + "x" + size);

        // 周期性重画，避免 buffer 被回收后图层失去 HDR 标记
        mHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (mView != null) {
                    draw(mView.getHolder());
                }
                mHandler.postDelayed(this, 5000);
            }
        }, 5000);
    }

    /**
     * 用 HardwareRenderer 把带 gain map 的位图画到 Surface。
     *
     * 为什么不能直接用 SurfaceHolder.lockCanvas() 或 lockHardwareCanvas()：
     * 实测两条路画出来的 buffer dataspace 都是 sRGB、hdr metadata types=0，
     * gain map 在绘制时丢掉了，SurfaceFlinger 就不把这一层算作 HDR 图层
     * （numHdrLayers 一直是 0）。HardwareRenderer 是把它带进 buffer 的正路。
     */
    private void setupRenderer(android.view.Surface surface) {
        if (surface == null || !surface.isValid() || mBitmap == null) {
            return;
        }
        try {
            mRenderer = new android.graphics.HardwareRenderer();
            mRenderer.setSurface(surface);
            mRenderer.setLightSourceAlpha(0f, 0f);
            mRenderer.setLightSourceGeometry(0f, 0f, 0f, 0f);

            android.graphics.RenderNode node =
                    new android.graphics.RenderNode("hdrwin-node");
            // Surface.getWidth()/getHeight() 是 protected、SDK 里调不到，
            // 直接用我们自己的窗口尺寸（就是 surface 的尺寸）。
            int px = Math.max(1, Math.round(SIZE_DP
                    * getResources().getDisplayMetrics().density));
            int w = px;
            int h = px;
            node.setPosition(0, 0, w, h);
            android.graphics.RecordingCanvas rc = node.beginRecording();
            rc.drawColor(Color.TRANSPARENT, android.graphics.PorterDuff.Mode.CLEAR);
            Paint p = new Paint();
            p.setFilterBitmap(true);
            rc.drawBitmap(mBitmap, null, new android.graphics.Rect(0, 0, w, h), p);
            node.endRecording();

            mRenderer.setContentRoot(node);
            mRenderer.createRenderRequest()
                    .setWaitForPresent(true)
                    .syncAndDraw();

            mDrewOnce = true;
            Log.i(TAG, "rendered via HardwareRenderer " + w + "x" + h
                    + " gainmap=" + mBitmap.hasGainmap());
        } catch (Throwable t) {
            Log.e(TAG, "HardwareRenderer failed: " + t, t);
            // 兜底：退回硬件画布
            draw(mView.getHolder());
        }
    }

    /**
     * 把 UltraHDR 解码出来的 HardwareBuffer 直接绑到 SurfaceView 的 SurfaceControl 上。
     *
     * 这是最后一条路：Canvas / HardwareRenderer 都会在绘制时丢掉 gain map
     * （实测 buffer dataspace 始终是 V0_SRGB、hdr metadata types=0），
     * 只有把带 HDR 标记的 buffer 原样提交，SurfaceFlinger 才可能把它算成 HDR 图层。
     */
    private void bindHardwareBuffer(SurfaceView v) {
        try {
            // 1) 解码出带 gain map 的位图，取 HardwareBuffer
            Bitmap src = ImageDecoder.decodeBitmap(
                    ImageDecoder.createSource(new java.io.File(getCacheDir(), IMG_PATH_NAME)));
            Log.i(TAG, "decoded " + src.getWidth() + "x" + src.getHeight()
                    + " config=" + src.getConfig() + " hasGainmap=" + src.hasGainmap());
            Bitmap hw = src.getConfig() == Bitmap.Config.HARDWARE
                    ? src : src.copy(Bitmap.Config.HARDWARE, false);
            android.hardware.HardwareBuffer buf = hw == null ? null : hw.getHardwareBuffer();
            if (buf == null) {
                Log.w(TAG, "no HardwareBuffer");
                return;
            }
            Log.i(TAG, "hardware buffer " + buf.getWidth() + "x" + buf.getHeight()
                    + " fmt=" + buf.getFormat());

            // 2) 拿 SurfaceView 的 SurfaceControl —— getSurfaceControl() 是公开 API，
            //    比反射 mBlastSurfaceControl 可靠（实测反射那条路字段是 null）。
            android.view.SurfaceControl sc = v.getSurfaceControl();
            if (sc == null || !sc.isValid()) {
                Log.w(TAG, "surfaceControl null/invalid");
                return;
            }
            Log.i(TAG, "surfaceControl ok");

            // 2b) 试着强制这一层走 HDR（Surface.setForceHdrEnabled 是隐藏 API）
            try {
                java.lang.reflect.Field sf = null;
                for (Class<?> c = SurfaceView.class; c != null && sf == null; c = c.getSuperclass()) {
                    try {
                        sf = c.getDeclaredField("mSurface");
                    } catch (NoSuchFieldException ignored) {
                    }
                }
                if (sf != null) {
                    sf.setAccessible(true);
                    Object surfaceObj = sf.get(v);
                    if (surfaceObj != null) {
                        java.lang.reflect.Method fhe = android.view.Surface.class
                                .getDeclaredMethod("setForceHdrEnabled", boolean.class);
                        fhe.setAccessible(true);
                        fhe.invoke(surfaceObj, Boolean.TRUE);
                        Log.i(TAG, "Surface.setForceHdrEnabled(true) ok");
                    }
                }
            } catch (Throwable t) {
                Log.w(TAG, "setForceHdrEnabled failed: " + t);
            }

            // 3) Transaction.setBuffer + setExtendedRangeBrightness
            android.view.SurfaceControl.Transaction tx =
                    new android.view.SurfaceControl.Transaction();
            tx.setBuffer(sc, buf);
            tx.setExtendedRangeBrightness(sc, HEADROOM, HEADROOM);
            tx.apply();
            mDrewOnce = true;
            Log.i(TAG, "bound HardwareBuffer to SurfaceControl + extendedRange " + HEADROOM);
        } catch (Throwable t) {
            Log.e(TAG, "bindHardwareBuffer failed: " + t, t);
        }
    }

    private void draw(SurfaceHolder holder) {
        Canvas c = null;
        boolean hw = false;
        try {
            // 用 **硬件画布** —— 软件 lockCanvas() 产出的 buffer dataspace 是纯 sRGB，
            // gain map 也在绘制时丢掉，系统就不会把它算成 HDR 图层。
            try {
                c = holder.lockHardwareCanvas();
                hw = (c != null);
            } catch (Throwable t) {
                Log.w(TAG, "lockHardwareCanvas failed: " + t);
            }
            if (c == null) {
                c = holder.lockCanvas();
            }
            if (c == null) {
                Log.w(TAG, "no canvas");
                return;
            }
            c.drawColor(Color.TRANSPARENT, android.graphics.PorterDuff.Mode.CLEAR);
            if (mBitmap != null) {
                Paint p = new Paint();
                p.setFilterBitmap(true);
                c.drawBitmap(mBitmap, null,
                        new android.graphics.Rect(0, 0, c.getWidth(), c.getHeight()), p);
            }
            if (!mDrewOnce) {
                mDrewOnce = true;
                Log.i(TAG, "drew via " + (hw ? "hardware" : "software") + " canvas"
                        + " size=" + c.getWidth() + "x" + c.getHeight()
                        + " gainmap=" + (mBitmap != null && mBitmap.hasGainmap()));
            }
        } catch (Throwable t) {
            Log.w(TAG, "draw failed: " + t);
        } finally {
            if (c != null) {
                try {
                    holder.unlockCanvasAndPost(c);
                } catch (Throwable ignored) {
                }
            }
        }
    }

    // ------------------------------------------------------------------ image

    /**
     * 造一张 **全透明** 的、带 gain map 的位图。
     *
     * 不落盘再解码 —— ImageDecoder 解出来是 HARDWARE 位图，而 SurfaceView.lockCanvas()
     * 是软件画布，画不上去（实测 "Software rendering doesn't support hardware bitmaps"）。
     * gain map 是挂在 Bitmap 对象上的，直接持有对象就行。
     */
    private Bitmap buildTransparentUltraHdr() {
        Bitmap base = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(base);
        // 几乎全黑但**不透明**：完全透明(alpha=0)时 SurfaceFlinger 会把它当成
        // 「不可见图层」排除在 HDR 统计外（实测 alpha=0 时 numHdrLayers 一直是 0）。
        // 全黑在 AMOLED 上不发光，肉眼同样看不见。
        c.drawColor(0xFF000000);

        Bitmap gain = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888);
        Canvas gc = new Canvas(gain);
        gc.drawColor(Color.rgb(0xC0, 0xC0, 0xC0));  // 均匀中等增益

        Gainmap gm = new Gainmap(gain);
        gm.setRatioMin(1f, 1f, 1f);
        gm.setRatioMax(4f, 4f, 4f);
        gm.setGamma(1f, 1f, 1f);
        gm.setEpsilonSdr(0f, 0f, 0f);
        gm.setEpsilonHdr(0f, 0f, 0f);
        gm.setDisplayRatioForFullHdr(4f);
        gm.setMinDisplayRatioForHdrTransition(1f);
        gm.setGainmapDirection(Gainmap.GAINMAP_DIRECTION_SDR_TO_HDR);
        base.setGainmap(gm);

        Log.i(TAG, "transparent ultraHDR " + base.getWidth() + "x" + base.getHeight()
                + " hasGainmap=" + base.hasGainmap());

        // 顺手也落一份 JPEG 备查
        try {
            File f = new File(getCacheDir(), IMG_PATH_NAME);
            FileOutputStream fos = new FileOutputStream(f);
            try {
                base.compress(Bitmap.CompressFormat.JPEG, 95, fos);
                fos.flush();
            } finally {
                fos.close();
            }
            Log.i(TAG, "wrote " + f + " " + f.length() + " bytes");
        } catch (Throwable t) {
            Log.w(TAG, "dump jpg failed: " + t);
        }
        return base;
    }

    // ------------------------------------------------------------------ notif

    private void startForegroundNotif() {
        String id = "hdrwin";
        NotificationManager nm = (NotificationManager) getSystemService(
                Context.NOTIFICATION_SERVICE);
        if (nm != null) {
            NotificationChannel ch = new NotificationChannel(id, "HDR",
                    NotificationManager.IMPORTANCE_MIN);
            nm.createNotificationChannel(ch);
        }
        Notification n = new Notification.Builder(this, id)
                .setContentTitle("HDR 小窗")
                .setContentText("正在用透明 HDR 图片放开亮度上限")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setOngoing(true)
                .build();
        startForeground(1, n);
    }
}
