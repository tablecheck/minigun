# frozen_string_literal: true

module Minigun
  module HUD
    # Renders pipeline DAG as animated ASCII flow diagram
    class FlowDiagram
      attr_reader :width, :height

      def initialize(width, height)
        @width = width
        @height = height
        @animation_frame = 0
        @particles = [] # Moving particles showing data flow
      end

      # Render the flow diagram to terminal
      def render(terminal, stats_data, x_offset: 0, y_offset: 0)
        return unless stats_data && stats_data[:stages]

        # Draw title
        title = "PIPELINE FLOW"
        terminal.write_at(x_offset + 2, y_offset, title, color: Theme.border_active + Terminal::COLORS[:bold])

        # Calculate layout
        stages = stats_data[:stages]
        return if stages.empty?

        # Simple vertical layout for now
        y = y_offset + 2
        spacing = 3

        stages.each_with_index do |stage_data, index|
          next if y + spacing > y_offset + @height - 2

          # Render stage node
          render_stage_node(terminal, stage_data, x_offset + 2, y)

          # Render connector to next stage
          if index < stages.length - 1
            render_connector(terminal, stage_data, x_offset + 2, y + 1)
          end

          y += spacing
        end

        # Update animation
        @animation_frame = (@animation_frame + 1) % 60
      end

      private

      def render_stage_node(terminal, stage_data, x, y)
        name = stage_data[:stage_name]
        status = determine_status(stage_data)
        type = stage_data[:type] || :processor

        # Truncate name if too long
        max_name_width = @width - 10
        display_name = name.to_s.length > max_name_width ? name.to_s[0...(max_name_width - 2)] + ".." : name.to_s

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

        # Render node: [icon] name indicator
        # Calculate visual length (without ANSI codes)
        visual_text = "#{icon} #{display_name} #{indicator}"

        # Add throughput if available, but ensure total doesn't exceed width
        if stage_data[:throughput] && stage_data[:throughput] > 0
          throughput_suffix = " (#{format_throughput(stage_data[:throughput])} i/s)"
          # Check if adding throughput would exceed width
          if visual_text.length + throughput_suffix.length <= @width
            visual_text += throughput_suffix
          end
        end

        # Truncate if still too long
        visual_text = visual_text[0...@width] if visual_text.length > @width

        terminal.write_at(x, y, visual_text, color: color)
      end

      def render_connector(terminal, stage_data, x, y)
        # Animated connector showing data flow
        active = stage_data[:throughput] && stage_data[:throughput] > 0

        if active
          # Animate with flowing characters
          frame_mod = @animation_frame % Theme::FLOW_CHARS.length
          char = Theme::FLOW_CHARS[frame_mod]
          color = Theme.primary
        else
          # Static connector
          char = "│"
          color = Theme.muted
        end

        terminal.write_at(x + 1, y, char, color: color)
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
        if value > 1_000_000_000
          "#{(value / 1_000_000_000.0).round(1)}B"
        elsif value > 1_000_000
          "#{(value / 1_000_000.0).round(1)}M"
        elsif value > 1_000
          "#{(value / 1_000.0).round(1)}K"
        else
          value.round(1).to_s
        end
      end
    end
  end
end
