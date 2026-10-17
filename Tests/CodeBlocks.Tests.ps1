# Every ```powershell block in the markdown files must parse.

BeforeDiscovery {
    $root = Split-Path $PSScriptRoot -Parent
    $blocks = foreach ($file in Get-ChildItem $root -Filter *.md) {
        $text = Get-Content $file.FullName -Raw
        $i = 0
        foreach ($m in [regex]::Matches($text, '(?ms)^```powershell\r?\n(.*?)^```')) {
            $i++
            $line = ($text.Substring(0, $m.Index) -split "`n").Count
            @{ File = $file.Name; Line = $line; Code = $m.Groups[1].Value }
        }
    }
}

Describe '<File> line <Line>' -ForEach $blocks {
    It 'parses' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$errors) | Out-Null
        $errors | ForEach-Object { $_.Message } | Should -BeNullOrEmpty
    }
}
