# Moteur du plugin Aplats : étape L<n 2-12>. Chargé via Import-AsciiEngine à la racine.
# Regroupe les luminosités du sujet en n paliers (k-means 1D sur l'histogramme), supprime les taches isolées
# (filtre majoritaire 5x5), puis chaque zone connexe de même palier devient un aplat de sa couleur moyenne.
# Fond (Background) et pixels exclus (Excluded) ne participent à rien (histogramme, votes, zones, moyennes)
# et ne sont jamais modifiés : un pixel exclu garde sa couleur, une zone ne se propage pas à travers lui.
$code = @'
// @requires AsciiArtRaster.ps1
using System;
using System.Collections.Generic;

public sealed class AsciiPosterize : IAsciiStep
{
    readonly int levels;

    public AsciiPosterize(int levels) { this.levels = Math.Min(12, Math.Max(2, levels)); }

    public int Levels { get { return levels; } }
    public string Code { get { return "L" + levels; } }

    public void Apply(AsciiRaster raster) { Run(raster, levels); }

    public static void Run(AsciiRaster raster, int levels)
    {
        if (raster == null) throw new ArgumentNullException("raster");
        levels = Math.Min(12, Math.Max(2, levels));
        float[] rgb = raster.Rgb;
        bool[] bg = raster.Background, ex = raster.Excluded;
        int w = raster.Width, h = raster.Height, n = raster.Count;

        float[] lum = new float[n];
        double[] hist = new double[256]; int lo = 255, hi = 0;
        for (int i = 0; i < n; i++)
        {
            lum[i] = 0.299f * rgb[i * 3] + 0.587f * rgb[i * 3 + 1] + 0.114f * rgb[i * 3 + 2];
            if (bg[i] || ex[i]) continue;
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
        // -1 = hors calcul (fond ou exclu) : ne vote pas, n'est pas relabellisé, coupe les zones connexes
        int[] lab = new int[n];
        for (int i = 0; i < n; i++)
        {
            if (bg[i] || ex[i]) { lab[i] = -1; continue; }
            int b = 0; for (int k = 1; k < levels; k++) if (Math.Abs(lum[i] - c[k]) < Math.Abs(lum[i] - c[b])) b = k;
            lab[i] = b;
        }

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