# Layout helpers are independent of physical monitors so 1..N-screen layouts
# can be checked without changing Windows display settings.
function Select-PlayerScreens($Monitors,[int]$Count=0){
    $all=@($Monitors|Sort-Object X,Y)
    if($Count -le 0 -or $Count -ge $all.Count){return $all}
    $primary=@($all|Where-Object Primary|Select-Object -First 1)
    if(-not $primary.Count){$primary=@($all[0])}
    $main=$primary[0]
    $others=@($all|Where-Object {$_.Device -ne $main.Device}|Sort-Object @{Expression={
        $dx=($_.X+$_.Width/2)-($main.X+$main.Width/2);$dy=($_.Y+$_.Height/2)-($main.Y+$main.Height/2);$dx*$dx+$dy*$dy
    }},X,Y|Select-Object -First ($Count-1))
    @(@($main)+$others|Sort-Object X,Y)
}
function Get-PlayerScreens {
    Add-Type -AssemblyName System.Windows.Forms
    @([Windows.Forms.Screen]::AllScreens | ForEach-Object {
        $area=$_.WorkingArea
        $scale=[LayeredMusic.ConsoleTile]::ScaleAt($area.X+$area.Width/2,$area.Y+$area.Height/2)
        [PSCustomObject]@{ Device=$_.DeviceName; Primary=$_.Primary; X=$area.X; Y=$area.Y;
            Width=$area.Width; Height=$area.Height; Scale=$scale }
    } | Sort-Object X,Y)
}

function Get-PlayerScreenBudget($Monitors,[int]$RequestedMax=0,[string]$Mode='Auto') {
    $usable=@($Monitors | Sort-Object X,Y)
    if ($Mode -eq 'OneScreen') { $usable=@($usable | Where-Object Primary | Select-Object -First 1) }
    if ($usable.Count -eq 0) { throw 'Windows did not report a usable screen.' }
    $capacity=0; $comfortable=0
    foreach ($monitor in $usable) {
        $scale=if($monitor.Scale -gt 0){$monitor.Scale}else{1}
        $slots=[Math]::Max(1,[Math]::Floor($monitor.Width/(480*$scale))*[Math]::Floor($monitor.Height/(240*$scale)))
        $capacity+=$slots
        $comfortable+=[Math]::Min(8,$slots)
    }
    $limit=if($RequestedMax -gt 0){[Math]::Min($RequestedMax,$capacity)}else{$comfortable}
    [PSCustomObject]@{ Limit=[int][Math]::Max(3,[Math]::Min(128,$limit)); Monitors=$usable; Explicit=($RequestedMax -gt 0) }
}

