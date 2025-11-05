# frozen_string_literal: true

module Minigun
  module HUD
    # Non-blocking keyboard input handler
    class Keyboard
      # Read a single keypress without blocking
      # Returns nil if no key is pressed
      def self.read_nonblocking
        return nil unless IO.select([$stdin], nil, nil, 0)

        char = $stdin.getc

        # Handle special keys (arrows, etc)
        if char == "\e"
          # Escape sequence
          next_char = $stdin.getc
          if next_char == '['
            # ANSI escape sequence
            case $stdin.getc
            when 'A' then :up
            when 'B' then :down
            when 'C' then :right
            when 'D' then :left
            else nil
            end
          else
            :escape
          end
        else
          char
        end
      rescue StandardError
        nil
      end

      # Key mappings
      KEYS = {
        quit: ['q', 'Q', "\u0003"], # q, Q, or Ctrl+C
        pause: [' '],                # Space
        help: ['h', 'H', '?'],
        refresh: ['r', 'R'],
        detail: ['d', 'D'],
        compact: ['c', 'C'],
        expand: ['e', 'E'],
        reset: ['0']
      }.freeze

      # Check if a key matches an action
      def self.matches?(key, action)
        KEYS[action]&.include?(key) || false
      end
    end
  end
end
