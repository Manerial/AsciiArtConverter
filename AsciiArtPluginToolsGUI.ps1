# Infrastructure GUI des plugins : les moteurs C# et leurs interfaces CLI restent indépendants.
# Les scripts plugin\<nom>\AsciiArtTool*.ps1 déclarent chacun leur bouton, leurs paramètres et leur action.
$script:stepTools = [ordered]@{}
$script:brushTools = [ordered]@{}
$script:brushButtonGroups = @{}
$script:brushActionButtons = @{}

function Register-AsciiStepTool([hashtable]$tool) {
    $script:stepTools[$tool.Kind] = $tool
}
function Register-AsciiBrushTool([hashtable]$tool) {
    $script:brushTools[$tool.Name] = $tool
    $brushName = $tool.Name
    Register-AsciiStepTool @{
        Kind = $tool.Kind; Button = $tool.Button; Label = $tool.Label
        Tip = $tool.StepTip; BrushTool = $brushName
        Create = { param($descriptor) New-AsciiBrushStep $descriptor.BrushTool }
    }
}
function New-AsciiBrushStep([string]$toolName) {
    $editor = New-Object $brushType
    $editor.SetToolEnabled(1, $false)
    $editor.SetToolEnabled(2, $false)
    $tool = $script:brushTools[$toolName]
    $editor.SetToolEnabled($tool.ToolId, $true)
    @{ Kind = $tool.Kind; BrushTool = $toolName; Editor = $editor }
}
function Add-AsciiStepButtons($parent) {
    $index = 0
    foreach ($tool in $script:stepTools.Values) {
        $button = New-Object Windows.Forms.Button
        $button.Text = $tool.Button
        $button.SetBounds((10 + ($index % 3) * 90), ($script:y + [int][math]::Floor($index / 3) * 30), 85, 26)
        $button.Tag = $tool
        Set-Tip $button $tool.Tip
        $button.Add_Click({
            $step = & $this.Tag.Create $this.Tag
            if ($null -eq $step -or -not $step.Kind -or -not $script:stepTools.Contains($step.Kind)) {
                [void][Windows.Forms.MessageBox]::Show("Impossible de créer l'étape : $($this.Tag.Label)")
                return
            }
            [void]$script:steps.Add($step)
            Update-StepList ($script:steps.Count - 1)
            Request-Work $script:pre
        })
        $parent.Controls.Add($button)
        $index++
    }
    $script:y += [int][math]::Ceiling($index / 3) * 30
}
function Get-AsciiBrush {
    if (-not $script:maskEditor -or -not $script:activeBrushTool) { return $null }
    foreach ($button in $script:brushButtonGroups[$script:activeBrushTool].Buttons) {
        if ($button.Checked) { return $button.Tag }
    }
    return $null
}
function Add-AsciiBrushButtons($parent) {
    $script:brushButtonGroups = @{}
    foreach ($tool in $script:brushTools.Values) {
        $group = New-Object Windows.Forms.GroupBox
        $group.Text = $tool.Label; $group.SetBounds(5, $script:y, 275, 58)
        $parent.Controls.Add($group); $script:y += 60
        $brush = New-Object Windows.Forms.RadioButton
        $brush.Text = $tool.Text; $brush.ForeColor = $tool.Color
        $brush.Tag = @{ Name = $tool.Name; ToolId = $tool.ToolId; Color = $tool.Color }
        $brush.SetBounds(8, 14, 255, 20)
        $group.Controls.Add($brush)
        Set-Tip $brush $tool.Tip
        $brush.Add_CheckedChanged({
            $script:maskDrawing = $false; $script:maskPoint = $null
            if ($maskPic) { $maskPic.Capture = $false; $maskPic.Invalidate() }
        })

        $restore = New-Object Windows.Forms.RadioButton
        $restore.Text = $tool.RestoreText; $restore.ForeColor = $tool.Color
        $restore.Tag = @{ Name = $tool.Name; ToolId = 0; Restore = $true; Color = $tool.Color }
        $restore.SetBounds(8, 34, 255, 20)
        $group.Controls.Add($restore)
        Set-Tip $restore $tool.RestoreTip
        $restore.Add_CheckedChanged({
            $script:maskDrawing = $false; $script:maskPoint = $null
            if ($maskPic) { $maskPic.Capture = $false; $maskPic.Invalidate() }
        })
        $script:brushButtonGroups[$tool.Name] = @{ Panel = $group; Buttons = @($brush, $restore) }
        $brush.Checked = $true
    }
}
function Add-AsciiBrushActions($parent) {
    foreach ($tool in $script:brushTools.Values) {
        if (-not $tool.SaveImage) { continue }
        $button = New-Object Windows.Forms.Button
        $button.Text = $tool.SaveImage.Text; $button.Tag = $tool
        $button.SetBounds(10, $script:y, 265, 28)
        $parent.Controls.Add($button); $script:y += 36
        $button.Visible = $false
        $script:brushActionButtons[$tool.Name] = $button
        $button.Add_Click({
            if (-not $script:previewBmp -or -not $script:maskEditor -or $script:activeBrushTool -ne $this.Tag.Name) { return }
            $d = New-Object Windows.Forms.SaveFileDialog
            $d.Filter = $this.Tag.SaveImage.Filter
            if ($d.ShowDialog() -eq 'OK') {
                $marks = $script:maskEditor.Rasterize($script:previewBmp.Width, $script:previewBmp.Height)
                try {
                    $image = ($rasterMaskType -as [type])::Apply($script:previewBmp, $marks, $false)
                    try { $image.Save($d.FileName, [Drawing.Imaging.ImageFormat]::Png) }
                    finally { $image.Dispose() }
                } finally { $marks.Dispose() }
            }
            $d.Dispose()
        })
    }
}
