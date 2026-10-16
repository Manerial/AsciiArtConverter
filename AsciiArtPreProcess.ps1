# Usage : .\AsciiArtPreProcess.ps1 -Path photo.png [-Out photo_pre.png] [-MaxSize 800] [-White 250] [-Steps "L3,E2"]
# Pipeline explicite : .\AsciiArtPreProcess.ps1 -Path photo.png -Pipeline -Steps "S800,W250,L4"
# Avec -Pipeline : source brute (transparence sur blanc), aucune préparation implicite ; S et W sont réordonnables,
# répétables et supprimables comme L/E/G/X/M. Sans -Pipeline : -MaxSize/-White restent la préparation historique.
# -Pipeline ignore -MaxSize/-White. Sans S : dimensions d'origine ; sans W : aucun fond détecté automatiquement.
# S conserve les couches de fond/gomme/exclusion par empreinte ; la gomme reste blanche et une exclusion garde
# la couleur d'un pixel exclu de son empreinte (gomme prioritaire en cas de recouvrement).
# W est cumulatif : remonter le seuil plus tard ne restaure pas un fond déjà blanchi.
# Transparence : le mode explicite l'aplatit au chargement, le mode historique pendant le redimensionnement ;
# le rééchantillonnage de pixels semi-transparents peut donc différer entre ces deux modes.
#         .\AsciiArtPreProcess.ps1 -Path photo.png -Pipeline -Steps "G0,L4,X1" -Masks gomme.png,masque.png [-MaskOut photo_pre_mask.png]
# Prétraitement d'une image avant conversion ASCII : réduit l'image en "taches" de couleur homogènes.
#   1. redimensionnement (côté le plus long = MaxSize)
#   2. détection du fond : pixels quasi blancs (>= White) -> remis en blanc pur et jamais modifiés ni mélangés au sujet
#   3. liste d'étapes appliquées dans l'ordre donné, autant de fois que voulu (séparées par , ou ;) :
#        S<n 100-4000> = taille maximale à cette étape, jamais d'agrandissement (plugin\Taille)
#        W<n 200-255>  = pixels R,V,B >= n : fond blanc, hors pixels exclus (plugin\SeuilBlanc)
#        L<n 2-12>  = réduction à n nuances de luminosité (k-means) en aplats de couleur sans taches   (plugin\Aplats\AsciiArtPosterize.ps1)
#        E<r 1-6>   = lissage des bords des aplats (filtre majoritaire de rayon r, sans flou) ; après un L (plugin\Bords\AsciiArtEdges.ps1)
#        G<i>       = gomme avec le canal rouge du masque -Masks[i] (plugin\Gomme) ; seul ce canal est lu
#        X<i>       = exclusion avec le canal vert du masque -Masks[i] (plugin\Masque) ; seul ce canal est lu
#        M<i>       = retouche historique combinant gomme rouge et exclusion verte (compatibilité CLI)
#                     gomme : pixels remis en fond blanc (vrais contours) ; exclusion : pixels figés, couleur conservée,
#                     ignorés par toutes les étapes suivantes (histogramme, aplats, votes) et par le convertisseur ASCII.
#                     Les marques se cumulent : une étape de masque n'annule jamais celles des étapes précédentes.
# Sortie : l'image (1re ligne). Si une étape G, X ou M est présente, le masque combiné (rouge = gomme, vert = exclusion cumulées,
# à la taille de l'image) est aussi écrit et son chemin sort en 2e ligne : le donner à .\AsciiArtConverter.ps1 -Mask.
# En mode historique sans étape G/X/M, le résultat est identique à l'ancienne version (même -Steps "L3,E2").
#
# Contrat d'intégration (C#, chargé par Import-AsciiEngine -File AsciiArtPreProcess.ps1 -Class PreProcessor, cf. AsciiArtPluginCompilator.ps1) :
#   Bitmap           PreProcessor.Run(string path, int maxSize, int white, string steps)                  (compatibilité)
#   PreProcessResult PreProcessor.Run(string path, int maxSize, int white, string steps, Bitmap[] masks)
#   (mêmes surcharges avec Bitmap src au lieu de path)
#   Bitmap RunPipeline(string path, string steps) / RunPipeline(Bitmap src, string steps)
#   PreProcessResult RunPipeline(string path, string steps, Bitmap[] masks) (idem Bitmap src).
#   Ces API partent de la source brute. Ex. "S800,W250,L4" ; les previews suivent les dimensions de chaque étape.
#   G<i>/X<i>/M<i> lisent masks[i] (taille quelconque, ramené à la taille de travail) ; G ne lit que rouge, X que vert,
#   M conserve l'ancien comportement combiné ; les masques restent à l'appelant (non libérés).
#   PreProcessResult : IDisposable -> Image, Mask (rouge/vert combinés), Previews[k] = image AVANT l'étape k,
#   Steps[k] = code normalisé de l'étape k ("S800", "W250", "L4", "E2", "G0", "X1", "M0"), Width, Height, HasMarks.
#   Dispose libère toutes les images.
#   PreProcessCache (même espace de noms) : IDisposable, usage sérialisé, Run(path, sourceKey, maxSize, white, steps, masks).
#   Surcharge explicite : Run(path, sourceKey, steps, masks), base brute ; changer S/W ne recharge pas la source.
#   L'ancienne surcharge conserve ses compteurs/préviews limités aux étapes explicites (préparation implicite hors compte).
#   sourceKey doit changer à chaque réouverture/modification du fichier (génération GUI, ou métadonnées côté appelant).
#   Les résultats restent indépendants du cache et doivent être libérés. ReusedSteps/ProcessedSteps/BaseReloaded décrivent
#   le dernier Run réussi ; SourceLoads compte les chargements réussis. Dispose ne libère pas les résultats retournés.
#   Mémoire : un raster complet (RGB float + fond/exclusion/gomme) par frontière d'étape, uniquement la chaîne courante ;
#   le suffixe précédent reste vivant pendant un calcul pour permettre un échec sans altérer le cache.
#   Codecs/signatures PNG : AsciiRasterMask (AsciiArtRaster.ps1). Le pipeline ne dépend pas de l'éditeur AsciiBrush.
#   Le pipeline explicite conserve une base à la résolution d'origine : placer S tôt limite la mémoire de la suite.
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Out,                                       # PNG de sortie (défaut : <nom>_pre.png à côté de l'image)
    [ValidateRange(100, 4000)][int]$MaxSize = 800,      # taille de travail (côté le plus long, en pixels) ; ne sur-échantillonne jamais
    [ValidateRange(200, 255)][int]$White = 250,         # seuil de "blanc pur" (R,G,B >= seuil) = fond non traité
    [string]$Steps = "L4",                              # étapes dans l'ordre, séparées par , ou ; (ex : "L3,E2" ou "M0,L4,E2")
    [string[]]$Masks,                                   # PNG de masque référencés par G0, X1... (dans cet ordre)
    [string]$MaskOut,                                   # masque combiné (défaut : <sortie>_mask.png), écrit si G, X ou M est présent
    [Alias('RawPipeline')][switch]$Pipeline             # désactive la préparation implicite ; utiliser S800,W250 dans -Steps
)

