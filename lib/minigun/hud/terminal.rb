# frozen_string_literal: true

require 'io/console'

module Minigun
  module HUD
    # Terminal control using ANSI escape sequences
    # Provides cursor control, colors, and double-buffered rendering
    class Terminal
      attr_reader :width, :height

      def initialize
        # Handle non-TTY environments (CI, piped output, etc.)
        if IO.console
          @width, @height = IO.console.winsize.reverse
        else
          # Default dimensions for non-TTY
          @width = 120
          @height = 40
        end
        @buffer = []
        @previous_buffer = []
      end

      # Update terminal dimensions
      def update_size
        if IO.console
          @width, @height = IO.console.winsize.reverse
        end
      end

      # Clear the terminal
      def clear
        print "\e[2J\e[H"
      end

      # Hide cursor
      def hide_cursor
        print "\e[?25l"
      end

      # Show cursor
      def show_cursor
        print "\e[?25h"
      end

      # Move cursor to position (x, y) - 1-indexed
      def move_to(x, y)
        print "\e[#{y};#{x}H"
      end

      # Clear current line
      def clear_line
        print "\e[2K"
      end

      # Write text at position with optional color
      def write_at(x, y, text, color: nil)
        @buffer << { x: x, y: y, text: text, color: color }
      end

      # Draw a box
      def draw_box(x, y, w, h, title: nil, color: nil)
        # Top border
        top_line = "┌" + ("─" * (w - 2)) + "┐"
        top_line = "┌─ #{title} " + ("─" * (w - 5 - title.length)) + "┐" if title

        write_at(x, y, top_line, color: color)

        # Sides
        (1...h-1).each do |i|
          write_at(x, y + i, "│" + (" " * (w - 2)) + "│", color: color)
        end

        # Bottom border
        write_at(x, y + h - 1, "└" + ("─" * (w - 2)) + "┘", color: color)
      end

      # Render the buffer to screen (double-buffered)
      def render
        # Only redraw changed parts
        @buffer.each_with_index do |item, index|
          if @previous_buffer[index] != item
            move_to(item[:x], item[:y])
            if item[:color]
              print item[:color] + item[:text] + COLORS[:reset]
            else
              print item[:text]
            end
          end
        end

        @previous_buffer = @buffer.dup
        @buffer.clear
      end

      # Setup terminal for TUI mode
      def setup
        return unless IO.console

        hide_cursor
        clear
        # Enable raw mode for immediate key input
        $stdin.raw!
        # Disable echo
        $stdin.echo = false
      end

      # Restore terminal to normal mode
      def teardown
        return unless IO.console

        show_cursor
        clear
        # Restore cooked mode
        $stdin.cooked!
        $stdin.echo = true
        move_to(1, 1)
      end

      # ANSI color codes (cyberpunk theme)
      COLORS = {
        reset: "\e[0m",

        # Matrix green theme
        green: "\e[38;5;46m",        # Bright green
        green_dim: "\e[38;5;28m",    # Dim green
        green_bright: "\e[38;5;118m", # Very bright green

        # Cyberpunk accents
        cyan: "\e[38;5;51m",         # Bright cyan
        cyan_dim: "\e[38;5;37m",     # Dim cyan
        magenta: "\e[38;5;201m",     # Hot pink
        blue: "\e[38;5;33m",         # Electric blue
        yellow: "\e[38;5;226m",      # Warning yellow
        red: "\e[38;5;196m",         # Alert red
        orange: "\e[38;5;208m",      # Orange

        # Grays for UI chrome
        gray: "\e[38;5;240m",
        gray_light: "\e[38;5;248m",
        white: "\e[38;5;231m",

        # Background colors
        bg_black: "\e[48;5;0m",
        bg_gray_dark: "\e[48;5;232m",

        # Bold/effects
        bold: "\e[1m",
        dim: "\e[2m",
        italic: "\e[3m",
        underline: "\e[4m",
        blink: "\e[5m",
        reverse: "\e[7m"
      }.freeze
    end
  end
end
