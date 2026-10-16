# Moteur partagé (bibliothèque, ne s'exécute pas seul) : image de travail des étapes de prétraitement + interface d'étape.
# Chargé via Import-AsciiEngine (AsciiArtPluginCompilator.ps1) par les fichiers qui déclarent  // @requires AsciiArtRaster.ps1
#   AsciiRaster : pixels RGB (float) à la taille de travail + 3 couches d'état cumulées au fil des étapes :
#     Background = fond blanc pur : jamais modifié par L/E ; ignoré de l'histogramme et des aplats de L ; vote "blanc" dans E
#     Excluded   = exclusion ASCII (vert des masques) : pixel figé (couleur d'origine conservée, jamais blanchi) et
#                  invisible pour les étapes suivantes (ni histogramme, ni moyenne d'aplat, ni vote de lissage)
#     Erased     = gomme (rouge des masques) : pixel remis en blanc pur et ajouté au fond -> vrais contours
#   IAsciiStep  : une étape (L, E, M...) = Code (ex. "L4") + Apply(raster) qui modifie le raster en place.
#   AsciiRasterMask : codecs PNG rouge/vert (Decode/Compose), Resize et Apply (aperçu/overlay).
#   Les couches du masque sont celles du raster, sans objet d'état parallèle ; aucun lien avec le pinceau.
$code = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public interface IAsciiStep
{
    string Code { get; }
    void Apply(AsciiRaster raster);
}

public interface IAsciiMaskStep : IAsciiStep
{
    int Index { get; }
    Bitmap Mask { get; }
    char Channel { get; }
}

public sealed class AsciiRaster
{
    public int Width { get; private set; }
    public int Height { get; private set; }
    public float[] Rgb { get; private set; }
    public bool[] Background { get; private set; }
    public bool[] Excluded { get; private set; }
    public bool[] Erased { get; private set; }

    public AsciiRaster(int width, int height)
    {
        if (width < 1 || height < 1) throw new ArgumentOutOfRangeException("width");
        Width = width; Height = height;
        int n = width * height;
        Rgb = new float[n * 3]; Background = new bool[n]; Excluded = new bool[n]; Erased = new bool[n];
    }

    public int Count { get { return Width * Height; } }

    // Copie indépendante : le raster remplacé peut rester une frontière du cache.
    public void ReplaceWith(AsciiRaster source)
    {
        if (source == null) throw new ArgumentNullException("source");
        AsciiRaster copy = source.Clone();
        Width = copy.Width; Height = copy.Height;
        Rgb = copy.Rgb; Background = copy.Background; Excluded = copy.Excluded; Erased = copy.Erased;
    }

    public AsciiRaster Clone()
    {
        AsciiRaster copy = new AsciiRaster(Width, Height);
        Array.Copy(Rgb, copy.Rgb, Rgb.Length);
        Array.Copy(Background, copy.Background, Background.Length);
        Array.Copy(Excluded, copy.Excluded, Excluded.Length);
        Array.Copy(Erased, copy.Erased, Erased.Length);
        return copy;
    }

    // Chargement brut : transparence sur blanc, sans changement de taille ni détection de fond.
    public static AsciiRaster Load(Bitmap src)
    {
        if (src == null) throw new ArgumentNullException("src");
        int w = src.Width, h = src.Height;
        AsciiRaster r = new AsciiRaster(w, h);
        float[] rgb = r.Rgb;
        using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.White);
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(src, 0, 0, w, h);
            }
            BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            byte[] bytes = new byte[data.Stride * h];
            try { Marshal.Copy(data.Scan0, bytes, 0, bytes.Length); }
            finally { bmp.UnlockBits(data); }
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    int p = y * data.Stride + x * 4, i = (y * w + x) * 3;
                    rgb[i] = bytes[p + 2]; rgb[i + 1] = bytes[p + 1]; rgb[i + 2] = bytes[p];
                }
        }
        return r;
    }

    public Bitmap ToBitmap()
    {
        int w = Width, h = Height;
        Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        try
        {
            BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            try
            {
                byte[] bytes = new byte[data.Stride * h];
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++)
                    {
                        int p = y * data.Stride + x * 4, i = (y * w + x) * 3;
                        bytes[p] = Clamp(Rgb[i + 2]); bytes[p + 1] = Clamp(Rgb[i + 1]); bytes[p + 2] = Clamp(Rgb[i]); bytes[p + 3] = 255;
                    }
                Marshal.Copy(bytes, 0, data.Scan0, bytes.Length);
            }
            finally { bmp.UnlockBits(data); }
            return bmp;
        }
        catch { bmp.Dispose(); throw; }
    }

    static byte Clamp(float v) { return (byte)Math.Max(0, Math.Min(255, (int)Math.Round(v))); }
}