$code = @'
// @requires AsciiArtRaster.ps1
// @requires plugin\Taille\AsciiArtSize.ps1
// @requires plugin\SeuilBlanc\AsciiArtWhite.ps1
// @requires plugin\Aplats\AsciiArtPosterize.ps1
// @requires plugin\Bords\AsciiArtEdges.ps1
// @requires AsciiArtRetouch.ps1
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Security.Cryptography;

public sealed class PreProcessResult : IDisposable
{
    Bitmap image, mask;
    Bitmap[] previews;
    readonly string[] steps;
    readonly int width, height;
    readonly bool hasMarks;

    internal PreProcessResult(Bitmap image, Bitmap mask, Bitmap[] previews, string[] steps, bool hasMarks)
    {
        this.image = image; this.mask = mask; this.previews = previews; this.steps = steps; this.hasMarks = hasMarks;
        width = image.Width; height = image.Height;
    }

    // Après Dispose : Image et Mask valent null, Previews est vide.
    public Bitmap Image { get { return image; } }
    public Bitmap Mask { get { return mask; } }
    public Bitmap[] Previews { get { return previews; } }
    public string[] Steps { get { return (string[])steps.Clone(); } }
    public int Width { get { return width; } }
    public int Height { get { return height; } }
    public bool HasMarks { get { return hasMarks; } }
    public bool IsDisposed { get { return image == null; } }

    public void Dispose()
    {
        if (image != null) { image.Dispose(); image = null; }
        if (mask != null) { mask.Dispose(); mask = null; }
        if (previews != null) foreach (Bitmap b in previews) if (b != null) b.Dispose();
        previews = new Bitmap[0];
    }
}

