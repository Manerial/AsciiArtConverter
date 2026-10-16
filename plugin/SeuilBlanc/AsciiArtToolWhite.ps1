# Interface du plugin SeuilBlanc ; moteur : AsciiArtWhite.ps1 dans ce dossier.
Register-AsciiStepTool @{
    Kind = 'W'; Button = '+ Seuil blanc'; Label = 'Seuil blanc : {0}'
    Minimum = 200; Maximum = 255; ValueLabel = 'Seuil du fond blanc : {0}'; Default = $true
    Tip = 'Détecte le fond à cette étape : R, V et B au-dessus du seuil deviennent blancs. Les pixels exclus restent intacts.'
    SliderTip = '200 à 255. Baisser le seuil élimine les tons très clairs ; 255 ne détecte que le blanc pur.'
    Create = { @{ Kind = 'W'; Value = 250 } }
}
