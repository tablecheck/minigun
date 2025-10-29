# frozen_string_literal: true

require 'tsort'

module Minigun
  # Directed Acyclic Graph for stage routing using Ruby's TSort
  class DAG
    include TSort

    attr_reader :nodes, :edges, :reverse_edges

    def initialize(nodes: [], edges: nil, reverse_edges: nil)
      @nodes = nodes.dup # Track insertion order
      @edges = edges ? edges.dup : Hash.new { |h, k| h[k] = [] } # stage_name => [downstream_stage_names]
      @reverse_edges = reverse_edges ? reverse_edges.dup : Hash.new { |h, k| h[k] = [] } # stage_name => [upstream_stage_names]
    end

    # Duplicate this DAG
    def dup
      DAG.new(
        nodes: @nodes.dup,
        edges: Hash.new { |h, k| h[k] = [] }.merge(@edges.transform_values(&:dup)),
        reverse_edges: Hash.new { |h, k| h[k] = [] }.merge(@reverse_edges.transform_values(&:dup))
      )
    end

    # Add a node (stage) to the graph
    def add_node(name)
      @nodes << name unless @nodes.include?(name)
    end

    # Add an edge from source to target
    def add_edge(from, to)
      add_node(from)
      add_node(to)

      # Check for circular dependencies
      raise Minigun::Error, "Circular dependency detected: adding edge #{from} -> #{to} would create a cycle" if would_create_cycle?(from, to)

      @edges[from] << to unless @edges[from].include?(to)
      @reverse_edges[to] << from unless @reverse_edges[to].include?(from)
    end

    # Remove an edge from source to target
    def remove_edge(from, to)
      @edges[from].delete(to)
      @reverse_edges[to].delete(from)
    end

    # Get all downstream stages from a given stage
    def downstream(name)
      @edges[name]
    end

    # Get all upstream stages to a given stage
    def upstream(name)
      @reverse_edges[name]
    end

    # Check if a stage is a terminal node (no downstream)
    def terminal?(name)
      downstream(name).empty?
    end

    # Check if a stage is a source node (no upstream)
    def source?(name)
      upstream(name).empty?
    end

    # Get all terminal (leaf) nodes
    def terminals
      @nodes.select { |n| terminal?(n) }
    end

    # Get all source (root) nodes
    def sources
      @nodes.select { |n| source?(n) }
    end

    # Validate that all referenced nodes exist
    def validate!
      # First check that all edges point to existing nodes
      @edges.each_value do |targets|
        targets.each do |target|
          raise Minigun::Error, "Stage routes to non-existent stage '#{target}'" unless @nodes.include?(target)
        end
      end

      # Check for cycles using TSort
      begin
        tsort # This will raise TSort::Cyclic if there's a cycle
      rescue TSort::Cyclic => e
        raise Minigun::Error, "Pipeline contains a cycle: #{e.message}"
      end
    end

    # Topological sort (provided by TSort)
    # Returns nodes in dependency order (sources first, sinks last)
    def topological_sort
      tsort.reverse # TSort returns reverse order, so we flip it
    rescue TSort::Cyclic
      [] # Return empty if cyclic
    end

    # Build default sequential routing
    # Connects nodes in the order they were added
    def build_sequential!
      @nodes.each_with_index do |node, index|
        next_node = @nodes[index + 1]
        add_edge(node, next_node) if next_node
      end
    end

    # Fill in missing sequential connections
    # If a node has no downstream edges, connect it to the next node in order
    def fill_sequential_gaps!
      @nodes.each_with_index do |node, index|
        if downstream(node).empty? && index < @nodes.size - 1
          next_node = @nodes[index + 1]
          add_edge(node, next_node)
        end
      end
    end

    # Get all sibling nodes (nodes that share at least one upstream parent)
    def siblings(node)
      upstream(node).flat_map { |parent| downstream(parent) } - [node]
    end

    # Check if adding edge from->to would create a cycle
    # Returns true if 'to' can already reach 'from' (which would create a cycle)
    def would_create_cycle?(from, to)
      visited = Set.new
      queue = [to]

      while queue.any?
        current = queue.shift
        next if visited.include?(current)

        visited.add(current)

        return true if current == from

        queue.concat(downstream(current))
      end

      false
    end

    # Check if two nodes are fan-out siblings (share upstream and don't connect to each other)
    def fan_out_siblings?(node1, node2)
      return false unless siblings(node1).include?(node2)

      # They're siblings - check if one routes to the other
      !downstream(node1).include?(node2) && !downstream(node2).include?(node1)
    end

    # Get execution order groups (stages that can run in parallel)
    def execution_groups
      in_degree = Hash.new(0)
      @nodes.each { |n| in_degree[n] = upstream(n).size }

      groups = []
      remaining = @nodes.dup

      until remaining.empty?
        # Find all nodes with no incoming edges
        current_group = remaining.select { |n| in_degree[n] == 0 }
        break if current_group.empty? # Cycle detected

        groups << current_group

        # Remove this group and update in-degrees
        current_group.each do |node|
          remaining.delete(node)
          downstream(node).each { |child| in_degree[child] -= 1 }
        end
      end

      groups
    end

    # Debug: Print the graph
    def to_s
      lines = ["DAG with #{@nodes.size} nodes:"]
      @edges.each do |from, targets|
        lines << if targets.empty?
                   "  #{from} → (terminal)"
                 else
                   "  #{from} → #{targets.join(', ')}"
                 end
      end
      lines.join("\n")
    end

    # Required by TSort: iterate over all nodes
    def tsort_each_node(&)
      @nodes.each(&)
    end

    # Required by TSort: iterate over children of a given node
    def tsort_each_child(node, &)
      @edges[node].each(&)
    end
  end
end
