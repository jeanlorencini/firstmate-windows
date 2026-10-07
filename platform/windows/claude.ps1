# Dot-source this from the PowerShell profile. A claude.exe that PowerShell
# starts has no MSYS pid, so its session can never own state/.lock; started
# through Git Bash with env.sh sourced, it gets one, and the overlay is on.

function claude {
    # An npm install puts shims on PATH (claude.cmd, claude.ps1, claude) and the
    # real claude.exe under node_modules beside them. A shim starts it through
    # cmd.exe, so it is no child of bash and gets no MSYS pid: resolve the exe.
    $cmd = Get-Command claude -CommandType Application -All -ErrorAction Stop | ForEach-Object {
        if ($_.Source -like '*.exe') { $_.Source } else { Join-Path (Split-Path $_.Source) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe' }
    } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $cmd) { throw 'claude: no claude.exe on PATH, and no node_modules\@anthropic-ai\claude-code\bin\claude.exe beside the claude shim' }
    $cmdArgs = $args
    $envSh = Join-Path $PWD.ProviderPath 'platform\windows\env.sh'
    if ((Test-Path -LiteralPath $envSh) -and (Test-Path -LiteralPath (Join-Path $PWD.ProviderPath 'bin\fm-lock.sh'))) {
        $env:FM_WIN_LAUNCH_ENV = $envSh
        $env:FM_WIN_LAUNCH_CLAUDE = $cmd
        $cmd = $env:CLAUDE_CODE_GIT_BASH_PATH
        if (-not $cmd) {
            $cmd = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
            $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            for ($dir = if ($git) { Split-Path $git.Source } else { '' }; $dir; $dir = Split-Path $dir) {
                if ((Test-Path -LiteralPath "$dir\bin\bash.exe") -and (Test-Path -LiteralPath "$dir\usr\bin")) { $cmd = "$dir\bin\bash.exe"; break }
            }
        }
        $cmdArgs = @('-c', 'e=$FM_WIN_LAUNCH_ENV c=$FM_WIN_LAUNCH_CLAUDE; unset FM_WIN_LAUNCH_ENV FM_WIN_LAUNCH_CLAUDE; . "$e" && exec "$c" "$@"', 'claude') + $args
    }
    try {
        if ($MyInvocation.ExpectingInput) { $input | & $cmd @cmdArgs } else { & $cmd @cmdArgs }
    } finally {
        Remove-Item Env:FM_WIN_LAUNCH_ENV, Env:FM_WIN_LAUNCH_CLAUDE -ErrorAction SilentlyContinue
    }
}
