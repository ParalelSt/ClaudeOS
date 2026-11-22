# Push ClaudeOS repo to GitHub
# Run this after creating the repo at https://github.com/new
# Name it "ClaudeOS" (or whatever you like)

$repoPath = "C:\Users\arond\AlcatelBackup\claudeos-repo"

# If you don't have gh CLI, create the repo manually at github.com/new first
# Then set the remote URL:
#   cd $repoPath
#   git remote add origin https://github.com/ParalelSt/ClaudeOS.git
#   git push -u origin master

# If you have gh CLI:
#   cd $repoPath
#   gh repo create ClaudeOS --public --source=. --push

# Quick one-liner (after creating repo on GitHub):
Set-Location $repoPath
$hasRemote = git remote 2>&1
if (-not $hasRemote) {
    git remote add origin "https://github.com/ParalelSt/ClaudeOS.git"
}
git push -u origin master
Write-Host "Done! Check https://github.com/ParalelSt/ClaudeOS" -ForegroundColor Green
