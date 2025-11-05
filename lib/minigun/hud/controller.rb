# frozen_string_literal: true

require 'io/console'

module Minigun
  module HUD
    # Main HUD controller - orchestrates all components
    class Controller
      FPS = 15 # Refresh rate
      FRAME_TIME = 1.0 / FPS

      attr_reader :terminal, :flow_diagram, :process_list, :stats_aggregator
      attr_accessor :running, :paused, :pipeline_finished

      def initialize(pipeline, on_quit: nil)
        @pipeline = pipeline
        @terminal = Terminal.new
        @stats_aggregator = StatsAggregator.new(pipeline)
        @running = false
        @paused = false
        @pipeline_finished = false
        @show_help = false
        @resize_requested = false
        @on_quit = on_quit  # Optional callback when user quits

        # Calculate layout (2-column split)
        calculate_layout

        # Set up terminal resize handler
        setup_resize_handler
      end

      # Start the HUD
      def start
        @running = true
        @terminal.setup

        # Render initial screen
        render_frame

        # Main event loop
        loop do
          frame_start = Time.now

          # Check for terminal resize
          if @resize_requested
            @resize_requested = false
            @terminal.clear
            @terminal.reset_buffers
            calculate_layout
          end

          # Handle keyboard input
          handle_input
          break unless @running

          # Update and render if not paused (or if finished - always show final state)
          unless @paused && !@pipeline_finished
            render_frame
          end

          # Sleep to maintain consistent FPS
          elapsed = Time.now - frame_start
          sleep([FRAME_TIME - elapsed, 0].max)
        end
      ensure
        cleanup_resize_handler
        @terminal.teardown
      end

      # Stop the HUD
      def stop
        @running = false
      end

      private

      def calculate_layout
        @terminal.update_size
        width = @terminal.width
        height = @terminal.height

        # Split screen: 40% left (flow), 60% right (stats)
        @left_width = (width * 0.4).to_i
        @right_width = width - @left_width

        # Components - resize existing or create new
        if @flow_diagram
          @flow_diagram.resize(@left_width - 2, height - 4)
        else
          @flow_diagram = FlowDiagramFrame.new(@left_width - 2, height - 4)
        end

        # Preserve scroll offset if process_list exists
        old_scroll = @process_list&.scroll_offset || 0
        @process_list = ProcessList.new(@right_width - 2, height - 4)
        @process_list.scroll_offset = old_scroll
      end

      def render_frame
        # Check minimum terminal size
        if @terminal.width < 60 || @terminal.height < 10
          @terminal.clear
          @terminal.reset_buffers
          msg = "Terminal too small! Minimum: 60x10, Current: #{@terminal.width}x#{@terminal.height}"
          @terminal.write_at(1, 1, msg, color: Theme.warning)
          @terminal.render
          return
        end

        # Collect fresh stats
        stats_data = @stats_aggregator.collect
        return unless stats_data

        # Draw boxes
        @terminal.draw_box(1, 1, @left_width, @terminal.height - 2,
                           title: "FLOW DIAGRAM", color: Theme.border)

        @terminal.draw_box(@left_width + 1, 1, @right_width, @terminal.height - 2,
                           title: "PROCESS STATISTICS", color: Theme.border)

        # Render flow diagram (left panel)
        # Clear panel if frame needs it (e.g., after panning)
        if @flow_diagram.needs_clear?
          panel_height = @terminal.height - 4
          (0...panel_height).each do |y|
            @terminal.write_at(2, 2 + y, " " * (@left_width - 2))
          end
          @flow_diagram.mark_cleared
        end

        # Render diagram - frame handles centering and panning
        @flow_diagram.render(@terminal, stats_data, x_offset: 2, y_offset: 2)

        # Render process list (right panel)
        @process_list.render(@terminal, stats_data, x_offset: @left_width + 1, y_offset: 2)

        # Status bar at bottom
        render_status_bar

        # Help overlay
        render_help_overlay if @show_help

        # Flush to screen
        @terminal.render
      end

      def render_status_bar
        y = @terminal.height - 1
        status_text = if @pipeline_finished
                        "#{Theme.info}FINISHED#{Terminal::COLORS[:reset]}"
                      elsif @paused
                        "#{Theme.warning}PAUSED#{Terminal::COLORS[:reset]}"
                      else
                        "#{Theme.success}RUNNING#{Terminal::COLORS[:reset]}"
                      end

        # Left side: status and pipeline name
        left_text = "#{status_text} | Pipeline: #{Theme.info}#{@pipeline.name}#{Terminal::COLORS[:reset]}"
        @terminal.write_at(2, y, left_text)

        # Right side: controls hint
        right_text = if @pipeline_finished
                       "Press [q] to exit..."
                     else
                       "[h] Help [q] Quit [space] Pause"
                     end
        @terminal.write_at(@terminal.width - right_text.length - 2, y, right_text, color: Theme.muted)
      end

      def render_help_overlay
        # Center overlay
        overlay_width = 60
        overlay_height = 16
        x = (@terminal.width - overlay_width) / 2
        y = (@terminal.height - overlay_height) / 2

        # Draw help box
        @terminal.draw_box(x, y, overlay_width, overlay_height,
                           title: "KEYBOARD CONTROLS", color: Theme.border_active)

        # Help content
        help_lines = [
          "",
          "  Navigation:",
          "    ↑ / ↓     - Scroll process list",
          "    w / s     - Pan diagram up/down",
          "    a / d     - Pan diagram left/right",
          "",
          "  Controls:",
          "    SPACE     - Pause/Resume updates",
          "    r / R     - Force refresh/resize",
          "    c / C     - Compact view (future)",
          "",
          "  Other:",
          "    h / H / ? - Toggle this help",
          "    q / Q     - Quit HUD",
          "    Ctrl+C    - Quit HUD",
          "",
          "  Press any key to close this help..."
        ]

        help_lines.each_with_index do |line, index|
          @terminal.write_at(x + 2, y + index + 1, line, color: Theme.text)
        end
      end

      def handle_input
        key = Keyboard.read_nonblocking
        return unless key

        # If help is showing, any key closes it (except for toggling help again)
        if @show_help && key != 'h' && key != 'H' && key != '?'
          @show_help = false
          # q still quits even when help is shown
          if key == 'q' || key == 'Q' || key == "\u0003"
            @running = false
            @on_quit&.call
          end
          return
        end

        case key
        when 'q', 'Q', "\u0003" # q, Q, or Ctrl+C
          @running = false
          @on_quit&.call  # Notify that user requested quit

        when ' ' # Space - pause/resume
          @paused = !@paused

        when 'h', 'H', '?' # Help
          @show_help = !@show_help

        when 'r', 'R' # Force refresh
          @resize_requested = true

        when :up # Scroll up (process list)
          @process_list.scroll_offset = [@process_list.scroll_offset - 1, 0].max

        when :down # Scroll down (process list)
          @process_list.scroll_offset += 1

        when 'w', 'W' # Pan diagram up (move content up, see what's below)
          @flow_diagram.pan(0, 2)

        when 'a', 'A' # Pan diagram left (move content left, see what's right)
          @flow_diagram.pan(2, 0)

        when 's', 'S' # Pan diagram down (move content down, see what's above)
          @flow_diagram.pan(0, -2)

        when 'd', 'D' # Pan diagram right (move content right, see what's left)
          @flow_diagram.pan(-2, 0)

        when 'c', 'C' # Compact view
          # Future: implement compact view
        end
      rescue StandardError => e
        # Log error but don't crash HUD
        warn "Error handling input: #{e.message}"
      end

      def setup_resize_handler
        return unless Signal.list.key?('WINCH')

        @resize_handler = Signal.trap('WINCH') do
          @resize_requested = true
        end
      rescue StandardError => e
        # SIGWINCH not supported on this platform
        warn "Terminal resize detection not available: #{e.message}" if $DEBUG
      end

      def cleanup_resize_handler
        return unless @resize_handler

        Signal.trap('WINCH', @resize_handler)
      rescue StandardError
        # Ignore cleanup errors
      end
    end
  end
end