public sealed class PreProcessCache : IDisposable
{
    AsciiRaster[] snapshots = new AsciiRaster[0];
    string[] signatures = new string[0];
    string sourcePath, sourceKey;
    int maxSize, white;
    bool legacy;
    bool disposed;

    public int ReusedSteps { get; private set; }
    public int ProcessedSteps { get; private set; }
    public bool BaseReloaded { get; private set; }
    public int SourceLoads { get; private set; }

    public PreProcessResult Run(string path, string sourceKey, int maxSize, int white, string steps, Bitmap[] masks)
    {
        if (maxSize < 1) throw new ArgumentOutOfRangeException("maxSize");
        return RunCore(path, sourceKey, maxSize, white, steps, masks, true);
    }

    public PreProcessResult Run(string path, string sourceKey, string steps, Bitmap[] masks)
    {
        return RunCore(path, sourceKey, 0, 0, steps, masks, false);
    }

    PreProcessResult RunCore(string path, string sourceKey, int maxSize, int white, string steps, Bitmap[] masks, bool legacy)
    {
        if (disposed) throw new ObjectDisposedException("PreProcessCache");
        if (sourceKey == null) throw new ArgumentNullException("sourceKey");
        string fullPath = System.IO.Path.GetFullPath(path);
        IAsciiStep[] list = PreProcessor.Parse(steps, masks);
        string[] nextSignatures = new string[list.Length];
        string[] codes = new string[list.Length];
        for (int k = 0; k < list.Length; k++)
        {
            codes[k] = list[k].Code;
            IAsciiMaskStep maskStep = list[k] as IAsciiMaskStep;
            nextSignatures[k] = codes[k] + (maskStep == null ? "" : ":" + MaskSignature(maskStep.Mask, maskStep.Channel));
        }
        bool reload = snapshots.Length == 0 || !String.Equals(sourcePath, fullPath, StringComparison.OrdinalIgnoreCase)
            || this.sourceKey != sourceKey || this.maxSize != maxSize || this.white != white || this.legacy != legacy;
        int prefix = 0;
        if (!reload)
            while (prefix < signatures.Length && prefix < nextSignatures.Length && signatures[prefix] == nextSignatures[prefix])
                prefix++;

        AsciiRaster[] next = new AsciiRaster[list.Length + 1];
        if (reload)
        {
            using (Bitmap src = new Bitmap(fullPath))
                next[0] = legacy ? PreProcessor.LoadLegacy(src, maxSize, white) : AsciiRaster.Load(src);
        }
        else Array.Copy(snapshots, next, prefix + 1);
        for (int k = prefix; k < list.Length; k++)
        {
            // Never apply a mutable step to a retained boundary (including the new base).
            AsciiRaster raster = next[k].Clone();
            list[k].Apply(raster);
            next[k + 1] = raster;
        }

        List<Bitmap> owned = new List<Bitmap>();
        try
        {
            for (int k = 0; k < list.Length; k++) owned.Add(next[k].ToBitmap());
            Bitmap[] previews = owned.ToArray();
            AsciiRaster final = next[list.Length];
            Bitmap image = final.ToBitmap(); owned.Add(image);
            Bitmap mask = AsciiRasterMask.Compose(final.Erased, final.Excluded, final.Width, final.Height); owned.Add(mask);
            bool marks = Array.IndexOf(final.Erased, true) >= 0 || Array.IndexOf(final.Excluded, true) >= 0;
            PreProcessResult result = new PreProcessResult(image, mask, previews, codes, marks);
            // Commit only after every step and output allocation succeeded. Drop the old suffix.
            snapshots = next; signatures = nextSignatures;
            sourcePath = fullPath; this.sourceKey = sourceKey; this.maxSize = maxSize; this.white = white;
            this.legacy = legacy;
            ReusedSteps = prefix; ProcessedSteps = list.Length - prefix; BaseReloaded = reload;
            if (reload) SourceLoads++;
            return result;
        }
        catch
        {
            foreach (Bitmap bitmap in owned) bitmap.Dispose();
            throw;
        }
    }

