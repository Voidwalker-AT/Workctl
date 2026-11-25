param([Parameter(Position=0)][string]$Command, [switch]$Json)
if ($Command -eq "info") {
    Write-Output '{"workspaceName":"Fixture","workspaceRoot":"E:\\Workspace","projectsCount":1}'
    exit 0
}
$root = $env:WORKCTL_NEXT_WORKSPACE_ROOT
$obj = [PSCustomObject]@{
    id = "fixture-proj"
    name = "Fixture Project"
    path = "proj dir"
    category = "active"
    status = "active"
    environment = "uv"
    gpu = "none"
    git = $false
    commands = [PSCustomObject]@{
        check = [PSCustomObject]@{ risk = "safe"; executable = "python"; description = "fixture check" }
    }
}
$obj | ConvertTo-Json -Depth 4
exit 0