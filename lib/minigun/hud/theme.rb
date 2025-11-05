# frozen_string_literal: true

module Minigun
  module HUD
    # Cyberpunk-inspired color theme (Matrix/Blade Runner/Hackers)
    module Theme
      # Color palette
      def self.primary
        Terminal::COLORS[:green]
      end

      def self.secondary
        Terminal::COLORS[:cyan]
      end

      def self.accent
        Terminal::COLORS[:magenta]
      end

      def self.warning
        Terminal::COLORS[:yellow]
      end

      def self.danger
        Terminal::COLORS[:red]
      end

      def self.success
        Terminal::COLORS[:green_bright]
      end

      def self.info
        Terminal::COLORS[:blue]
      end

      def self.muted
        Terminal::COLORS[:gray]
      end

      def self.text
        Terminal::COLORS[:white]
      end

      # Stage status colors
      def self.stage_active
        Terminal::COLORS[:green_bright] + Terminal::COLORS[:bold]
      end

      def self.stage_idle
        Terminal::COLORS[:gray]
      end

      def self.stage_bottleneck
        Terminal::COLORS[:yellow] + Terminal::COLORS[:bold]
      end

      def self.stage_error
        Terminal::COLORS[:red] + Terminal::COLORS[:bold]
      end

      def self.stage_done
        Terminal::COLORS[:green_dim]
      end

      # Performance indicators
      def self.throughput_high
        Terminal::COLORS[:green_bright]
      end

      def self.throughput_medium
        Terminal::COLORS[:yellow]
      end

      def self.throughput_low
        Terminal::COLORS[:orange]
      end

      def self.throughput_critical
        Terminal::COLORS[:red]
      end

      # Box borders
      def self.border
        Terminal::COLORS[:cyan_dim]
      end

      def self.border_active
        Terminal::COLORS[:cyan]
      end

      # Animation chars for data flow
      FLOW_CHARS = ['⠀', '⠁', '⠃', '⠇', '⠏', '⠟', '⠿', '⡿', '⣿'].freeze
      SPARK_CHARS = ['⢀', '⢠', '⢰', '⢸', '⡀', '⣀', '⣠', '⣰', '⣸'].freeze
      DOTS = ['⠁', '⠂', '⠄', '⡀', '⢀', '⠠', '⠐', '⠈'].freeze

      # Stage type icons
      def self.stage_icon(stage_type)
        case stage_type
        when :producer
          "▶"
        when :processor
          "◆"
        when :consumer
          "◀"
        when :accumulator
          "⊞"
        when :router
          "◇"
        when :fork
          "⑂"
        else
          "●"
        end
      end

      # Status indicators
      def self.status_indicator(status)
        case status
        when :active
          "⚡"
        when :idle
          "⏸"
        when :bottleneck
          "⚠"
        when :error
          "✖"
        when :done
          "✓"
        else
          "●"
        end
      end

      # Format numbers with colors based on magnitude
      def self.format_throughput(value)
        color = if value > 1000
                  throughput_high
                elsif value > 100
                  throughput_medium
                elsif value > 10
                  throughput_low
                else
                  throughput_critical
                end

        formatted = if value > 1_000_000
                      "#{(value / 1_000_000.0).round(2)}M"
                    elsif value > 1000
                      "#{(value / 1000.0).round(2)}K"
                    else
                      value.round(2).to_s
                    end

        "#{color}#{formatted}#{Terminal::COLORS[:reset]}"
      end

      # Format latency with color
      def self.format_latency(ms)
        color = if ms < 10
                  success
                elsif ms < 100
                  throughput_medium
                elsif ms < 1000
                  warning
                else
                  danger
                end

        "#{color}#{ms.round(1)}ms#{Terminal::COLORS[:reset]}"
      end

      # Format percentages
      def self.format_percentage(value)
        color = if value > 90
                  success
                elsif value > 70
                  throughput_medium
                elsif value > 50
                  warning
                else
                  danger
                end

        "#{color}#{value.round(1)}%#{Terminal::COLORS[:reset]}"
      end

      # Cyberpunk banner/logo
      def self.logo
        [
          "███╗   ███╗██╗███╗   ██╗██╗ ██████╗ ██╗   ██╗███╗   ██╗",
          "████╗ ████║██║████╗  ██║██║██╔════╝ ██║   ██║████╗  ██║",
          "██╔████╔██║██║██╔██╗ ██║██║██║  ███╗██║   ██║██╔██╗ ██║",
          "██║╚██╔╝██║██║██║╚██╗██║██║██║   ██║██║   ██║██║╚██╗██║",
          "██║ ╚═╝ ██║██║██║ ╚████║██║╚██████╔╝╚██████╔╝██║ ╚████║",
          "╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝",
          "                    GO BRRRRR 🔥                       "
        ]
      end
    end
  end
end
