# Usage : .\AsciiArtConverter.ps1 -Path photo.png [-Width 100] [-Height 40] [-Detail 0.5] [-Smooth 2] [-MinSize 5] [-Invert] [-Fill] [-Straight 0.9] [-Chars "..."] [-Out resultat.txt]
# Conseil : passer d'abord l'image dans .\AsciiArtPreProcess.ps1 (aplats de couleur, fond blanc préservé) et donner le résultat à -Path.
# Compatibilité : AsciiArtMask.ps1 applique toujours un masque combine ; le GUI produit separement Gomme et Masque.
# Contours via une détection de type Canny (étirement du contraste -> flou -> Sobel -> suppression des
# non-maxima -> hystérésis -> nettoyage des fragments), puis chaque cellule est associée au caractère ASCII
# dont la FORME (police Consolas) ressemble le plus au contour local : toute la palette est exploitée
# ( ) [ ] { } ~ ' ` , . : ; ! 1 l I ...). Les traits droits - _ | / \ < > ^ v ┌ ┐ └ ┘ sont tracés à part, d'après la géométrie du contour (cf. -Straight).
param(
    [Parameter(Mandatory)][string]$Path,
    [int]$Width = 0,                                  # colonnes (0 = auto)
    [int]$Height = 0,                                 # lignes (0 = auto, proportionnel). Si les deux sont donnés, le ratio est forcé
    [ValidateRange(0.0, 1.0)][double]$Detail = 0.5,   # 0 = contours principaux seulement, 1 = très détaillé
    [ValidateRange(0.0, 6.0)][double]$Smooth = 0,     # flou gaussien optionnel avant détection (0 = aucun) : plus haut = moins de texture/bruit
    [ValidateRange(0, 50)][double]$MinSize = 5,        # taille minimale (en caractères) d'un contour ; en dessous = petit détail ignoré (feuilles, texture)
    [switch]$Invert,                                  # inverse la luminance (contours clairs sur fond sombre)
    [switch]$Fill,                                    # ajoute un léger remplissage ( . : ) dans les zones sombres sans contour
    [ValidateRange(0.5, 1.0)][double]$Straight = 0.9, # cohérence minimale pour tracer un trait droit (- _ | / \) : 1 = jamais (tout en recherche de forme), 0.5 = très souvent
    [string]$Chars = '()[]{}~''",.:;!=+',   # caractères de contour autorisés (pour la palette complète : -Chars (-join ([char[]](33..126))) )
    [string]$Out,
    [string]$Mask                                   # PNG de retouches : canal vert = exclusion, apres application de la gomme par AsciiArtMask.ps1
)

$code = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;

public static class AsciiEdge
{
    const int CW = 8, CH = 16;   // pixels par caractère (caractère ~2x plus haut que large)

    public static string[] Run(string path, int width, int rows, double detail, double smooth, double minSize,
                               bool invert, bool fill, string chars, double straightThr)
    {
        using (Bitmap src = new Bitmap(path))
            return Run(src, width, rows, detail, smooth, minSize, invert, fill, chars, straightThr);
    }

    public static string[] Run(Bitmap src, int width, int rows, double detail, double smooth, double minSize,
                               bool invert, bool fill, string chars, double straightThr)
    {
        return Run(src, width, rows, detail, smooth, minSize, invert, fill, chars, straightThr, null);
    }