function New-RegisterBandCells($Monitor,$Layers){
    $groups=@(foreach($band in @('High','Mid','Low')){
        $part=@($Layers|Where-Object Band -eq $band|Sort-Object Track,Channel,Id)
        if($part.Count){[PSCustomObject]@{Band=$band;Layers=$part}}
    })
    $n=@($Layers).Count
    $maximum=($groups|ForEach-Object {$_.Layers.Count}|Measure-Object -Maximum).Maximum
    $scale=if($Monitor.Scale -gt 0){$Monitor.Scale}else{1}
    $columns=1;$bestCost=[double]::PositiveInfinity
    for($candidate=1;$candidate -le $maximum;$candidate++){
        $rows=[int](($groups|ForEach-Object {[Math]::Ceiling($_.Layers.Count/[double]$candidate)}|Measure-Object -Sum).Sum)
        $height=$Monitor.Height/[double]$rows;$cost=0.0
        foreach($group in $groups){
            for($offset=0;$offset -lt $group.Layers.Count;$offset+=$candidate){
                $count=[Math]::Min($candidate,$group.Layers.Count-$offset);$width=$Monitor.Width/[double]$count
                $rowCost=[Math]::Abs([Math]::Log(($width/$height)/2.0))
                if($width -lt 480*$scale -or $height -lt 240*$scale){$rowCost+=10}
                $cost+=$rowCost*$count/$n
            }
        }
        if($cost -lt $bestCost){$bestCost=$cost;$columns=$candidate}
    }
    $rows=[int](($groups|ForEach-Object {[Math]::Ceiling($_.Layers.Count/[double]$columns)}|Measure-Object -Sum).Sum)
    $rowOffset=0
    foreach($group in $groups){
        for($i=0;$i -lt $group.Layers.Count;$i++){
            $localRow=[int][Math]::Floor($i/$columns);$row=$rowOffset+$localRow;$col=$i%$columns
            $rowColumns=[Math]::Min($columns,$group.Layers.Count-$localRow*$columns)
            $left=[int][Math]::Floor($Monitor.Width*$col/[double]$rowColumns);$right=[int][Math]::Floor($Monitor.Width*($col+1)/[double]$rowColumns)
            $top=[int][Math]::Floor($Monitor.Height*$row/[double]$rows);$bottom=[int][Math]::Floor($Monitor.Height*($row+1)/[double]$rows)
            $layer=$group.Layers[$i]
            [PSCustomObject]@{Id=$layer.Id;Title=$layer.Title;Band=$layer.Band;NoteCount=$layer.NoteCount;Monitor=$Monitor.Device;X=$Monitor.X+$left;Y=$Monitor.Y+$top;Width=$right-$left;Height=$bottom-$top}
        }
        $rowOffset+=[int][Math]::Ceiling($group.Layers.Count/[double]$columns)
    }
}

