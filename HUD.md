# Minigun HUD

A cyberpunk-inspired terminal UI for monitoring Minigun pipelines in real-time. Features an htop-like interface with animated flow diagrams and live performance metrics.

![Minigun HUD Demo](docs/hud-screenshot.png)

## Features

- **Real-time monitoring**: Live updates of pipeline execution
- **Dual-panel layout**:
  - **Left**: Animated ASCII flow diagram showing data moving through stages
  - **Right**: Process statistics table with throughput, latency, and resource metrics
- **Cyberpunk aesthetic**: Matrix/Blade Runner-inspired color scheme with animations
- **Keyboard controls**: Navigate, pause, and inspect pipeline execution
- **Zero dependencies**: Pure Ruby with ANSI terminal control

## Installation

The HUD is included with Minigun. Simply require it:

```ruby
require 'minigun/hud'
```

## Quick Start

### Option 1: Automatic (Recommended)

Use `Minigun::HUD.run_with_hud` to automatically run your task with HUD monitoring:

```ruby
class MyPipelineTask
  include Minigun::DSL

  pipeline do
    producer :generate { 100.times { |i| emit(i) } }
    processor :double { |n| emit(n * 2) }
    consumer :save { |n| save_to_db(n) }
  end
end

# Run with HUD
Minigun::HUD.run_with_hud(MyPipelineTask)
```

### Option 2: Manual Control

For more control, manually create and manage the HUD controller:

```ruby
task = MyPipelineTask.new
task.send(:_evaluate_pipeline_blocks!)
pipeline = task.instance_variable_get(:@_minigun_task).root_pipeline

# Start HUD in background thread
hud = Minigun::HUD::Controller.new(pipeline)
hud_thread = Thread.new { hud.start }

# Run your pipeline
task.run

# Stop HUD
hud.stop
hud_thread.join
```

## Keyboard Controls

| Key | Action |
|-----|--------|
| `q` / `Q` | Quit HUD |
| `Space` | Pause/Resume updates |
| `h` / `H` / `?` | Toggle help overlay |
| `r` / `R` | Force refresh / recalculate layout |
| `↑` / `↓` | Scroll process list |
| `d` / `D` | Toggle detailed view (future) |
| `c` / `C` | Compact view (future) |

## Display Elements

### Flow Diagram (Left Panel)

The left panel shows your pipeline stages as an animated flow diagram:

- **Stage icons**:
  - `▶` Producer (generates data)
  - `◆` Processor (transforms data)
  - `◀` Consumer (consumes data)
  - `⊞` Accumulator (batches items)
  - `◇` Router (distributes to multiple stages)
  - `⑂` Fork (IPC/COW process)

- **Status indicators**:
  - `⚡` Active (currently processing)
  - `⏸` Idle (waiting for work)
  - `⚠` Bottleneck (slowest stage)
  - `✖` Error (failures detected)
  - `✓` Done (completed)

- **Animations**: Flowing characters indicate active data movement

### Process Statistics (Right Panel)

The right panel displays a performance table:

| Column | Description |
|--------|-------------|
| **STAGE** | Stage name with type icon |
| **STATUS** | Current status indicator |
| **ITEMS** | Total items processed |
| **THRU** | Throughput (items/second) |
| **P50** | Median latency (50th percentile) |
| **P99** | 99th percentile latency |

**Color coding**:
- **Green**: High performance / good metrics
- **Yellow**: Moderate performance / warning
- **Red**: Poor performance / critical
- **Cyan**: UI chrome / borders
- **Gray**: Idle or inactive

### Status Bar (Bottom)

Shows:
- **Pipeline status**: RUNNING or PAUSED
- **Pipeline name**: Current pipeline being monitored
- **Keyboard hints**: Available controls

## Example

See `examples/hud_demo.rb` for a complete working example:

```bash
ruby examples/hud_demo.rb
```

This demo creates a multi-stage pipeline with varying latencies to demonstrate the HUD's monitoring capabilities.

## Architecture

The HUD is built with modular components under the `Minigun::HUD` namespace:

```
lib/minigun/hud/
├── terminal.rb         # ANSI terminal control & rendering
├── theme.rb            # Cyberpunk color schemes
├── keyboard.rb         # Non-blocking input handling
├── flow_diagram.rb     # ASCII flow visualization
├── process_list.rb     # Statistics table renderer
├── stats_aggregator.rb # Stats collection from pipeline
└── controller.rb       # Main orchestrator
```

### Key Design Decisions

1. **No external dependencies**: Uses only Ruby stdlib with ANSI escape sequences
2. **Double buffering**: Prevents screen flicker during updates
3. **Non-blocking I/O**: Keyboard input doesn't interrupt rendering
4. **Fixed FPS**: Updates at 15 FPS for smooth animations
5. **Thread-safe**: Safe to run HUD in parallel with pipeline execution

## Performance Considerations

- **CPU overhead**: ~1-2% for HUD rendering thread
- **Memory overhead**: Minimal (~1MB for stats buffering)
- **Refresh rate**: 15 FPS (configurable in `Controller::FPS`)
- **Stats sampling**: Uses reservoir sampling for latency tracking

## Future Enhancements

The HUD is designed to be extensible. Planned features:

- [ ] **IPC stats transmission**: Real-time stats from forked child processes
- [ ] **Detailed view mode**: Expanded per-stage metrics
- [ ] **Compact view mode**: More stages on screen
- [ ] **Multiple pipelines**: Monitor multiple pipelines simultaneously
- [ ] **Historical graphs**: Throughput/latency over time
- [ ] **Export stats**: Save performance data to file
- [ ] **Custom themes**: User-configurable color schemes
- [ ] **Stage filtering**: Show/hide specific stages
- [ ] **Alert thresholds**: Configurable warnings for bottlenecks

## Troubleshooting

### "No TTY" errors

The HUD requires a terminal (TTY). If running in CI or piped contexts, the HUD will detect this and gracefully degrade.

### Garbled output

Ensure your terminal supports ANSI escape sequences and UTF-8:

```bash
export TERM=xterm-256color
export LANG=en_US.UTF-8
```

### Performance issues

If the HUD causes performance issues:

1. Reduce FPS: Edit `Controller::FPS` constant
2. Simplify animations: Disable flow animations in `FlowDiagram`
3. Skip HUD entirely for production: Only use in development

## Contributing

The HUD is part of Minigun's core. Contributions welcome:

1. New visualization modes
2. Additional metrics (CPU, memory per stage)
3. Export/logging capabilities
4. Theme customization
5. Improved layouts for complex pipelines

## License

Same as Minigun (MIT License)

---

**GO BRRRRR WITH STYLE** 🔥
