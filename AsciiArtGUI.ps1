<#
  Interface à deux onglets :
    1. Prétraitement : étapes réordonnables de taille, seuil blanc, aplats, bords, gomme et masque
    2. ASCII : conversion de l'image et du masque issus du prétraitement
  Chaque changement de paramètre recalcule automatiquement la vue.
  Usage : .\AsciiArtGUI.ps1 [-Path image.png]
  Test  : .\AsciiArtGUI.ps1 -Path img.png -Screenshot out.png [-Tab 0|1]
#>
param(
    [string]$Path,
    [string]$Screenshot,
    [ValidateRange(0, 1)][int]$Tab = 1
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# ---------- Chargement des moteurs C# ----------
function Import-Engine([string]$file, [string]$class) {
    . (Join-Path $PSScriptRoot 'AsciiArtPluginCompilator.ps1')
    return Import-AsciiEngine -File $file -Class $class
}
$script:preCache = New-Object (Import-Engine 'AsciiArtPreProcess.ps1' 'PreProcessCache')
$script:sourceGeneration = [long]0
$ascType = Import-Engine 'AsciiArtConverter.ps1' 'AsciiEdge'
# Les pinceaux éditent chacun un canal d'étape dédié ; le raster garde les couches et aperçus.
$brushType = Import-Engine 'AsciiArtBrush.ps1' 'AsciiBrush'
$rasterMaskType = Import-Engine 'AsciiArtRaster.ps1' 'AsciiRasterMask'
$script:maskEditor = $null
$script:preResult = $null
$script:previewBmp = $null

# Interfaces des outils (moteurs/CLI inchangés). Commenter UNE ligne retire l'outil,
# ses boutons, ses paramètres et ses actions, y compris ses canaux PNG importés.
. (Join-Path $PSScriptRoot 'AsciiArtPluginToolsGUI.ps1')
. (Join-Path $PSScriptRoot 'plugin\Taille\AsciiArtToolSize.ps1')
. (Join-Path $PSScriptRoot 'plugin\SeuilBlanc\AsciiArtToolWhite.ps1')
. (Join-Path $PSScriptRoot 'plugin\Aplats\AsciiArtToolPosterize.ps1')
. (Join-Path $PSScriptRoot 'plugin\Bords\AsciiArtToolEdges.ps1')
. (Join-Path $PSScriptRoot 'plugin\Gomme\AsciiArtToolEraser.ps1')
. (Join-Path $PSScriptRoot 'plugin\Masque\AsciiArtToolExclusion.ps1')

# ---------- Palettes ----------
$palettes = [ordered]@{
    'Courbes (défaut)'         = '()[]{}~''",.:;!=+'
    'Courbes minimal'          = '()[]{}'
    'Traits droits seuls'      = ''
    'Pointillés / épais'       = '=+:;!~'
    'Ponctuation complète'     = '!"#$%&''()*+,.:;=?@[]`{}~'
    'Chiffres et lettres'      = '()[]{}1lIiTtYyXxZz'
    'ASCII complète'           = '!"#$%&''()*+,./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]`abcdefghijklmnopqrstuwxyz{}~'
    'Personnalisée'            = $null
}

# ---------- Workers (calcul en arrière-plan avec anti-rebond) ----------
function New-Worker([scriptblock]$work, [scriptblock]$getArgs, [scriptblock]$onDone) {
    $w = @{ Work = $work; GetArgs = $getArgs; OnDone = $onDone; Job = $null; Dirty = $false; Status = $null; Revision = 0 }
    $t = New-Object Windows.Forms.Timer
    $t.Interval = 350
    $t.Tag = $w
    $t.Add_Tick({ $this.Stop(); Invoke-Work $this.Tag })
    $w.Timer = $t
    return $w
}
function Request-Work($w) {
    $w.Revision++; $w.Timer.Stop(); $w.Timer.Start()
    if ($w -eq $script:pre -and $script:asc) {
        $script:asc.Revision++
        $script:lines = @()
        if ($txt) { $txt.Clear() }
    }
}
function Invoke-Work($w) {
    if ($w.Job) { $w.Revision++; $w.Dirty = $true; return }
    $jobArgs = & $w.GetArgs
    if ($null -eq $jobArgs) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($w.Work)
    foreach ($a in $jobArgs) { [void]$ps.AddArgument($a) }
    $w.Job = @{ Ps = $ps; Handle = $ps.BeginInvoke(); Watch = [Diagnostics.Stopwatch]::StartNew(); Revision = $w.Revision }
    if ($w.Status) { $w.Status.Text = 'Calcul en cours...' }
}
function Complete-Work($w) {
    $j = $w.Job
    if (-not $j -or -not $j.Handle.IsCompleted) { return }
    $w.Job = $null
    try {
        $res = $j.Ps.EndInvoke($j.Handle)
        if ($j.Ps.Streams.Error.Count -gt 0) { throw $j.Ps.Streams.Error[0].ToString() }
        if ($j.Revision -eq $w.Revision) {
            & $w.OnDone $res $j.Watch.Elapsed.TotalSeconds
        } else {
            foreach ($item in $res) { if ($item -is [IDisposable]) { $item.Dispose() } }
        }
    } catch {
        if ($w.Status) { $w.Status.Text = "Erreur : $($_.Exception.Message)" }
    }
    $j.Ps.Dispose()
    if ($w.Dirty) { $w.Dirty = $false; Invoke-Work $w }
}

$preWork = {
    param($cache, $path, $sourceKey, $steps, $masks)
    try { $cache.Run($path, $sourceKey, $steps, [Drawing.Bitmap[]]$masks) }
    finally { foreach ($mask in $masks) { $mask.Dispose() } }
}
$ascWork = {
    param($tn, $bmp, $w, $h, $detail, $smooth, $minSize, $invert, $fill, $chars, $straight, $mask)
    try { ($tn -as [type])::Run($bmp, $w, $h, $detail, $smooth, $minSize, $invert, $fill, $chars, $straight, $mask) }
    finally { $bmp.Dispose(); $mask.Dispose() }
}

$script:file   = $null
$script:orig   = $null   # image d'origine
$script:preBmp = $null   # résultat du prétraitement
$script:lines  = @()
$script:shotDone = $false

# ---------- Fenêtre ----------
$form = New-Object Windows.Forms.Form
$form.Text = 'ASCII Art - Prétraitement, masques et conversion'
$form.Size = New-Object Drawing.Size(1350, 900)
$form.StartPosition = 'CenterScreen'
$form.AllowDrop = $true

$top = New-Object Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 38
$btnOpen = New-Object Windows.Forms.Button
$btnOpen.Text = 'Ouvrir une image...'; $btnOpen.SetBounds(8, 6, 140, 26)
$lblFile = New-Object Windows.Forms.Label
$lblFile.SetBounds(160, 11, 1000, 20); $lblFile.Text = '(glisser-déposer une image dans la fenêtre)'
$top.Controls.AddRange(@($btnOpen, $lblFile))

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabPre = New-Object Windows.Forms.TabPage; $tabPre.Text = '1 · Prétraitement'
$tabAsc = New-Object Windows.Forms.TabPage; $tabAsc.Text = '2 · ASCII'
$tabs.TabPages.AddRange(@($tabPre, $tabAsc))
$form.Controls.Add($tabs)
$form.Controls.Add($top)
$top.BringToFront(); $tabs.BringToFront()

# ---------- Infobulles ----------
$tt = New-Object Windows.Forms.ToolTip
$tt.AutoPopDelay = 30000; $tt.InitialDelay = 300; $tt.ReshowDelay = 100
function Set-Tip($ctl, [string]$text) {
    $tt.SetToolTip($ctl, $text)
    if ($ctl.Tag -is [hashtable] -and $ctl.Tag.Label) { $tt.SetToolTip($ctl.Tag.Label, $text) }
}

# ---------- Helpers de mise en page ----------
$script:y = 10
function New-SidePanel($page) {
    $p = New-Object Windows.Forms.Panel
    $p.Dock = 'Left'; $p.Width = 290; $p.AutoScroll = $true
    $page.Controls.Add($p)
    $script:y = 10
    return $p
}
function Add-Label($parent, [string]$text) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.SetBounds(10, $script:y, 265, 18)
    $parent.Controls.Add($l); $script:y += 20
    return $l
}
function Add-Slider($parent, [string]$text, [double]$min, [double]$max, [double]$val, [double]$step, $worker) {
    $lbl = Add-Label $parent ''
    $tb = New-Object Windows.Forms.TrackBar
    $tb.SetBounds(5, $script:y, 275, 40)
    $tb.Minimum = [int][math]::Round($min / $step); $tb.Maximum = [int][math]::Round($max / $step)
    $tb.Value = [int][math]::Round($val / $step); $tb.TickFrequency = [math]::Max(1, [int](($tb.Maximum - $tb.Minimum) / 10))
    $tb.Tag = @{ Label = $lbl; Text = $text; Step = $step; Worker = $worker }
    $lbl.Text = ('{0} : {1}' -f $text, ($tb.Value * $step))
    $tb.Add_ValueChanged({
        $t = $this.Tag
        $t.Label.Text = ('{0} : {1}' -f $t.Text, ($this.Value * $t.Step))
        Request-Work $t.Worker
    })
    $parent.Controls.Add($tb); $script:y += 46
    return $tb
}
function Add-Number($parent, [string]$text, [int]$min, [int]$max, [int]$val, $worker) {
    [void](Add-Label $parent $text)
    $n = New-Object Windows.Forms.NumericUpDown
    $n.SetBounds(10, $script:y, 100, 24); $n.Minimum = $min; $n.Maximum = $max; $n.Value = $val
    $n.Tag = $worker
    $n.Add_ValueChanged({ Request-Work $this.Tag })
    $parent.Controls.Add($n); $script:y += 32
    return $n
}
function Add-Check($parent, [string]$text, [bool]$val, $worker) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $text; $c.Checked = $val; $c.SetBounds(10, $script:y, 260, 22); $c.Tag = $worker
    $c.Add_CheckedChanged({ Request-Work $this.Tag })
    $parent.Controls.Add($c); $script:y += 26
    return $c
}

