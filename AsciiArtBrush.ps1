# Bibliothèque de pinceau : AsciiBrush possède les traits et l'import d'une étape M, jamais le raster de travail.
# Add/Reset/Load/Rasterize ; SetToolEnabled filtre aussi les canaux PNG importés (1 = gomme, 2 = exclusion).
# Coordonnées et diamètre relatifs à l'image ; outil 0 = restauration des seules marques de ce pinceau.
# Les codecs et aperçus appartiennent à AsciiRasterMask dans AsciiArtRaster.ps1.
$code = @'
// @requires AsciiArtRaster.ps1
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public sealed class AsciiBrush : IDisposable
{
    sealed class Stroke
    {
        public float X1, Y1, X2, Y2, Diameter;
        public int Tool;
    }
    readonly List<Stroke> strokes = new List<Stroke>();
    Bitmap saved;
    readonly bool[] enabledTools = { true, true, true };

    public void SetToolEnabled(int tool, bool enabled)
    {
        if (tool < 1 || tool > 2) throw new ArgumentOutOfRangeException("tool");
        enabledTools[tool] = enabled;
    }

    public void Add(float x1, float y1, float x2, float y2, float diameter, int tool)
    {
        if (diameter <= 0 || tool < 0 || tool > 2) throw new ArgumentOutOfRangeException();
        if (!enabledTools[tool]) return;
        strokes.Add(new Stroke { X1 = x1, Y1 = y1, X2 = x2, Y2 = y2, Diameter = diameter, Tool = tool });
    }

    public void Reset()
    {
        strokes.Clear();
        if (saved != null) { saved.Dispose(); saved = null; }
    }

    public void Load(string path)
    {
        using (Bitmap source = new Bitmap(path))
        {
            Bitmap copy = new Bitmap(source);
            Reset();
            saved = copy;
        }
    }

    public Bitmap Rasterize(int width, int height)
    {
        using (Bitmap eraser = Plane(width, height, true))
        using (Bitmap exclusion = Plane(width, height, false))
        {
            byte[] r = AsciiRasterMask.Read(eraser), g = AsciiRasterMask.Read(exclusion);
            for (int i = 0; i < r.Length; i += 4)
            {
                r[i] = 0; r[i + 1] = g[i + 2]; r[i + 3] = 255;
            }
            return AsciiRasterMask.Write(width, height, r);
        }
    }

    Bitmap Plane(int width, int height, bool eraser)
    {
        Bitmap plane = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(plane))
        {
            graphics.Clear(Color.Black);
            if (!enabledTools[eraser ? 1 : 2]) return plane;
            if (saved != null)
            {
                using (Bitmap scaled = AsciiRasterMask.Resize(saved, width, height))
                {
                    byte[] data = AsciiRasterMask.Read(scaled);
                    for (int i = 0; i < data.Length; i += 4)
                    {
                        byte v = data[i + (eraser ? 2 : 1)] >= 128 ? (byte)255 : (byte)0;
                        data[i] = data[i + 1] = data[i + 2] = v; data[i + 3] = 255;
                    }
                    using (Bitmap channel = AsciiRasterMask.Write(width, height, data))
                        graphics.DrawImageUnscaled(channel, 0, 0);
                }
            }
            graphics.SmoothingMode = SmoothingMode.None;
            foreach (Stroke stroke in strokes)
            {
                if (stroke.Tool != 0 && stroke.Tool != (eraser ? 1 : 2)) continue;
                float diameter = Math.Max(1, stroke.Diameter * width);
                Color color = stroke.Tool == 0 ? Color.Black : Color.White;
                float x1 = stroke.X1 * width, y1 = stroke.Y1 * height;
                float x2 = stroke.X2 * width, y2 = stroke.Y2 * height;
                using (Pen pen = new Pen(color, diameter))
                using (Brush brush = new SolidBrush(color))
                {
                    graphics.DrawLine(pen, x1, y1, x2, y2);
                    graphics.FillEllipse(brush, x1 - diameter / 2, y1 - diameter / 2, diameter, diameter);
                    graphics.FillEllipse(brush, x2 - diameter / 2, y2 - diameter / 2, diameter, diameter);
                }
            }
        }
        return plane;
    }

    public void Dispose() { Reset(); }
}
'@
