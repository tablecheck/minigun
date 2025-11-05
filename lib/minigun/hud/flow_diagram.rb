# frozen_string_literal: true

require 'set'

module Minigun
  module HUD
    # Renders pipeline DAG as animated ASCII flow diagram with boxes and connections
    class FlowDiagram

      def initialize(_frame_width, _frame_height)
        @animation_frame = 0
        @width = 0  # Actual width of diagram content
        @height = 0  # Actual height of diagram content
      end

      # Update dimensions (called on resize)
      def resize(_frame_width, _frame_height)
        # Dimensions not used - diagram renders in coordinate space starting at (0,0)
        # FlowDiagramFrame handles viewport sizing and clipping via ClippedTerminal
      end

      # Calculate layout and return diagram dimensions
      def prepare_layout(stats_data)
        return { width: 0, height: 0 } unless stats_data && stats_data[:stages]

        stages = stats_data[:stages]
        dag = stats_data[:dag]
        return { width: 0, height: 0 } if stages.empty?

        # Filter out router stages (internal implementation details)
        visible_stages = stages.reject { |s| s[:type] == :router }

        # Calculate layout (boxes with positions) using DAG structure
        @cached_layout = calculate_layout(visible_stages, dag)
        @cached_visible_stages = visible_stages
        @cached_dag = dag

        # Calculate actual diagram content height
        unless @cached_layout.empty?
          max_y = @cached_layout.values.map { |pos| pos[:y] + pos[:height] }.max
          @height = max_y
        else
          @height = 0
        end

        # Return diagram dimensions
        { width: @width, height: @height }
      end

      # Render the flow diagram to terminal at given position
      def render(terminal, stats_data, x_offset: 0, y_offset: 0)
        # If prepare_layout wasn't called, do it now
        prepare_layout(stats_data) unless @cached_layout

        return unless @cached_layout

        # Render connections first (so they appear behind boxes)
        render_connections(terminal, @cached_layout, @cached_visible_stages, @cached_dag, x_offset, y_offset)

        # Render stage boxes
        @cached_layout.each do |stage_name, pos|
          stage_data = @cached_visible_stages.find { |s| s[:stage_name] == stage_name }
          next unless stage_data

          render_stage_box(terminal, stage_data, pos, x_offset, y_offset)
        end

        # Update animation
        @animation_frame = (@animation_frame + 1) % 60

        # Clear cached layout for next frame
        @cached_layout = nil
        @cached_visible_stages = nil
        @cached_dag = nil
      end

      private

      # Calculate box positions using DAG-based layered layout
      def calculate_layout(stages, dag)
        layout = {}
        box_width = 14
        box_height = 3
        layer_height = 5  # Vertical spacing between layers (room for connection spine)
        box_spacing = 2   # Horizontal spacing between boxes

        # Calculate layers based on DAG topological depth
        layers = calculate_layers_from_dag(stages, dag)

        # Find maximum layer width to center layers relative to each other
        max_layer_width = layers.map do |layer_stages|
          (layer_stages.size * box_width) + ((layer_stages.size - 1) * box_spacing)
        end.max || 0

        # Position stages in each layer (centered relative to each other)
        layers.each_with_index do |layer_stages, layer_idx|
          y = 0 + (layer_idx * layer_height)

          # Calculate total width needed for this layer
          total_width = (layer_stages.size * box_width) + ((layer_stages.size - 1) * box_spacing)

          # Center this layer relative to the widest layer
          start_x = (max_layer_width - total_width) / 2

          # Position each stage in the layer horizontally
          layer_stages.each_with_index do |stage_name, stage_idx|
            x = start_x + (stage_idx * (box_width + box_spacing))

            layout[stage_name] = {
              x: x,
              y: y,
              width: box_width,
              height: box_height,
              layer: layer_idx
            }
          end
        end

        # Normalize: shift entire diagram left so leftmost item is at x=0
        unless layout.empty?
          min_x = layout.values.map { |pos| pos[:x] }.min
          layout.each { |name, pos| pos[:x] -= min_x }

          # Store actual diagram width
          max_x = layout.values.map { |pos| pos[:x] + pos[:width] }.max
          @width = max_x
        else
          @width = 0
        end

        layout
      end

      # Calculate layers using topological depth from DAG
      def calculate_layers_from_dag(stages, dag)
        stage_names = stages.map { |s| s[:stage_name] }

        # Return single vertical stack if no DAG info
        return stage_names.map { |name| [name] } unless dag && dag[:edges]

        # Build adjacency lists
        edges = dag[:edges] || []
        sources = dag[:sources] || []

        # Bridge router stages: when filtering them out, connect their inputs to their outputs
        # This preserves connectivity after removing intermediate router nodes
        bridged_edges = []
        edges.each do |edge|
          from_visible = stage_names.include?(edge[:from])
          to_visible = stage_names.include?(edge[:to])

          if from_visible && to_visible
            # Both endpoints visible, keep edge as-is
            bridged_edges << edge
          elsif !from_visible && !to_visible
            # Both hidden (routers), skip
            next
          elsif from_visible && !to_visible
            # Source visible, target is router - find router's outputs
            router_outputs = edges.select { |e| e[:from] == edge[:to] }
            router_outputs.each do |router_edge|
              if stage_names.include?(router_edge[:to])
                # Bridge: connect source directly to router's output
                bridged_edges << { from: edge[:from], to: router_edge[:to] }
              end
            end
          elsif !from_visible && to_visible
            # Source is router, target visible - find router's inputs
            router_inputs = edges.select { |e| e[:to] == edge[:from] }
            router_inputs.each do |router_edge|
              if stage_names.include?(router_edge[:from])
                # Bridge: connect router's input directly to target
                bridged_edges << { from: router_edge[:from], to: edge[:to] }
              end
            end
          end
        end

        edges = bridged_edges.uniq

        # Build forward edges map (from -> [to1, to2, ...])
        forward_edges = Hash.new { |h, k| h[k] = [] }
        edges.each { |e| forward_edges[e[:from]] << e[:to] }

        # Build reverse edges map (to -> [from1, from2, ...])
        reverse_edges = Hash.new { |h, k| h[k] = [] }
        edges.each { |e| reverse_edges[e[:to]] << e[:from] }

        # Calculate depth for each stage using longest path from sources
        depths = {}

        # BFS to assign depths
        queue = sources.select { |s| stage_names.include?(s) }.map { |s| [s, 0] }

        while !queue.empty?
          stage, depth = queue.shift

          # Update depth if this path is longer
          if !depths[stage] || depth > depths[stage]
            depths[stage] = depth

            # Queue downstream stages
            forward_edges[stage].each do |next_stage|
              queue << [next_stage, depth + 1]
            end
          end
        end

        # Assign depth 0 to any stages not reached (orphans)
        stage_names.each do |name|
          depths[name] ||= 0
        end

        # Group stages by depth into layers
        max_depth = depths.values.max || 0
        layers = Array.new(max_depth + 1) { [] }

        stage_names.each do |name|
          layers[depths[name]] << name
        end

        layers.reject(&:empty?)
      end

      # Render connections between stages using DAG edges
      def render_connections(terminal, layout, stages, dag, x_offset, y_offset)
        return unless dag && dag[:edges]

        stage_map = stages.map { |s| [s[:stage_name], s] }.to_h
        stage_names = stages.map { |s| s[:stage_name] }

        # Bridge router stages to preserve connectivity
        all_edges = dag[:edges]
        bridged_edges = []

        all_edges.each do |edge|
          from_visible = stage_names.include?(edge[:from])
          to_visible = stage_names.include?(edge[:to])

          if from_visible && to_visible
            bridged_edges << edge
          elsif from_visible && !to_visible
            # Source visible, target is router - find router's outputs
            router_outputs = all_edges.select { |e| e[:from] == edge[:to] }
            router_outputs.each do |router_edge|
              if stage_names.include?(router_edge[:to])
                bridged_edges << { from: edge[:from], to: router_edge[:to] }
              end
            end
          elsif !from_visible && to_visible
            # Source is router, target visible - find router's inputs
            router_inputs = all_edges.select { |e| e[:to] == edge[:from] }
            router_inputs.each do |router_edge|
              if stage_names.include?(router_edge[:from])
                bridged_edges << { from: router_edge[:from], to: edge[:to] }
              end
            end
          end
        end

        edges = bridged_edges.uniq

        # Group edges by source and target to detect fan-out and fan-in
        edges_by_source = edges.group_by { |e| e[:from] }
        edges_by_target = edges.group_by { |e| e[:to] }

        # Track which edges have been rendered
        rendered_edges = Set.new

        # First pass: Render fan-out connections (one source to multiple targets)
        edges_by_source.each do |from_name, from_edges|
          next if from_edges.size <= 1  # Skip single connections for now

          from_pos = layout[from_name]
          next unless from_pos

          stage_data = stage_map[from_name]
          next unless stage_data

          target_names = from_edges.map { |e| e[:to] }
          target_positions = target_names.map { |name| layout[name] }.compact
          next if target_positions.empty?

          render_fanout_connection(terminal, from_pos, target_positions, stage_data, x_offset, y_offset)
          from_edges.each { |e| rendered_edges.add(e) }
        end

        # Second pass: Render fan-in connections (multiple sources to one target)
        edges_by_target.each do |to_name, to_edges|
          next if to_edges.size <= 1  # Skip single connections for now

          to_pos = layout[to_name]
          next unless to_pos

          source_names = to_edges.map { |e| e[:from] }
          source_positions = source_names.zip(to_edges).map do |name, edge|
            next if rendered_edges.include?(edge)
            layout[name]
          end.compact
          next if source_positions.empty?

          # Get stage data from first source for color
          first_source = to_edges.first[:from]
          stage_data = stage_map[first_source] || {}

          render_fanin_connection(terminal, source_positions, to_pos, stage_data, x_offset, y_offset)
          to_edges.each { |e| rendered_edges.add(e) }
        end

        # Third pass: Render remaining single connections
        edges.each do |edge|
          next if rendered_edges.include?(edge)

          from_pos = layout[edge[:from]]
          to_pos = layout[edge[:to]]
          next unless from_pos && to_pos

          stage_data = stage_map[edge[:from]]
          next unless stage_data

          render_connection_line(terminal, from_pos, to_pos, stage_data, x_offset, y_offset)
        end
      end

      # Draw a fan-out connection (one source to multiple targets)
      def render_fanout_connection(terminal, from_pos, target_positions, stage_data, x_offset, y_offset)
        from_x = from_pos[:x] + from_pos[:width] / 2
        from_y = from_pos[:y] + from_pos[:height]

        # Check if connection is active
        active = stage_data[:throughput] && stage_data[:throughput] > 0
        color = active ? Theme.primary : Theme.muted

        # Calculate split point (horizontal spine where fan-out occurs)
        first_target_y = target_positions.first[:y]
        split_y = from_y + 1

        # Draw vertical line from source to split point
        terminal.write_at(x_offset + from_x, y_offset + from_y, "│", color: color)

        # Get X positions of all targets (sorted)
        target_xs = target_positions.map { |pos| pos[:x] + pos[:width] / 2 }.sort
        leftmost_x = target_xs.first
        rightmost_x = target_xs.last

        # Check if there's a target directly below the source
        has_center_target = target_xs.include?(from_x)

        # Draw horizontal spine with junctions
        # Pattern with center target:  ┌───────────────┼───────────────┐
        # Pattern without center:      ┌───────────────┴───────────────┐
        (leftmost_x..rightmost_x).each do |x|
          # Determine the proper box-drawing character
          char = if x == leftmost_x
                   # Left corner
                   "┌"
                 elsif x == rightmost_x
                   # Right corner
                   "┐"
                 elsif x == from_x
                   # Source position: ┼ if target below, ┴ if not
                   has_center_target ? "┼" : "┴"
                 else
                   # Regular horizontal line (spine)
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

      # Draw a fan-in connection (multiple sources to one target)
      def render_fanin_connection(terminal, source_positions, to_pos, stage_data, x_offset, y_offset)
        to_x = to_pos[:x] + to_pos[:width] / 2
        to_y = to_pos[:y]

        # Check if connection is active
        active = stage_data[:throughput] && stage_data[:throughput] > 0
        color = active ? Theme.primary : Theme.muted

        # Calculate merge point (where horizontal lines converge)
        # Place it 1 line above the target
        merge_y = to_y - 1

        # Get source X positions (sorted)
        source_data = source_positions.map do |pos|
          {
            x: pos[:x] + pos[:width] / 2,
            y: pos[:y] + pos[:height]
          }
        end.sort_by { |s| s[:x] }

        # Draw vertical lines from each source down to merge level
        # Then turn inward with corners
        source_data.each do |source|
          # Vertical line from source to turn point
          (source[:y]...merge_y).each do |y|
            char = if active
                     offset = (@animation_frame / 4) % Theme::FLOW_CHARS.length
                     phase = (y - source[:y] + offset) % Theme::FLOW_CHARS.length
                     Theme::FLOW_CHARS[phase]
                   else
                     "│"
                   end

            terminal.write_at(x_offset + source[:x], y_offset + y, char, color: color)
          end

          # Corner at turn point
          if source[:x] < to_x
            # Left source: turn right with └
            terminal.write_at(x_offset + source[:x], y_offset + merge_y, "└", color: color)

            # Horizontal line from corner to center (or near target)
            ((source[:x] + 1)...to_x).each do |x|
              char = if active
                       offset = (@animation_frame / 4) % 4
                       ["─", "╌", "┄", "┈"][offset]
                     else
                       "─"
                     end

              terminal.write_at(x_offset + x, y_offset + merge_y, char, color: color)
            end
          elsif source[:x] > to_x
            # Right source: turn left with ┘
            terminal.write_at(x_offset + source[:x], y_offset + merge_y, "┘", color: color)

            # Horizontal line from corner to center (or near target)
            ((to_x + 1)...source[:x]).each do |x|
              char = if active
                       offset = (@animation_frame / 4) % 4
                       ["─", "╌", "┄", "┈"][offset]
                     else
                       "─"
                     end

              terminal.write_at(x_offset + x, y_offset + merge_y, char, color: color)
            end
          else
            # Source directly above target - just draw vertical line
            # (already drawn above)
          end
        end

        # Draw junction at the converge point (center X position)
        # Use ┼ if there's a source directly above, ┬ if not
        has_center_source = source_data.any? { |s| s[:x] == to_x }
        junction_char = has_center_source ? "┼" : "┬"
        terminal.write_at(x_offset + to_x, y_offset + merge_y, junction_char, color: color)
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

        # Icon only (no status indicator for clean layout)
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

        # Middle line with content (icon + name, no status indicator)
        content = "#{icon} #{display_name}"
        padding_left = [(w - content.length - 2) / 2, 1].max
        padding_right = [w - content.length - padding_left - 2, 1].max

        terminal.write_at(x_offset + x, y_offset + y + 1,
                         "│" + (" " * padding_left) + content + (" " * padding_right) + "│",
                         color: color)

        # Bottom border (no throughput for clean layout)
        bottom_line = "└" + ("─" * (w - 2)) + "┘"
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
