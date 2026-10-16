# Interface du plugin Bords ; moteur : AsciiArtEdges.ps1 dans ce dossier.
Register-AsciiStepTool @{
    Kind = 'E'; Button = '+ Bords'; Label = 'Lissage des bords : rayon {0}'
    Minimum = 1; Maximum = 6; ValueLabel = 'Rayon de lissage : {0}'
    Tip = "Lissage par couleur majoritaire, sans flou ni mélange de couleurs.`nUn rayon plus grand arrondit davantage les formes. À placer après des aplats."
    SliderTip = 'Rayon du voisinage en pixels (1 à 6).'
    Create = { @{ Kind = 'E'; Value = 2.0 } }
}
