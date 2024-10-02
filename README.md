![Minigun](https://github.com/user-attachments/assets/0c9ee9ed-8592-43f7-bdb5-1abe0c84210e)

# Minigun go BRRR

Minigun is a lightweight framework for rapid-fire batch job processing
using a Producer-Accumulator-Consumer pattern. Minigun uses forking and threads
to maximize system resource utilization.
  
In many use cases, Minigun can replace queue systems like Resque, Solid Queue, or Sidekiq.
Minigun itself is run entire in Ruby's memory, and is database and application agnostic.

## Enough talk, show me the code!

Here is a trivial proof-of-concept--Minigun can do a lot more than this!

```ruby
require 'minigun'

class NewsletterSender
  include Minigun::Runner

  max_threads 10
  max_consumer_forks 5

  def initialize(start_time: Time.now - 1.day)
    @start_time = start_time
  end

  producer do
    # fix this
    User.where("created_at >= ?", @start_time)
        .not.where()
        .each do |user|
      produce(user)
    end
  end
  
  consumer do |user|
    NewsletterMailer.my_newsletter(user).deliver_now
    user.update(newsletter_sent_at: Time.now)
  end
end

# Run the Minigun job
NewsletterSender.new.go_brrr!


Use cases for Minigun include:
- Send a large number of emails to users in a target audience.


## Installation

```cmd
gem install minigun
```

### Special Thanks

Alex Nicholson for the original idea for Minigun.
