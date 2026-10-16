# Interface du plugin Masque ; moteur : AsciiArtExclusion.ps1 dans ce dossier.
Register-AsciiBrushTool @{
    Name = 'Masque'; Text = 'Masque : ne pas dessiner'; ToolId = 2
    Kind = 'X'; Button = '+ Masque'; Label = 'Masque'
    StepTip = 'Ajoute une étape Masque indépendante, appliquée avant les étapes suivantes.'
    Color = [Drawing.Color]::DarkMagenta
    Tip = "Magenta : exclut les pixels des traitements suivants sans blanchir leur couleur ni créer de contour.`nInterdit les caractères ASCII dans les cellules touchées, remplissage compris."
    Status = 'Magenta = exclusion.'
    RestoreText = 'Restaurer le masque'
    RestoreTip = 'Retire uniquement les exclusions de cette étape.'
    OverlayLabel = 'du masque'
    ResetText = 'Réinitialiser le masque'
}
