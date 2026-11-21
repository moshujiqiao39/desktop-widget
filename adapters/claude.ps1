# Claude Code 适配器：读 ~/.claude/projects/**/*.jsonl 里今天的 usage
@{
    Id         = 'claude'
    Name       = 'Claude Code'
    ShortName  = 'Claude'
    Note       = '今日已用 token（本地日志）'
    Order      = 10
    Interval   = 300
    Summary    = $true
    KeyName    = ''
    Collect    = {
        $root = Join-Path $env:USERPROFILE '.claude\projects'
        if (-not (Test-Path -LiteralPath $root)) {
            return @{ Ok = $false; Value = '未检测到'; Note = '没有 ~/.claude 目录' }
        }
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.jsonl -ErrorAction SilentlyContinue
        if (-not $files) {
            return @{ Ok = $false; Value = '没有会话记录'; Note = '~/.claude/projects 是空的' }
        }

        $sum = 0.0
        foreach ($file in $files) {
            try {
                $reader = [IO.File]::OpenText($file.FullName)
                try {
                    while ($null -ne ($line = $reader.ReadLine())) {
                        if ($line.IndexOf($today, [StringComparison]::Ordinal) -lt 0) { continue }
                        foreach ($m in [regex]::Matches($line, '"(?:input_tokens|output_tokens|cache_read_input_tokens|cache_creation_input_tokens)":(\d+)')) {
                            $sum += [double]$m.Groups[1].Value
                        }
                    }
                } finally { $reader.Close() }
            } catch { }
        }

        return @{
            Ok    = $true
            Value = (Format-TokenCount $sum)
            Note  = ('今日已用 · {0} 个会话文件' -f $files.Count)
            Data  = @{ tokens = $sum }
        }
    }
}