# ---------- Onglet 1 : Prétraitement ----------
$script:pre = New-Worker $preWork {
    if (-not $script:file) { return $null }
    $masks = New-Object 'Collections.Generic.List[Drawing.Bitmap]'
    foreach ($step in $script:steps) {
        if ($step.Editor) { $masks.Add($step.Editor.Rasterize($script:orig.Width, $script:orig.Height)) }
    }
    $script:runningSteps = $script:steps.ToArray()
    @($script:preCache, $script:file, [string]$script:sourceGeneration, (Get-Steps), $masks.ToArray())
} {
    param($res, $secs)
    if ($script:preResult) { $script:preResult.Dispose() }
    $script:preResult = $res[0]
    $script:resultSteps = $script:runningSteps
    $script:preBmp = $script:preResult.Image
    Update-Picture
    $script:pre.Status.Text = ('Prétraitement : {0}x{1} en {2:N2} s ({3} réutilisées, {4} calculées)' -f $script:preBmp.Width, $script:preBmp.Height, $secs, $script:preCache.ReusedSteps, $script:preCache.ProcessedSteps)
    Invoke-Work $script:asc
}

$pnlPre = New-SidePanel $tabPre

# Liste d'étapes appliquées dans l'ordre (en nombre quelconque)
[void](Add-Label $pnlPre 'Étapes (appliquées de haut en bas) :')
$lstSteps = New-Object Windows.Forms.ListBox
$lstSteps.SetBounds(10, $script:y, 265, 110); $lstSteps.IntegralHeight = $false
$pnlPre.Controls.Add($lstSteps); $script:y += 116
Add-AsciiStepButtons $pnlPre
$btnDel = New-Object Windows.Forms.Button; $btnDel.Text = 'Supprimer cette étape'; $btnDel.SetBounds(10, $script:y, 265, 26)
$pnlPre.Controls.Add($btnDel); $script:y += 30
$btnUp   = New-Object Windows.Forms.Button; $btnUp.Text = [string][char]0x25B2 + ' Monter';  $btnUp.SetBounds(10, $script:y, 130, 26)
$btnDown = New-Object Windows.Forms.Button; $btnDown.Text = [string][char]0x25BC + ' Descendre'; $btnDown.SetBounds(145, $script:y, 130, 26)
$pnlPre.Controls.AddRange(@($btnUp, $btnDown)); $script:y += 34
$lblStep = Add-Label $pnlPre 'Sélectionnez une étape pour régler sa valeur'
$tbStep = New-Object Windows.Forms.TrackBar
$tbStep.SetBounds(5, $script:y, 275, 40); $tbStep.Enabled = $false
$pnlPre.Controls.Add($tbStep); $script:y += 46

