# frozen_string_literal: true

module Minigun
  module HUD
    # Aggregates and formats statistics from Pipeline for HUD display
    class StatsAggregator
      attr_reader :pipeline

      def initialize(pipeline)
        @pipeline = pipeline
        @last_update = Time.now
      end

      # Collect current statistics snapshot
      def collect
        stats = @pipeline.stats
        return nil unless stats

        # Identify bottleneck
        bottleneck_stage = stats.bottleneck

        # Collect stage data
        stages_data = stats.stages_in_order.map do |stage_stats|
          {
            stage_name: stage_stats.stage_name,
            type: determine_stage_type(stage_stats.stage),
            runtime: stage_stats.runtime,
            items_produced: stage_stats.items_produced,
            items_consumed: stage_stats.items_consumed,
            items_failed: stage_stats.items_failed,
            total_items: stage_stats.total_items,
            throughput: stage_stats.throughput,
            time_per_item: stage_stats.time_per_item,
            success_rate: stage_stats.success_rate,
            is_bottleneck: stage_stats == bottleneck_stage,
            start_time: stage_stats.start_time,
            end_time: stage_stats.end_time,
            latency: stage_stats.latency_data? ? {
              p50: stage_stats.p50 * 1000, # Convert to ms
              p90: stage_stats.p90 * 1000,
              p95: stage_stats.p95 * 1000,
              p99: stage_stats.p99 * 1000,
              samples: stage_stats.latency_samples.size
            } : nil
          }
        end

        # Get DAG structure
        dag_info = extract_dag_info

        # Pipeline summary
        {
          pipeline_name: @pipeline.name,
          runtime: stats.runtime,
          total_produced: stats.total_produced,
          total_consumed: stats.total_consumed,
          throughput: stats.throughput,
          stages: stages_data,
          dag: dag_info,
          bottleneck: bottleneck_stage ? {
            stage: bottleneck_stage.stage_name,
            throughput: bottleneck_stage.throughput
          } : nil,
          last_update: @last_update = Time.now
        }
      end

      private

      def extract_dag_info
        dag = @pipeline.dag
        return nil unless dag

        # Extract edges (connections between stages)
        edges = []
        dag.nodes.each do |from_stage|
          targets = dag.edges[from_stage] || []
          targets.each do |to_stage|
            edges << {
              from: from_stage.name,
              to: to_stage.name
            }
          end
        end

        {
          edges: edges,
          sources: dag.sources.map(&:name),
          terminals: dag.terminals.map(&:name)
        }
      end

      def determine_stage_type(stage)
        return :producer if stage.is_a?(Minigun::ProducerStage)
        return :consumer if stage.is_a?(Minigun::ConsumerStage)
        return :accumulator if stage.is_a?(Minigun::AccumulatorStage)
        return :router if stage.is_a?(Minigun::RouterStage)
        return :fork if stage.options[:execution] && %i[cow_fork ipc_fork].include?(stage.options[:execution][:type])

        :processor
      end
    end
  end
end
