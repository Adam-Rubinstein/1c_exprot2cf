$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$dir = Join-Path $root ".vscode"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$path = Join-Path $dir "tasks.json"
$json = @'
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "1C основная: загрузить из файлов в ИБ (LoadOnly)",
      "type": "shell",
      "command": "powershell",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}/Export-MainCf.ps1",
        "-Step",
        "LoadOnly"
      ],
      "options": { "cwd": "${workspaceFolder}" },
      "problemMatcher": [],
      "presentation": { "reveal": "always", "panel": "dedicated", "focus": true }
    },
    {
      "label": "1C основная: выгрузить в CF (DumpOnly)",
      "type": "shell",
      "command": "powershell",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}/Export-MainCf.ps1",
        "-Step",
        "DumpOnly"
      ],
      "options": { "cwd": "${workspaceFolder}" },
      "problemMatcher": [],
      "presentation": { "reveal": "always", "panel": "dedicated", "focus": true }
    },
    {
      "label": "1C основная: загрузить из файлов + выгрузить CF (All)",
      "type": "shell",
      "command": "powershell",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}/Export-MainCf.ps1",
        "-Step",
        "All"
      ],
      "options": { "cwd": "${workspaceFolder}" },
      "problemMatcher": [],
      "presentation": { "reveal": "always", "panel": "dedicated", "focus": true }
    },
    {
      "label": "1C основная: dry run (WhatIf)",
      "type": "shell",
      "command": "powershell",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}/Export-MainCf.ps1",
        "-WhatIf"
      ],
      "options": { "cwd": "${workspaceFolder}" },
      "problemMatcher": [],
      "presentation": { "reveal": "always", "panel": "dedicated", "focus": true }
    },
    {
      "label": "1C расширение: загрузить из файлов в ИБ (LoadOnly)",
      "type": "shell",
      "command": "powershell",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}/Export-ExtensionCfe.ps1",
        "-Step",
        "LoadOnly"
      ],
      "options": { "cwd": "${workspaceFolder}" },
      "problemMatcher": [],
      "presentation": { "reveal": "always", "panel": "dedicated", "focus": true }
    },
    {
      "label": "1C расширение: выгрузить в CFE (DumpOnly)",
      "type": "shell",
      "command": "powershell",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}/Export-ExtensionCfe.ps1",
        "-Step",
        "DumpOnly"
      ],
      "options": { "cwd": "${workspaceFolder}" },
      "problemMatcher": [],
      "presentation": { "reveal": "always", "panel": "dedicated", "focus": true }
    },
    {
      "label": "1C расширение: загрузить из файлов + выгрузить CFE (All)",
      "type": "shell",
      "command": "powershell",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}/Export-ExtensionCfe.ps1",
        "-Step",
        "All"
      ],
      "options": { "cwd": "${workspaceFolder}" },
      "problemMatcher": [],
      "presentation": { "reveal": "always", "panel": "dedicated", "focus": true }
    },
    {
      "label": "1C расширение: dry run (WhatIf)",
      "type": "shell",
      "command": "powershell",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}/Export-ExtensionCfe.ps1",
        "-WhatIf"
      ],
      "options": { "cwd": "${workspaceFolder}" },
      "problemMatcher": [],
      "presentation": { "reveal": "always", "panel": "dedicated", "focus": true }
    }
  ]
}
'@
[System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Wrote $path"