Set-Tip $lstSteps "Les étapes sont appliquées dans cet ordre. Chaque étape Gomme ou Masque possède son propre pinceau et son propre canal.`nSélectionner une étape affiche son image d'entrée pour peindre avant les traitements suivants."
Set-Tip $btnDel "Retire l'étape sélectionnée."
Set-Tip $btnUp "Remonte l'étape sélectionnée (appliquée plus tôt)."
Set-Tip $btnDown "Descend l'étape sélectionnée (appliquée plus tard)."
$script:steps = New-Object Collections.ArrayList
foreach ($tool in $script:stepTools.Values) {
    if ($tool.Default) { [void]$script:steps.Add((& $tool.Create)) }
}
$script:loading = $false
function Get-Steps {
    $maskIndex = 0
    ($script:steps | ForEach-Object {
        if ($_.Editor) { '{0}{1}' -f $_.Kind, $maskIndex; $maskIndex++ }
        else { '{0}{1}' -f $_.Kind, [int]$_.Value }
    }) -join ','
}
function Get-StepText($st) {
    if ($st.Editor) { $script:stepTools[$st.Kind].Label }
    else { $script:stepTools[$st.Kind].Label -f [int]$st.Value }
}
function Update-StepList([int]$select) {
    $script:loading = $true
    $lstSteps.Items.Clear()
    for ($i = 0; $i -lt $script:steps.Count; $i++) { [void]$lstSteps.Items.Add(('{0}. {1}' -f ($i + 1), (Get-StepText $script:steps[$i]))) }
    if ($select -ge 0 -and $select -lt $lstSteps.Items.Count) { $lstSteps.SelectedIndex = $select }
    $script:loading = $false
    Show-StepEditor
}
function Show-StepEditor {
    $script:loading = $true
    $i = $lstSteps.SelectedIndex
    if ($maskPic) { $maskPic.Capture = $false }
    $script:maskEditor = $null
    $script:maskDrawing = $false; $script:maskPoint = $null; $script:brushPoint = $null
    $script:activeBrushTool = $null
    if ($pnlMask) { $pnlMask.Visible = $false }
    $tbStep.Visible = $true
    if ($i -lt 0) { $tbStep.Enabled = $false; $lblStep.Text = 'Sélectionnez une étape pour régler sa valeur' }
    elseif ($script:steps[$i].Editor) {
        $st = $script:steps[$i]
        $script:maskEditor = $st.Editor
        $script:activeBrushTool = $st.BrushTool
        $tbStep.Visible = $false
        $lblStep.Text = '{0} de cette étape' -f $script:stepTools[$st.Kind].Label
        if ($pnlMask) {
            foreach ($name in $script:brushButtonGroups.Keys) {
                $script:brushButtonGroups[$name].Panel.Visible = ($name -eq $script:activeBrushTool)
            }
            foreach ($name in $script:brushActionButtons.Keys) {
                $script:brushActionButtons[$name].Visible = ($name -eq $script:activeBrushTool)
            }
            $tool = $script:brushTools[$script:activeBrushTool]
            $lblMaskHelp.Text = '{0} : image à cette étape, avant la suite des traitements.' -f $tool.Label
            $chkOverlay.Text = 'Afficher les couleurs {0}' -f $tool.OverlayLabel
            $btnResetMask.Text = $tool.ResetText
            $btnLoadMask.Text = 'Charger un masque {0} PNG...' -f $tool.Label
            $btnSaveMask.Text = 'Enregistrer le masque {0} PNG...' -f $tool.Label
            $lblMaskStatus.Text = $tool.Status + "`r`nEffets appliqués à cette étape seulement."
            Set-Tip $chkOverlay ('Afficher uniquement les marques de {0} de cette étape.' -f $tool.Label)
            Set-Tip $btnLoadMask ('Importe uniquement le canal de {0} depuis un PNG.' -f $tool.Label)
            Set-Tip $btnSaveMask ('Exporte uniquement le canal de {0} de cette étape.' -f $tool.Label)
            $pnlMask.Visible = $true
        }
    }
    else {
        $st = $script:steps[$i]
        $tbStep.Enabled = $true
        $tool = $script:stepTools[$st.Kind]
        $tbStep.SetRange([int]$tool.Minimum, [int]$tool.Maximum)
        $tbStep.Value = [int]$st.Value
        $tbStep.TickFrequency = if ($tool.TickFrequency) { [int]$tool.TickFrequency } else { 1 }
        $lblStep.Text = $tool.ValueLabel -f [int]$st.Value
        Set-Tip $tbStep $tool.SliderTip
    }
    $script:loading = $false
    if ($chkOrig) {
        $bottom = if ($script:maskEditor) { $pnlMask.Bottom } else { $tbStep.Bottom }
        $chkOrig.Top = $bottom + 8
        $btnSavePre.Top = $chkOrig.Bottom + 8
        $lblPreStatus.Top = $btnSavePre.Bottom + 8
    }
    if ($pic) { Update-Picture }
}
$lstSteps.Add_SelectedIndexChanged({ if (-not $script:loading) { Show-StepEditor } })
$tbStep.Add_ValueChanged({
    if ($script:loading) { return }
    $i = $lstSteps.SelectedIndex; if ($i -lt 0) { return }
    $st = $script:steps[$i]
    $st.Value = [double]$tbStep.Value
    $lblStep.Text = $script:stepTools[$st.Kind].ValueLabel -f [int]$st.Value
    $script:loading = $true; $lstSteps.Items[$i] = '{0}. {1}' -f ($i + 1), (Get-StepText $st); $script:loading = $false
    Request-Work $script:pre
})
$btnDel.Add_Click({
    $i = $lstSteps.SelectedIndex; if ($i -lt 0) { return }
    if ($script:steps[$i].Editor) {
        if ($maskPic) { $maskPic.Capture = $false }
        $script:maskDrawing = $false; $script:maskPoint = $null
        $script:steps[$i].Editor.Dispose()
    }
    $script:steps.RemoveAt($i); Update-StepList ([math]::Min($i, $script:steps.Count - 1)); Request-Work $script:pre
})
$btnUp.Add_Click({
    $i = $lstSteps.SelectedIndex; if ($i -lt 1) { return }
    $x = $script:steps[$i]; $script:steps.RemoveAt($i); $script:steps.Insert($i - 1, $x); Update-StepList ($i - 1); Request-Work $script:pre
})
$btnDown.Add_Click({
    $i = $lstSteps.SelectedIndex; if ($i -lt 0 -or $i -ge $script:steps.Count - 1) { return }
    $x = $script:steps[$i]; $script:steps.RemoveAt($i); $script:steps.Insert($i + 1, $x); Update-StepList ($i + 1); Request-Work $script:pre
})
Update-StepList 0
$script:y += 4
$chkOrig  = New-Object Windows.Forms.CheckBox
$chkOrig.Text = "Afficher l'original"; $chkOrig.SetBounds(10, $script:y, 260, 22)
Set-Tip $chkOrig "Compare visuellement : affiche l'image d'origine à la place du résultat du prétraitement (n'affecte pas l'ASCII)."
$chkOrig.Add_CheckedChanged({ Update-Picture })
$pnlPre.Controls.Add($chkOrig); $script:y += 30
$btnSavePre = New-Object Windows.Forms.Button
$btnSavePre.Text = "Enregistrer l'image prétraitée..."; $btnSavePre.SetBounds(10, $script:y, 265, 28)
$pnlPre.Controls.Add($btnSavePre); $script:y += 36
$lblPreStatus = Add-Label $pnlPre ''
$lblPreStatus.Height = 36
$script:pre.Status = $lblPreStatus

