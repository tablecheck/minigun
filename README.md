# Minigun go BRRR!!!

[![Build Status][build-img]][build-url]
[![Gem Version][rubygems-img]][rubygems-url]
[![License][license-img]][license-url]

Minigun is a lightweight framework for *rapid-fire* batch job processing.
In many common use cases, Minigun can replace database-backed job queue systems
like Sidekiq, Resque, Solid Queue, or Delayed Job.

### Why Minigun?

- **No database required**: Minigun operates entirely in Ruby memory, and does not
  require its own database or Redis instance to run jobs. (Of course, you'll need to
  bring your own database for the objects you're processing.)
- **Bulk-based processing**: Minigun is designed to both read and process objects
  in bulk batches, enabling bulk API calls and bulk database reads/upserts.
  The popular job queue systems (Sidekiq, etc.) process one object at a time.
- **Multi-process and multi-threaded**: Minigun forks multiple processes and run
  multiple threads to max-out CPU utilization on all cores and minimize I/0 wait times.
- **Idempotency**: Minigun jobs are designed to be idempotent, so you can safely
  re-run a job if it fails or is interrupted. When used correctly, you'll never have
  to worry about backed-up queues or lost jobs.
- **Framework agnostic**: Minigun is designed to work with any Ruby application, and
  does not require any specific database or application framework.

### Common Use Cases

- Bulk-ingesting or bulk-transmitting data from/to other databases, data warehouses, or APIs.
- Mass-emailing a target audience.
- Running a series of data transformations on each database row.
- Publishing objects from your database to Apache Kafka, RabbitMQ, or other message brokers.

- **Data Synchronization Between Systems**: Minigun can be used to sync data between different platforms, ensuring that data changes in one system are quickly mirrored in another without relying on slow, one-at-a-time job processing.
- **Scheduled Maintenance Tasks**: Ideal for running periodic maintenance jobs, such as database cleanup, re-indexing, or other repetitive tasks that require batch execution without clogging up a queue system.
- **Batch Data Import/Export**: Use Minigun to efficiently handle large-scale imports or exports of data between applications, such as moving data from a CRM to a data warehouse or vice versa.
- **ETL (Extract, Transform, Load) Processes**: Minigun excels at executing ETL tasks in bulk, making it perfect for processing large datasets that need to be extracted, transformed, and loaded into different systems.
- **Large-Scale Calculations and Aggregations**: Perform calculations or aggregations on large datasets, such as generating reports, updating analytical models, or recalculating metrics in bulk, all without database queue constraints.
- **Image Processing and File Transformations**: Batch process large volumes of images, videos, or other files for tasks like resizing, watermarking, transcoding, or any type of transformation needed en masse.
- **Batch Notification Systems**: Send out large-scale push notifications, SMS, or other types of alerts in bulk, reducing the load on your system compared to processing each notification individually.
- **Machine Learning Model Inference**: Run batch predictions using trained machine learning models, allowing for bulk data scoring and processing without the overhead of individual job queuing.
- **Data Cleaning and Deduplication**: Use Minigun for cleaning and deduplicating large datasets, automating the process of identifying and removing duplicates or invalid data entries at scale.
- **Cache Priming and Preloading**: Efficiently preload or refresh cache layers in batch mode, ensuring that data caches are primed and up-to-date without hitting performance bottlenecks from single-threaded updates.
- **High-Volume Web Scraping and API Polling**: Run web scraping tasks or periodic API polling at scale, processing the results in batches to avoid the pitfalls of traditional job queue systems that might overwhelm your infrastructure.
- **Real-Time Data Enrichment**: Enrich your data in real-time by integrating Minigun to pull in additional data points from external APIs in bulk, enhancing your records quickly and efficiently.
- **Bulk User Account Updates**: Perform updates to large numbers of user accounts simultaneously, such as applying permissions changes, resetting statuses, or rolling out new features.
- **Event Processing for IoT Devices**: Aggregate and process data from IoT devices in bulk, allowing for efficient management of incoming events or sensor data without relying on slower, individual job processing.
- **Batch Reconciliation Tasks**: Reconcile large volumes of transactions, payments, or inventory data in a single batch process, reducing manual workload and potential errors compared to line-by-line reconciliation.



using a Producer-Accumulator-Consumer pattern. Minigun uses forking and threads
to maximize system resource utilization.



Minigun is database and application agnostic, and does not require any database or app framework.

## Enough talk, show me the code!

Here is a trivial proof-of-concept--Minigun can do a lot more than this!

```ruby
require 'minigun'

class NewsletterSender
  include Minigun::Job

  max_threads { 10 }
  max_processes { 5 }

  def initialize(start_time)
    @start_time = start_time
  end

  # Define producer stage which yields each User object.
  produce do
    User.where("created_at >= ?", @start_time).each do |user|
      yield user
    end
  end

  # Define consumer stage which sends the newsletter to each User.
  consume do |user|
    NewsletterMailer.my_newsletter(user).deliver_now
  end
end

NewsletterSender.new(1.day.ago).go_brrr!
```

## How does it work

- **Producer Stage:** Iterate over a collection (e.g. Users) and put the objects in the Accumulator.
- **Accumulator Stage:** Wait until a batch of N objects have been accumulated, then fork a Consumer process and pass it the batch.
- **Consumer Stage:** Iterate over the batch and perform an action (e.g. send an email).

## Queues, Batches, etc.



# Run the Minigun job
NewsletterSender.new.go_brrr!


Use cases for Minigun include:
- Send a large number of emails to users in a target audience.

## Multiple queues
  
  
### Configuration

Minigun supports both global and per-job configuration (per-job overrides global).

#### Global Config

```ruby
# in an initalizer

Minigun.configure do |config|
  config.logger = Rails.logger
  config.log_format = :json
  config.max_threads = ENV['RAILS_MAX_THREADS']&.to_i || 5
end
```


| Name                     | Type                 | Usage                                                                                                                                                                                                         |
|--------------------------|----------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `logger`                 | `Logger`             | The Logger instance to use.                                                                                                                                                                                   |
| `log_format`             | `Symbol`             | The format of the log message to use. Values: `:plain` (default), `:json`.                                                                                                                                    |
| `log_writer`             | `Minigun::LogWriter` | Used to deeply customize the log messsage. Mutually exclusive with `log_format`                                                                                                                               |
| `consumer_max_processes` | `Integer`            | The maximum number of consumer processes to fork. Aliased as `max_processes`. Defaults `ENV['MINIGUN_MAX_PROCESSES']` or `ENV['WEB_CONCURRENCY']` or `1`. Values `nil`, `false`, `<= 0` will disable forking. |
| `max_threads`            | `Integer`            | The maximum number of threads to use in both the producer and consumer. Defaults to `ENV['MINIGUN_MAX_THREADS']` or `ENV['RAILS_MAX_THREADS']` or `5`.                                                        |
| `producer_max_threads`   | `Integer`            | The maximum number of producer threads to use. Overrides `max_threads` for the producer only.                                                                                                                 |
| `consumer_max_threads`   | `Integer`            | The maximum number of consumer threads to use. Overrides `max_threads` for the consumer only.                                                                                                                 |
| `max_retries`            | `Integer`            | The maximum number of retries to attempt when fetching IDs from a queue. Default `0` (no retries).                                                                                                            |
| `producer_max_retries`   | `Integer`            | The maximum number of producer threads to use. Overrides `max_retries` for the producer only.                                                                                                                 |
| `consumer_max_retries`   | `Integer`            | The maximum number of consumer threads to use. Overrides `max_retries` for the consumer only.                                                                                                                 |



### Installation

Add to your application's `Gemfile`:

```ruby
gem 'minigun'
```

Then make a `class` which extends `Minigun::Job` and implements the `produce` and `consume` methods.

### Compatibility

Ruby version support:
- Ruby (MRI) 2.7+
- Rails 6.0+
- JRuby 9.4+
- TruffleRuby 23+

Minigun requires a forking OS (Linux, Mac) in order to support forking.
If not available (Windows) it will gracefully degrade to non-forking mode.

### Configuration

Minigun supports both global and 



### Special Thanks

Special thanks to [Alexander Nicholson](https://alexander.town/) for the original idea for Minigun forking.

[github-new-issue]: https://github.com/tablecheck/minigun/issues/new
[github-new-discussion]: https://github.com/tablecheck/minigun/discussions/new
[github-contributors]: https://github.com/tablecheck/minigun/graphs/contributors
[build-img]: https://github.com/tablecheck/minigun/actions/workflows/test.yml/badge.svg
[build-url]: https://github.com/tablecheck/minigun/actions
[rubygems-img]: https://badge.fury.io/rb/minigun.svg
[rubygems-url]: http://badge.fury.io/rb/minigun
[license-img]: https://img.shields.io/badge/license-MIT-green.svg
[license-url]: https://www.opensource.org/licenses/MIT