    static string MaskSignature(Bitmap mask, char channel)
    {
        // Hash decoded channels and dimensions, not PNG encoding, unused colors, or stride padding.
        bool[] erase, exclude;
        AsciiRasterMask.Decode(mask, mask.Width, mask.Height, out erase, out exclude);
        using (SHA256 hash = SHA256.Create())
        {
            byte[] size = new byte[8];
            Array.Copy(BitConverter.GetBytes(mask.Width), 0, size, 0, 4);
            Array.Copy(BitConverter.GetBytes(mask.Height), 0, size, 4, 4);
            hash.TransformBlock(size, 0, size.Length, size, 0);
            byte[] channels = new byte[erase.Length];
            for (int p = 0; p < channels.Length; p++)
            {
                channels[p] = channel == 'G' ? (byte)(erase[p] ? 1 : 0)
                    : channel == 'X' ? (byte)(exclude[p] ? 1 : 0)
                    : (byte)((erase[p] ? 1 : 0) | (exclude[p] ? 2 : 0));
            }
            hash.TransformFinalBlock(channels, 0, channels.Length);
            return Convert.ToBase64String(hash.Hash);
        }
    }

    public void Dispose()
    {
        snapshots = new AsciiRaster[0]; signatures = new string[0];
        sourcePath = sourceKey = null; disposed = true;
    }
}

public static class PreProcessor
{
    public static Bitmap Run(string path, int maxSize, int white, string steps)
    {
        using (Bitmap src = new Bitmap(path))
            return Run(src, maxSize, white, steps);
    }

    public static Bitmap Run(Bitmap src, int maxSize, int white, string steps)
    {
        IAsciiStep[] list = Parse(steps, null);
        return Process(src, maxSize, white, list, null).ToBitmap();
    }

    public static PreProcessResult Run(string path, int maxSize, int white, string steps, Bitmap[] masks)
    {
        using (Bitmap src = new Bitmap(path))
            return Run(src, maxSize, white, steps, masks);
    }

    public static PreProcessResult Run(Bitmap src, int maxSize, int white, string steps, Bitmap[] masks)
    {
        IAsciiStep[] list = Parse(steps, masks);
        return CreateResult(LoadLegacy(src, maxSize, white), list);
    }

    public static Bitmap RunPipeline(string path, string steps)
    {
        using (Bitmap src = new Bitmap(path)) return RunPipeline(src, steps);
    }

    public static Bitmap RunPipeline(Bitmap src, string steps)
    {
        IAsciiStep[] list = Parse(steps, null);
        return Process(AsciiRaster.Load(src), list, null).ToBitmap();
    }

    public static PreProcessResult RunPipeline(string path, string steps, Bitmap[] masks)
    {
        using (Bitmap src = new Bitmap(path)) return RunPipeline(src, steps, masks);
    }

    public static PreProcessResult RunPipeline(Bitmap src, string steps, Bitmap[] masks)
    {
        IAsciiStep[] list = Parse(steps, masks);
        return CreateResult(AsciiRaster.Load(src), list);
    }

    static PreProcessResult CreateResult(AsciiRaster source, IAsciiStep[] list)
    {
        List<Bitmap> owned = new List<Bitmap>();
        try
        {
            AsciiRaster raster = Process(source, list, owned);
            Bitmap[] previews = owned.ToArray();
            Bitmap image = raster.ToBitmap(); owned.Add(image);
            Bitmap mask = AsciiRasterMask.Compose(raster.Erased, raster.Excluded, raster.Width, raster.Height); owned.Add(mask);
            bool marks = Array.IndexOf(raster.Erased, true) >= 0 || Array.IndexOf(raster.Excluded, true) >= 0;
            string[] codes = new string[list.Length];
            for (int k = 0; k < list.Length; k++) codes[k] = list[k].Code;
            return new PreProcessResult(image, mask, previews, codes, marks);
        }
        catch
        {
            foreach (Bitmap b in owned) b.Dispose();
            throw;
        }
    }

