<#
  Interface à deux onglets :
    1. Prétraitement (AsciiArtPreProcess.ps1)  : lissage, posterisation, fond blanc
    2. ASCII         (AsciiArtConverter.ps1)    : conversion de l'image prétraitée
  Chaque changement de paramètre recalcule automatiquement la vue.
  Usage : .\AsciiArtGUI.ps1 [-Path image.png]
  Test  : .\AsciiArtGUI.ps1 -Path img.png -Screenshot out.png [-Tab 0|1]
#>
param(
    [string]$Path,
    [string]$Screenshot,
    [int]$Tab = 1
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# ---------- Chargement des moteurs C# ----------
function Import-Engine([string]$file, [string]$class) {
    $text = Get-Content (Join-Path $PSScriptRoot $file) -Raw -Encoding UTF8
    $m = [regex]::Match($text, "(?s)\`$code = @'\r?\n(.*?)\r?\n'@")
    if (-not $m.Success) { throw "Moteur introuvable dans $file" }
    $code = $m.Groups[1].Value
    $md5  = [Security.Cryptography.MD5]::Create()
    $hash = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($code))[0..5] | ForEach-Object { $_.ToString('x2') })
    $tn = "${class}_$hash"
    if (-not ($tn -as [type])) {
        Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $code.Replace($class, $tn)
    }
    return $tn
}
$preType = Import-Engine 'AsciiArtPreProcess.ps1' 'PreProcessor'
$ascType = Import-Engine 'AsciiArtConverter.ps1' 'AsciiEdge'

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
    $w = @{ Work = $work; GetArgs = $getArgs; OnDone = $onDone; Job = $null; Dirty = $false; Status = $null }
    $t = New-Object Windows.Forms.Timer
    $t.Interval = 350
    $t.Tag = $w
    $t.Add_Tick({ $this.Stop(); Invoke-Work $this.Tag })
    $w.Timer = $t
    return $w
}
function Request-Work($w) { $w.Timer.Stop(); $w.Timer.Start() }
function Invoke-Work($w) {
    if ($w.Job) { $w.Dirty = $true; return }
    $jobArgs = & $w.GetArgs
    if ($null -eq $jobArgs) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($w.Work)
    foreach ($a in $jobArgs) { [void]$ps.AddArgument($a) }
    $w.Job = @{ Ps = $ps; Handle = $ps.BeginInvoke(); Watch = [Diagnostics.Stopwatch]::StartNew() }
    if ($w.Status) { $w.Status.Text = 'Calcul en cours...' }
}
function Complete-Work($w) {
    $j = $w.Job
    if (-not $j -or -not $j.Handle.IsCompleted) { return }
    $w.Job = $null
    try {
        $res = $j.Ps.EndInvoke($j.Handle)
        if ($j.Ps.Streams.Error.Count -gt 0) { throw $j.Ps.Streams.Error[0].ToString() }
        & $w.OnDone $res $j.Watch.Elapsed.TotalSeconds
    } catch {
        if ($w.Status) { $w.Status.Text = "Erreur : $($_.Exception.Message)" }
    }
    $j.Ps.Dispose()
    if ($w.Dirty) { $w.Dirty = $false; Invoke-Work $w }
}

$preWork = {
    param($tn, $path, $maxSize, $white, $steps)
    ($tn -as [type])::Run($path, $maxSize, $white, $steps)
}
$ascWork = {
    param($tn, $bmp, $w, $h, $detail, $smooth, $minSize, $invert, $fill, $chars, $straight)
    try { ($tn -as [type])::Run($bmp, $w, $h, $detail, $smooth, $minSize, $invert, $fill, $chars, $straight) }
    finally { $bmp.Dispose() }
}

$script:file   = $null
$script:orig   = $null   # image d'origine
$script:preBmp = $null   # résultat du prétraitement
$script:lines  = @()
$script:shotDone = $false

# ---------- Fenêtre ----------
$form = New-Object Windows.Forms.Form
$form.Text = 'ASCII Art - Prétraitement et conversion'
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
    @($preType, $script:file, [int]$numMax.Value, [int]$numWhite.Value, (Get-Steps))
} {
    param($res, $secs)
    if ($script:preBmp) { $script:preBmp.Dispose() }
    $script:preBmp = [Drawing.Bitmap]$res[0]
    Update-Picture
    $script:pre.Status.Text = ('Prétraitement : {0}x{1} en {2:N2} s' -f $script:preBmp.Width, $script:preBmp.Height, $secs)
    Invoke-Work $script:asc
}

