# Moteur du plugin Taille : S<100-4000>, réduction du côté le plus long, jamais d'agrandissement.
# Les couches de retouches sont projetées par empreinte (une marque isolée n'est pas perdue).
$code = @'
// @requires AsciiArtRaster.ps1
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public sealed class AsciiSize : IAsciiStep
{
    readonly int maxSize;
    public AsciiSize(int maxSize)
    {
        if (maxSize < 1) throw new ArgumentOutOfRangeException("maxSize");
        this.maxSize = maxSize;
    }
    public int MaxSize { get { return maxSize; } }
    public string Code { get { return "S" + maxSize; } }

    // Même interpolation que la préparation historique, également utilisée par les API de compatibilité.
    public static AsciiRaster Load(Bitmap source, int maxSize)
    {
        if (source == null) throw new ArgumentNullException("source");
        if (maxSize < 1) throw new ArgumentOutOfRangeException("maxSize");
        double scale = Math.Min(1.0, (double)maxSize / Math.Max(source.Width, source.Height));
        int w = Math.Max(1, (int)Math.Round(source.Width * scale));
        int h = Math.Max(1, (int)Math.Round(source.Height * scale));
        using (Bitmap resized = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(resized))
            {
                g.Clear(Color.White);
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(source, 0, 0, w, h);
            }
            return AsciiRaster.Load(resized);
        }
    }

    public void Apply(AsciiRaster raster)
    {
        if (raster == null) throw new ArgumentNullException("raster");
        if (Math.Max(raster.Width, raster.Height) <= maxSize) return;
        AsciiRaster resized;
        using (Bitmap source = raster.ToBitmap()) resized = Load(source, maxSize);
        int w = resized.Width, h = resized.Height;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int i = y * w + x;
                int left = x * raster.Width / w, top = y * raster.Height / h;
                int right = (int)Math.Ceiling((double)(x + 1) * raster.Width / w);
                int bottom = (int)Math.Ceiling((double)(y + 1) * raster.Height / h);
                int excluded = -1;
                bool background = false, erased = false;
                for (int yy = top; yy < bottom; yy++)
                    for (int xx = left; xx < right; xx++)
                    {
                        int p = yy * raster.Width + xx;
                        if (raster.Excluded[p] && excluded < 0) excluded = p;
                        erased |= raster.Erased[p];
                        background |= raster.Background[p];
                    }
                resized.Excluded[i] = excluded >= 0;
                resized.Erased[i] = erased;
                resized.Background[i] = erased || background;
                if (excluded >= 0)
                {
                    for (int c = 0; c < 3; c++) resized.Rgb[i * 3 + c] = raster.Rgb[excluded * 3 + c];
                    resized.Background[i] = erased || raster.Background[excluded];
                }
                if (resized.Background[i])
                    resized.Rgb[i * 3] = resized.Rgb[i * 3 + 1] = resized.Rgb[i * 3 + 2] = 255f;
            }
        raster.ReplaceWith(resized);
    }
}
'@
