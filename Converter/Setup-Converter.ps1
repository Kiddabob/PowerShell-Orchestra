#requires -Version 5.1
[CmdletBinding()]
param([string]$PythonPath)
$ErrorActionPreference='Stop'
if(-not $PythonPath){$PythonPath=Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'}
if(-not(Test-Path -LiteralPath $PythonPath)){
    if(Get-Command py.exe -ErrorAction SilentlyContinue){$PythonPath=(& py.exe -3.11 -c 'import sys; print(sys.executable)' | Select-Object -Last 1)}
}
if(-not $PythonPath -or -not(Test-Path -LiteralPath $PythonPath)){throw 'Python 3.11 is required. Supply its executable using -PythonPath.'}
$runtime=Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if(-not(Test-Path -LiteralPath $runtime)){
    & $PythonPath -m venv (Join-Path $PSScriptRoot '.venv')
    if($LASTEXITCODE -ne 0){throw 'Could not create the project-only converter environment.'}
}
& $runtime -m pip install --no-deps basic-pitch==0.4.0
if($LASTEXITCODE -ne 0){throw 'Basic Pitch installation failed.'}
& $runtime -m pip install -r (Join-Path $PSScriptRoot 'requirements-onnx.txt')
if($LASTEXITCODE -ne 0){throw 'ONNX dependency installation failed.'}
& $runtime -m pip install torch==2.5.1 torchaudio==2.5.1 --index-url https://download.pytorch.org/whl/cpu
if($LASTEXITCODE -ne 0){throw 'CPU separation runtime installation failed.'}
& $runtime -m pip install demucs==4.0.1
if($LASTEXITCODE -ne 0){throw 'Source-separation installation failed.'}
& $runtime -m pip install torchcrepe==0.0.24
if($LASTEXITCODE -ne 0){throw 'Phrase pitch-tracker installation failed.'}
$env:TORCH_HOME=Join-Path $PSScriptRoot 'Models'
& $runtime -c 'from demucs.pretrained import get_model; get_model("htdemucs")'
if($LASTEXITCODE -ne 0){throw 'Separation model download failed.'}
Write-Output 'PowerShell Orchestra converter is ready. Audio is processed locally.'
