# Interface du plugin Gomme ; moteur : AsciiArtEraser.ps1 dans ce dossier.
Register-AsciiBrushTool @{
    Name = 'Gomme'; Text = 'Gomme : redéfinit les contours'; ToolId = 1
    Kind = 'G'; Button = '+ Gomme'; Label = 'Gomme'
    StepTip = 'Ajoute une étape Gomme indépendante, appliquée avant les étapes suivantes.'
    Color = [Drawing.Color]::DarkOrange
    Tip = 'Orange : remplace les pixels par du blanc. Les bords de la gomme deviennent de vrais contours.'
    Status = 'Orange = gomme.'
    RestoreText = 'Restaurer la gomme'
    RestoreTip = 'Retire uniquement les marques de gomme de cette étape.'
    OverlayLabel = 'de la gomme'
    ResetText = 'Réinitialiser la gomme'
    SaveImage = @{ Text = "Enregistrer l'image gommée..."; Filter = 'Image gommée PNG|*.png' }
}
