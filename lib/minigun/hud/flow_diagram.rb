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
      end

      # Render the flow diagram to terminal
      def render(terminal, stats_data, x_offset: 0, y_offset: 0)
        return unless stats_data && stats_data[:stages]

        # Draw title
        title = "PIPELINE FLOW"
        terminal.write_at(x_offset + 2, y_offset, title, color: Theme.border_active + Terminal::COLORS[:bold])

        stages = stats_data[:stages]
        return if stages.empty?

        # Calculate layout (boxes with positions)
        layout = calculate_layout(stages)

        # Render connections first (so they appear behind boxes)
        render_connections(terminal, layout, stages, x_offset, y_offset)

        # Render stage boxes
        layout.each do |stage_name, pos|
          stage_data = stages.find { |s| s[:stage_name] == stage_name }
          next unless stage_data

          render_stage_box(terminal, stage_data, pos, x_offset, y_offset)
        end

        # Update animation
        @animation_frame = (@animation_frame + 1) % 60
      end

      private

      # Calculate box positions using simple vertical layout with layers
      # For more complex DAGs, this could be enhanced with proper graph layout
      def calculate_layout(stages)
        layout = {}
        layer_height = 4  # Height for each box + spacing
        box_width = [@width - 6, 16].min
        box_height = 3

        # Simple vertical stacking
        stages.each_with_index do |stage_data, idx|
          stage_name = stage_data[:stage_name]
          y = 2 + (idx * layer_height)

          # Skip if it would be off-screen
          next if y + box_height >= @height

          # Center horizontally
          x = (@width - box_width) / 2

          layout[stage_name] = { x: x, y: y, width: box_width, height: box_height }
        end

        layout
      end

      # Render connections between stages
      def render_connections(terminal, layout, stages, x_offset, y_offset)
        stages.each_with_index do |stage_data, idx|
          next if idx >= stages.length - 1  # Last stage has no outgoing connections

          from_name = stage_data[:stage_name]
          from_pos = layout[from_name]
          next unless from_pos

          # Connect to next stage
          to_stage = stages[idx + 1]
          to_name = to_stage[:stage_name]
          to_pos = layout[to_name]
          next unless to_pos

          # Draw connection
          render_connection_line(terminal, from_pos, to_pos, stage_data, x_offset, y_offset)
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

        # Draw vertical line with flowing animation
        (from_y...to_y).each do |y|
          next if y < 0 || y >= @height

          # Animated flowing character
          char = if active
                   # Use animation frame to create flowing effect
                   offset = (@animation_frame / 4) % Theme::FLOW_CHARS.length
                   phase = (y - from_y + offset) % Theme::FLOW_CHARS.length
                   Theme::FLOW_CHARS[phase]
                 else
                   "│"
                 end

          color = active ? Theme.primary : Theme.muted

          terminal.write_at(x_offset + from_x, y_offset + y, char, color: color)
        end

        # If stages are not vertically aligned, draw horizontal segment
        if from_x != to_x
          x_start = [from_x, to_x].min
          x_end = [from_x, to_x].max
          (x_start..x_end).each do |x|
            next if x < 0 || x >= @width

            char = if active
                     # Animated horizontal flow
                     offset = (@animation_frame / 4) % 4
                     ["─", "╌", "┄", "┈"][offset]
                   else
                     "─"
                   end

            color = active ? Theme.primary : Theme.muted

            terminal.write_at(x_offset + x, y_offset + from_y, char, color: color)
          end

          # Corner characters
          color = active ? Theme.primary : Theme.muted
          if from_x < to_x
            terminal.write_at(x_offset + from_x, y_offset + from_y, "└", color: color)
            terminal.write_at(x_offset + to_x, y_offset + from_y, "┐", color: color) if to_y > from_y
          elsif from_x > to_x
            terminal.write_at(x_offset + from_x, y_offset + from_y, "┘", color: color)
            terminal.write_at(x_offset + to_x, y_offset + from_y, "┌", color: color) if to_y > from_y
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
