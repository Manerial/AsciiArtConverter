# Moteur (bibliothèque) : étape M<i> = retouches, i = indice du masque fourni au prétraitement. Chargé via Import-AsciiEngine.
# Masque de taille quelconque (codec AsciiRasterMask : rouge = gomme, vert = exclusion), ramené à la taille de travail.
#   gomme     : pixel remis en blanc pur et ajouté au fond (Background + Erased) -> les bords de la gomme sont de vrais contours
#   exclusion : pixel marqué Excluded, couleur intacte (aucun blanchiment donc aucun contour de découpe) ; les étapes
#               suivantes l'ignorent totalement et le convertisseur n'y place aucun caractère (vert du masque combiné)
# Effets cumulatifs et définitifs : une étape M n'annule jamais les marques des étapes précédentes (la restauration
# de l'éditeur ne retire que les marques de son propre masque). Le masque n'est pas libéré par l'étape (propriété de l'appelant).
$code = @'
// @requires AsciiArtRaster.ps1
// @requires plugin\Gomme\AsciiArtEraser.ps1
// @requires plugin\Masque\AsciiArtExclusion.ps1
using System;
using System.Drawing;

public sealed class AsciiRetouch : IAsciiMaskStep
{
    readonly Bitmap mask;
    readonly int index;

    public AsciiRetouch(Bitmap mask, int index)
    {
        if (mask == null) throw new ArgumentNullException("mask", "Masque M" + index + " absent");
        this.mask = mask; this.index = index;
    }

    public int Index { get { return index; } }
    public Bitmap Mask { get { return mask; } }
    public char Channel { get { return 'M'; } }
    public string Code { get { return "M" + index; } }

    public void Apply(AsciiRaster raster) { Run(raster, mask); }

    public static void Run(AsciiRaster raster, Bitmap mask)
    {
        if (raster == null) throw new ArgumentNullException("raster");
        bool[] erase, exclude;
        AsciiRasterMask.Decode(mask, raster.Width, raster.Height, out erase, out exclude);
        AsciiEraser.Run(raster, erase);
        AsciiExclusion.Run(raster, exclude);
    }
}
'@