    public static string[] Run(Bitmap src, int width, int rows, double detail, double smooth, double minSize,
                               bool invert, bool fill, string chars, double straightThr, Bitmap mask)
    {
        float[] rgb; int w, h;
        Load(src, ref width, ref rows, out rgb, out w, out h);
        int n = w * h;
        bool[] excluded = LoadExclusion(mask, w, h);
        bool[] hiddenCells = new bool[width * rows];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (excluded[y * w + x]) hiddenCells[(y / CH) * width + x / CW] = true;

        // Fond : blanc pur (celui laissé intact par le prétraitement) -> exclu du calcul de contraste
        bool[] bg = new bool[n]; bool hasBg = false;
        for (int i = 0; i < n; i++)
            if (Math.Min(rgb[i * 3], Math.Min(rgb[i * 3 + 1], rgb[i * 3 + 2])) >= 254f) { bg[i] = true; hasBg = true; }

        float[] lum = new float[n];
        for (int i = 0; i < n; i++) lum[i] = bg[i] ? 255f : 0.299f * rgb[i * 3] + 0.587f * rgb[i * 3 + 1] + 0.114f * rgb[i * 3 + 2];
        Stretch(lum, bg, hasBg, excluded);
        if (invert) for (int i = 0; i < n; i++) lum[i] = 255f - lum[i];
        float[] blur = smooth > 0 ? Blur(lum, w, h, smooth, (int)Math.Ceiling(smooth * 3)) : lum;   // 0 = pas de flou

        float[] gx = new float[w * h], gy = new float[w * h], mag = new float[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int x0 = Math.Max(x - 1, 0), x1 = Math.Min(x + 1, w - 1), y0 = Math.Max(y - 1, 0), y1 = Math.Min(y + 1, h - 1);
                float sx = -blur[y0*w+x0] - 2*blur[y*w+x0] - blur[y1*w+x0] + blur[y0*w+x1] + 2*blur[y*w+x1] + blur[y1*w+x1];
                float sy = -blur[y0*w+x0] - 2*blur[y0*w+x] - blur[y0*w+x1] + blur[y1*w+x0] + 2*blur[y1*w+x] + blur[y1*w+x1];
                int i = y*w+x; gx[i] = sx; gy[i] = sy; mag[i] = (float)Math.Sqrt(sx*sx + sy*sy);
            }

        // Later preprocessing may change colors beside an untouched excluded zone.
        // Reject gradients whose sampling footprint crosses that zone, not just its center.
        SuppressMaskedGradients(mag, excluded, w, h, 1 + (smooth > 0 ? (int)Math.Ceiling(smooth * 3) : 0));
        float[] nms = NonMaxSuppression(mag, gx, gy, w, h);
        bool[] edge = Hysteresis(nms, w, h, detail, Math.Max(1.0, smooth));
        RemoveSmall(edge, w, h, 14, (int)Math.Round(minSize * CW));
        // Keep the original image during detection: the mask cannot introduce a cut-out edge.
        for (int i = 0; i < n; i++) if (excluded[i]) edge[i] = false;

        // Carte de contours légèrement floutée : tolère un petit décalage avec la forme des glyphes
        float[] ef = new float[w * h];
        for (int i = 0; i < ef.Length; i++) ef[i] = edge[i] ? 1f : 0f;
        ef = Blur(ef, w, h, 1.3, 3);

        // Les traits droits (ci-dessous) sont tracés par la géométrie du contour, jamais par la recherche de forme
        const string STRAIGHT = "-_|/\\<>^v\u250C\u2510\u2514\u2518";
        var keep = new System.Text.StringBuilder();
        foreach (char c in chars ?? "") if (STRAIGHT.IndexOf(c) < 0) keep.Append(c);
        char[] glyphChars; float[][] glyphs; float[] ginks;
        BuildGlyphs(keep.ToString(), out glyphChars, out glyphs, out ginks);

        char[][] grid = new char[rows][];
        float[] patch = new float[CW * CH];
        int[] nk = new int[4]; double[] sxk = new double[4], syk = new double[4];   // classes : 0 horizontal, 1 '/', 2 vertical, 3 '\'
        for (int cy = 0; cy < rows; cy++)
        {
            char[] line = new char[width];
            for (int q = 0; q < width; q++) line[q] = ' ';
            grid[cy] = line;
            for (int cx = 0; cx < width; cx++)
            {
                if (hiddenCells[cy * width + cx]) continue;
                int count = 0; double lsum = 0; double en = 0;
                double c2 = 0, s2 = 0, wsum = 0, sy = 0;
                Array.Clear(nk, 0, 4); Array.Clear(sxk, 0, 4); Array.Clear(syk, 0, 4);
                for (int y = 0; y < CH; y++)
                    for (int x = 0; x < CW; x++)
                    {
                        int i = (cy * CH + y) * w + cx * CW + x;
                        float v = ef[i]; patch[y * CW + x] = v; en += v * v;
                        if (edge[i])
                        {
                            count++;
                            double phi = Math.Atan2(gy[i], gx[i]);   // angle doublé pour moyenner les orientations
                            c2 += mag[i] * Math.Cos(2 * phi); s2 += mag[i] * Math.Sin(2 * phi);
                            wsum += mag[i]; sy += y;
                            double ad = (-(phi * 180 / Math.PI + 90)) % 180; if (ad < 0) ad += 180;
                            int k = (ad < 22.5 || ad >= 157.5) ? 0 : (ad < 67.5 ? 1 : (ad < 112.5 ? 2 : 3));
                            nk[k]++; sxk[k] += x; syk[k] += y;
                        }
                        lsum += lum[i];
                    }
                char ch = ' ';
                double coherence = wsum > 0 ? Math.Sqrt(c2 * c2 + s2 * s2) / wsum : 0;
                bool straight = false;
                if (straightThr < 1.0 && count >= 6)
                {
                    if (count >= 8 && coherence > straightThr)
                    {
                        // Trait rectiligne : le caractère est choisi selon l'orientation
                        double a = (-(0.5 * Math.Atan2(s2, c2) * 180 / Math.PI + 90)) % 180; if (a < 0) a += 180;
                        if (a >= 22.5 && a < 67.5) ch = '/';
                        else if (a >= 67.5 && a < 112.5) ch = '|';
                        else if (a >= 112.5 && a < 157.5) ch = '\\';
                        else
                        {
                            double my = sy / count;
                            if (my > 10.67) ch = '_';                                     // bas de la cellule
                            else if (my >= 5.33) ch = '-';                                // milieu
                            else if (cy > 0 && grid[cy - 1][cx] == ' ') { grid[cy - 1][cx] = '_'; ch = ' '; }   // haut : '_' dans la cellule vide du dessus
                            else ch = '-';
                        }
                        straight = true;
                    }
                    else
                    {
                        double minFrac = straightThr - 0.15;
                        // Coin : un trait horizontal + un trait vertical qui se rejoignent
                        if (nk[0] >= 2 && nk[2] >= 2 && (nk[0] + nk[2]) >= minFrac * count)
                        {
                            double dx = sxk[0] / nk[0] - sxk[2] / nk[2];      // > 0 : l'horizontale part vers la droite
                            double dy = syk[2] / nk[2] - syk[0] / nk[0];      // > 0 : la verticale part vers le bas
                            if (Math.Abs(dx) >= 1.0 && Math.Abs(dy) >= 1.0)
                            {
                                ch = dx > 0 ? (dy > 0 ? '\u250C' : '\u2514') : (dy > 0 ? '\u2510' : '\u2518');
                                straight = true;
                            }
                        }
                        // Pointe : une diagonale '/' + une diagonale '\' qui se rejoignent
                        if (!straight && nk[1] >= 3 && nk[3] >= 3 && (nk[1] + nk[3]) >= minFrac * count)
                        {
                            double dx = sxk[3] / nk[3] - sxk[1] / nk[1];      // > 0 : '\' à droite de '/'  => ^
                            double dy = (syk[3] / nk[3] - syk[1] / nk[1]) / 2; // > 0 : '\' sous '/'         => <   (cellule 2x plus haute)
                            if (Math.Max(Math.Abs(dx), Math.Abs(dy)) >= 1.0)
                            {
                                if (Math.Abs(dx) >= Math.Abs(dy)) ch = dx > 0 ? '^' : 'v';
                                else ch = dy > 0 ? '<' : '>';
                                straight = true;
                            }
                        }
                    }
                }
                if (!straight && count >= 4)
                {
                    // Courbe ou détail : le caractère dont la forme ressemble le plus au contour
                    float pmax = 0; foreach (float v in patch) if (v > pmax) pmax = v;
                    double pe2 = 0; for (int k = 0; k < patch.Length; k++) { patch[k] /= pmax; pe2 += patch[k] * patch[k]; }
                    double best = pe2 * 0.95;                                   // doit faire mieux que "rien" (espace)
                    for (int g = 0; g < glyphs.Length; g++)
                    {
                        float[] gl = glyphs[g]; double ssd = 0;
                        for (int k = 0; k < patch.Length; k++) { double d = patch[k] - gl[k]; ssd += d > 0 ? d * d : 1.3 * d * d; }   // encre en trop pénalisée
                        if (ssd < best) { best = ssd; ch = glyphChars[g]; }
                    }
                }
                else if (!straight && fill)
                {
                    double l = lsum / (CW * CH);
                    ch = l < 64 ? ':' : (l < 128 ? '.' : ' ');
                }
                if (ch != ' ') grid[cy][cx] = ch;
            }
        }
        string[] lines = new string[rows];
        // Also clear characters moved into the previous row by straight-line placement.
        for (int cy = 0; cy < rows; cy++)
            for (int cx = 0; cx < width; cx++)
                if (hiddenCells[cy * width + cx]) grid[cy][cx] = ' ';
        for (int cy = 0; cy < rows; cy++) lines[cy] = new string(grid[cy]).TrimEnd();        return lines;
    }

