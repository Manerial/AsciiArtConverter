# Usage : .\AsciiArtPreProcess.ps1 -Path photo.png [-Out photo_pre.png] [-MaxSize 800] [-White 250] [-Steps "L3,E2"]
# Prétraitement d'une image avant conversion ASCII : réduit l'image en "taches" de couleur homogènes.
#   1. redimensionnement (côté le plus long = MaxSize)
#   2. détection du fond : pixels quasi blancs (>= White) -> remis en blanc pur et jamais modifiés ni mélangés au sujet
#   3. liste d'étapes appliquées dans l'ordre donné, autant de fois que voulu :
#        L<n 2-12>      = réduction à n nuances de luminosité (k-means) en aplats de couleur sans taches
#        E<r 1-6>       = lissage des bords des aplats (filtre majoritaire de rayon r, sans flou) : supprime pointes et dentelures ; à placer après un L
# L'image obtenue se donne ensuite à .\AsciiArtConverter.ps1 -Path.
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Out,                                       # PNG de sortie (défaut : <nom>_pre.png à côté de l'image)
    [ValidateRange(100, 4000)][int]$MaxSize = 800,      # taille de travail (côté le plus long, en pixels) ; ne sur-échantillonne jamais
    [ValidateRange(200, 255)][int]$White = 250,         # seuil de "blanc pur" (R,G,B >= seuil) = fond non traité
    [string]$Steps = "L4"                             # étapes dans l'ordre, séparées par , ou ; (ex : "L3,E2")
)