$pic = New-Object Windows.Forms.PictureBox
$pic.Dock = 'Fill'; $pic.SizeMode = 'Zoom'; $pic.BackColor = [Drawing.Color]::FromArgb(230, 230, 230)
$tabPre.Controls.Add($pic); $pic.BringToFront()

function Update-Picture {
    $src = if ($chkOrig.Checked) { $script:orig } else { $script:preBmp }
    $i = $lstSteps.SelectedIndex
    $script:previewBmp = $null
    $sameOrder = $script:resultSteps -and $script:resultSteps.Length -eq $script:steps.Count
    if ($sameOrder) {
        for ($j = 0; $j -lt $script:steps.Count; $j++) {
            if (-not [object]::ReferenceEquals($script:resultSteps[$j], $script:steps[$j])) { $sameOrder = $false; break }
        }
    }
    if ($script:maskEditor -and $sameOrder -and $script:preResult -and $i -ge 0 -and $i -lt $script:preResult.Previews.Length) {
        $script:previewBmp = $script:preResult.Previews[$i]
        if (-not $chkOrig.Checked) { $src = $script:previewBmp }
    }
    $old = $pic.Image
    if ($src -and $script:maskEditor -and -not $chkOrig.Checked) {
        $marks = $script:maskEditor.Rasterize($src.Width, $src.Height)
        try { $pic.Image = ($rasterMaskType -as [type])::Apply($src, $marks, $chkOverlay.Checked) }
        finally { $marks.Dispose() }
    } else {
        $pic.Image = if ($src) { New-Object Drawing.Bitmap $src } else { $null }
    }
    if ($old) { $old.Dispose() }
}

