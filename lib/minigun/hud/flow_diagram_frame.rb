# frozen_string_literal: true

module Minigun
  module HUD
    # Terminal wrapper that clips writes to viewport boundaries
    class ClippedTerminal
      def initialize(terminal, viewport_x, viewport_y, viewport_width, viewport_height)
        @terminal = terminal
        @viewport_x = viewport_x
        @viewport_y = viewport_y
        @viewport_width = viewport_width
        @viewport_height = viewport_height
      end

      def write_at(x, y, text, color: nil)
        # Check if position is within viewport bounds
        return if y < @viewport_y || y >= @viewport_y + @viewport_height
        return if x >= @viewport_x + @viewport_width

        # Clip text if it extends beyond right edge of viewport
        if x < @viewport_x
          # Text starts before viewport - clip left portion
          chars_before = @viewport_x - x
          return if chars_before >= text.length
          text = text[chars_before..-1]
          x = @viewport_x
        end

        # Clip right side if needed
        if x + text.length > @viewport_x + @viewport_width
          visible_length = @viewport_x + @viewport_width - x
          text = text[0...visible_length] if visible_length > 0
        end

        # Write clipped text to terminal
        @terminal.write_at(x, y, text, color: color) if text && !text.empty?
      end
    end

    # Frame/viewport wrapper for FlowDiagram that handles:
    # - Centering the diagram within the viewport
    # - Panning via arrow keys (a/s/d/w)
    # - Viewport boundaries and clipping
    class FlowDiagramFrame
      attr_reader :width, :height

      def initialize(width, height)
        @width = width
        @height = height
        @flow_diagram = FlowDiagram.new(width, height)
        @pan_x = 0  # Horizontal pan offset
        @pan_y = 0  # Vertical pan offset
        @user_panned = false  # Track if user has manually panned
        @needs_clear = false  # Flag to indicate if we need to clear before rendering
      end

      # Update dimensions (called on resize)
      def resize(width, height)
        @width = width
        @height = height
        @flow_diagram.resize(width, height)
        # Reset user pan state on resize - next render will re-center
        @user_panned = false
        @needs_clear = true
      end

      # Pan the diagram
      def pan(dx, dy)
        @pan_x += dx
        @pan_y += dy
        @user_panned = true
        @needs_clear = true
      end

      # Check if frame needs clearing (for Controller to handle)
      def needs_clear?
        @needs_clear
      end

      # Mark as cleared (called by Controller after clearing)
      def mark_cleared
        @needs_clear = false
      end

      # Render the flow diagram with viewport management
      def render(terminal, stats_data, x_offset: 0, y_offset: 0)
        # Get diagram dimensions
        dims = @flow_diagram.prepare_layout(stats_data)
        diagram_width = dims[:width]
        diagram_height = dims[:height]

        # Calculate centering and panning offsets
        unless @user_panned
          # Auto-center if user hasn't manually panned
          center_x = diagram_width > 0 && diagram_width < @width ? (@width - diagram_width) / 2 : 0
          @pan_x = -center_x  # Pan is negative of offset

          # Vertical: If diagram fits with 1-line margin, use it. Otherwise start at zero.
          if diagram_height + 1 <= @height
            @pan_y = -1  # 1-line top margin
          else
            @pan_y = 0   # Start at top, no margin
          end
        end

        # Clamp pan offsets to valid range
        clamp_pan_offsets(diagram_width, diagram_height)

        # Calculate final render position
        # Pan offsets shift the viewport: negative pan moves content right/down
        final_x_offset = x_offset - @pan_x
        final_y_offset = y_offset - @pan_y

        # Create a clipped terminal wrapper that enforces viewport boundaries
        clipped_terminal = ClippedTerminal.new(terminal, x_offset, y_offset, @width, @height)

        # Render diagram through the clipped wrapper
        @flow_diagram.render(clipped_terminal, stats_data, x_offset: final_x_offset, y_offset: final_y_offset)
      end

      private

      # Clamp pan offsets based on diagram and viewport dimensions
      def clamp_pan_offsets(diagram_width, diagram_height)
        # Horizontal panning limits:
        # - Wide diagram: pan from 0 to (diagram_width - viewport_width)
        # - Narrow diagram: pan from (diagram_width - viewport_width) to 0 (negative values)
        delta_x = diagram_width - @width
        min_pan_x = [delta_x, 0].min  # Negative for narrow diagrams
        max_pan_x = [delta_x, 0].max  # Positive for wide diagrams

        # Vertical panning limits:
        # Min: If diagram fits with margin, -1. Otherwise 0 (no negative panning)
        # Max: Pan down until bottom of diagram at bottom of viewport
        #
        # When pan_y = -1: content at (y_offset + 1), giving 1-line top margin
        # When pan_y = 0:  content at y_offset, no margin
        # When pan_y = X:  content at (y_offset - X)
        #
        # For bottom alignment:
        #   (y_offset - pan_y) + diagram_height = y_offset + @height
        #   diagram_height - pan_y = @height
        #   pan_y = diagram_height - @height

        if diagram_height + 1 <= @height
          min_pan_y = -1  # Small diagram: allow 1-line top margin
        else
          min_pan_y = 0   # Large diagram: start at top, no negative panning
        end

        max_pan_y = diagram_height - @height  # Pan down until bottom of diagram at bottom of viewport

        # Ensure max is at least min (for small diagrams that fit entirely)
        max_pan_y = [max_pan_y, min_pan_y].max

        # Apply clamping
        @pan_x = [[@pan_x, min_pan_x].max, max_pan_x].min
        @pan_y = [[@pan_y, min_pan_y].max, max_pan_y].min
      end
    end
  end
end