$pnlPre = New-SidePanel $tabPre
$numMax   = Add-Number $pnlPre 'Taille max (px, plus grand côté)' 100 4000 800 $script:pre
$numWhite = Add-Number $pnlPre 'Seuil du fond blanc (200-255)' 200 255 250 $script:pre
Set-Tip $numMax "Taille de travail : le plus grand côté de l'image est ramené à cette valeur (jamais agrandie).`nPlus petit = plus rapide et plus de lissage naturel ; plus grand = contours plus fins mais plus de détails parasites."
Set-Tip $numWhite "Un pixel dont R, V et B sont tous >= ce seuil est considéré comme fond : remis en blanc pur et jamais lissé ni mélangé au sujet.`nBaisser le seuil supprime les ombres et reflets très clairs, mais peut avaler un sujet clair. 255 = seul le blanc pur est du fond."

# Liste d'étapes d'aplats appliquées dans l'ordre (en nombre quelconque)
[void](Add-Label $pnlPre 'Étapes (appliquées de haut en bas) :')
$lstSteps = New-Object Windows.Forms.ListBox
$lstSteps.SetBounds(10, $script:y, 265, 110); $lstSteps.IntegralHeight = $false
$pnlPre.Controls.Add($lstSteps); $script:y += 116
$btnAddL = New-Object Windows.Forms.Button; $btnAddL.Text = '+ Aplats'; $btnAddL.SetBounds(10, $script:y, 85, 26)
$btnAddE = New-Object Windows.Forms.Button; $btnAddE.Text = '+ Bords'; $btnAddE.SetBounds(100, $script:y, 85, 26)
$btnDel  = New-Object Windows.Forms.Button; $btnDel.Text  = 'Supprimer'; $btnDel.SetBounds(190, $script:y, 85, 26)
$pnlPre.Controls.AddRange(@($btnAddL, $btnAddE, $btnDel)); $script:y += 30
$btnUp   = New-Object Windows.Forms.Button; $btnUp.Text = [string][char]0x25B2 + ' Monter';  $btnUp.SetBounds(10, $script:y, 130, 26)
$btnDown = New-Object Windows.Forms.Button; $btnDown.Text = [string][char]0x25BC + ' Descendre'; $btnDown.SetBounds(145, $script:y, 130, 26)
$pnlPre.Controls.AddRange(@($btnUp, $btnDown)); $script:y += 34
$lblStep = Add-Label $pnlPre 'Sélectionnez une étape pour régler sa valeur'
$tbStep = New-Object Windows.Forms.TrackBar
$tbStep.SetBounds(5, $script:y, 275, 40); $tbStep.Enabled = $false
$pnlPre.Controls.Add($tbStep); $script:y += 46

Set-Tip $lstSteps "Chaque ligne est une étape d'aplats ; l'ordre compte (6 niveaux puis 3 n'est pas pareil que 3 puis 6) et on peut en empiler plusieurs.`nListe vide = image simplement redimensionnée, fond détecté."
Set-Tip $btnAddL "Ajoute une étape d'aplats : la luminosité est réduite à N paliers et chaque zone devient une couleur unie, sans dégradé ni taches isolées.`n2-3 = très graphique, gros aplats ; 5-8 = transitions plus douces.`nEmpiler plusieurs étapes simplifie progressivement l'image."
Set-Tip $btnAddE "Ajoute un lissage des bords : chaque pixel prend la couleur majoritaire de son voisinage, sans flou ni mélange de couleurs.
Supprime les petites pointes et dentelures des aplats ; plus le rayon est grand, plus les formes sont arrondies et simplifiées.
À placer après une étape d'Aplats (sur une image non aplatie, il ne change presque rien)."
Set-Tip $btnDel "Retire l'étape sélectionnée."
Set-Tip $btnUp "Remonte l'étape sélectionnée (appliquée plus tôt)."
Set-Tip $btnDown "Descend l'étape sélectionnée (appliquée plus tard)."
Set-Tip $tbStep "Aplats : nombre de paliers de luminosité (2 à 12).
Bords : rayon du voisinage en pixels (1 à 6)."