# ---------- Éditeurs des étapes Gomme et Masque ----------
if ($script:brushTools.Count) {
$maskPanelTop = $lblStep.Bottom + 4
$pnlMask = New-Object Windows.Forms.Panel
$pnlMask.SetBounds(0, $maskPanelTop, 285, 470)
$pnlMask.Visible = $false
$pnlPre.Controls.Add($pnlMask)
$pnlMask.BringToFront()
$script:y = 4
$lblMaskHelp = Add-Label $pnlMask 'Image à cette étape : peindre par cliquer-glisser, avant la suite des traitements.'
$lblMaskHelp.Height = 36; $script:y += 18
Add-AsciiBrushButtons $pnlMask
[void](Add-Label $pnlMask 'Diamètre du pinceau (pixels de l''image)')
$numBrush = New-Object Windows.Forms.NumericUpDown
$numBrush.SetBounds(10, $script:y, 100, 24)
$numBrush.Minimum = 1; $numBrush.Maximum = 500; $numBrush.Value = 30
$pnlMask.Controls.Add($numBrush); $script:y += 34
$chkOverlay = New-Object Windows.Forms.CheckBox
$chkOverlay.Text = 'Afficher les couleurs'; $chkOverlay.Checked = $true
$chkOverlay.SetBounds(10, $script:y, 270, 26)
$pnlMask.Controls.Add($chkOverlay); $script:y += 34
foreach ($spec in @(
    @('btnResetMask', 'Réinitialiser'),
    @('btnLoadMask', 'Charger un masque PNG...'),
    @('btnSaveMask', 'Enregistrer le masque PNG...')
)) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $spec[1]; $button.SetBounds(10, $script:y, 265, 28)
    $pnlMask.Controls.Add($button); $script:y += 36
    Set-Variable -Name $spec[0] -Value $button
}
Add-AsciiBrushActions $pnlMask
$lblMaskStatus = Add-Label $pnlMask ''
$lblMaskStatus.Height = 50
$pnlMask.Height = $lblMaskStatus.Bottom + 4
$chkOrig.Top = $pnlMask.Bottom + 4
$btnSavePre.Top = $chkOrig.Bottom + 8
$lblPreStatus.Top = $btnSavePre.Bottom + 8
$maskPic = $pic
$maskPic.Cursor = [Windows.Forms.Cursors]::Cross
$script:maskDrawing = $false
$script:maskPoint = $null
$script:brushPoint = $null

