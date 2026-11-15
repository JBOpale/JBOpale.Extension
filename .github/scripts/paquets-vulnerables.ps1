# Contrôle des paquets NuGet vulnérables (directs ET transitifs) pour tous les projets de la solution.
# - Vulnérabilité HAUTE ou CRITIQUE : échec (code de sortie 1).
# - Vulnérabilité FAIBLE ou MODÉRÉE : avertissement seulement.
# Tous les projets du dépôt sont au format SDK : « dotnet list package --vulnerable » fonctionne
# pour chacun (net48 compris), donc pas besoin de NuGetAudit au restore.
# Prérequis : la solution doit avoir été restaurée (dotnet restore).
# Usage local : pwsh .github/scripts/paquets-vulnerables.ps1 [-Solution JBOpale.Extensions.sln]
# Ne jamais baisser le seuil ni désactiver ce contrôle (voir CLAUDE.md).
param(
    [string]$Solution = "JBOpale.Extensions.sln"
)

$ErrorActionPreference = "Stop"
$solutionDir = Split-Path -Parent (Resolve-Path $Solution)
$projets = dotnet sln $Solution list | Where-Object { $_ -match '\.(cs|vb|fs)proj$' }
if (-not $projets) { Write-Host "::error::Aucun projet trouvé dans $Solution"; exit 1 }

$bloquantes = @()
$avertissements = @()

foreach ($projet in $projets) {
    $chemin = Join-Path $solutionDir $projet.Trim()
    Write-Host "Analyse de $chemin"
    $sortie = dotnet list $chemin package --vulnerable --include-transitive --format json
    if ($LASTEXITCODE -ne 0) { Write-Host "::error::dotnet list package a échoué pour $chemin"; Write-Host ($sortie -join "`n"); exit 1 }
    $json = ($sortie -join "`n") | ConvertFrom-Json

    if ($json.problems) {
        foreach ($p in $json.problems) { Write-Host "::error::$($p.project) : $($p.text)" }
        exit 1
    }

    foreach ($proj in $json.projects) {
        foreach ($fw in $proj.frameworks) {
            $paquets = @($fw.topLevelPackages) + @($fw.transitivePackages) | Where-Object { $_ }
            foreach ($pkg in $paquets) {
                foreach ($v in $pkg.vulnerabilities) {
                    $ligne = "$($pkg.id) $($pkg.resolvedVersion) [$($fw.framework)] ($($v.severity)) $($v.advisoryurl) — $(Split-Path -Leaf $chemin)"
                    if ($v.severity -in @("High", "Critical")) { $bloquantes += $ligne } else { $avertissements += $ligne }
                }
            }
        }
    }
}

foreach ($a in ($avertissements | Sort-Object -Unique)) { Write-Host "::warning::Paquet vulnérable (faible/modérée) : $a" }
if ($bloquantes) {
    foreach ($b in ($bloquantes | Sort-Object -Unique)) { Write-Host "::error::Paquet vulnérable (haute/critique) : $b" }
    Write-Host "Échec : $(@($bloquantes | Sort-Object -Unique).Count) vulnérabilité(s) haute/critique. Mettre à jour la dépendance ou épingler une version corrigée (commentaire avec l'avis GHSA)."
    exit 1
}
Write-Host "Aucune vulnérabilité haute ou critique."