public static class AsciiRasterMask
{
    public static Bitmap Resize(Bitmap mask, int width, int height)
    {
        Bitmap result = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(result))
        {
            graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
            graphics.PixelOffsetMode = PixelOffsetMode.Half;
            graphics.DrawImage(mask, new Rectangle(0, 0, width, height), 0, 0, mask.Width, mask.Height, GraphicsUnit.Pixel);
        }
        return result;
    }

    // Gomme sur blanc ; overlay orange/magenta, avec recouvrement distinct.
    public static Bitmap Apply(Bitmap source, Bitmap mask, bool overlay)
    {
        if (source == null) throw new ArgumentNullException("source");
        bool[] erase, exclude;
        Decode(mask, source.Width, source.Height, out erase, out exclude);
        using (Bitmap flat = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb))
        {
            using (Graphics graphics = Graphics.FromImage(flat))
            {
                graphics.Clear(Color.White);
                graphics.DrawImageUnscaled(source, 0, 0);
            }
            byte[] image = Read(flat);
            for (int i = 0, p = 0; i < image.Length; i += 4, p++)
            {
                bool erased = erase[p], excluded = exclude[p];
                if (erased) image[i] = image[i + 1] = image[i + 2] = 255;
                if (overlay && (erased || excluded))
                {
                    int red = 255, green = excluded ? (erased ? 100 : 0) : 150, blue = excluded ? 255 : 0;
                    image[i] = (byte)((image[i] + blue * 2) / 3);
                    image[i + 1] = (byte)((image[i + 1] + green * 2) / 3);
                    image[i + 2] = (byte)((image[i + 2] + red * 2) / 3);
                }
            }
            return Write(source.Width, source.Height, image);
        }
    }

    // Rouge >= 128 = gomme, vert >= 128 = exclusion ; plus proche voisin à la taille demandée.
    public static void Decode(Bitmap mask, int width, int height, out bool[] erase, out bool[] exclude)
    {
        if (mask == null) throw new ArgumentNullException("mask");
        if (width < 1 || height < 1) throw new ArgumentOutOfRangeException("width");
        erase = new bool[width * height]; exclude = new bool[width * height];
        using (Bitmap scaled = Resize(mask, width, height))
        {
            byte[] marks = Read(scaled);
            for (int i = 0, p = 0; i < marks.Length; i += 4, p++)
            {
                erase[p] = marks[i + 2] >= 128;
                exclude[p] = marks[i + 1] >= 128;
            }
        }
    }

    // Exporte directement les couches du raster, sans les copier dans un second modèle.
    public static Bitmap Compose(bool[] erase, bool[] exclude, int width, int height)
    {
        if (width < 1 || height < 1) throw new ArgumentOutOfRangeException("width");
        int n = width * height;
        if ((erase != null && erase.Length != n) || (exclude != null && exclude.Length != n))
            throw new ArgumentException("Taille de couche incompatible avec " + width + "x" + height);
        byte[] bytes = new byte[n * 4];
        for (int p = 0, i = 0; p < n; p++, i += 4)
        {
            if (erase != null && erase[p]) bytes[i + 2] = 255;
            if (exclude != null && exclude[p]) bytes[i + 1] = 255;
            bytes[i + 3] = 255;
        }
        return Write(width, height, bytes);
    }

    internal static byte[] Read(Bitmap bitmap)
    {
        BitmapData data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height),
            ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            byte[] bytes = new byte[bitmap.Width * bitmap.Height * 4];
            for (int y = 0; y < bitmap.Height; y++)
                Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), bytes, y * bitmap.Width * 4, bitmap.Width * 4);
            return bytes;
        }
        finally { bitmap.UnlockBits(data); }
    }

    internal static Bitmap Write(int width, int height, byte[] bytes)
    {
        Bitmap bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        try
        {
            BitmapData data = bitmap.LockBits(new Rectangle(0, 0, width, height),
                ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            try
            {
                for (int y = 0; y < height; y++)
                    Marshal.Copy(bytes, y * width * 4, IntPtr.Add(data.Scan0, y * data.Stride), width * 4);
            }
            finally { bitmap.UnlockBits(data); }
            return bitmap;
        }
        catch { bitmap.Dispose(); throw; }
    }
}
'@