function Update-MaskPicture {
    Update-Picture
    $maskPic.Invalidate()
}
function Get-MaskRectangle {
    if (-not $script:previewBmp -or -not $script:maskEditor -or $chkOrig.Checked -or $maskPic.ClientSize.Width -le 0 -or $maskPic.ClientSize.Height -le 0) { return $null }
    $scale = [math]::Min($maskPic.ClientSize.Width / $script:previewBmp.Width, $maskPic.ClientSize.Height / $script:previewBmp.Height)
    $w = [int]($script:previewBmp.Width * $scale); $h = [int]($script:previewBmp.Height * $scale)
    New-Object Drawing.Rectangle ([int](($maskPic.ClientSize.Width - $w) / 2)), ([int](($maskPic.ClientSize.Height - $h) / 2)), $w, $h
}
function Paint-MaskPoint([Drawing.Point]$point) {
    $brush = Get-AsciiBrush
    if (-not $brush) { $script:maskPoint = $null; return }
    $rect = Get-MaskRectangle
    if ($null -eq $rect -or -not $rect.Contains($point)) { $script:maskPoint = $null; return }
    $x = [single](($point.X - $rect.X) / $rect.Width)
    $y = [single](($point.Y - $rect.Y) / $rect.Height)
    $previous = if ($null -ne $script:maskPoint) { $script:maskPoint } else { New-Object Drawing.PointF $x, $y }
    $script:maskEditor.Add($previous.X, $previous.Y, $x, $y, [single]($numBrush.Value / $script:previewBmp.Width), $brush.ToolId)
    $script:maskPoint = New-Object Drawing.PointF $x, $y
    Update-MaskPicture
    Request-Work $script:pre
}
$maskPic.Add_MouseDown({
    if ($_.Button -ne [Windows.Forms.MouseButtons]::Left -or -not (Get-AsciiBrush) -or -not $script:previewBmp -or $chkOrig.Checked) { return }
    $script:maskDrawing = $true; $script:maskPoint = $null
    $maskPic.Capture = $true
    Paint-MaskPoint $_.Location
})
$maskPic.Add_MouseMove({
    $script:brushPoint = $_.Location
    if ($script:maskDrawing) { Paint-MaskPoint $_.Location }
    $maskPic.Invalidate()
})
$maskPic.Add_MouseUp({
    if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) {
        $script:maskDrawing = $false; $script:maskPoint = $null; $maskPic.Capture = $false
    }
})
$maskPic.Add_MouseCaptureChanged({
    if (-not $maskPic.Capture) { $script:maskDrawing = $false; $script:maskPoint = $null }
})
$maskPic.Add_MouseLeave({ $script:brushPoint = $null; $maskPic.Invalidate() })
$maskPic.Add_Paint({
    $brush = Get-AsciiBrush
    if (-not $brush) { return }
    $rect = Get-MaskRectangle
    if ($null -eq $rect -or $null -eq $script:brushPoint -or -not $rect.Contains($script:brushPoint)) { return }
    $diameter = [single]($numBrush.Value * $rect.Width / $script:previewBmp.Width)
    $outline = New-Object Drawing.Pen ([Drawing.Color]::Black), 3
    $pen = New-Object Drawing.Pen $brush.Color, 1
    try {
        $x = [single]($script:brushPoint.X - $diameter / 2); $y = [single]($script:brushPoint.Y - $diameter / 2)
        $_.Graphics.DrawEllipse($outline, $x, $y, $diameter, $diameter)
        $_.Graphics.DrawEllipse($pen, $x, $y, $diameter, $diameter)
    } finally { $outline.Dispose(); $pen.Dispose() }
})
$numBrush.Add_ValueChanged({ $maskPic.Invalidate() })
$chkOverlay.Add_CheckedChanged({ Update-MaskPicture })
$btnResetMask.Add_Click({
    if (-not $script:maskEditor) { return }
    $script:maskEditor.Reset()
    Update-MaskPicture
    Request-Work $script:pre
})
$btnLoadMask.Add_Click({
    if (-not $script:preBmp -or -not $script:maskEditor) { return }
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Filter = ('Masque {0} PNG|*.png' -f $script:brushTools[$script:activeBrushTool].Label)
    if ($d.ShowDialog() -eq 'OK') {
        try {
            $script:maskEditor.Load($d.FileName)
            Update-MaskPicture
            Request-Work $script:pre
        } catch { [void][Windows.Forms.MessageBox]::Show("Masque illisible : $($_.Exception.Message)") }
    }
    $d.Dispose()
})
$btnSaveMask.Add_Click({
    if (-not $script:preBmp -or -not $script:maskEditor) { return }
    $d = New-Object Windows.Forms.SaveFileDialog
    $d.Filter = ('Masque {0} PNG|*.png' -f $script:brushTools[$script:activeBrushTool].Label)
    if ($d.ShowDialog() -eq 'OK') {
        $marks = $script:maskEditor.Rasterize($script:preBmp.Width, $script:preBmp.Height)
        try { $marks.Save($d.FileName, [Drawing.Imaging.ImageFormat]::Png) }
        finally { $marks.Dispose() }
    }
    $d.Dispose()
})
}
Show-StepEditor

# ---------- Onglet 2 : ASCII ----------
$script:asc = New-Worker $ascWork {
    if (-not $script:preResult -or $script:pre.Job -or $script:pre.Timer.Enabled) { return $null }
    $marks = New-Object Drawing.Bitmap $script:preResult.Mask
    $image = New-Object Drawing.Bitmap $script:preBmp
    @($ascType, $image, [int]$numW.Value, [int]$numH.Value,
      [double]($tbDetail.Value / 100), $(if ($script:blurOn) { [double]($tbSmooth.Value / 10) } else { 0.0 }), [double]($tbMin.Value / 2),
      [bool]$chkInv.Checked, [bool]$chkFill.Checked, [string]$txtChars.Text, [double]($tbStraight.Value / 100), $marks)
} {
    param($res, $secs)
    $script:lines = @($res | ForEach-Object { [string]$_ })
    $txt.Text = $script:lines -join "`r`n"
    $script:asc.Status.Text = ('ASCII : {0} lignes en {1:N2} s' -f $script:lines.Count, $secs)
}

$pnlAsc = New-SidePanel $tabAsc
$numW      = Add-Number $pnlAsc 'Largeur (caractères)' 20 400 100 $script:asc
$numH      = Add-Number $pnlAsc 'Hauteur (0 = auto)' 0 400 0 $script:asc
$tbDetail  = Add-Slider $pnlAsc 'Détail (contours)' 0.05 1 0.3 0.01 $script:asc

