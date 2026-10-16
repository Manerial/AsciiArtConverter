# Moteur du plugin Masque : exclut les pixels sans modifier leurs couleurs.
$code = @'
// @requires AsciiArtRaster.ps1
using System;

public static class AsciiExclusion
{
    public static void Run(AsciiRaster raster, bool[] selection)
    {
        if (raster == null) throw new ArgumentNullException("raster");
        if (selection == null) throw new ArgumentNullException("selection");
        if (selection.Length != raster.Count) throw new ArgumentException("Taille de selection incompatible", "selection");
        for (int i = 0; i < raster.Count; i++)
            if (selection[i]) raster.Excluded[i] = true;
    }
}

public sealed class AsciiExclusionStep : IAsciiMaskStep
{
    readonly Bitmap mask;
    readonly int index;

    public AsciiExclusionStep(Bitmap mask, int index)
    {
        if (mask == null) throw new ArgumentNullException("mask", "Masque X" + index + " absent");
        this.mask = mask; this.index = index;
    }

    public int Index { get { return index; } }
    public Bitmap Mask { get { return mask; } }
    public char Channel { get { return 'X'; } }
    public string Code { get { return "X" + index; } }

    public void Apply(AsciiRaster raster)
    {
        if (raster == null) throw new ArgumentNullException("raster");
        bool[] erase, exclude;
        AsciiRasterMask.Decode(mask, raster.Width, raster.Height, out erase, out exclude);
        AsciiExclusion.Run(raster, exclude);
    }
}
'@