$code = @'
using System;
using System.Drawing;
using System.Collections.Generic;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class PreProcessor
{
    public static Bitmap Run(string path, int maxSize, int white, string steps)
    {
        using (Bitmap src = new Bitmap(path))
            return Run(src, maxSize, white, steps);
    }

    public static Bitmap Run(Bitmap src, int maxSize, int white, string steps)
    {
        double scale = Math.Min(1.0, (double)maxSize / Math.Max(src.Width, src.Height));
        int w = Math.Max(1, (int)Math.Round(src.Width * scale)), h = Math.Max(1, (int)Math.Round(src.Height * scale));
        float[] rgb = Load(src, w, h);
        int n = w * h;

        bool[] bg = new bool[n];
        for (int i = 0; i < n; i++)
            if (Math.Min(rgb[i * 3], Math.Min(rgb[i * 3 + 1], rgb[i * 3 + 2])) >= white)
            {
                bg[i] = true; rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = 255f;
            }

        foreach (string raw in (steps ?? "").Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string s = raw.Trim(); if (s.Length < 2) continue;
            double v = double.Parse(s.Substring(1), System.Globalization.CultureInfo.InvariantCulture);
            char kind = char.ToUpperInvariant(s[0]);
            if (kind == 'L') Posterize(rgb, bg, w, h, Math.Min(12, Math.Max(2, (int)Math.Round(v))));
            else if (kind == 'E') Regularize(rgb, bg, w, h, Math.Min(6, Math.Max(1, (int)Math.Round(v))));
            else throw new ArgumentException("Étape inconnue : " + raw);
        }
        return ToBitmap(rgb, w, h);
    }

    static float[] Load(Bitmap src, int w, int h)
    {
        using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.White);   // transparence -> fond blanc
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(src, 0, 0, w, h);
            }
            float[] rgb = new float[w * h * 3];
            BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            byte[] bytes = new byte[data.Stride * h];
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            bmp.UnlockBits(data);
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    int p = y * data.Stride + x * 4, i = (y * w + x) * 3;
                    rgb[i] = bytes[p + 2]; rgb[i + 1] = bytes[p + 1]; rgb[i + 2] = bytes[p];
                }
            return rgb;
        }
    }

    static Bitmap ToBitmap(float[] rgb, int w, int h)
    {
        Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        byte[] bytes = new byte[data.Stride * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int p = y * data.Stride + x * 4, i = (y * w + x) * 3;
                bytes[p] = Clamp(rgb[i + 2]); bytes[p + 1] = Clamp(rgb[i + 1]); bytes[p + 2] = Clamp(rgb[i]); bytes[p + 3] = 255;
            }
        System.Runtime.InteropServices.Marshal.Copy(bytes, 0, data.Scan0, bytes.Length);
        bmp.UnlockBits(data);
        return bmp;
    }

    static byte Clamp(float v) { return (byte)Math.Max(0, Math.Min(255, (int)Math.Round(v))); }

    // Lissage des bords sans flou : chaque pixel du sujet prend la couleur la plus fréquente de son voisinage
    // (filtre modal). Les couleurs ne sont jamais mélangées, seules les frontières deviennent régulières.
    // Le fond blanc vote mais n'est jamais modifié ; une pointe de sujet entourée de fond redevient fond.
    static void Regularize(float[] rgb, bool[] bg, int w, int h, int radius)
    {
        int n = w * h;
        int[] key = new int[n];
        for (int i = 0; i < n; i++)
            key[i] = ((int)Math.Round(rgb[i * 3]) << 16) | ((int)Math.Round(rgb[i * 3 + 1]) << 8) | (int)Math.Round(rgb[i * 3 + 2]);
        int[] next = new int[n];
        for (int pass = 0; pass < 2; pass++)
        {
            int[] src = key, dst = next;
            System.Threading.Tasks.Parallel.For(0, h, y =>
            {
                int size = (2 * radius + 1) * (2 * radius + 1);
                int[] ks = new int[size], cs = new int[size];
                for (int x = 0; x < w; x++)
                {
                    int i = y * w + x;
                    if (bg[i]) { dst[i] = src[i]; continue; }
                    int m = 0;
                    for (int dy = -radius; dy <= radius; dy++)
                    {
                        int yy = y + dy; if (yy < 0 || yy >= h) continue;
                        for (int dx = -radius; dx <= radius; dx++)
                        {
                            int xx = x + dx; if (xx < 0 || xx >= w) continue;
                            int k = src[yy * w + xx], q = 0;
                            while (q < m && ks[q] != k) q++;
                            if (q == m) { ks[m] = k; cs[m] = 0; m++; }
                            cs[q]++;
                        }
                    }
                    int best = src[i], bc = 0;
                    for (int q = 0; q < m; q++) if (ks[q] == src[i]) { bc = cs[q]; break; }
                    for (int q = 0; q < m; q++) if (cs[q] > bc) { bc = cs[q]; best = ks[q]; }   // égalité : on garde la couleur actuelle
                    dst[i] = best;
                }
            });
            key = dst; next = src;
        }
        for (int i = 0; i < n; i++)
        {
            if (bg[i]) continue;
            int k = key[i];
            rgb[i * 3] = (k >> 16) & 255; rgb[i * 3 + 1] = (k >> 8) & 255; rgb[i * 3 + 2] = k & 255;
            if (k == 0xFFFFFF) bg[i] = true;
        }
    }
    // Regroupe les luminosités du sujet en N paliers (k-means 1D sur l'histogramme) ; puis chaque zone connexe devient un aplat (taches isolées lissées)
    static void Posterize(float[] rgb, bool[] bg, int w, int h, int levels)
    {
        int n = bg.Length;
        float[] lum = new float[n];
        double[] hist = new double[256]; int lo = 255, hi = 0;
        for (int i = 0; i < n; i++)
        {
            lum[i] = 0.299f * rgb[i * 3] + 0.587f * rgb[i * 3 + 1] + 0.114f * rgb[i * 3 + 2];
            if (bg[i]) continue;
            int v = (int)Math.Min(255, Math.Max(0, lum[i])); hist[v]++; lo = Math.Min(lo, v); hi = Math.Max(hi, v);
        }
        if (hi <= lo) return;
        double[] c = new double[levels];
        for (int k = 0; k < levels; k++) c[k] = lo + (hi - lo) * (k + 0.5) / levels;
        for (int it = 0; it < 20; it++)
        {
            double[] s = new double[levels], cnt = new double[levels];
            for (int v = lo; v <= hi; v++)
            {
                if (hist[v] == 0) continue;
                int b = 0; for (int k = 1; k < levels; k++) if (Math.Abs(v - c[k]) < Math.Abs(v - c[b])) b = k;
                s[b] += v * hist[v]; cnt[b] += hist[v];
            }
            for (int k = 0; k < levels; k++) if (cnt[k] > 0) c[k] = s[k] / cnt[k];
        }
        int[] lab = new int[n];
        for (int i = 0; i < n; i++)
        {
            if (bg[i]) { lab[i] = -1; continue; }
            int b = 0; for (int k = 1; k < levels; k++) if (Math.Abs(lum[i] - c[k]) < Math.Abs(lum[i] - c[b])) b = k;
            lab[i] = b;
        }

        // Filtre majoritaire : supprime les pixels isolés qui basculent d'un palier à l'autre (taches)
        int[] cnt2 = new int[levels];
        for (int pass = 0; pass < 3; pass++)
        {
            int[] nl = (int[])lab.Clone();
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    int i = y * w + x; if (lab[i] < 0) continue;
                    Array.Clear(cnt2, 0, levels);
                    for (int dy = -2; dy <= 2; dy++)
                    {
                        int yy = y + dy; if (yy < 0 || yy >= h) continue;
                        for (int dx = -2; dx <= 2; dx++)
                        {
                            int xx = x + dx; if (xx < 0 || xx >= w) continue;
                            int l = lab[yy * w + xx]; if (l >= 0) cnt2[l]++;
                        }
                    }
                    int best = lab[i]; for (int k = 0; k < levels; k++) if (cnt2[k] > cnt2[best]) best = k;
                    nl[i] = best;
                }
            lab = nl;
        }

        // Chaque zone connexe de même palier devient un aplat : couleur moyenne de la zone (plus de dégradé)
        bool[] seen = new bool[n];
        Stack<int> st = new Stack<int>(); List<int> comp = new List<int>();
        for (int s = 0; s < n; s++)
        {
            if (lab[s] < 0 || seen[s]) continue;
            comp.Clear(); st.Push(s); seen[s] = true; double sr = 0, sg = 0, sb = 0;
            while (st.Count > 0)
            {
                int i = st.Pop(); comp.Add(i); sr += rgb[i * 3]; sg += rgb[i * 3 + 1]; sb += rgb[i * 3 + 2];
                int x = i % w, y = i / w;
                if (x > 0 && !seen[i - 1] && lab[i - 1] == lab[s]) { seen[i - 1] = true; st.Push(i - 1); }
                if (x < w - 1 && !seen[i + 1] && lab[i + 1] == lab[s]) { seen[i + 1] = true; st.Push(i + 1); }
                if (y > 0 && !seen[i - w] && lab[i - w] == lab[s]) { seen[i - w] = true; st.Push(i - w); }
                if (y < h - 1 && !seen[i + w] && lab[i + w] == lab[s]) { seen[i + w] = true; st.Push(i + w); }
            }
            float mr = (float)(sr / comp.Count), mg = (float)(sg / comp.Count), mb = (float)(sb / comp.Count);
            foreach (int i in comp) { rgb[i * 3] = mr; rgb[i * 3 + 1] = mg; rgb[i * 3 + 2] = mb; }
        }
    }
}
'@

# Nom de classe unique par version du code : évite l'erreur "type déjà existant" si le script est relancé dans la même session
$hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($code))).Replace('-', '').Substring(0, 8)
$typeName = "PreProcessor_$hash"
if (-not ("$typeName" -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $code.Replace('PreProcessor', $typeName)
}

$in = (Resolve-Path $Path).Path
if ($Out -and -not [IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }
if (-not $Out) { $Out = Join-Path (Split-Path $in) ([IO.Path]::GetFileNameWithoutExtension($in) + '_pre.png') }
$bmp = ("$typeName" -as [type])::Run($in, $MaxSize, $White, $Steps)
try { $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
Write-Output $Out
