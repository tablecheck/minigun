#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/minigun'

# Example 3: Fan-Out Pattern
# One producer feeds multiple independent consumers
class FanOutPipeline
  include Minigun::DSL

  max_threads 4

  attr_accessor :emails, :sms_messages, :push_notifications

  def initialize
    @emails = []
    @sms_messages = []
    @push_notifications = []
    @mutex = Mutex.new
  end

  pipeline do
    # Producer fans out to three consumers
    producer :generate_notifications, to: %i[email_sender sms_sender push_sender] do |output|
      users = [
        { id: 1, name: 'Alice', message: 'Hello Alice' },
        { id: 2, name: 'Bob', message: 'Hello Bob' },
        { id: 3, name: 'Charlie', message: 'Hello Charlie' },
        { id: 4, name: 'Diana', message: 'Hello Diana' },
        { id: 5, name: 'Eve', message: 'Hello Eve' },
        { id: 6, name: 'Frank', message: 'Hello Frank' },
        { id: 7, name: 'Grace', message: 'Hello Grace' },
        { id: 8, name: 'Hank', message: 'Hello Hank' }
      ]
      users.each do |user|
        output << user
        sleep 0.05 if ENV['MINIGUN_HUD'] == '1' # Slow down for HUD visualization
      end
    end

    # Email consumer
    consumer :email_sender, threads: 2 do |user|
      sleep rand(0.02..0.05) if ENV['MINIGUN_HUD'] == '1' # Simulate work
      @mutex.synchronize do
        emails << "Email to #{user[:name]}: #{user[:message]}"
      end
    end

    # SMS consumer
    consumer :sms_sender, threads: 2 do |user|
      sleep rand(0.03..0.06) if ENV['MINIGUN_HUD'] == '1' # Simulate work
      @mutex.synchronize do
        sms_messages << "SMS to #{user[:name]}: #{user[:message]}"
      end
    end

    # Push notification consumer
    consumer :push_sender, threads: 2 do |user|
      sleep rand(0.01..0.04) if ENV['MINIGUN_HUD'] == '1' # Simulate work
      @mutex.synchronize do
        push_notifications << "Push to #{user[:name]}: #{user[:message]}"
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  pipeline = FanOutPipeline.new

  if ENV['MINIGUN_HUD'] == '1'
    require_relative '../lib/minigun/hud'
    puts 'Starting fan-out pipeline with HUD...'
    puts 'Press [q] to quit the HUD when done'
    sleep 1
    Minigun::HUD.run_with_hud(pipeline)
  else
    pipeline.run
  end

  puts 'Fan-Out Pipeline Results:'
  puts "\nEmails sent: #{pipeline.emails.size}"
  pipeline.emails.each { |e| puts "  - #{e}" }

  puts "\nSMS sent: #{pipeline.sms_messages.size}"
  pipeline.sms_messages.each { |s| puts "  - #{s}" }

  puts "\nPush notifications sent: #{pipeline.push_notifications.size}"
  pipeline.push_notifications.each { |p| puts "  - #{p}" }
end
