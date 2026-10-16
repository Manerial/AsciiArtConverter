# Interface du plugin Aplats ; moteur : AsciiArtPosterize.ps1 dans ce dossier.
Register-AsciiStepTool @{
    Kind = 'L'; Button = '+ Aplats'; Label = 'Aplats : {0} niveaux'
    Minimum = 2; Maximum = 12; ValueLabel = 'Nombre de niveaux : {0}'; Default = $true
    Tip = "Réduit la luminosité en aplats de couleur unie.`n2-3 = graphique ; 5-8 = transitions plus douces. Les étapes peuvent être empilées."
    SliderTip = 'Nombre de paliers de luminosité (2 à 12).'
    Create = { @{ Kind = 'L'; Value = 4.0 } }
}
