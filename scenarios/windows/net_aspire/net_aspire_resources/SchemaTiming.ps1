# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

function Get-SchemaRuntimeVersion {
    param([string]$DotNetPath, [int]$Major)
    $runtimes = & $DotNetPath --list-runtimes
    if ($LASTEXITCODE -ne 0) {
        throw " ERROR - Could not list runtimes using $DotNetPath."
    }
    $version = $runtimes | ForEach-Object {
        if ($_ -match '^Microsoft\.NETCore\.App (\d+\.\d+\.\d+) \[') {
            $candidate = [version]$Matches[1]
            if ($candidate.Major -eq $Major) { $candidate }
        }
    } | Sort-Object -Descending | Select-Object -First 1
    if (-not $version) {
        throw " ERROR - No stable Microsoft.NETCore.App $Major runtime reported by $DotNetPath."
    }
    return $version.ToString()
}

function Set-SchemaTimingMarker {
    param([string]$Source, [string]$Anchor, [string]$Replacement)
    $index = $Source.IndexOf($Anchor, [StringComparison]::Ordinal)
    if ($index -lt 0 -or $Source.IndexOf($Anchor, $index + $Anchor.Length, [StringComparison]::Ordinal) -ge 0) {
        throw " ERROR - Expected exactly one SchemaGenerator source anchor: $Anchor"
    }
    return $Source.Replace($Anchor, $Replacement)
}

function New-SchemaTimingSources {
    param([string]$AspireDirectory, [string]$TimingDirectory)
    $generator = Join-Path $AspireDirectory "src\Tools\ConfigurationSchemaGenerator"
    $program = Get-Content -LiteralPath (Join-Path $generator "Program.cs") -Raw -ErrorAction Stop
    $schema = Get-Content -LiteralPath (Join-Path $generator "ConfigSchemaGenerator.cs") -Raw -ErrorAction Stop

    $program = Set-SchemaTimingMarker $program '#if LAUNCH_DEBUGGER' @'
var hoblEntryTicks = System.Diagnostics.Stopwatch.GetTimestamp();
#if LAUNCH_DEBUGGER
'@
    $program = Set-SchemaTimingMarker $program 'return await rootCommand.Parse(args).InvokeAsync(CancellationToken.None).ConfigureAwait(false);' @'
var hoblExitCode = await rootCommand.Parse(args).InvokeAsync(CancellationToken.None).ConfigureAwait(false);
var hoblFinishTicks = System.Diagnostics.Stopwatch.GetTimestamp();
if (hoblExitCode == 0) HoblSchemaTiming.WriteSample(hoblEntryTicks, hoblFinishTicks);
return hoblExitCode;

internal static class HoblSchemaTiming
{
    internal static long MetadataTicks;
    internal static string? SchemaOutput;

    internal static void WriteSample(long entryTicks, long finishTicks)
    {
        var directory = Environment.GetEnvironmentVariable("HOBL_SCHEMA_TIMING_DIR");
        var responseFile = Environment.GetEnvironmentVariable("HOBL_SCHEMA_TIMING_RSP");
        var launch = Environment.GetEnvironmentVariable("HOBL_SCHEMA_LAUNCH_TICKS");
        if (directory is null || responseFile is null ||
            !long.TryParse(launch, System.Globalization.NumberStyles.None,
                System.Globalization.CultureInfo.InvariantCulture, out var launchTicks) ||
            launchTicks > entryTicks || entryTicks > MetadataTicks || MetadataTicks > finishTicks)
        {
            throw new InvalidOperationException("Invalid HOBL schema timing context or timestamps.");
        }

        static string CsvField(string value) => "\"" + value.Replace("\"", "\"\"") + "\"";
        var runtime = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription;
        var schemaOutput = SchemaOutput is null ? "" : Path.GetFullPath(SchemaOutput);
        var row = FormattableString.Invariant(
            $"{Environment.ProcessId},{CsvField(responseFile)},{CsvField(runtime)},{launchTicks},{entryTicks},{MetadataTicks},{finishTicks},{System.Diagnostics.Stopwatch.Frequency},{SchemaOutput is not null},{CsvField(schemaOutput)}");
        File.WriteAllText(Path.Combine(directory, $"{Guid.NewGuid():N}.csv"),
            "pid,response_file,runtime,launch_ticks,entry_ticks,metadata_ticks,finish_ticks,tick_frequency,schema_written,schema_output" +
            Environment.NewLine + row + Environment.NewLine);
    }
}
'@
    $schema = Set-SchemaTimingMarker $schema 'var assemblySymbol = (IAssemblySymbol)compilation.GetAssemblyOrModuleSymbol(inputReference);' @'
var assemblySymbol = (IAssemblySymbol)compilation.GetAssemblyOrModuleSymbol(inputReference);
        HoblSchemaTiming.MetadataTicks = System.Diagnostics.Stopwatch.GetTimestamp();
'@
    $schema = Set-SchemaTimingMarker $schema 'File.WriteAllText(outputFile, schema);' @'
File.WriteAllText(outputFile, schema);
            HoblSchemaTiming.SchemaOutput = outputFile;
'@
    Set-Content -LiteralPath (Join-Path $TimingDirectory "Program.cs") -Value $program -NoNewline -ErrorAction Stop
    Set-Content -LiteralPath (Join-Path $TimingDirectory "ConfigSchemaGenerator.cs") -Value $schema -NoNewline -ErrorAction Stop
}

function Export-SchemaTimingSamples {
    param([string]$TimingDirectory, [string]$OutputPath, [string]$ExpectedRuntimeVersion)
    $files = @(Get-ChildItem -LiteralPath $TimingDirectory -Filter "*.csv" -File -ErrorAction Stop)
    if (-not $files) {
        throw " ERROR - No SchemaGenerator timing samples were recorded."
    }
    $rows = foreach ($file in $files) {
        $row = Import-Csv -LiteralPath $file.FullName -ErrorAction Stop
        if ($ExpectedRuntimeVersion -and $row.runtime -ne ".NET $ExpectedRuntimeVersion") {
            throw " ERROR - Expected .NET $ExpectedRuntimeVersion but SchemaGenerator reported '$($row.runtime)' for $($row.response_file)."
        }
        $hash = ""
        if ($row.schema_written -eq 'True') {
            $hash = (Get-FileHash -LiteralPath $row.schema_output -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        $row | Add-Member -NotePropertyName schema_sha256 -NotePropertyValue $hash -PassThru
    }
    $rows |
        Sort-Object { [long]$_.launch_ticks } |
        Export-Csv -LiteralPath $OutputPath -NoTypeInformation -ErrorAction Stop
}
