# frozen_string_literal: true

module Minigun
  module HUD
    # Renders process/stage statistics as a table
    class ProcessList
      attr_reader :width, :height
      attr_accessor :scroll_offset

      def initialize(width, height)
        @width = width
        @height = height
        @scroll_offset = 0
      end

      # Render the process list to terminal
      def render(terminal, stats_data, x_offset: 0, y_offset: 0)
        return unless stats_data

        # Draw title bar
        title = "PROCESS STATS"
        terminal.write_at(x_offset + 2, y_offset, title, color: Theme.border_active + Terminal::COLORS[:bold])

        # Pipeline summary
        y = y_offset + 1
        render_pipeline_summary(terminal, stats_data, x_offset, y)

        # Table header
        y += 3
        render_table_header(terminal, x_offset, y)

        # Stages
        y += 2
        stages = stats_data[:stages] || []
        visible_height = @height - 8

        stages.each_with_index do |stage_data, index|
          next if index < @scroll_offset
          break if y >= y_offset + @height - 2

          render_stage_row(terminal, stage_data, x_offset, y, index)
          y += 1
        end

        # Scroll indicator
        if stages.length > visible_height
          indicator = "↓ #{stages.length - visible_height - @scroll_offset} more"
          terminal.write_at(x_offset + 2, y_offset + @height - 2, indicator, color: Theme.muted)
        end
      end

      private

      def render_pipeline_summary(terminal, stats_data, x, y)
        runtime = stats_data[:runtime] || 0
        throughput = stats_data[:throughput] || 0
        total_produced = stats_data[:total_produced] || 0
        total_consumed = stats_data[:total_consumed] || 0

        # Line 1: Runtime and overall throughput
        line1 = "Runtime: #{Theme.info}#{runtime.round(2)}s#{Terminal::COLORS[:reset]} | " \
                "Throughput: #{Theme.format_throughput(throughput)} i/s"
        terminal.write_at(x + 2, y, line1)

        # Line 2: Items
        line2 = "Produced: #{Theme.success}#{total_produced}#{Terminal::COLORS[:reset]} | " \
                "Consumed: #{Theme.success}#{total_consumed}#{Terminal::COLORS[:reset]}"
        terminal.write_at(x + 2, y + 1, line2)
      end

      def render_table_header(terminal, x, y)
        # Headers
        headers = [
          { text: "STAGE", width: 20 },
          { text: "STATUS", width: 8 },
          { text: "ITEMS", width: 10 },
          { text: "THRU", width: 10 },
          { text: "P50", width: 8 },
          { text: "P99", width: 8 }
        ]

        x_pos = x + 2
        headers.each do |header|
          text = header[:text].ljust(header[:width])
          terminal.write_at(x_pos, y, text, color: Theme.secondary + Terminal::COLORS[:bold])
          x_pos += header[:width]
        end

        # Separator line
        separator = "─" * (@width - 4)
        terminal.write_at(x + 2, y + 1, separator, color: Theme.border)
      end

      def render_stage_row(terminal, stage_data, x, y, _index)
        name = stage_data[:stage_name].to_s
        status = determine_status(stage_data)

        # Column 1: Stage name with icon
        type = stage_data[:type] || :processor
        icon = Theme.stage_icon(type)
        name_text = "#{icon} #{truncate(name, 17)}"
        terminal.write_at(x + 2, y, name_text, color: stage_color(status))

        x_pos = x + 22

        # Column 2: Status indicator
        indicator = Theme.status_indicator(status)
        terminal.write_at(x_pos, y, indicator.ljust(8), color: stage_color(status))
        x_pos += 8

        # Column 3: Items (produced or consumed)
        items = stage_data[:total_items] || 0
        items_text = format_number(items).rjust(10)
        terminal.write_at(x_pos, y, items_text, color: Theme.text)
        x_pos += 10

        # Column 4: Throughput
        throughput = stage_data[:throughput] || 0
        throughput_text = format_throughput_short(throughput).rjust(10)
        terminal.write_at(x_pos, y, throughput_text, color: throughput_color(throughput))
        x_pos += 10

        # Column 5: P50 latency
        if stage_data[:latency] && stage_data[:latency][:p50]
          p50 = stage_data[:latency][:p50]
          p50_text = "#{p50.round(1)}ms".rjust(8)
          terminal.write_at(x_pos, y, p50_text, color: latency_color(p50))
        else
          terminal.write_at(x_pos, y, "-".rjust(8), color: Theme.muted)
        end
        x_pos += 8

        # Column 6: P99 latency
        if stage_data[:latency] && stage_data[:latency][:p99]
          p99 = stage_data[:latency][:p99]
          p99_text = "#{p99.round(1)}ms".rjust(8)
          terminal.write_at(x_pos, y, p99_text, color: latency_color(p99))
        else
          terminal.write_at(x_pos, y, "-".rjust(8), color: Theme.muted)
        end
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

      def stage_color(status)
        case status
        when :active then Theme.stage_active
        when :bottleneck then Theme.stage_bottleneck
        when :error then Theme.stage_error
        when :done then Theme.stage_done
        else Theme.stage_idle
        end
      end

      def throughput_color(value)
        return Theme.muted if value == 0

        if value > 100
          Theme.throughput_high
        elsif value > 10
          Theme.throughput_medium
        else
          Theme.throughput_low
        end
      end

      def latency_color(ms)
        if ms < 10
          Theme.success
        elsif ms < 100
          Theme.warning
        else
          Theme.danger
        end
      end

      def truncate(text, max_length)
        return text if text.length <= max_length

        text[0...(max_length - 2)] + ".."
      end

      def format_number(value)
        if value > 1_000_000
          "#{(value / 1_000_000.0).round(1)}M"
        elsif value > 1000
          "#{(value / 1000.0).round(1)}K"
        else
          value.to_s
        end
      end

      def format_throughput_short(value)
        return "0" if value == 0

        if value > 1000
          "#{(value / 1000.0).round(1)}K/s"
        else
          "#{value.round(1)}/s"
        end
      end
    end
  end
end