$script:steps = New-Object Collections.ArrayList
[void]$script:steps.Add(@{ Kind = 'L'; Value = 4.0 })
$script:loading = $false
function Get-Steps {
    ($script:steps | ForEach-Object { '{0}{1}' -f $_.Kind, ([string]$_.Value).Replace(',', '.') }) -join ','
}
function Get-StepText($st) {
    if ($st.Kind -eq 'E') { 'Lissage des bords : rayon {0}' -f [int]$st.Value } else { 'Aplats : {0} niveaux' -f [int]$st.Value }
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
    if ($i -lt 0) { $tbStep.Enabled = $false; $lblStep.Text = 'Sélectionnez une étape pour régler sa valeur' }
    else {
        $st = $script:steps[$i]
        $tbStep.Enabled = $true
        if ($st.Kind -eq 'E') { $tbStep.Minimum = 1; $tbStep.Maximum = 6 } else { $tbStep.Minimum = 2; $tbStep.Maximum = 12 }
        $tbStep.Value = [int]$st.Value; $tbStep.TickFrequency = 1
        $lblStep.Text = if ($st.Kind -eq 'E') { 'Rayon de lissage : {0}' -f [int]$st.Value } else { 'Nombre de niveaux : {0}' -f [int]$st.Value }
    }
    $script:loading = $false
}
$lstSteps.Add_SelectedIndexChanged({ if (-not $script:loading) { Show-StepEditor } })
$tbStep.Add_ValueChanged({
    if ($script:loading) { return }
    $i = $lstSteps.SelectedIndex; if ($i -lt 0) { return }
    $st = $script:steps[$i]
    $st.Value = [double]$tbStep.Value
    $lblStep.Text = if ($st.Kind -eq 'E') { 'Rayon de lissage : {0}' -f [int]$st.Value } else { 'Nombre de niveaux : {0}' -f [int]$st.Value }
    $script:loading = $true; $lstSteps.Items[$i] = '{0}. {1}' -f ($i + 1), (Get-StepText $st); $script:loading = $false
    Request-Work $script:pre
})
$btnAddL.Add_Click({ [void]$script:steps.Add(@{ Kind = 'L'; Value = 4.0 }); Update-StepList ($script:steps.Count - 1); Request-Work $script:pre })
$btnAddE.Add_Click({ [void]$script:steps.Add(@{ Kind = 'E'; Value = 2.0 }); Update-StepList ($script:steps.Count - 1); Request-Work $script:pre })
$btnDel.Add_Click({
    $i = $lstSteps.SelectedIndex; if ($i -lt 0) { return }
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
    $old = $pic.Image
    $pic.Image = if ($src) { New-Object Drawing.Bitmap $src } else { $null }
    if ($old) { $old.Dispose() }
}

# ---------- Onglet 2 : ASCII ----------
$script:asc = New-Worker $ascWork {
    if (-not $script:preBmp) { return $null }
    @($ascType, (New-Object Drawing.Bitmap $script:preBmp), [int]$numW.Value, [int]$numH.Value,
      [double]($tbDetail.Value / 100), $(if ($script:blurOn) { [double]($tbSmooth.Value / 10) } else { 0.0 }), [double]($tbMin.Value / 2),
      [bool]$chkInv.Checked, [bool]$chkFill.Checked, [string]$txtChars.Text, [double]($tbStraight.Value / 100))
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
    if ($d.ShowDialog() -eq 'OK') { $script:preBmp.Save($d.FileName, [Drawing.Imaging.ImageFormat]::Png) }
})

# ---------- Boucle de scrutation des workers ----------
$poll = New-Object Windows.Forms.Timer
$poll.Interval = 100
$poll.Add_Tick({
    Complete-Work $script:pre
    Complete-Work $script:asc
    if ($Screenshot -and -not $script:shotDone -and $script:lines.Count -gt 0 -and -not $script:pre.Job -and -not $script:asc.Job) {
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
$form.Add_FormClosed({ $poll.Stop() })
[void]$form.ShowDialog()