# Flou gaussien optionnel : un bouton l'ajoute / le retire, le curseur n'apparaît qu'une fois ajouté
$script:blurOn = $false
$pnlBlur = New-Object Windows.Forms.Panel
$pnlBlur.SetBounds(0, $script:y, 285, 32)
$pnlAsc.Controls.Add($pnlBlur)
$btnBlur = New-Object Windows.Forms.Button
$btnBlur.Text = '+ Ajouter un flou gaussien'; $btnBlur.SetBounds(10, 0, 265, 26)
$pnlBlur.Controls.Add($btnBlur)
$yBlur = $script:y; $script:y = 34
$tbSmooth = Add-Slider $pnlBlur 'Flou gaussien' 0.5 6 2.5 0.1 $script:asc
$tbSmooth.Visible = $false; $tbSmooth.Tag.Label.Visible = $false
$script:y = $yBlur + 38
$script:blurIdx = $pnlAsc.Controls.Count
$btnBlur.Add_Click({
    $script:blurOn = -not $script:blurOn
    $delta = if ($script:blurOn) { 68 } else { -68 }
    $tbSmooth.Visible = $script:blurOn; $tbSmooth.Tag.Label.Visible = $script:blurOn
    $btnBlur.Text = if ($script:blurOn) { 'Retirer le flou gaussien' } else { '+ Ajouter un flou gaussien' }
    $pnlBlur.Height += $delta
    for ($k = $script:blurIdx; $k -lt $pnlAsc.Controls.Count; $k++) { $pnlAsc.Controls[$k].Top += $delta }
    Request-Work $script:asc
})
$tbMin     = Add-Slider $pnlAsc 'Taille min. des traits' 0 20 5 0.5 $script:asc
$tbStraight = Add-Slider $pnlAsc 'Traits droits : régularité (1 = désactivé)' 0.5 1 0.9 0.01 $script:asc
$chkInv    = Add-Check $pnlAsc 'Inverser (fond sombre)' $false $script:asc
$chkFill   = Add-Check $pnlAsc 'Remplir les aplats' $false $script:asc

Set-Tip $numW "Nombre de colonnes de caractères. Plus grand = plus de finesse, mais le texte devient très large."
Set-Tip $numH "Nombre de lignes. 0 = calculé pour respecter les proportions de l'image ; sinon les proportions sont forcées."
Set-Tip $tbDetail "Sensibilité de la détection de contours.`nBas = seulement les grandes lignes principales ; haut = beaucoup de traits, y compris les contrastes faibles."
Set-Tip $btnBlur "Ajoute / retire un flou gaussien appliqué avant la détection de contours. Sans flou, les contours sont précis mais très bruités (texture, grain)."
Set-Tip $tbSmooth "Intensité du flou (en pixels).`nPlus haut = contours plus continus et moins de bruit/texture, mais coins arrondis et fins détails perdus ; bas = contours précis mais hachés."
Set-Tip $tbMin "Taille minimale d'un contour, en caractères. Les traits plus petits sont supprimés.`nPlus haut = ignore les petits détails (feuilles, texture) ; 0 = tout garder."
Set-Tip $tbStraight "Traits droits : horizontal bas _, milieu -, haut _ (placé dans la cellule vide du dessus) ; vertical | ; diagonales / \ ; pointes < > ^ v ; coins ┌ ┐ └ ┘.`nSeuil de régularité du contour dans une cellule pour employer ces caractères ; sinon le caractère est choisi par ressemblance de forme dans la palette.`nBas (0,5-0,8) = beaucoup de traits droits, rendu très linéaire ; haut (0,95+) = seulement les lignes parfaitement droites ; 1 = désactivé, tout passe par la ressemblance de forme."
Set-Tip $chkInv "Inverse la polarité : pour un affichage clair sur fond sombre (terminal noir)."
Set-Tip $chkFill "Remplit aussi les aplats sombres avec des caractères denses, au lieu de ne tracer que les contours."
[void](Add-Label $pnlAsc 'Palette des courbes et détails')
$cmbPal = New-Object Windows.Forms.ComboBox
$cmbPal.DropDownStyle = 'DropDownList'; $cmbPal.SetBounds(10, $script:y, 265, 24)
[void]$cmbPal.Items.AddRange(@($palettes.Keys))
$pnlAsc.Controls.Add($cmbPal); $script:y += 30
$txtChars = New-Object Windows.Forms.TextBox
$txtChars.SetBounds(10, $script:y, 265, 24); $txtChars.Font = New-Object Drawing.Font('Consolas', 10)
$txtChars.Text = $palettes['Courbes (défaut)']
$pnlAsc.Controls.Add($txtChars); $script:y += 34
$script:syncing = $false
$cmbPal.Add_SelectedIndexChanged({
    $v = $palettes[[string]$cmbPal.SelectedItem]
    if ($null -ne $v) { $script:syncing = $true; $txtChars.Text = $v; $script:syncing = $false }
})
$txtChars.Add_TextChanged({
    if (-not $script:syncing) {
        $name = ($palettes.Keys | Where-Object { $palettes[$_] -ceq $txtChars.Text } | Select-Object -First 1)
        $script:syncing = $true
        $cmbPal.SelectedItem = if ($name) { $name } else { 'Personnalisée' }
        $script:syncing = $false
    }
    Request-Work $script:asc
})
$cmbPal.SelectedIndex = 0
Set-Tip $cmbPal "Caractères utilisés pour les courbes et petits détails (choisis par ressemblance de forme).`nLes traits droits - _ | / \ < > ^ v ┌ ┐ └ ┘ sont gérés à part par la géométrie du contour : ils ne font pas partie de cette palette (même s'ils y figurent, ils sont ignorés). 'Traits droits seuls' = aucune courbe."
Set-Tip $txtChars "Caractères autorisés (modifiable librement ; la palette passe alors en « Personnalisée »)."

$numFont = Add-Number $pnlAsc 'Taille de police' 3 24 7 $script:asc
Set-Tip $numFont "Taille de la police d'affichage uniquement ; ne change pas le texte généré."
$numFont.Add_ValueChanged({ $txt.Font = New-Object Drawing.Font('Consolas', [single]$numFont.Value) })

