import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Gainmap;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Shader;

import java.io.File;
import java.io.FileOutputStream;

/**
 * UltraHdrGen —— 用系统 Gainmap API 造真正的 UltraHDR JPEG。
 *
 * 这是酷安显示 HDR 图片用的格式，也是"局部高光"那套机制：
 *   - 主图是普通 SDR JPEG，任何看图软件都能显示
 *   - 附一张 gain map，看图软件支持 HDR 时用它把高光像素提亮
 *   - 屏幕不需要进整屏 HDR 模式 —— 这正是它不偏色的原因
 *
 * 用法：CLASSPATH=ultrahdr.jar app_process /data/local/tmp UltraHdrGen <输出目录>
 */
public final class UltraHdrGen {

    // 默认做小的（几像素就够当触发器），--big 时做 1080x1080 给人看
    private static int W = 8;
    private static int H = 8;

    public static void main(String[] args) throws Exception {
        String dir = args.length > 0 ? args[0] : "/sdcard/Download/HDRTest";
        boolean big = false;
        String name = "ultrahdr_small.jpg";
        for (int i = 1; i < args.length; i++) {
            if ("--big".equals(args[i])) {
                big = true;
                name = "ultrahdr.jpg";
            }
        }
        if (big) {
            W = 1080;
            H = 1080;
        }
        File d = new File(dir);
        //noinspection ResultOfMethodCallIgnored
        d.mkdirs();

        // ---- 主图：普通 SDR 内容（暗一点，好看出高光）----
        Bitmap base = Bitmap.createBitmap(W, H, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(base);
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        // 深色背景渐变
        p.setShader(new LinearGradient(0, 0, W, H,
                new int[]{0xFF101820, 0xFF203040, 0xFF0A0E12},
                new float[]{0f, 0.5f, 1f}, Shader.TileMode.CLAMP));
        c.drawRect(0, 0, W, H, p);
        // 几个灰阶色块，方便比较
        p.setShader(null);
        int[] grays = {0x20, 0x50, 0x80, 0xB0, 0xE0};
        for (int i = 0; i < grays.length; i++) {
            p.setColor(Color.rgb(grays[i], grays[i], grays[i]));
            c.drawRect(i * (W / 5f), H * 0.62f, (i + 1) * (W / 5f) - 8, H * 0.72f, p);
        }
        // 中间一个亮白圆（高光锚点）
        p.setShader(new RadialGradient(W / 2f, H / 2f, W * 0.30f,
                new int[]{0xFFFFFFFF, 0xFFBBBBBB, 0x00000000},
                new float[]{0f, 0.55f, 1f}, Shader.TileMode.CLAMP));
        c.drawCircle(W / 2f, H / 2f, W * 0.30f, p);
        c.drawBitmap(base, 0, 0, null);

        // ---- gain map：灰度图，越亮 = 该像素增益越大 ----
        Bitmap gain = Bitmap.createBitmap(W, H, Bitmap.Config.ARGB_8888);
        Canvas gc = new Canvas(gain);
        Paint gp = new Paint(Paint.ANTI_ALIAS_FLAG);
        // 基础增益较低（128 附近 = 基本不加）
        gp.setColor(Color.rgb(0x80, 0x80, 0x80));
        gc.drawRect(0, 0, W, H, gp);
        // 中心区域强增益（白圆位置 -> 拉到最大）
        gp.setShader(new RadialGradient(W / 2f, H / 2f, W * 0.30f,
                new int[]{0xFFFFFFFF, 0xFFC0C0C0, 0x00000080},
                new float[]{0f, 0.6f, 1f}, Shader.TileMode.CLAMP));
        gc.drawCircle(W / 2f, H / 2f, W * 0.30f, gp);
        // 右上角一块也拉高，便于对比
        gp.setShader(null);
        gp.setColor(Color.rgb(0xFF, 0xFF, 0xFF));
        gc.drawRect(W * 0.7f, H * 0.08f, W * 0.94f, H * 0.24f, gp);

        // ---- 组装 Gainmap 元数据 ----
        Gainmap gm = new Gainmap(gain);
        gm.setRatioMin(1.0f, 1.0f, 1.0f);
        gm.setRatioMax(4.0f, 4.0f, 4.0f);     // 最大 4 倍增益
        gm.setGamma(1.0f, 1.0f, 1.0f);
        gm.setEpsilonSdr(0.0f, 0.0f, 0.0f);
        gm.setEpsilonHdr(0.0f, 0.0f, 0.0f);
        gm.setDisplayRatioForFullHdr(4.0f);
        gm.setMinDisplayRatioForHdrTransition(1.0f);
        gm.setGainmapDirection(Gainmap.GAINMAP_DIRECTION_SDR_TO_HDR);

        base.setGainmap(gm);
        System.out.println("hasGainmap after set = " + base.hasGainmap());

        File out = new File(d, name);
        FileOutputStream fos = new FileOutputStream(out);
        boolean ok;
        try {
            ok = base.compress(Bitmap.CompressFormat.JPEG, 95, fos);
            fos.flush();
        } finally {
            fos.close();
        }
        System.out.println("compress ok = " + ok + "  -> " + out.getAbsolutePath()
                + "  " + out.length() + " bytes");

        // 简单对照：不带 gain map 的同内容 JPEG
        File plain = new File(d, "plain.jpg");
        FileOutputStream fos2 = new FileOutputStream(plain);
        try {
            base.setGainmap(null);
            base.compress(Bitmap.CompressFormat.JPEG, 95, fos2);
            fos2.flush();
        } finally {
            fos2.close();
        }
        System.out.println("plain -> " + plain.getAbsolutePath() + "  " + plain.length());
    }
}