function New-PlayerScreenLayout($Score,$Monitors,[string]$Mode='Auto',[bool]$ExplicitBudget=$false,[bool]$ExplicitScreens=$false) {
    $all=@($Monitors | Sort-Object X,Y)
    $primary=@($all | Where-Object Primary | Select-Object -First 1)
    if ($primary.Count -eq 0) { $primary=@($all[0]) }
    $usable=@(if($Mode -eq 'OneScreen' -or (-not $ExplicitScreens -and $Score.Layers.Count -le 3)){$primary}else{$all})
    if ($usable.Count -eq 0) { throw 'No screen is available for the note windows.' }
    $assignments=New-Object Collections.Generic.List[object]
    $ordered=@($Score.Layers | Sort-Object @{Expression={if($_.Band -eq 'Low'){0}elseif($_.Band -eq 'Mid'){1}else{2}}},Track,Channel,Id)
    $bands=@('Low','Mid','High' | Where-Object { $name=$_; @($ordered | Where-Object Band -eq $name).Count -gt 0 })
    $dedicatedRegisters=$usable.Count -eq 3 -and $bands.Count -eq 3
    if ($dedicatedRegisters) {
        $limits=@()
        foreach ($monitor in $usable) {
            $scale=if($monitor.Scale -gt 0){$monitor.Scale}else{1}
            $slots=[int][Math]::Max(1,[Math]::Floor($monitor.Width/(480*$scale))*[Math]::Floor($monitor.Height/(240*$scale)))
            $limits+= $(if($ExplicitBudget){$slots}else{[Math]::Min(8,$slots)})
        }
        [LayeredMusic.Midi]::LimitRegisters($Score,$limits[0],$limits[1],$limits[2])
        for($i=0;$i -lt 3;$i++) {
            $part=@($Score.Layers | Where-Object Band -eq @('Low','Mid','High')[$i] | Sort-Object Track,Channel,Id)
            if($part.Count -gt 0){$assignments.Add(@{Monitor=$usable[$i]; Layers=$part})}
        }
    } else {
        $count=[Math]::Min($usable.Count,$ordered.Count)
        if($count -lt $usable.Count) {
            $usable=@(Select-PlayerScreens $usable $count)
        }
        $counts=@(foreach($monitor in $usable){0})
        $capacities=@(foreach($monitor in $usable){
            $scale=if($monitor.Scale -gt 0){$monitor.Scale}else{1}
            $slots=[int][Math]::Max(1,[Math]::Floor($monitor.Width/(480*$scale))*[Math]::Floor($monitor.Height/(240*$scale)))
            if($ExplicitBudget){$slots}else{[Math]::Min(8,$slots)}
        })
        $perScreen=@{};for($i=0;$i -lt $usable.Count;$i++){$perScreen[$i]=New-Object 'Collections.Generic.List[object]'}
        # Spread each register across the selected monitors, rather than giving
        # one monitor all bass parts and the other all treble parts.
        foreach($band in @('High','Mid','Low')){
            $bandCounts=@(foreach($monitor in $usable){0})
            foreach($layer in @($ordered|Where-Object Band -eq $band)){
                $best=-1;$bestCost=[double]::PositiveInfinity
                for($i=0;$i -lt $usable.Count;$i++){
                    if($counts[$i] -ge $capacities[$i]){continue}
                    $cost=$bandCounts[$i]*100.0/$capacities[$i]+$counts[$i]/[double]$capacities[$i]
                    if($cost -lt $bestCost){$best=$i;$bestCost=$cost}
                }
                if($best -lt 0){$best=0;for($i=1;$i -lt $usable.Count;$i++){if($counts[$i] -lt $counts[$best]){$best=$i}}}
                $perScreen[$best].Add($layer);$counts[$best]++;$bandCounts[$best]++
            }
        }
        # More requested screens than notes cannot create extra musical parts.
        # When there are enough parts, ensure every selected screen is used.
        for($i=0;$i -lt $usable.Count;$i++){
            if($counts[$i] -eq 0){
                $donor=0;for($j=1;$j -lt $usable.Count;$j++){if($counts[$j] -gt $counts[$donor]){$donor=$j}}
                $last=$perScreen[$donor].Count-1;$layer=$perScreen[$donor][$last];$perScreen[$donor].RemoveAt($last);$perScreen[$i].Add($layer);$counts[$donor]--;$counts[$i]++
            }
            $assignments.Add(@{Monitor=$usable[$i];Layers=$perScreen[$i].ToArray()})
        }
    }
    $cells=New-Object Collections.Generic.List[object]
    foreach($assignment in $assignments) {
        $monitor=$assignment.Monitor; $layers=@($assignment.Layers); $n=$layers.Count
        if(-not $dedicatedRegisters){foreach($cell in @(New-RegisterBandCells $monitor $layers)){$cells.Add($cell)};continue}
        if($n -le 3){$columns=$n}else{
            $columns=1; $bestCost=[double]::PositiveInfinity
            for($candidate=1;$candidate -le $n;$candidate++) {
                $rows=[Math]::Ceiling($n/[double]$candidate)
                $width=$monitor.Width/[double]$candidate; $height=$monitor.Height/$rows
                $cost=[Math]::Abs([Math]::Log(($width/$height)/2.0))+0.3*($candidate*$rows-$n)
                $scale=if($monitor.Scale -gt 0){$monitor.Scale}else{1}
                if($width -lt 480*$scale -or $height -lt 240*$scale){$cost+=10}
                if($cost -lt $bestCost){$bestCost=$cost;$columns=$candidate}
            }
        }
        $rows=[int][Math]::Ceiling($n/[double]$columns)
        for($i=0;$i -lt $n;$i++) {
            $row=[int][Math]::Floor($i/$columns);$col=$i%$columns
            $rowColumns=[Math]::Min($columns,$n-$row*$columns)
            $left=[int][Math]::Floor($monitor.Width*$col/[double]$rowColumns)
            $right=[int][Math]::Floor($monitor.Width*($col+1)/[double]$rowColumns)
            $top=[int][Math]::Floor($monitor.Height*$row/[double]$rows)
            $bottom=[int][Math]::Floor($monitor.Height*($row+1)/[double]$rows)
            $layer=$layers[$i]
            $cells.Add([PSCustomObject]@{Id=$layer.Id;Title=$layer.Title;Band=$layer.Band;NoteCount=$layer.NoteCount;
                Monitor=$monitor.Device;X=$monitor.X+$left;Y=$monitor.Y+$top;Width=$right-$left;Height=$bottom-$top})
        }
    }
    @($cells.ToArray())
}
