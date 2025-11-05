# Minigun HUD

A cyberpunk-inspired terminal UI for monitoring Minigun pipelines in real-time. Features an htop-like interface with animated flow diagrams and live performance metrics.

> **GO BRRRRR WITH STYLE** 🔥💚⚡

![Minigun HUD Demo](docs/hud-screenshot.png)

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Keyboard Controls](#keyboard-controls)
- [Display Elements](#display-elements)
- [Example](#example)
- [Architecture](#architecture)
- [API Reference](#api-reference)
- [Performance](#performance-considerations)
- [Troubleshooting](#troubleshooting)
- [Future Enhancements](#future-enhancements)

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

### Option 1: Interactive (IRB/Console)

Perfect for development and debugging. Run your task in the background, then open HUD:

```ruby
class MyPipelineTask
  include Minigun::DSL

  pipeline do
    producer :generate { loop { emit(Time.now) } }
    processor :process, threads: 4 { |item| emit(transform(item)) }
    consumer :save { |item| save_to_db(item) }
  end
end

# In IRB or your console:
task = MyPipelineTask.new
task.run(background: true)  # Runs in background thread

task.hud                    # Opens HUD (blocks until you press 'q')
# HUD closed, but task still running!

task.running?               # => true
task.hud                    # Reopen HUD anytime
task.stop                   # Stop execution when done
```

### Option 2: Automatic (One-liner)

Use `Minigun::HUD.run_with_hud` to automatically run your task with HUD monitoring:

```ruby
# Run with HUD (blocks until complete or user quits)
Minigun::HUD.run_with_hud(MyPipelineTask)
```

**Note**: When the pipeline finishes, the HUD stays open to display final statistics. Press `q` to exit. This allows you to review the final state, throughput metrics, and latency percentiles before closing.

### Option 3: Manual Control

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
| `q` / `Q` | Quit HUD (works anytime, including when pipeline finished) |
| `Space` | Pause/Resume updates (disabled when finished) |
| `h` / `H` / `?` | Toggle help overlay (disabled when finished) |
| `r` / `R` | Force refresh / recalculate layout (disabled when finished) |
| `↑` / `↓` | Scroll process list |
| `d` / `D` | Toggle detailed view (future) |
| `c` / `C` | Compact view (future) |

## Display Elements

### Flow Diagram (Left Panel)

The left panel shows your pipeline stages as boxes with animated connections:

```
  ┌─────────────────┐
  │ ▶ generator ⚡  │
  └──── 23.5/s ─────┘
          ⣿  ← flowing animation
  ┌─────────────────┐
  │ ◆ processor ⚡  │
  └──── 23.5/s ─────┘
          ⣿
  ┌─────────────────┐
  │ ◀ consumer ⏸   │
  └─────────────────┘
```

**Box Components:**
- **Header Line**: Top border with stage name
- **Content**: Icon + Stage Name + Status Indicator
- **Footer**: Bottom border with throughput rate (when active)
- **Colors**: Status-based (green=active, yellow=bottleneck, red=error, gray=idle)

**Stage Icons:**
- `▶` Producer (generates data)
- `◆` Processor (transforms data)
- `◀` Consumer (consumes data)
- `⊞` Accumulator (batches items)
- `◇` Router (distributes to multiple stages)
- `⑂` Fork (IPC/COW process)

**Status Indicators:**
- `⚡` Active (currently processing)
- `⏸` Idle (waiting for work)
- `⚠` Bottleneck (slowest stage)
- `✖` Error (failures detected)
- `✓` Done (completed)

**Connection Animations:**
- Active connections show flowing Braille characters: `⠀⠁⠃⠇⠏⠟⠿⡿⣿`
- Horizontal lines pulse with dashed patterns: `─╌┄┈`
- Inactive connections shown as static gray lines
- Flow direction top-to-bottom through pipeline stages

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
- **Pipeline status**: RUNNING, PAUSED, or FINISHED
- **Pipeline name**: Current pipeline being monitored
- **Keyboard hints**: Available controls (changes to "Press [q] to exit..." when finished)

## Example

See `examples/hud_demo.rb` for a complete working example:

```bash
ruby examples/hud_demo.rb
```

This demo creates a multi-stage pipeline with varying latencies to demonstrate the HUD's monitoring capabilities.

## API Reference

### Task Instance Methods

When using the DSL, tasks have these methods for background execution and monitoring:

#### `task.run(background: true)`

Run the task in a background thread. Returns immediately.

**Example:**
```ruby
task = MyTask.new
task.run(background: true)
# Task running in background (Thread #12345)
# Use task.hud to open the HUD monitor
# Use task.stop to stop execution
```

#### `task.hud`

Open HUD monitor for the running pipeline. Blocks until user quits (`q`).
Can be called multiple times - close and reopen as needed.

**Example:**
```ruby
task.hud  # Opens HUD
# Press 'q' to close
task.hud  # Open again
```

#### `task.running?`

Check if task is running in background. Returns `true` or `false`.

**Example:**
```ruby
task.running?  # => true
task.stop
task.running?  # => false
```

#### `task.stop`

Stop background execution immediately.

**Example:**
```ruby
task.stop
# Background task stopped
```

#### `task.wait`

Wait for background task to complete. Blocks until finished.

**Example:**
```ruby
task.run(background: true)
task.wait  # Blocks until complete
# Background task completed
```

### Module Methods

### `Minigun::HUD.launch(pipeline)`

Launch HUD for a pipeline. Blocks until user quits.

**Parameters:**
- `pipeline` - A `Minigun::Pipeline` instance

**Example:**
```ruby
pipeline = task.instance_variable_get(:@_minigun_task).root_pipeline
Minigun::HUD.launch(pipeline)
```

### `Minigun::HUD.run_with_hud(task)`

Run a task with HUD monitoring. Automatically manages HUD lifecycle.

**Parameters:**
- `task` - A task class or instance (must have a pipeline)

**Returns:** Nothing (blocks until completion or user quits)

**Example:**
```ruby
Minigun::HUD.run_with_hud(MyTask)
# or
Minigun::HUD.run_with_hud(MyTask.new)
```

### `Minigun::HUD::Controller.new(pipeline, on_quit: nil)`

Create a HUD controller for manual management.

**Parameters:**
- `pipeline` - A `Minigun::Pipeline` instance
- `on_quit` - Optional callback lambda called when user quits

**Methods:**
- `start()` - Start the HUD (blocks)
- `stop()` - Stop the HUD
- `running` - Boolean indicating if HUD is running
- `paused` - Boolean indicating if HUD is paused

**Example:**
```ruby
hud = Minigun::HUD::Controller.new(pipeline)
hud_thread = Thread.new { hud.start }

# Do work...

hud.stop
hud_thread.join
```

### Color Theme

Access theme colors via `Minigun::HUD::Theme`:

```ruby
Theme.primary         # Matrix green
Theme.secondary       # Cyan
Theme.success        # Bright green
Theme.warning        # Yellow
Theme.danger         # Red
Theme.stage_active   # Bold bright green
Theme.stage_idle     # Gray
```

### Icons

```ruby
Theme.stage_icon(:producer)    # ▶
Theme.stage_icon(:processor)   # ◆
Theme.stage_icon(:consumer)    # ◀
Theme.stage_icon(:accumulator) # ⊞
Theme.stage_icon(:router)      # ◇
Theme.stage_icon(:fork)        # ⑂

Theme.status_indicator(:active)     # ⚡
Theme.status_indicator(:idle)       # ⏸
Theme.status_indicator(:bottleneck) # ⚠
Theme.status_indicator(:error)      # ✖
Theme.status_indicator(:done)       # ✓
```

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
