# Chargeur commun des moteurs C# (Windows PowerShell 5.1, Add-Type) : à dot-sourcer ; sans paramètre ni effet de bord : définit seulement Get-AsciiEngineBlock et Import-AsciiEngine.
#   . (Join-Path $PSScriptRoot 'AsciiArtPluginCompilator.ps1')
#   $type = Import-AsciiEngine -File 'AsciiArtPreProcess.ps1' -Class 'PreProcessor' [-Root <dossier>]   # -> 'AsciiEngine_<hash>.PreProcessor'
# Les fichiers moteurs sont seulement lus (jamais exécutés) : leurs param() obligatoires ne sont pas sollicités.
#   ($type -as [type])::Run(...)
# Organisation : un fichier .ps1 par traitement ; le C# de chaque fichier est le bloc  $code = @' ... '@  qu'il contient.
# Dépendances : lignes  // @requires <Fichier.ps1>  dans ce bloc (chemins relatifs au dossier des moteurs).
# Tous les blocs de la fermeture des dépendances sont compilés ensemble (ordre : dépendances d'abord) dans un espace
# de noms AsciiEngine_<hash des sources> : chaque classe, y compris les types de retour (PreProcessResult...), est unique
# par version du code, rechargeable dans la même session, et les références entre moteurs n'ont besoin d'aucun remplacement.

# Exécution directe (au lieu du dot-sourcing) : les fonctions seraient perdues à la sortie du script -> avertir.
if ($MyInvocation.InvocationName -ne '.') {
    Write-Warning "AsciiArtPluginCompilator.ps1 est une bibliothèque : chargez-la par dot-sourcing  . '$PSCommandPath'"
}

function Get-AsciiEngineBlock {
    # Lit le bloc C# d'un fichier moteur : renvoie @{ Path; Name; Code; Line (ligne du .ps1 où commence le code); Requires }
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Moteur introuvable : $Path" }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $m = [regex]::Match($text, "(?s)\`$code\s*=\s*@'\r?\n(.*?)\r?\n'@")
    if (-not $m.Success) { throw "Bloc `$code = @'...'@ introuvable dans $Path" }
    $code = $m.Groups[1].Value
    $line = ([regex]::Matches($text.Substring(0, $m.Groups[1].Index), "\n")).Count + 1
    $requires = @([regex]::Matches($code, '(?m)^\s*//\s*@requires\s+(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value })
    @{ Path = $Path; Name = [IO.Path]::GetFileName($Path); Code = $code; Line = $line; Requires = $requires }
}

function Import-AsciiEngine {
    <#
      Compile (une seule fois par version du code) le moteur -File et toutes ses dépendances, puis renvoie le nom complet
      de la classe -Class, utilisable avec ($nom -as [type]) ou New-Object $nom. Les erreurs (fichier, dépendance
      circulaire, compilation, classe absente) sont levées comme exceptions.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Class,
        [string]$Root                      # dossier des moteurs (défaut : dossier de AsciiArtPluginCompilator.ps1)
    )
    # Dans une fonction, $PSScriptRoot désigne le fichier qui la définit : aucun état global n'est nécessaire.
    $engineDir = if ($Root) { [IO.Path]::GetFullPath($Root) } else { $PSScriptRoot }
    $blocks = New-Object 'Collections.Generic.List[hashtable]'
    $state = @{}
    $stack = New-Object 'Collections.Generic.List[string]'

    function Add-Block([string]$p) {
        $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $engineDir $p }))
        $key = $full.ToLowerInvariant()
        if ($state[$key] -eq 'done') { return }
        if ($state[$key] -eq 'visiting') { throw "Dépendance circulaire entre moteurs : $((@($stack) + $full) -join ' -> ')" }
        $state[$key] = 'visiting'; $stack.Add($full)
        $block = Get-AsciiEngineBlock $full
        foreach ($dep in $block.Requires) { Add-Block $dep }
        $stack.RemoveAt($stack.Count - 1); $state[$key] = 'done'
        $blocks.Add($block)
    }
    Add-Block $File

    # Les directives using sont remontées en tête (remplacées par des lignes vides pour garder les numéros de ligne)
    $usingRe = '(?m)^[ \t]*using[ \t]+(?:[A-Za-z_]\w*[ \t]*=[ \t]*)?[A-Za-z_][\w.]*[ \t]*;[ \t]*\r?$'
    $usings = New-Object 'Collections.Generic.List[string]'
    $body = New-Object Text.StringBuilder
    foreach ($b in $blocks) {
        foreach ($u in [regex]::Matches($b.Code, $usingRe)) {
            $s = $u.Value.Trim()
            if (-not $usings.Contains($s)) { $usings.Add($s) }
        }
        $code = [regex]::Replace($b.Code, $usingRe, '')
        [void]$body.AppendLine(('#line {0} "{1}"' -f $b.Line, $b.Name)).AppendLine($code)
    }
    [void]$body.AppendLine('#line default')
    $sources = ($usings -join "`n") + "`n" + $body.ToString()
    $md5 = [Security.Cryptography.MD5]::Create()
    try { $hash = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($sources))[0..7] | ForEach-Object { $_.ToString('x2') }) }
    finally { $md5.Dispose() }
    $ns = "AsciiEngine_$hash"
    $typeName = "$ns.$Class"
    if (-not ($typeName -as [type])) {
        # Marqueur : distingue "espace déjà compilé sans cette classe" de "pas encore compilé"
        $unit = ($usings -join "`r`n") + "`r`nnamespace $ns`r`n{`r`n" + $body.ToString() + "public static class AsciiEngineMarker { }`r`n}`r`n"
        if (-not ("$ns.AsciiEngineMarker" -as [type])) {
            Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $unit -ErrorAction Stop
        }
        if (-not ($typeName -as [type])) { throw "Classe '$Class' introuvable dans $File et ses dépendances" }
    }
    return $typeName
}