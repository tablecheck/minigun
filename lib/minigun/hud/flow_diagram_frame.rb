# frozen_string_literal: true

module Minigun
  module HUD
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

        # Calculate centering and panning offsets
        unless @user_panned
          # Auto-center if user hasn't manually panned
          center_x = diagram_width > 0 && diagram_width < @width ? (@width - diagram_width) / 2 : 0
          @pan_x = -center_x  # Pan is negative of offset
          @pan_y = -1  # 1-line top margin
        end

        # Clamp pan offsets to valid range
        clamp_pan_offsets(diagram_width)

        # Calculate final render position
        # Pan offsets shift the viewport: negative pan moves content right/down
        final_x_offset = x_offset - @pan_x
        final_y_offset = y_offset - @pan_y

        # Render diagram at calculated position
        @flow_diagram.render(terminal, stats_data, x_offset: final_x_offset, y_offset: final_y_offset)
      end

      private

      # Clamp pan offsets based on diagram and viewport dimensions
      def clamp_pan_offsets(diagram_width)
        # Horizontal panning limits:
        # - Wide diagram: pan from 0 to (diagram_width - viewport_width)
        # - Narrow diagram: pan from (diagram_width - viewport_width) to 0 (negative values)
        delta_x = diagram_width - @width
        min_pan_x = [delta_x, 0].min  # Negative for narrow diagrams
        max_pan_x = [delta_x, 0].max  # Positive for wide diagrams

        # Vertical panning limits:
        # - Top: Allow pan_y = -1 for 1-line top margin
        # - Bottom: Allow panning to see full diagram height
        # Note: We don't have diagram height here, so just enforce minimum
        min_pan_y = -1  # Always allow 1-line top margin
        max_pan_y = 100  # Arbitrary large value, actual clamping happens in FlowDiagram

        # Apply clamping
        @pan_x = [[@pan_x, min_pan_x].max, max_pan_x].min
        @pan_y = [[@pan_y, min_pan_y].max, max_pan_y].min
      end
    end
  end
end
