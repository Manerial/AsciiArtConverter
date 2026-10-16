# Interface du plugin Taille ; moteur : AsciiArtSize.ps1 dans ce dossier.
Register-AsciiStepTool @{
    Kind = 'S'; Button = '+ Taille'; Label = 'Taille : {0} px maximum'
    Minimum = 100; Maximum = 4000; TickFrequency = 100
    ValueLabel = 'Côté le plus long : {0} px'; Default = $true
    Tip = 'Réduit la taille à cette étape (jamais agrandie). Les retouches déjà appliquées sont conservées.'
    SliderTip = 'Taille maximale (100 à 4000 pixels). Une taille plus petite accélère les étapes suivantes.'
    Create = { @{ Kind = 'S'; Value = 800 } }
}
