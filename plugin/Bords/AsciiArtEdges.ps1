# Moteur du plugin Bords : étape E<r 1-6>. Chargé via Import-AsciiEngine à la racine.
# Filtre modal (2 passes) : chaque pixel du sujet prend la couleur la plus fréquente de son voisinage de rayon r ;
# les couleurs ne sont jamais mélangées, seules les frontières deviennent régulières. À placer après un L.
# Fond (Background) : vote "blanc" mais n'est jamais modifié ; un pixel du sujet devenu blanc pur rejoint le fond.
# Pixels exclus (Excluded) : ne votent pas et ne sont jamais modifiés (couleur d'origine conservée).
$code = @'
// @requires AsciiArtRaster.ps1
using System;
using System.Threading.Tasks;

public sealed class AsciiEdges : IAsciiStep
{
    readonly int radius;

    public AsciiEdges(int radius) { this.radius = Math.Min(6, Math.Max(1, radius)); }

    public int Radius { get { return radius; } }
    public string Code { get { return "E" + radius; } }

    public void Apply(AsciiRaster raster) { Run(raster, radius); }

    public static void Run(AsciiRaster raster, int radius)
    {
        if (raster == null) throw new ArgumentNullException("raster");
        radius = Math.Min(6, Math.Max(1, radius));
        float[] rgb = raster.Rgb;
        bool[] bg = raster.Background, ex = raster.Excluded;
        int w = raster.Width, h = raster.Height, n = raster.Count;

        int[] key = new int[n];
        for (int i = 0; i < n; i++)
            key[i] = ((int)Math.Round(rgb[i * 3]) << 16) | ((int)Math.Round(rgb[i * 3 + 1]) << 8) | (int)Math.Round(rgb[i * 3 + 2]);
        int[] next = new int[n];
        for (int pass = 0; pass < 2; pass++)
        {
            int[] src = key, dst = next;
            Parallel.For(0, h, y =>
            {
                int size = (2 * radius + 1) * (2 * radius + 1);
                int[] ks = new int[size], cs = new int[size];
                for (int x = 0; x < w; x++)
                {
                    int i = y * w + x;
                    if (bg[i] || ex[i]) { dst[i] = src[i]; continue; }
                    int m = 0;
                    for (int dy = -radius; dy <= radius; dy++)
                    {
                        int yy = y + dy; if (yy < 0 || yy >= h) continue;
                        for (int dx = -radius; dx <= radius; dx++)
                        {
                            int xx = x + dx; if (xx < 0 || xx >= w) continue;
                            int j = yy * w + xx; if (ex[j]) continue;
                            int k = src[j], q = 0;
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
            if (bg[i] || ex[i]) continue;
            int k = key[i];
            rgb[i * 3] = (k >> 16) & 255; rgb[i * 3 + 1] = (k >> 8) & 255; rgb[i * 3 + 2] = k & 255;
            if (k == 0xFFFFFF) bg[i] = true;
        }
    }
}
'@