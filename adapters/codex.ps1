# Codex / ChatGPT 桌面版适配器：读 ~/.codex/state_5.sqlite 的 threads.tokens_used
# 用本机 Python 自带的 sqlite3 读（PowerShell 没有 SQLite 驱动）
@{
    Id        = 'codex'
    Name      = 'Codex'
    ShortName = 'Codex'
    Note      = '今日已用 token（本地数据库）'
    Order     = 20
    Interval  = 300
    Summary   = $true
    KeyName   = ''
    Collect   = {
        $db = Join-Path $env:USERPROFILE '.codex\state_5.sqlite'
        if (-not (Test-Path -LiteralPath $db)) {
            return @{ Ok = $false; Value = '未检测到'; Note = '没有 ~/.codex/state_5.sqlite' }
        }
        $python = Get-Command python -ErrorAction SilentlyContinue
        if (-not $python) {
            return @{ Ok = $false; Value = '需要 Python'; Note = '用 Python 的 sqlite3 读数据库' }
        }

        $py = @'
import sqlite3, os, datetime
p = os.path.join(os.path.expanduser("~"), ".codex", "state_5.sqlite")
try:
    con = sqlite3.connect("file:%s?mode=ro" % p.replace("\\", "/"), uri=True)
    start = int(datetime.datetime.combine(datetime.date.today(), datetime.time.min).timestamp())
    row = con.execute(
        "select coalesce(sum(tokens_used),0), coalesce(sum(case when updated_at >= ? then tokens_used else 0 end),0) from threads",
        (start,)).fetchone()
    print("%d %d" % (row[0], row[1]))
    con.close()
except Exception:
    print("ERR")
'@
        # 多行脚本用 -c 传会被 Windows 参数引号吃掉，写成临时文件再跑
        $pyPath = Join-Path (Get-WidgetCacheDir) 'codex-usage.py'
        try {
            [IO.File]::WriteAllText($pyPath, $py, (New-Object Text.UTF8Encoding($false)))
            $out = & $python.Source $pyPath 2>$null | Out-String
            $text = $out.Trim()
        } catch {
            return @{ Ok = $false; Value = '读取失败'; Note = $_.Exception.Message }
        }

        if ($text -notmatch '^(\d+)\s+(\d+)$') {
            return @{ Ok = $false; Value = '读取失败'; Note = 'SQLite 查询出错' }
        }
        return @{
            Ok    = $true
            Value = (Format-TokenCount ([double]$Matches[2]))
            Note  = ('今日已用 · 累计 {0}' -f (Format-TokenCount ([double]$Matches[1])))
            Data  = @{ today = [double]$Matches[2]; total = [double]$Matches[1] }
        }
    }
}
