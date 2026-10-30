# Extrapolate the last audio-clock sample using the same monotonic clock in
# every display process. A stale sample is capped to avoid runaway playback.
function Get-OrchestraDisplayPosition($State) {
    $position=[double]$State.PositionMs
    if($State.Status -eq 'Playing' -and $State.ClockTicks -and [Diagnostics.Stopwatch]::IsHighResolution){
        $elapsed=([double][Diagnostics.Stopwatch]::GetTimestamp()-[double]$State.ClockTicks)*1000.0/[Diagnostics.Stopwatch]::Frequency
        if($elapsed -ge 0){$position+=[Math]::Min(100.0,$elapsed)}
    }
    return $position
}