$btnCopy = New-Object Windows.Forms.Button
$btnCopy.Text = 'Copier'; $btnCopy.SetBounds(10, $script:y, 125, 28)
$btnSave = New-Object Windows.Forms.Button
$btnSave.Text = 'Enregistrer .txt'; $btnSave.SetBounds(150, $script:y, 125, 28)
$pnlAsc.Controls.AddRange(@($btnCopy, $btnSave)); $script:y += 36
$lblAscStatus = Add-Label $pnlAsc ''
$lblAscStatus.Height = 36
$script:asc.Status = $lblAscStatus

$txt = New-Object Windows.Forms.TextBox
$txt.Multiline = $true; $txt.ReadOnly = $true; $txt.WordWrap = $false
$txt.ScrollBars = 'Both'; $txt.Dock = 'Fill'; $txt.Font = New-Object Drawing.Font('Consolas', 7)
$txt.BackColor = [Drawing.Color]::White
$tabAsc.Controls.Add($txt); $txt.BringToFront()

# ---------- Actions ----------
function Open-Image([string]$p) {
    try {
        $bytes = [IO.File]::ReadAllBytes($p)
        $ms = New-Object IO.MemoryStream(, $bytes)
        $tmp = [Drawing.Image]::FromStream($ms)
        $copy = New-Object Drawing.Bitmap $tmp
        $tmp.Dispose(); $ms.Dispose()
    } catch { [void][Windows.Forms.MessageBox]::Show("Image illisible : $p"); return }
    if ($script:orig) { $script:orig.Dispose() }
    $script:orig = $copy
    $script:sourceGeneration++
    foreach ($step in $script:steps) { if ($step.Editor) { $step.Editor.Reset() } }
    $script:asc.Revision++
    if ($script:preResult) { $script:preResult.Dispose(); $script:preResult = $null }
    $script:preBmp = $null; $script:previewBmp = $null
    $script:lines = @(); $txt.Clear()
    Update-Picture
    if ($script:brushTools.Count) { Update-MaskPicture }
    $script:file = $p
    $lblFile.Text = $p
    Invoke-Work $script:pre
}
$btnOpen.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Filter = 'Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|Tous|*.*'
    if ($d.ShowDialog() -eq 'OK') { Open-Image $d.FileName }
})
$form.Add_DragEnter({ if ($_.Data.GetDataPresent('FileDrop')) { $_.Effect = 'Copy' } })
$form.Add_DragDrop({ Open-Image ($_.Data.GetData('FileDrop')[0]) })
$btnCopy.Add_Click({ if ($txt.Text) { [Windows.Forms.Clipboard]::SetText($txt.Text) } })
$btnSave.Add_Click({
    $d = New-Object Windows.Forms.SaveFileDialog
    $d.Filter = 'Texte|*.txt'
    if ($d.ShowDialog() -eq 'OK') { [IO.File]::WriteAllText($d.FileName, $txt.Text, (New-Object Text.UTF8Encoding $true)) }
})
$btnSavePre.Add_Click({
    if (-not $script:preBmp) { return }
    $d = New-Object Windows.Forms.SaveFileDialog
    $d.Filter = 'PNG|*.png'
    if ($d.ShowDialog() -eq 'OK') {
        $script:preBmp.Save($d.FileName, [Drawing.Imaging.ImageFormat]::Png)
        $maskPath = Join-Path (Split-Path $d.FileName) ([IO.Path]::GetFileNameWithoutExtension($d.FileName) + '_mask.png')
        $script:preResult.Mask.Save($maskPath, [Drawing.Imaging.ImageFormat]::Png)
        $lblPreStatus.Text = "Image enregistrée avec son masque : $maskPath"
    }
})

# ---------- Boucle de scrutation des workers ----------
$poll = New-Object Windows.Forms.Timer
$poll.Interval = 100
$poll.Add_Tick({
    Complete-Work $script:pre
    Complete-Work $script:asc
    if ($Screenshot -and -not $script:shotDone -and $script:lines.Count -gt 0 -and -not $script:pre.Job -and -not $script:asc.Job -and -not $script:pre.Timer.Enabled -and -not $script:asc.Timer.Enabled) {
        $script:shotDone = $true
        $tabs.SelectedIndex = $Tab
        $form.Refresh()
        $bmp = New-Object Drawing.Bitmap $form.Width, $form.Height
        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $form.Width, $form.Height))
        $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        $form.Close()
    }
})
$poll.Start()

$form.Add_Shown({ if ($Path) { Open-Image (Resolve-Path $Path).Path } })
$form.Add_FormClosed({
    $poll.Stop(); $poll.Dispose()
    foreach ($worker in @($script:pre, $script:asc)) {
        $worker.Timer.Stop(); $worker.Timer.Dispose()
        if ($worker.Job) {
            $worker.Job.Ps.Stop()
            # A completed but unpolled result still owns bitmaps.
            try {
                $pending = $worker.Job.Ps.EndInvoke($worker.Job.Handle)
                foreach ($item in $pending) { if ($item -is [IDisposable]) { $item.Dispose() } }
            } catch { }
            $worker.Job.Ps.Dispose()
        }
    }
    $script:preCache.Dispose()
    foreach ($image in @($script:orig, $pic.Image)) {
        if ($image) { $image.Dispose() }
    }
    if ($script:preResult) { $script:preResult.Dispose() }
    foreach ($step in $script:steps) { if ($step.Editor) { $step.Editor.Dispose() } }
})
[void]$form.ShowDialog()
