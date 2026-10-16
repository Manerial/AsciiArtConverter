# Moteur du plugin SeuilBlanc : W<200-255>, détection cumulative du fond à cette étape.
$code = @'
// @requires AsciiArtRaster.ps1
using System;

public sealed class AsciiWhite : IAsciiStep
{
    readonly int white;
    public AsciiWhite(int white) { this.white = white; }
    public int White { get { return white; } }
    public string Code { get { return "W" + white; } }
    public void Apply(AsciiRaster raster) { Run(raster, white); }

    public static void Run(AsciiRaster raster, int white)
    {
        if (raster == null) throw new ArgumentNullException("raster");
        float[] rgb = raster.Rgb;
        for (int i = 0; i < raster.Count; i++)
        {
            if (raster.Excluded[i]) continue;
            if (raster.Background[i] || raster.Erased[i]
                || Math.Min(rgb[i * 3], Math.Min(rgb[i * 3 + 1], rgb[i * 3 + 2])) >= white)
            {
                raster.Background[i] = true;
                rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = 255f;
            }
        }
    }
}
'@
