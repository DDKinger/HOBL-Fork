# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

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
    internal static bool SchemaWritten;

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
        var row = FormattableString.Invariant(
            $"{Environment.ProcessId},{CsvField(responseFile)},{CsvField(runtime)},{launchTicks},{entryTicks},{MetadataTicks},{finishTicks},{System.Diagnostics.Stopwatch.Frequency},{SchemaWritten}");
        File.WriteAllText(Path.Combine(directory, $"{Guid.NewGuid():N}.csv"),
            "pid,response_file,runtime,launch_ticks,entry_ticks,metadata_ticks,finish_ticks,tick_frequency,schema_written" +
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
            HoblSchemaTiming.SchemaWritten = true;
'@
    Set-Content -LiteralPath (Join-Path $TimingDirectory "Program.cs") -Value $program -NoNewline -ErrorAction Stop
    Set-Content -LiteralPath (Join-Path $TimingDirectory "ConfigSchemaGenerator.cs") -Value $schema -NoNewline -ErrorAction Stop
}

function Export-SchemaTimingSamples {
    param([string]$TimingDirectory, [string]$OutputPath)
    $files = @(Get-ChildItem -LiteralPath $TimingDirectory -Filter "*.csv" -File -ErrorAction Stop)
    if (-not $files) {
        throw " ERROR - No SchemaGenerator timing samples were recorded."
    }
    $files | ForEach-Object { Import-Csv -LiteralPath $_.FullName -ErrorAction Stop } |
        Sort-Object { [long]$_.launch_ticks } |
        Export-Csv -LiteralPath $OutputPath -NoTypeInformation -ErrorAction Stop
}
