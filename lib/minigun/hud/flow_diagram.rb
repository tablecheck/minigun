# frozen_string_literal: true

module Minigun
  module HUD
    # Renders pipeline DAG as animated ASCII flow diagram with boxes and connections
    class FlowDiagram
      attr_reader :width, :height

      def initialize(width, height)
        @width = width
        @height = height
        @animation_frame = 0
        @pan_x = 0  # Horizontal pan offset
        @pan_y = 0  # Vertical pan offset
        @needs_clear = false  # Flag to indicate if we need to clear before rendering
      end

      # Pan the diagram
      def pan(dx, dy)
        @pan_x += dx
        @pan_y += dy
        @needs_clear = true  # Mark that we need to clear on next render
      end

      # Render the flow diagram to terminal
      def render(terminal, stats_data, x_offset: 0, y_offset: 0)
        return unless stats_data && stats_data[:stages]

        # Clear the diagram area if panning occurred
        if @needs_clear
          clear_diagram_area(terminal, x_offset, y_offset)
          @needs_clear = false
        end

        # Draw title
        title = "PIPELINE FLOW"
        terminal.write_at(x_offset + 2, y_offset, title, color: Theme.border_active + Terminal::COLORS[:bold])

        stages = stats_data[:stages]
        return if stages.empty?

        # Calculate layout (boxes with positions)
        layout = calculate_layout(stages)

        # Clamp pan offsets to prevent panning outside the diagram bounds
        clamp_pan_offsets(layout)

        # Apply pan offset: shift all positions
        # Pan acts as a viewport offset - positive pan moves viewport right (content appears left)
        view_x_offset = x_offset - @pan_x
        view_y_offset = y_offset - @pan_y

        # Render connections first (so they appear behind boxes)
        render_connections(terminal, layout, stages, view_x_offset, view_y_offset)

        # Render stage boxes
        layout.each do |stage_name, pos|
          stage_data = stages.find { |s| s[:stage_name] == stage_name }
          next unless stage_data

          render_stage_box(terminal, stage_data, pos, view_x_offset, view_y_offset)
        end

        # Update animation
        @animation_frame = (@animation_frame + 1) % 60
      end

      private

      # Clear the diagram area to prevent ghost trails when panning
      def clear_diagram_area(terminal, x_offset, y_offset)
        # Clear entire diagram area including title line
        (0...@height).each do |y|
          terminal.write_at(x_offset, y_offset + y, " " * @width)
        end
      end

      # Clamp pan offsets to keep at least some diagram content visible
      def clamp_pan_offsets(layout)
        return if layout.empty?

        # Find diagram bounds
        min_x = layout.values.map { |pos| pos[:x] }.min
        max_x = layout.values.map { |pos| pos[:x] + pos[:width] }.max
        min_y = layout.values.map { |pos| pos[:y] }.min
        max_y = layout.values.map { |pos| pos[:y] + pos[:height] }.max

        # Clamp pan_x: allow panning to see all content
        # Can pan right until leftmost element is at left edge of viewport
        max_pan_x = min_x
        # Can pan left until rightmost element is at right edge of viewport
        min_pan_x = max_x - @width

        # Clamp pan_y: allow panning to see all content
        # Can pan down until topmost element is at top edge (below title at y=2)
        max_pan_y = min_y - 2
        # Can pan up until bottommost element is at bottom edge
        min_pan_y = max_y - @height

        # Apply clamping
        @pan_x = [[@pan_x, min_pan_x].max, max_pan_x].min
        @pan_y = [[@pan_y, min_pan_y].max, max_pan_y].min
      end

      # Calculate box positions using DAG-based layered layout
      def calculate_layout(stages)
        layout = {}
        box_width = 14
        box_height = 3
        layer_height = 4  # Vertical spacing between layers
        box_spacing = 2   # Horizontal spacing between boxes

        # Build adjacency list from stages (fallback if no DAG info)
        stage_names = stages.map { |s| s[:stage_name] }

        # Calculate layers based on topological depth
        layers = calculate_layers(stages)

        # Position stages in each layer
        layers.each_with_index do |layer_stages, layer_idx|
          y = 2 + (layer_idx * layer_height)

          # Skip if layer would be off-screen
          next if y + box_height >= @height

          # Calculate total width needed for this layer
          total_width = (layer_stages.size * box_width) + ((layer_stages.size - 1) * box_spacing)

          # Start X position (center the layer)
          start_x = [(@width - total_width) / 2, 1].max

          # Position each stage in the layer horizontally
          layer_stages.each_with_index do |stage_name, stage_idx|
            x = start_x + (stage_idx * (box_width + box_spacing))

            # Ensure it fits
            next if x + box_width >= @width

            layout[stage_name] = {
              x: x,
              y: y,
              width: box_width,
              height: box_height,
              layer: layer_idx
            }
          end
        end

        layout
      end

      # Calculate layers (topological depth) for each stage
      def calculate_layers(stages)
        stage_names = stages.map { |s| s[:stage_name] }
        stage_map = stages.map { |s| [s[:stage_name], s] }.to_h

        # Build dependency map (who depends on whom)
        dependencies = {}
        stage_names.each { |name| dependencies[name] = [] }

        # For simple fan-out detection: find stages with same type that appear consecutively
        # This is a heuristic for when DAG edges aren't available
        producers = stages.select { |s| s[:type] == :producer }.map { |s| s[:stage_name] }
        consumers = stages.select { |s| s[:type] == :consumer }.map { |s| s[:stage_name] }
        routers = stages.select { |s| s[:type] == :router }.map { |s| s[:stage_name] }

        # Assign to layers
        layers = []

        # Layer 0: Producers
        layers << producers if producers.any?

        # Layer 1: Routers (if any)
        layers << routers if routers.any?

        # Layer 2: Consumers (parallel)
        layers << consumers if consumers.any?

        # If no clear structure, just stack vertically
        if layers.flatten.size != stage_names.size
          return stage_names.map { |name| [name] }
        end

        layers.reject(&:empty?)
      end

      # Render connections between stages
      def render_connections(terminal, layout, stages, x_offset, y_offset)
        # Group stages by layer to identify fan-out patterns
        stages_by_layer = layout.values.group_by { |pos| pos[:layer] }
        stage_map = stages.map { |s| [s[:stage_name], s] }.to_h

        # For each stage, find its downstream targets
        layout.each do |from_name, from_pos|
          stage_data = stage_map[from_name]
          next unless stage_data

          # Find downstream stages (next layer)
          next_layer = from_pos[:layer] + 1
          next_layer_stages = stages_by_layer[next_layer]
          next unless next_layer_stages

          # For producers/routers, connect to all stages in next layer (fan-out)
          # For others, connect to next stage only
          targets = if [:producer, :router].include?(stage_data[:type])
                      next_layer_stages.map { |pos| layout.key(pos) }
                    else
                      # Find the next stage in sequence
                      stage_idx = stages.index(stage_data)
                      next_stage = stages[stage_idx + 1] if stage_idx
                      next_stage ? [next_stage[:stage_name]] : []
                    end

          next if targets.empty?

          # Get target positions
          target_positions = targets.map { |name| layout[name] }.compact

          # Draw fan-out connection
          if target_positions.size > 1
            render_fanout_connection(terminal, from_pos, target_positions, stage_data, x_offset, y_offset)
          else
            render_connection_line(terminal, from_pos, target_positions.first, stage_data, x_offset, y_offset)
          end
        end
      end

      # Draw a fan-out connection (one source to multiple targets)
      def render_fanout_connection(terminal, from_pos, target_positions, stage_data, x_offset, y_offset)
        from_x = from_pos[:x] + from_pos[:width] / 2
        from_y = from_pos[:y] + from_pos[:height]

        # Check if connection is active
        active = stage_data[:throughput] && stage_data[:throughput] > 0
        color = active ? Theme.primary : Theme.muted

        # Calculate split point (midway between source and targets)
        first_target_y = target_positions.first[:y]
        split_y = from_y + 1

        # Draw vertical line from source to split point
        terminal.write_at(x_offset + from_x, y_offset + from_y, "│", color: color)

        # Get X positions of all targets
        target_xs = target_positions.map { |pos| pos[:x] + pos[:width] / 2 }.sort
        leftmost_x = target_xs.first
        rightmost_x = target_xs.last

        # Draw horizontal line across all targets
        (leftmost_x..rightmost_x).each do |x|
          next if x < 0 || x >= @width

          # Determine the character based on position
          char = if x == from_x && target_xs.include?(x)
                   "┼"  # Source is aligned with a target
                 elsif x == from_x
                   "┬"  # Source drops down to horizontal
                 elsif target_xs.include?(x)
                   "┬"  # Target drops down from horizontal
                 else
                   if active
                     offset = (@animation_frame / 4) % 4
                     ["─", "╌", "┄", "┈"][offset]
                   else
                     "─"
                   end
                 end

          terminal.write_at(x_offset + x, y_offset + split_y, char, color: color)
        end

        # Draw vertical lines down to each target
        target_positions.each do |to_pos|
          to_x = to_pos[:x] + to_pos[:width] / 2
          to_y = to_pos[:y]

          ((split_y + 1)...to_y).each do |y|
            next if y < 0 || y >= @height

            char = if active
                     offset = (@animation_frame / 4) % Theme::FLOW_CHARS.length
                     phase = (y - split_y + offset) % Theme::FLOW_CHARS.length
                     Theme::FLOW_CHARS[phase]
                   else
                     "│"
                   end

            terminal.write_at(x_offset + to_x, y_offset + y, char, color: color)
          end
        end
      end

      # Draw animated connection line between two boxes
      def render_connection_line(terminal, from_pos, to_pos, stage_data, x_offset, y_offset)
        # Connection from bottom center of from_box to top center of to_box
        from_x = from_pos[:x] + from_pos[:width] / 2
        from_y = from_pos[:y] + from_pos[:height]

        to_x = to_pos[:x] + to_pos[:width] / 2
        to_y = to_pos[:y]

        # Check if connection is active (has throughput)
        active = stage_data[:throughput] && stage_data[:throughput] > 0
        color = active ? Theme.primary : Theme.muted

        if from_x == to_x
          # Straight vertical line
          (from_y...to_y).each do |y|
            next if y < 0 || y >= @height

            char = if active
                     offset = (@animation_frame / 4) % Theme::FLOW_CHARS.length
                     phase = (y - from_y + offset) % Theme::FLOW_CHARS.length
                     Theme::FLOW_CHARS[phase]
                   else
                     "│"
                   end

            terminal.write_at(x_offset + from_x, y_offset + y, char, color: color)
          end
        else
          # L-shaped connection: vertical down, horizontal across, vertical down
          mid_y = from_y + 1

          # First vertical segment (short drop from source)
          terminal.write_at(x_offset + from_x, y_offset + from_y, "│", color: color)

          # Horizontal segment
          x_start = [from_x, to_x].min
          x_end = [from_x, to_x].max
          (x_start..x_end).each do |x|
            next if x < 0 || x >= @width

            char = if active
                     offset = (@animation_frame / 4) % 4
                     ["─", "╌", "┄", "┈"][offset]
                   else
                     "─"
                   end

            terminal.write_at(x_offset + x, y_offset + mid_y, char, color: color)
          end

          # Second vertical segment (drop to target)
          ((mid_y + 1)...to_y).each do |y|
            next if y < 0 || y >= @height

            char = if active
                     offset = (@animation_frame / 4) % Theme::FLOW_CHARS.length
                     phase = (y - mid_y + offset) % Theme::FLOW_CHARS.length
                     Theme::FLOW_CHARS[phase]
                   else
                     "│"
                   end

            terminal.write_at(x_offset + to_x, y_offset + y, char, color: color)
          end

          # Corner characters
          if from_x < to_x
            terminal.write_at(x_offset + from_x, y_offset + mid_y, "└", color: color)
            terminal.write_at(x_offset + to_x, y_offset + mid_y, "┐", color: color)
          else
            terminal.write_at(x_offset + from_x, y_offset + mid_y, "┘", color: color)
            terminal.write_at(x_offset + to_x, y_offset + mid_y, "┌", color: color)
          end
        end
      end

      # Render a stage as a box with icon, name, and status
      def render_stage_box(terminal, stage_data, pos, x_offset, y_offset)
        name = stage_data[:stage_name]
        status = determine_status(stage_data)
        type = stage_data[:type] || :processor

        # Truncate name to fit in box
        max_name_len = pos[:width] - 4  # Leave room for icon and padding
        display_name = if name.to_s.length > max_name_len
                         name.to_s[0...(max_name_len - 1)] + "…"
                       else
                         name.to_s
                       end

        # Status indicator and icon
        indicator = Theme.status_indicator(status)
        icon = Theme.stage_icon(type)

        # Color based on status
        color = case status
                when :active then Theme.stage_active
                when :bottleneck then Theme.stage_bottleneck
                when :error then Theme.stage_error
                when :done then Theme.stage_done
                else Theme.stage_idle
                end

        x = pos[:x]
        y = pos[:y]
        w = pos[:width]
        h = pos[:height]

        # Draw box borders
        # Top border
        terminal.write_at(x_offset + x, y_offset + y, "┌" + ("─" * (w - 2)) + "┐", color: Theme.border)

        # Middle line with content
        content = "#{icon} #{display_name} #{indicator}"
        padding_left = [(w - content.length - 2) / 2, 1].max
        padding_right = [w - content.length - padding_left - 2, 1].max

        terminal.write_at(x_offset + x, y_offset + y + 1,
                         "│" + (" " * padding_left) + content + (" " * padding_right) + "│",
                         color: color)

        # Bottom border with throughput if available
        bottom_line = "└" + ("─" * (w - 2)) + "┘"

        if stage_data[:throughput] && stage_data[:throughput] > 0
          throughput_text = format_throughput(stage_data[:throughput])
          label = " #{throughput_text}/s "

          if label.length <= w - 4
            # Center the label in the bottom border
            padding_left = (w - label.length - 2) / 2
            padding_right = w - label.length - padding_left - 2
            bottom_line = "└" + ("─" * padding_left) + label + ("─" * padding_right) + "┘"
          end
        end

        terminal.write_at(x_offset + x, y_offset + y + 2, bottom_line, color: Theme.border)
      end

      def determine_status(stage_data)
        return :error if stage_data[:items_failed] && stage_data[:items_failed] > 0
        return :bottleneck if stage_data[:is_bottleneck]

        if stage_data[:throughput]
          if stage_data[:throughput] > 0
            :active
          else
            :idle
          end
        elsif stage_data[:runtime] && stage_data[:runtime] > 0
          if stage_data[:end_time]
            :done
          else
            :active
          end
        else
          :idle
        end
      end

      def format_throughput(value)
        if value >= 1_000_000
          "#{(value / 1_000_000.0).round(1)}M"
        elsif value >= 1_000
          "#{(value / 1_000.0).round(1)}K"
        else
          value.round(1).to_s
        end
      end
    end
  end
end