    static void SuppressMaskedGradients(float[] magnitude, bool[] excluded, int width, int height, int radius)
    {
        bool any = false;
        foreach (bool value in excluded) if (value) { any = true; break; }
        if (!any) return;
        bool[] horizontal = new bool[excluded.Length];
        for (int y = 0; y < height; y++)
        {
            int count = 0, row = y * width;
            for (int x = 0; x <= Math.Min(radius, width - 1); x++) if (excluded[row + x]) count++;
            for (int x = 0; x < width; x++)
            {
                horizontal[row + x] = count > 0;
                if (x - radius >= 0 && excluded[row + x - radius]) count--;
                if (x + radius + 1 < width && excluded[row + x + radius + 1]) count++;
            }
        }
        for (int x = 0; x < width; x++)
        {
            int count = 0;
            for (int y = 0; y <= Math.Min(radius, height - 1); y++) if (horizontal[y * width + x]) count++;
            for (int y = 0; y < height; y++)
            {
                if (count > 0) magnitude[y * width + x] = 0;
                if (y - radius >= 0 && horizontal[(y - radius) * width + x]) count--;
                if (y + radius + 1 < height && horizontal[(y + radius + 1) * width + x]) count++;
            }
        }
    }

    static bool[] LoadExclusion(Bitmap mask, int width, int height)
    {
        bool[] excluded = new bool[width * height];
        if (mask == null) return excluded;
        var data = mask.LockBits(new Rectangle(0, 0, mask.Width, mask.Height), System.Drawing.Imaging.ImageLockMode.ReadOnly,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        try
        {
            byte[] row = new byte[mask.Width * 4];
            for (int y = 0; y < mask.Height; y++)
            {
                System.Runtime.InteropServices.Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), row, 0, row.Length);
                int y0 = (int)((long)y * height / mask.Height);
                int y1 = (int)(((long)(y + 1) * height + mask.Height - 1) / mask.Height);
                for (int x = 0; x < mask.Width; x++)
                {
                    if (row[x * 4 + 1] < 128) continue;
                    // Preserve even a one-pixel mark when the ASCII working image is smaller.
                    int x0 = (int)((long)x * width / mask.Width);
                    int x1 = (int)(((long)(x + 1) * width + mask.Width - 1) / mask.Width);
                    for (int yy = y0; yy < y1; yy++)
                        for (int xx = x0; xx < x1; xx++) excluded[yy * width + xx] = true;
                }
            }
        }
        finally { mask.UnlockBits(data); }
        return excluded;
    }

    // Rend chaque caractère demandé dans une tuile CW x CH (couverture 0..1), légèrement floutée
    static void BuildGlyphs(string chars, out char[] gc, out float[][] glyphs, out float[] inks)
    {
        FontFamily fam;
        try { fam = new FontFamily("Consolas"); } catch { fam = new FontFamily("Courier New"); }
        var list = new List<char>(); var gl = new List<float[]>(); var nl = new List<float>();
        using (Font font = new Font(fam, 48, FontStyle.Regular, GraphicsUnit.Pixel))
        using (Bitmap probe = new Bitmap(1, 1))
        using (Graphics pg = Graphics.FromImage(probe))
        {
            StringFormat sf = StringFormat.GenericTypographic;
            int W = (int)Math.Ceiling(pg.MeasureString("M", font, 1000, sf).Width), H = font.Height;
            var seen = new HashSet<char>();
            foreach (char c in chars)
            {
                if (c == ' ' || !seen.Add(c)) continue;
                float[] tile = new float[CW * CH];
                using (Bitmap hb = new Bitmap(W, H))
                {
                    using (Graphics g = Graphics.FromImage(hb))
                    {
                        g.Clear(Color.White);
                        g.TextRenderingHint = TextRenderingHint.AntiAlias;
                        g.DrawString(c.ToString(), font, Brushes.Black, 0, 0, sf);
                    }
                    for (int ty = 0; ty < CH; ty++)
                        for (int tx = 0; tx < CW; tx++)
                        {
                            double s = 0; int n = 0;
                            for (int sy = 0; sy < 3; sy++)
                                for (int sx = 0; sx < 3; sx++)
                                {
                                    int px = Math.Min(W - 1, (int)((tx + (sx + 0.5) / 3) * W / CW));
                                    int py = Math.Min(H - 1, (int)((ty + (sy + 0.5) / 3) * H / CH));
                                    s += 1.0 - hb.GetPixel(px, py).R / 255.0; n++;
                                }
                            tile[ty * CW + tx] = (float)(s / n);
                        }
                }
                float[] b = Blur(tile, CW, CH, 0.9, 2);
                double ink = 0, mx = 0; foreach (float v in b) mx = Math.Max(mx, v);
                if (mx < 0.02) continue;
                for (int k = 0; k < b.Length; k++) { b[k] = (float)(b[k] / mx); ink += b[k]; }   // normalisé : max = 1
                list.Add(c); gl.Add(b); nl.Add((float)ink);
            }
        }
        gc = list.ToArray(); glyphs = gl.ToArray(); inks = nl.ToArray();
    }

    static void Load(Bitmap src, ref int width, ref int rows, out float[] rgb, out int w, out int h)
    {
        {
            if (width <= 0 && rows <= 0) width = 100;
            if (width <= 0) width = Math.Max(1, (int)Math.Round(rows * 2.0 * src.Width / src.Height));
            if (rows <= 0) rows = Math.Max(1, (int)Math.Round(src.Height * ((double)width / src.Width) * 0.5));
            w = width * CW; h = rows * CH;
            using (Bitmap bmp = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.Clear(Color.White);   // transparence -> fond blanc
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.DrawImage(src, 0, 0, w, h);
                }
                rgb = new float[w * h * 3];
                var data = bmp.LockBits(new Rectangle(0, 0, w, h), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                byte[] bytes = new byte[data.Stride * h];
                System.Runtime.InteropServices.Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
                bmp.UnlockBits(data);
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++)
                    {
                        int p = y * data.Stride + x * 4, i = (y * w + x) * 3;
                        rgb[i] = bytes[p + 2]; rgb[i + 1] = bytes[p + 1]; rgb[i + 2] = bytes[p];
                    }
            }
        }
    }

    // Étire le contraste du sujet (percentiles 1%..99%). Si un fond blanc existe, le sujet est ramené à 0..200
    // pour que sa silhouette garde toujours un contraste net avec le fond.
    static void Stretch(float[] a, bool[] bg, bool hasBg, bool[] excluded)
    {
        List<float> fg = new List<float>();
        for (int i = 0; i < a.Length; i++) if (!bg[i] && !excluded[i]) fg.Add(a[i]);
        if (fg.Count == 0) return;
        float[] s = fg.ToArray(); Array.Sort(s);
        float lo = s[(int)(s.Length * 0.01)], hi = s[(int)((s.Length - 1) * 0.99)];
        float r = Math.Max(1f, hi - lo), top = hasBg ? 200f : 255f;
        for (int i = 0; i < a.Length; i++)
            a[i] = bg[i] ? 255f : Math.Min(top, Math.Max(0f, (a[i] - lo) / r * top));
    }

    static float[] Blur(float[] src, int w, int h, double sigma, int radius)
    {
        float[] k = new float[2 * radius + 1]; float sum = 0;
        for (int i = -radius; i <= radius; i++) { k[i + radius] = (float)Math.Exp(-(i * i) / (2 * sigma * sigma)); sum += k[i + radius]; }
        for (int i = 0; i < k.Length; i++) k[i] /= sum;
        float[] tmp = new float[w * h], dst = new float[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                float v = 0;
                for (int i = -radius; i <= radius; i++) v += k[i + radius] * src[y * w + Math.Min(Math.Max(x + i, 0), w - 1)];
                tmp[y * w + x] = v;
            }
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                float v = 0;
                for (int i = -radius; i <= radius; i++) v += k[i + radius] * tmp[Math.Min(Math.Max(y + i, 0), h - 1) * w + x];
                dst[y * w + x] = v;
            }
        return dst;
    }

    // Ne garde que les maxima locaux dans la direction du gradient -> contours d'1 pixel
    static float[] NonMaxSuppression(float[] mag, float[] gx, float[] gy, int w, int h)
    {
        float[] r = new float[w * h];
        for (int y = 1; y < h - 1; y++)
            for (int x = 1; x < w - 1; x++)
            {
                int i = y * w + x; float m = mag[i];
                if (m <= 0) continue;
                double a = Math.Atan2(gy[i], gx[i]) * 180 / Math.PI; if (a < 0) a += 180;
                int dx, dy;
                if (a < 22.5 || a >= 157.5) { dx = 1; dy = 0; }
                else if (a < 67.5) { dx = 1; dy = 1; }
                else if (a < 112.5) { dx = 0; dy = 1; }
                else { dx = -1; dy = 1; }
                if (m >= mag[(y + dy) * w + x + dx] && m >= mag[(y - dy) * w + x - dx]) r[i] = m;
            }
        return r;
    }

    // Seuils automatiques (percentiles des maxima locaux) + propagation depuis les contours forts
    static bool[] Hysteresis(float[] nms, int w, int h, double detail, double smooth)
    {
        List<float> vals = new List<float>();
        float floor = (float)((120 - 90 * detail) * 1.4 / smooth);
        foreach (float v in nms) if (v > floor * 0.25f) vals.Add(v);   // ignore le bruit numérique des aplats (gradients ~0)
        bool[] edge = new bool[w * h];
        if (vals.Count == 0) return edge;
        vals.Sort();
        double keep = 0.03 + 0.25 * detail;                                   // part des maxima considérés "forts"
        float high = vals[Math.Min(vals.Count - 1, (int)(vals.Count * (1 - keep)))];
        high = Math.Max(floor, Math.Min(high, floor * 1.5f));   // le percentile ne peut pas écarter les contours moyens   // plancher absolu : ignore le bruit
        float low = high * 0.4f;

        Stack<int> st = new Stack<int>();
        for (int i = 0; i < nms.Length; i++) if (nms[i] >= high) { edge[i] = true; st.Push(i); }
        while (st.Count > 0)
        {
            int i = st.Pop(); int x = i % w, y = i / w;
            for (int dy = -1; dy <= 1; dy++)
                for (int dx = -1; dx <= 1; dx++)
                {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                    int j = ny * w + nx;
                    if (!edge[j] && nms[j] >= low) { edge[j] = true; st.Push(j); }
                }
        }
        return edge;
    }

    // Supprime les composantes connexes trop petites (poussière)
    static void RemoveSmall(bool[] edge, int w, int h, int minPixels, int minExtent)
    {
        bool[] seen = new bool[edge.Length];
        for (int s = 0; s < edge.Length; s++)
        {
            if (!edge[s] || seen[s]) continue;
            List<int> comp = new List<int>(); Stack<int> st = new Stack<int>();
            int minX = w, maxX = 0, minY = h, maxY = 0;
            st.Push(s); seen[s] = true;
            while (st.Count > 0)
            {
                int i = st.Pop(); comp.Add(i); int x = i % w, y = i / w;
                minX = Math.Min(minX, x); maxX = Math.Max(maxX, x); minY = Math.Min(minY, y); maxY = Math.Max(maxY, y);
                for (int dy = -1; dy <= 1; dy++)
                    for (int dx = -1; dx <= 1; dx++)
                    {
                        int nx = x + dx, ny = y + dy;
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        int j = ny * w + nx;
                        if (edge[j] && !seen[j]) { seen[j] = true; st.Push(j); }
                    }
            }
            if (comp.Count < minPixels || Math.Max(maxX - minX, maxY - minY) < minExtent) foreach (int i in comp) edge[i] = false;
        }
    }
}
'@

# Nom de classe unique par version du code : évite l'erreur "type déjà existant" si le script est relancé dans la même session
$hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($code))).Replace('-', '').Substring(0, 8)
$typeName = "AsciiEdge_$hash"
if (-not ("$typeName" -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $code.Replace('AsciiEdge', $typeName)
}

if ($Mask) {
    $source = New-Object Drawing.Bitmap (Resolve-Path $Path).Path
    $marks = New-Object Drawing.Bitmap (Resolve-Path $Mask).Path
    try {
        $lines = ("$typeName" -as [type])::Run($source, $Width, $Height, $Detail, $Smooth, $MinSize, [bool]$Invert, [bool]$Fill, $Chars, $Straight, $marks)
    } finally { $source.Dispose(); $marks.Dispose() }
} else {
    $lines = ("$typeName" -as [type])::Run((Resolve-Path $Path).Path, $Width, $Height, $Detail, $Smooth, $MinSize, [bool]$Invert, [bool]$Fill, $Chars, $Straight)
}
$lines
if ($Out) { $lines | Set-Content -Path $Out -Encoding UTF8 }

