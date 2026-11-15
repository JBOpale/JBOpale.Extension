# Contrôle de la couverture de code (règle de Jérôme, voir l'en-tête de pr-tests.yml) :
#  1. Code ajouté / modifié par la PR : au moins 90 % des lignes couvrables doivent être couvertes.
#  2. Couverture globale des lignes : jamais sous lineCoverage de tests/coverage-baseline.json.
# Compatible PowerShell 7 et Windows PowerShell 5.1.
#
# Usage :
#   pwsh .github/scripts/Test-Coverage.ps1 -ReportsPath TestResults -BaseRef origin/dev   # PR
#   pwsh .github/scripts/Test-Coverage.ps1 -ReportsPath TestResults                       # règle globale seule
# Ne jamais baisser le seuil, la référence, ni exclure du code pour faire passer une PR.
param(
    [string]$ReportsPath = "TestResults",
    [string]$BaseRef = "",
    [string]$BaselineFile = "tests/coverage-baseline.json",
    [double]$Threshold = 90
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Get-NormalizedPath([string]$Path) {
    return ($Path -replace '\\', '/')
}

function Write-Summary([string]$Text) {
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Text -Encoding UTF8 }
}

$repoRoot = Get-NormalizedPath ((git rev-parse --show-toplevel) | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { Write-Host "::error::Dépôt git introuvable."; exit 1 }
$repoRoot = $repoRoot.TrimEnd('/')

function Get-RepoRelativePath([string]$FullPath) {
    $p = Get-NormalizedPath ([System.IO.Path]::GetFullPath($FullPath))
    $prefix = $repoRoot + '/'
    if ($p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $p.Substring($prefix.Length) }
    return $p
}

# --- 1. Fusion des rapports Cobertura -------------------------------------------------------
$reports = @()
if (Test-Path $ReportsPath) {
    $reports = @(Get-ChildItem -Path $ReportsPath -Recurse -File -Filter "*.cobertura.xml")
}
if ($reports.Count -eq 0) {
    Write-Host "::error::Aucun rapport de couverture Cobertura trouvé sous '$ReportsPath'."
    exit 1
}

# fichier relatif au dépôt -> (numéro de ligne -> couverte ?). Une ligne est couverte si hits > 0 dans au moins un rapport.
$coverage = @{}
foreach ($report in $reports) {
    Write-Host "Rapport : $($report.FullName)"
    [xml]$xml = Get-Content -Path $report.FullName -Raw -Encoding UTF8
    $sources = @()
    if ($xml.coverage.SelectSingleNode('sources')) {
        $sources = @($xml.coverage.sources.SelectNodes('source') | ForEach-Object { $_.InnerText })
    }
    foreach ($class in $xml.SelectNodes('//class')) {
        $filename = $class.GetAttribute('filename')
        $full = $null
        if ([System.IO.Path]::IsPathRooted($filename)) {
            $full = $filename
        } else {
            foreach ($s in $sources) {
                $candidate = Join-Path $s $filename
                if (Test-Path $candidate) { $full = $candidate; break }
            }
            if (-not $full -and $sources.Count -gt 0) { $full = Join-Path $sources[0] $filename }
            if (-not $full) { $full = Join-Path $repoRoot $filename }
        }
        $rel = Get-RepoRelativePath $full
        if (-not $coverage.ContainsKey($rel)) { $coverage[$rel] = @{} }
        $lines = $coverage[$rel]
        foreach ($line in $class.SelectNodes('.//line')) {
            $n = [int]$line.GetAttribute('number')
            $covered = ([long]$line.GetAttribute('hits')) -gt 0
            if ($lines.ContainsKey($n)) { $lines[$n] = $lines[$n] -or $covered } else { $lines[$n] = $covered }
        }
    }
}

# --- 2. Couverture globale ---------------------------------------------------------------
$total = 0; $totalCovered = 0
foreach ($file in $coverage.Keys) {
    foreach ($v in $coverage[$file].Values) { $total++; if ($v) { $totalCovered++ } }
}
if ($total -eq 0) { Write-Host "::error::Les rapports ne contiennent aucune ligne couvrable."; exit 1 }
$globalPct = [math]::Round(100.0 * $totalCovered / $total, 2)

$baseline = 0.0
$baselinePath = Join-Path $repoRoot $BaselineFile
if (Test-Path $baselinePath) {
    $baseline = [double]((Get-Content -Path $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json).lineCoverage)
} else {
    Write-Host "::error::Fichier de référence $BaselineFile introuvable."
    exit 1
}

$echec = $false
Write-Host ""
Write-Host "Couverture globale : $globalPct % ($totalCovered / $total lignes), référence : $baseline %"
Write-Summary "## Couverture de code"
Write-Summary ""
Write-Summary "- Couverture globale : **$globalPct %** ($totalCovered / $total lignes), référence ``$BaselineFile`` : $baseline %"
if ($globalPct -lt $baseline) {
    Write-Host "::error::La couverture globale ($globalPct %) est passée sous la référence ($baseline %)."
    Write-Summary "- :x: Couverture globale sous la référence."
    $echec = $true
} elseif ($globalPct -ge $baseline + 1) {
    Write-Host "::notice::La couverture globale ($globalPct %) dépasse la référence d'au moins 1 point : relever lineCoverage dans $BaselineFile à $([math]::Floor($globalPct))."
}

# --- 3. Couverture du code modifié par la PR ---------------------------------------------
if ([string]::IsNullOrWhiteSpace($BaseRef)) {
    Write-Host "Pas de branche de base (workflow_dispatch) : règle globale seule."
    Write-Summary "- Code modifié : non vérifié (pas de branche de base)."
} else {
    $diff = git -c core.quotepath=off diff --unified=0 --diff-filter=AMR "$BaseRef...HEAD" -- '*.cs'
    if ($LASTEXITCODE -ne 0) { Write-Host "::error::git diff $BaseRef...HEAD a échoué (checkout avec fetch-depth: 0 ?)."; exit 1 }

    # fichier -> liste des lignes ajoutées / modifiées
    $changed = [ordered]@{}
    $current = $null
    foreach ($l in $diff) {
        if ($l -match '^\+\+\+ (.+)$') {
            $path = $Matches[1]
            if ($path -eq '/dev/null') { $current = $null; continue }
            $path = $path -replace '^b/', ''
            if ($path -match '(^|/)(tests|UnitTest[^/]*|obj)/') { $current = $null } else { $current = $path; $changed[$current] = New-Object System.Collections.Generic.List[int] }
        } elseif ($current -and $l -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@') {
            $start = [int]$Matches[1]
            $count = 1
            if ($Matches.Count -gt 2 -and $Matches[2] -ne $null -and $Matches[2] -ne '') { $count = [int]$Matches[2] }
            for ($i = 0; $i -lt $count; $i++) { $changed[$current].Add($start + $i) }
        }
    }

    $diffTotal = 0; $diffCovered = 0
    $nonCouvertes = New-Object System.Collections.Generic.List[string]
    foreach ($file in $changed.Keys) {
        $lignes = $changed[$file]
        if ($lignes.Count -eq 0) { continue }
        $key = $null
        foreach ($k in $coverage.Keys) { if ($k -ieq $file) { $key = $k; break } }
        if ($key) {
            foreach ($n in $lignes) {
                if ($coverage[$key].ContainsKey($n)) {
                    $diffTotal++
                    if ($coverage[$key][$n]) { $diffCovered++ } else { $nonCouvertes.Add("${file}:$n") }
                }
            }
        } else {
            # Fichier absent des rapports : ignoré si d'autres fichiers de son projet y figurent
            # (pas de code exécutable), sinon son projet n'est pas mesuré et ses lignes comptent comme non couvertes.
            $dir = Split-Path -Parent (Join-Path $repoRoot $file)
            $projDir = $null
            while ($dir -and (Get-NormalizedPath $dir).Length -ge $repoRoot.Length) {
                if (Get-ChildItem -Path $dir -Filter '*.csproj' -File -ErrorAction SilentlyContinue) { $projDir = $dir; break }
                $parent = Split-Path -Parent $dir
                if ($parent -eq $dir) { break }
                $dir = $parent
            }
            $projetMesure = $false
            if ($projDir) {
                $projRel = (Get-RepoRelativePath $projDir).TrimEnd('/') + '/'
                if ($projRel -eq '/') { $projRel = '' }
                foreach ($k in $coverage.Keys) { if ($k.StartsWith($projRel, [System.StringComparison]::OrdinalIgnoreCase)) { $projetMesure = $true; break } }
            }
            if ($projetMesure) {
                Write-Host "Ignoré (aucune ligne couvrable dans les rapports) : $file"
            } else {
                $contenu = @()
                $fullFile = Join-Path $repoRoot $file
                if (Test-Path $fullFile) { $contenu = @(Get-Content -Path $fullFile -Encoding UTF8) }
                foreach ($n in $lignes) {
                    if ($n -le $contenu.Count -and $contenu[$n - 1].Trim() -eq '') { continue }
                    $diffTotal++
                    $nonCouvertes.Add("${file}:$n (projet non mesuré)")
                }
            }
        }
    }

    if ($diffTotal -eq 0) {
        Write-Host "Code modifié : aucune ligne couvrable ajoutée ou modifiée par rapport à $BaseRef : OK."
        Write-Summary "- Code modifié : aucune ligne couvrable ajoutée ou modifiée par rapport à ``$BaseRef``."
    } else {
        $diffPct = [math]::Round(100.0 * $diffCovered / $diffTotal, 2)
        Write-Host "Code modifié : $diffPct % ($diffCovered / $diffTotal lignes couvrables), seuil : $Threshold %"
        Write-Summary "- Code modifié : **$diffPct %** ($diffCovered / $diffTotal lignes couvrables), seuil : $Threshold %"
        if ($nonCouvertes.Count -gt 0) {
            Write-Host "Lignes modifiées non couvertes :"
            Write-Summary ""
            Write-Summary "<details><summary>Lignes modifiées non couvertes ($($nonCouvertes.Count))</summary>"
            Write-Summary ""
            foreach ($nc in $nonCouvertes) { Write-Host "  $nc"; Write-Summary "- ``$nc``" }
            Write-Summary ""
            Write-Summary "</details>"
        }
        if ($diffPct -lt $Threshold) {
            Write-Host "::error::Couverture du code modifié insuffisante : $diffPct % < $Threshold %."
            $echec = $true
        }
    }
}

if ($echec) { exit 1 }
Write-Host "Couverture : OK."
