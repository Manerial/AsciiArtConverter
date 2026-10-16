# Moteur du plugin Gomme : blanchit les pixels et les marque comme fond.
$code = @'
// @requires AsciiArtRaster.ps1
using System;

public static class AsciiEraser
{
    public static void Run(AsciiRaster raster, bool[] selection)
    {
        if (raster == null) throw new ArgumentNullException("raster");
        if (selection == null) throw new ArgumentNullException("selection");
        if (selection.Length != raster.Count) throw new ArgumentException("Taille de selection incompatible", "selection");
        for (int i = 0; i < raster.Count; i++)
        {
            if (!selection[i]) continue;
            raster.Rgb[i * 3] = raster.Rgb[i * 3 + 1] = raster.Rgb[i * 3 + 2] = 255f;
            raster.Background[i] = true;
            raster.Erased[i] = true;
        }
    }
}

public sealed class AsciiEraserStep : IAsciiMaskStep
{
    readonly Bitmap mask;
    readonly int index;

    public AsciiEraserStep(Bitmap mask, int index)
    {
        if (mask == null) throw new ArgumentNullException("mask", "Masque G" + index + " absent");
        this.mask = mask; this.index = index;
    }

    public int Index { get { return index; } }
    public Bitmap Mask { get { return mask; } }
    public char Channel { get { return 'G'; } }
    public string Code { get { return "G" + index; } }

    public void Apply(AsciiRaster raster)
    {
        if (raster == null) throw new ArgumentNullException("raster");
        bool[] erase, exclude;
        AsciiRasterMask.Decode(mask, raster.Width, raster.Height, out erase, out exclude);
        AsciiEraser.Run(raster, erase);
    }
}
'@