    // Analyse et valide toute la liste avant le moindre calcul. Les éléments de moins de 2 caractères sont ignorés.
    public static IAsciiStep[] Parse(string steps, Bitmap[] masks)
    {
        List<IAsciiStep> list = new List<IAsciiStep>();
        foreach (string raw in (steps ?? "").Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string s = raw.Trim(); if (s.Length < 2) continue;
            char kind = char.ToUpperInvariant(s[0]);
            string arg = s.Substring(1).Trim();
            if (kind == 'M' || kind == 'G' || kind == 'X')
            {
                int index;
                if (!int.TryParse(arg, NumberStyles.None, CultureInfo.InvariantCulture, out index))
                    throw new ArgumentException("Étape de masque invalide : " + raw + " (attendu G, X ou M suivi de l'indice, ex. G0)");
                int count = masks == null ? 0 : masks.Length;
                if (index >= count)
                    throw new ArgumentException("Étape " + s + " : masque n°" + index + " non fourni (" + count + " masque(s) reçu(s))");
                if (masks[index] == null) throw new ArgumentNullException("masks", "Étape " + s + " : masque n°" + index + " nul");
                list.Add(kind == 'G' ? (IAsciiStep)new AsciiEraserStep(masks[index], index)
                    : kind == 'X' ? (IAsciiStep)new AsciiExclusionStep(masks[index], index)
                    : new AsciiRetouch(masks[index], index));
                continue;
            }
            if (kind != 'L' && kind != 'E' && kind != 'S' && kind != 'W') throw new ArgumentException("Étape inconnue : " + raw);
            double v;
            if (!double.TryParse(arg, NumberStyles.Float | NumberStyles.AllowThousands, CultureInfo.InvariantCulture, out v) || double.IsNaN(v) || double.IsInfinity(v))
                throw new ArgumentException("Valeur d'étape invalide : " + raw);
            if (kind == 'L') list.Add(new AsciiPosterize((int)Math.Round(v)));
            else if (kind == 'E') list.Add(new AsciiEdges((int)Math.Round(v)));
            else if (kind == 'S') list.Add(new AsciiSize((int)Math.Round(Math.Min(4000, Math.Max(100, v)))));
            else list.Add(new AsciiWhite((int)Math.Round(Math.Min(255, Math.Max(200, v)))));
        }
        return list.ToArray();
    }

    // previews != null : y ajoute l'image AVANT chaque étape (Previews[k] <-> étape k).
    static AsciiRaster Process(Bitmap src, int maxSize, int white, IAsciiStep[] steps, List<Bitmap> previews)
    {
        return Process(LoadLegacy(src, maxSize, white), steps, previews);
    }

    internal static AsciiRaster LoadLegacy(Bitmap src, int maxSize, int white)
    {
        AsciiRaster raster = AsciiSize.Load(src, maxSize);
        AsciiWhite.Run(raster, white);
        return raster;
    }

    static AsciiRaster Process(AsciiRaster raster, IAsciiStep[] steps, List<Bitmap> previews)
    {
        foreach (IAsciiStep step in steps)
        {
            if (previews != null) previews.Add(raster.ToBitmap());
            step.Apply(raster);
        }
        return raster;
    }
}
'@

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AsciiArtPluginCompilator.ps1')
$typeName = Import-AsciiEngine -File 'AsciiArtPreProcess.ps1' -Class 'PreProcessor'
$engine = $typeName -as [type]

$in = (Resolve-Path $Path).Path
if ($Out -and -not [IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }
if (-not $Out) { $Out = Join-Path (Split-Path $in) ([IO.Path]::GetFileNameWithoutExtension($in) + '_pre.png') }
$hasMaskStep = @(($Steps -split '[,;]') | Where-Object { $_.Trim() -match '^[MGXmgx].+' }).Count -gt 0

if (-not $hasMaskStep) {
    if ($Masks) { Write-Warning "-Masks ignoré : aucune étape G<i>, X<i> ou M<i> dans -Steps '$Steps'" }
    $bmp = if ($Pipeline) { $engine::RunPipeline($in, $Steps) } else { $engine::Run($in, $MaxSize, $White, $Steps) }
    try { $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
    Write-Output $Out
    return
}

if ($MaskOut -and -not [IO.Path]::IsPathRooted($MaskOut)) { $MaskOut = Join-Path (Get-Location).Path $MaskOut }
if (-not $MaskOut) { $MaskOut = Join-Path (Split-Path $Out) ([IO.Path]::GetFileNameWithoutExtension($Out) + '_mask.png') }
$maskBitmaps = New-Object 'Collections.Generic.List[Drawing.Bitmap]'
try {
    foreach ($m in @($Masks)) { if ($m) { $maskBitmaps.Add((New-Object Drawing.Bitmap (Resolve-Path $m).Path)) } }
    $result = if ($Pipeline) { $engine::RunPipeline($in, $Steps, $maskBitmaps.ToArray()) }
              else { $engine::Run($in, $MaxSize, $White, $Steps, $maskBitmaps.ToArray()) }
    try {
        $result.Image.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
        $result.Mask.Save($MaskOut, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $result.Dispose() }
} finally { foreach ($b in $maskBitmaps) { $b.Dispose() } }
Write-Output $Out
Write-Output $MaskOut
Write-Host "Masque combiné (rouge = gomme, vert = exclusion) pour .\AsciiArtConverter.ps1 -Mask : $MaskOut"