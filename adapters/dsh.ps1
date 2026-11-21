# DSH（DeepSeek Harness）适配器：解压会话日志，按每次请求的模型 + 时段折人民币
# 真正的解析在 tools/dsh-cost.js 里（Node 才能解多帧 zstd）
@{
    Id        = 'dsh'
    Name      = 'DeepSeek Harness'
    ShortName = 'DSH'
    Note      = '今日花费（人民币）'
    Order     = 30
    Interval  = 60
    Summary   = $true
    KeyName   = ''
    Collect   = {
        $sessionsDir = Join-Path $env:USERPROFILE '.dsh\sessions'
        if (-not (Test-Path -LiteralPath $sessionsDir)) {
            return @{ Ok = $false; Value = '未检测到'; Note = '没有 ~/.dsh/sessions' }
        }
        $node = Get-NodeRuntime
        $script = Join-Path (Get-WidgetRoot) 'tools\dsh-cost.js'
        if (-not $node -or -not (Test-Path -LiteralPath $script)) {
            return @{ Ok = $false; Value = '需要 Node'; Note = '用 Node 解压会话日志' }
        }

        $today = (Get-Date).ToString('yyyy-MM-dd')
        $prices = [ordered]@{
            'deepseek-flash' = [ordered]@{
                hit  = [double](Get-WidgetSetting 'priceHit' 0.04)
                miss = [double](Get-WidgetSetting 'priceMiss' 2.0)
                out  = [double](Get-WidgetSetting 'priceOut' 8.0)
            }
        }
        $pricesJson = ConvertTo-Json -InputObject $prices -Compress -Depth 4

        try {
            $raw = & $node $script $sessionsDir $today $pricesJson 2>$null | Out-String
            $data = $raw.Trim() | ConvertFrom-Json
        } catch {
            return @{ Ok = $false; Value = '计算失败'; Note = $_.Exception.Message }
        }

        if (-not $data -or -not $data.ok) {
            return @{ Ok = $false; Value = '今天还没有会话'; Note = '会话日志里没有今天的记录' }
        }

        $models = @($data.models | ForEach-Object { $_.model }) -join '+'
        if (-not $models) { $models = 'deepseek-flash' }
        $note = ('{0} 次 · {1} · 高峰时段' -f $data.requests, $models)
        if ([double]$data.offPeakCost -gt 0) {
            $note = ('{0} 次 · {1} · 高峰 ¥{2:0.00} / 空闲 ¥{3:0.00}' -f $data.requests, $models, [double]$data.peakCost, [double]$data.offPeakCost)
        }

        return @{
            Ok    = $true
            Value = ('{0}{1}' -f (Get-CurrencySymbol 'CNY'), ('{0:0.00}' -f [double]$data.cost))
            Note  = $note
            Data  = $data
        }
    }
}
