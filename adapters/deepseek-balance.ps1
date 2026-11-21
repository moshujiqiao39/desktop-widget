# DeepSeek 账户余额适配器：需要 sk- 开头的 API key（存在 config.json）
# 用异步请求，避免卡住界面（开始查询 → 主循环里轮询）
@{
    Id        = 'deepseek-balance'
    Name      = 'DeepSeek 账户'
    ShortName = '余额'
    Note      = '账户余额（人民币）'
    Order     = 40
    Interval  = 900
    Summary   = $false
    KeyName   = 'deepseekKey'
    Hint      = 'DeepSeek API key'
    Collect   = {
        $key = [string](Get-WidgetSetting 'deepseekKey' '')
        if ([string]::IsNullOrWhiteSpace($key)) {
            return @{ Ok = $false; Value = '未配置'; Note = '填一个 sk- 开头的 API key 即可查余额' }
        }

        $pending = Poll-BgRequest -Id 'deepseek-balance'
        if ($pending.Running) {
            return @{ Ok = $false; Value = '查询中'; Note = '正在请求 api.deepseek.com' }
        }
        if ($pending.Failed) {
            Start-BgRequest -Id 'deepseek-balance' -Url 'https://api.deepseek.com/user/balance' -Headers @{ Authorization = ('Bearer ' + $key.Trim()) }
            return @{ Ok = $false; Value = '查询中'; Note = $pending.Error }
        }
        if ($pending.Done) {
            $json = $pending.Json
            if ($json.balance_infos -and $json.balance_infos.Count -gt 0) {
                $info = $json.balance_infos[0]
                $currency = [string]$info.currency
                if (-not $currency) { $currency = 'CNY' }
                return @{
                    Ok    = $true
                    Value = ('{0}{1}' -f (Get-CurrencySymbol $currency), ('{0:0.00}' -f [double]$info.total_balance))
                    Note  = ('充值 {0} / 赠送 {1}' -f $info.topped_up_balance, $info.granted_balance)
                    Data  = $json
                }
            }
            return @{ Ok = $false; Value = '没有余额信息'; Note = '接口返回里没有 balance_infos' }
        }

        # 没在跑也没结果 → 发起查询，本次先显示查询中
        Start-BgRequest -Id 'deepseek-balance' -Url 'https://api.deepseek.com/user/balance' -Headers @{ Authorization = ('Bearer ' + $key.Trim()) }
        return @{ Ok = $false; Value = '查询中'; Note = '正在请求 api.deepseek.com' }
    }
}
